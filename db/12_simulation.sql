-- 12_simulation.sql
-- Time-travel simulation. The database keeps its own clock (dbo.SimClock) and can advance day by day:
--   each simulated day: purchase orders arrive, customers buy (demand is generated from recent history),
--   stock is reduced, shortages become lost sales, and the clock moves forward.
-- Scenarios: demand spike, supplier delay, price/cost change. A reset procedure restores the starting state.

USE InventoryDB;
GO

CREATE TABLE dbo.SimEvent (
    EventId     int IDENTITY(1,1) NOT NULL CONSTRAINT PK_SimEvent PRIMARY KEY,
    EventType   varchar(20)   NOT NULL
        CONSTRAINT CK_SimEvent_Type CHECK (EventType IN ('DEMAND_SPIKE', 'SUPPLIER_DELAY', 'PRICE_CHANGE')),
    SimDate     date          NOT NULL,                 -- simulated day when the event was created
    StartDate   date          NULL,
    EndDate     date          NULL,
    ProductId   int           NULL CONSTRAINT FK_SimEvent_Product  REFERENCES dbo.Product (ProductId),
    CategoryId  int           NULL CONSTRAINT FK_SimEvent_Category REFERENCES dbo.Category (CategoryId),
    SupplierId  int           NULL CONSTRAINT FK_SimEvent_Supplier REFERENCES dbo.Supplier (SupplierId),
    Multiplier  decimal(5,2)  NULL,
    DelayDays   int           NULL,
    Description nvarchar(300) NOT NULL,
    CreatedBy   nvarchar(128) NOT NULL CONSTRAINT DF_SimEvent_By DEFAULT (SUSER_SNAME()),
    CreatedAt   datetime2(0)  NOT NULL CONSTRAINT DF_SimEvent_At DEFAULT (SYSUTCDATETIME())
);
GO

-- Snapshot of product cost/price so a reset can undo price-change scenarios.
CREATE TABLE dbo.ProductBaseline (
    ProductId int           NOT NULL CONSTRAINT PK_ProductBaseline PRIMARY KEY
                            CONSTRAINT FK_PB_Product REFERENCES dbo.Product (ProductId),
    UnitCost  decimal(10,2) NOT NULL,
    UnitPrice decimal(10,2) NOT NULL
);
GO
INSERT dbo.ProductBaseline (ProductId, UnitCost, UnitPrice)
SELECT ProductId, UnitCost, UnitPrice FROM dbo.Product;
GO

-- ------------------------------------------------------------------ One simulated day (internal; no transaction of its own)
CREATE OR ALTER PROCEDURE dbo.usp_SimStep
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @D date = (SELECT SimDate FROM dbo.SimClock WHERE ClockId = 1);
    DECLARE @DowFactor float = CASE DATEDIFF(DAY, '19000101', @D) % 7
                                   WHEN 4 THEN 1.10 WHEN 5 THEN 1.30 WHEN 6 THEN 1.25 ELSE 1.0 END;
    DECLARE @DayNo int = DATEDIFF(DAY, '20241101', @D);

    -- 1. Orders placed on an earlier day are now on their way
    UPDATE dbo.PurchaseOrder SET Status = 'IN_TRANSIT'
    WHERE Status = 'APPROVED' AND OrderDate < @D;

    -- 2. Orders due today (or overdue) arrive in the morning and go into stock
    DECLARE @Po int;
    DECLARE due CURSOR LOCAL FAST_FORWARD FOR
        SELECT PoId FROM dbo.PurchaseOrder
        WHERE Status IN ('APPROVED', 'IN_TRANSIT') AND ExpectedDate <= @D
        ORDER BY ExpectedDate, PoId;
    OPEN due;
    FETCH NEXT FROM due INTO @Po;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.usp_ReceivePo @PoId = @Po;
        FETCH NEXT FROM due INTO @Po;
    END;
    CLOSE due;
    DEALLOCATE due;

    -- 3. Today's demand per item: recent average x weekday factor x active spike x random noise.
    --    1.0929 is the mean of the weekday factors, so the 28-day average is not double counted.
    ;WITH pairs AS (
        SELECT i.ProductId, i.WarehouseId, i.OnHand, p.UnitPrice, p.CategoryId, cat.ParentCategoryId,
               ISNULL(d.AvgDaily28, 0) AS Avg28
        FROM dbo.Inventory AS i
        JOIN dbo.Product   AS p   ON p.ProductId = i.ProductId
        JOIN dbo.Category  AS cat ON cat.CategoryId = p.CategoryId
        LEFT JOIN dbo.vw_ItemDemandStats AS d ON d.ProductId = i.ProductId AND d.WarehouseId = i.WarehouseId
    ),
    dem AS (
        SELECT pr.ProductId, pr.WarehouseId, pr.OnHand, pr.UnitPrice,
               CAST(ROUND(pr.Avg28 / 1.0929 * @DowFactor * ISNULL(ev.Mult, 1.0)
                          * (0.65 + 0.70 * ((ABS(CAST(CHECKSUM(pr.ProductId, pr.WarehouseId, @DayNo, 77) AS bigint)) % 1000) / 1000.0))
                    , 0) AS int) AS Demand
        FROM pairs AS pr
        OUTER APPLY (SELECT MAX(CAST(e.Multiplier AS float)) AS Mult
                     FROM dbo.SimEvent AS e
                     WHERE e.EventType = 'DEMAND_SPIKE'
                       AND e.StartDate <= @D AND e.EndDate >= @D
                       AND ( (e.ProductId IS NULL AND e.CategoryId IS NULL)
                             OR e.ProductId = pr.ProductId
                             OR e.CategoryId IN (pr.CategoryId, pr.ParentCategoryId) )) AS ev
    )
    SELECT ProductId, WarehouseId, UnitPrice, Demand,
           CASE WHEN Demand <= OnHand THEN Demand ELSE OnHand END AS Sold
    INTO #Day
    FROM dem;

    -- 4. Record sales (shortfall becomes lost sales), reduce stock, log movements
    INSERT dbo.SalesDaily (SaleDate, ProductId, WarehouseId, Quantity, LostQty, Revenue, PromoFlag)
    SELECT @D, ProductId, WarehouseId, Sold, Demand - Sold, CAST(Sold * UnitPrice AS decimal(12,2)), 0
    FROM #Day;

    UPDATE i
    SET OnHand = i.OnHand - d.Sold, LastUpdated = SYSUTCDATETIME()
    FROM dbo.Inventory AS i
    JOIN #Day AS d ON d.ProductId = i.ProductId AND d.WarehouseId = i.WarehouseId
    WHERE d.Sold > 0;

    INSERT dbo.StockMovement (MovementDate, ProductId, WarehouseId, MovementType, Quantity)
    SELECT @D, ProductId, WarehouseId, 'SALE', -Sold
    FROM #Day
    WHERE Sold > 0;

    -- 5. Next day
    UPDATE dbo.SimClock SET SimDate = DATEADD(DAY, 1, @D), UpdatedAt = SYSUTCDATETIME() WHERE ClockId = 1;
END
GO

-- ------------------------------------------------------------------ Advance the clock by N days (all or nothing)
CREATE OR ALTER PROCEDURE dbo.usp_AdvanceDays
    @Days    int = 1,
    @Refresh bit = 1          -- 1 = recompute forecast, reorder points and recommendations once at the end
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Days < 1 OR @Days > 90
        THROW 50040, 'Days must be between 1 and 90.', 1;

    DECLARE @Start date = (SELECT SimDate FROM dbo.SimClock WHERE ClockId = 1);
    DECLARE @i int = 0;

    BEGIN TRY
        BEGIN TRANSACTION;
        WHILE @i < @Days
        BEGIN
            EXEC dbo.usp_SimStep;
            SET @i += 1;
        END;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    IF @Refresh = 1
        EXEC dbo.usp_GenerateRecommendations @Quiet = 1;

    DECLARE @NewSim date = (SELECT SimDate FROM dbo.SimClock WHERE ClockId = 1);

    SELECT @Start                         AS FromDate,
           DATEADD(DAY, -1, @NewSim)      AS ToDate,
           @NewSim                        AS NewSimDate,
           @Days                          AS DaysAdvanced,
           ISNULL(SUM(s.Quantity), 0)     AS UnitsSold,
           ISNULL(SUM(s.LostQty), 0)      AS UnitsLost,
           ISNULL(SUM(s.Revenue), 0)      AS Revenue,
           ISNULL(SUM(CAST(s.LostQty * p.UnitPrice AS decimal(14,2))), 0) AS LostRevenue,
           (SELECT COUNT(*) FROM dbo.PurchaseOrder WHERE ReceivedDate >= @Start) AS OrdersReceived
    FROM dbo.SalesDaily AS s
    JOIN dbo.Product AS p ON p.ProductId = s.ProductId
    WHERE s.SaleDate >= @Start AND s.SaleDate < @NewSim;
END
GO

-- ------------------------------------------------------------------ Scenario: demand spike
-- Applies to one product, or a category (a top-level category includes its children), or to everything if both are NULL.
CREATE OR ALTER PROCEDURE dbo.usp_AddDemandSpike
    @ProductId  int = NULL,
    @CategoryId int = NULL,
    @Multiplier decimal(5,2),
    @Days       int,
    @CreatedBy  nvarchar(128) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Multiplier < 0.1 OR @Multiplier > 10 THROW 50050, 'Multiplier must be between 0.1 and 10.', 1;
    IF @Days < 1 OR @Days > 60                THROW 50051, 'Days must be between 1 and 60.', 1;
    IF @ProductId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.Product WHERE ProductId = @ProductId)
        THROW 50052, 'Product not found.', 1;
    IF @CategoryId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.Category WHERE CategoryId = @CategoryId)
        THROW 50053, 'Category not found.', 1;

    DECLARE @Sim date = (SELECT SimDate FROM dbo.SimClock WHERE ClockId = 1);
    DECLARE @Target nvarchar(150) =
        CASE WHEN @ProductId  IS NOT NULL THEN (SELECT CONCAT(N'product ', Sku, N' ', Name) FROM dbo.Product WHERE ProductId = @ProductId)
             WHEN @CategoryId IS NOT NULL THEN (SELECT CONCAT(N'category ', Name) FROM dbo.Category WHERE CategoryId = @CategoryId)
             ELSE N'all products' END;

    IF @ProductId IS NOT NULL SET @CategoryId = NULL;   -- a product target wins over a category

    INSERT dbo.SimEvent (EventType, SimDate, StartDate, EndDate, ProductId, CategoryId, Multiplier, Description, CreatedBy)
    VALUES ('DEMAND_SPIKE', @Sim, @Sim, DATEADD(DAY, @Days - 1, @Sim), @ProductId, @CategoryId, @Multiplier,
            CONCAT(N'Demand x', @Multiplier, N' for ', @Days, N' days on ', @Target),
            COALESCE(@CreatedBy, CONVERT(nvarchar(128), SESSION_CONTEXT(N'app_user')), SUSER_SNAME()));

    SELECT CAST(SCOPE_IDENTITY() AS int) AS EventId;
END
GO

-- ------------------------------------------------------------------ Scenario: supplier delay (open orders arrive later)
CREATE OR ALTER PROCEDURE dbo.usp_DelaySupplier
    @SupplierId int,
    @DelayDays  int,
    @CreatedBy  nvarchar(128) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.Supplier WHERE SupplierId = @SupplierId) THROW 50060, 'Supplier not found.', 1;
    IF @DelayDays < 1 OR @DelayDays > 30 THROW 50061, 'Delay must be between 1 and 30 days.', 1;

    DECLARE @Sim date = (SELECT SimDate FROM dbo.SimClock WHERE ClockId = 1);
    DECLARE @n int;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE dbo.PurchaseOrder
        SET ExpectedDate = DATEADD(DAY, @DelayDays, ExpectedDate)
        WHERE SupplierId = @SupplierId AND Status IN ('APPROVED', 'IN_TRANSIT');
        SET @n = @@ROWCOUNT;

        INSERT dbo.SimEvent (EventType, SimDate, StartDate, EndDate, SupplierId, DelayDays, Description, CreatedBy)
        SELECT 'SUPPLIER_DELAY', @Sim, @Sim, @Sim, @SupplierId, @DelayDays,
               CONCAT(N'Supplier ', s.Name, N' delayed ', @n, N' open order(s) by ', @DelayDays, N' days'),
               COALESCE(@CreatedBy, CONVERT(nvarchar(128), SESSION_CONTEXT(N'app_user')), SUSER_SNAME())
        FROM dbo.Supplier AS s WHERE s.SupplierId = @SupplierId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT CAST(SCOPE_IDENTITY() AS int) AS EventId, @n AS OrdersDelayed;
END
GO

-- ------------------------------------------------------------------ Scenario: price / cost change (trigger writes old and new values to AuditLog)
CREATE OR ALTER PROCEDURE dbo.usp_ChangePrice
    @ProductId int,
    @NewCost   decimal(10,2) = NULL,
    @NewPrice  decimal(10,2) = NULL,
    @CreatedBy nvarchar(128) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @NewCost IS NULL AND @NewPrice IS NULL THROW 50070, 'Provide a new cost or a new price.', 1;

    DECLARE @Sim date = (SELECT SimDate FROM dbo.SimClock WHERE ClockId = 1);
    DECLARE @Cost decimal(10,2), @Price decimal(10,2), @Name nvarchar(150);

    SELECT @Cost = UnitCost, @Price = UnitPrice, @Name = CONCAT(Sku, N' ', Name)
    FROM dbo.Product WHERE ProductId = @ProductId;

    IF @Name IS NULL THROW 50071, 'Product not found.', 1;

    DECLARE @OldCost decimal(10,2) = @Cost, @OldPrice decimal(10,2) = @Price;
    SET @Cost  = ISNULL(@NewCost,  @Cost);
    SET @Price = ISNULL(@NewPrice, @Price);

    IF @Cost <= 0      THROW 50072, 'Cost must be positive.', 1;
    IF @Price < @Cost  THROW 50073, 'Price cannot be lower than cost.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE dbo.Product SET UnitCost = @Cost, UnitPrice = @Price WHERE ProductId = @ProductId;

        INSERT dbo.SimEvent (EventType, SimDate, StartDate, EndDate, ProductId, Description, CreatedBy)
        VALUES ('PRICE_CHANGE', @Sim, @Sim, @Sim, @ProductId,
                CONCAT(N'Product ', @Name, N': cost ', @OldCost, N' -> ', @Cost, N', price ', @OldPrice, N' -> ', @Price),
                COALESCE(@CreatedBy, CONVERT(nvarchar(128), SESSION_CONTEXT(N'app_user')), SUSER_SNAME()));

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT CAST(SCOPE_IDENTITY() AS int) AS EventId;
END
GO

-- ------------------------------------------------------------------ Reset to the starting state (2026-11-01)
CREATE OR ALTER PROCEDURE dbo.usp_ResetSimulation
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Start date = '2026-11-01';

    BEGIN TRY
        BEGIN TRANSACTION;

        DELETE FROM dbo.PurchaseOrderLine;
        DELETE FROM dbo.PurchaseOrder;
        DELETE FROM dbo.Recommendation;
        DELETE FROM dbo.Forecast;
        DELETE FROM dbo.ForecastRun;
        DELETE FROM dbo.SimEvent;
        DELETE FROM dbo.StockMovement WHERE MovementType <> 'OPENING';
        DELETE FROM dbo.SalesDaily WHERE SaleDate >= @Start;

        -- Opening balance rows hold the original stock level
        UPDATE i
        SET OnHand = m.Quantity, Reserved = 0, LastUpdated = SYSUTCDATETIME()
        FROM dbo.Inventory AS i
        JOIN dbo.StockMovement AS m
          ON m.ProductId = i.ProductId AND m.WarehouseId = i.WarehouseId AND m.MovementType = 'OPENING';

        UPDATE p
        SET UnitCost = b.UnitCost, UnitPrice = b.UnitPrice
        FROM dbo.Product AS p
        JOIN dbo.ProductBaseline AS b ON b.ProductId = p.ProductId
        WHERE p.UnitCost <> b.UnitCost OR p.UnitPrice <> b.UnitPrice;

        -- Trigger-written history from the simulation (user account history is kept)
        DELETE FROM dbo.AuditLog WHERE TableName IN ('Inventory', 'Product', 'PurchaseOrder');

        UPDATE dbo.SimClock SET SimDate = @Start, UpdatedAt = SYSUTCDATETIME() WHERE ClockId = 1;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    EXEC dbo.usp_RunForecast @RunType = 'BACKTEST', @Quiet = 1;
    EXEC dbo.usp_GenerateRecommendations @Quiet = 1;

    SELECT SimDate FROM dbo.SimClock WHERE ClockId = 1;
END
GO
