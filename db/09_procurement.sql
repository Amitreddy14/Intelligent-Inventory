-- 09_procurement.sql
-- Inventory optimisation and procurement recommendation.
--   Safety stock    = z * (std of daily demand) * sqrt(lead time)       z depends on ABC class (A 99%, B 95%, C 90%)
--   Lead-time demand= forecast demand over the supplier lead time (falls back to average * lead time)
--   Reorder point   = lead-time demand + safety stock
--   EOQ             = sqrt(2 * D * S / H)   D annual demand, S ordering cost, H annual holding cost per unit
--   Order quantity  = (reorder point + EOQ) - inventory position, at least the supplier minimum order quantity
--   Inventory position = on hand + on order - reserved

USE InventoryDB;
GO

-- ------------------------------------------------------------------ z-score for a service level
CREATE OR ALTER FUNCTION dbo.fn_ZScore (@ServiceLevel decimal(5,4))
RETURNS float
AS
BEGIN
    RETURN CASE WHEN @ServiceLevel >= 0.99  THEN 2.326
                WHEN @ServiceLevel >= 0.975 THEN 1.960
                WHEN @ServiceLevel >= 0.95  THEN 1.645
                WHEN @ServiceLevel >= 0.90  THEN 1.282
                ELSE 0.842 END;
END
GO

-- ------------------------------------------------------------------ Supplier ranking (JSON terms + ROW_NUMBER)
-- Adjusted cost = price after contract discount, divided by reliability (an 85% reliable supplier effectively costs more).
CREATE OR ALTER VIEW dbo.vw_SupplierRank AS
SELECT
    sp.ProductId,
    sp.SupplierId,
    s.Name              AS SupplierName,
    sp.UnitPrice,
    j.DiscountPct,
    j.PaymentDays,
    sp.LeadTimeDays,
    sp.MinOrderQty,
    s.ReliabilityPct,
    s.OrderingCost,
    a.AdjustedUnitCost,
    ROW_NUMBER() OVER (PARTITION BY sp.ProductId
                       ORDER BY a.AdjustedUnitCost, sp.LeadTimeDays, sp.SupplierId) AS SupplierRank
FROM dbo.SupplierProduct AS sp
JOIN dbo.Supplier AS s ON s.SupplierId = sp.SupplierId
CROSS APPLY (SELECT DiscountPct = CAST(JSON_VALUE(sp.TermsJson, '$.discount_pct') AS decimal(5,2)),
                    PaymentDays = CAST(JSON_VALUE(sp.TermsJson, '$.payment_days') AS int)) AS j
CROSS APPLY (SELECT AdjustedUnitCost = CAST(sp.UnitPrice * (1 - j.DiscountPct / 100.0)
                                            / (s.ReliabilityPct / 100.0) AS decimal(12,4))) AS a;
GO

-- ------------------------------------------------------------------ Stock already ordered but not yet received
CREATE OR ALTER VIEW dbo.vw_OnOrder AS
SELECT po.WarehouseId, pol.ProductId,
       SUM(pol.Quantity)  AS OnOrderQty,
       MIN(po.ExpectedDate) AS NextArrival
FROM dbo.PurchaseOrder AS po
JOIN dbo.PurchaseOrderLine AS pol ON pol.PoId = po.PoId
WHERE po.Status IN ('APPROVED', 'IN_TRANSIT')
GROUP BY po.WarehouseId, pol.ProductId;
GO

-- ------------------------------------------------------------------ Stock health per item
CREATE OR ALTER VIEW dbo.vw_StockHealth AS
SELECT
    i.ProductId,
    p.Sku,
    p.Name         AS ProductName,
    p.CategoryId,
    i.WarehouseId,
    w.Name         AS WarehouseName,
    w.City,
    i.OnHand,
    i.Reserved,
    ISNULL(oo.OnOrderQty, 0) AS OnOrder,
    i.ReorderPoint,
    i.SafetyStock,
    CAST(ISNULL(d.AvgDaily28, 0) AS decimal(10,2)) AS AvgDaily28,
    CASE WHEN d.AvgDaily28 > 0 THEN CAST(i.OnHand / d.AvgDaily28 AS decimal(10,1)) END AS DaysOfCover,
    CASE WHEN i.OnHand = 0                                           THEN 'STOCKOUT'
         WHEN i.OnHand <= i.SafetyStock                              THEN 'CRITICAL'
         WHEN i.OnHand <= i.ReorderPoint                             THEN 'LOW'
         WHEN d.AvgDaily28 > 0 AND i.OnHand / d.AvgDaily28 > 60      THEN 'OVERSTOCK'
         ELSE 'HEALTHY' END AS StockStatus,
    CAST(i.OnHand * p.UnitCost AS decimal(14,2)) AS StockValue
FROM dbo.Inventory AS i
JOIN dbo.Product   AS p ON p.ProductId   = i.ProductId
JOIN dbo.Warehouse AS w ON w.WarehouseId = i.WarehouseId
LEFT JOIN dbo.vw_ItemDemandStats AS d ON d.ProductId = i.ProductId AND d.WarehouseId = i.WarehouseId
LEFT JOIN dbo.vw_OnOrder AS oo ON oo.ProductId = i.ProductId AND oo.WarehouseId = i.WarehouseId;
GO

-- ------------------------------------------------------------------ Safety stock and reorder point for every item
CREATE OR ALTER PROCEDURE dbo.usp_RecomputeStockParams
    @Items int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Sim   date = (SELECT SimDate FROM dbo.SimClock WHERE ClockId = 1);
    DECLARE @AsOf  date = DATEADD(DAY, -1, @Sim);

    -- Make sure a live forecast exists for today
    IF NOT EXISTS (SELECT 1 FROM dbo.ForecastRun WHERE RunType = 'LIVE' AND AsOfDate = @AsOf)
        EXEC dbo.usp_RunForecast @RunType = 'LIVE', @Quiet = 1;

    DECLARE @RunId int = (SELECT MAX(RunId) FROM dbo.ForecastRun WHERE RunType = 'LIVE' AND AsOfDate = @AsOf);

    UPDATE i
    SET SafetyStock  = c.SafetyStock,
        ReorderPoint = CAST(CEILING(x.LeadDemand + c.SafetyStock) AS int),
        LastUpdated  = SYSUTCDATETIME()
    FROM dbo.Inventory AS i
    JOIN dbo.vw_SupplierRank   AS sr ON sr.ProductId = i.ProductId AND sr.SupplierRank = 1
    JOIN dbo.vw_ItemDemandStats AS d ON d.ProductId = i.ProductId AND d.WarehouseId = i.WarehouseId
    JOIN dbo.vw_ABC_XYZ        AS g  ON g.ProductId = i.ProductId
    OUTER APPLY (SELECT SUM(f.ForecastQty) AS Fc
                 FROM dbo.Forecast AS f
                 WHERE f.RunId = @RunId AND f.Method = 'SEASONAL'
                   AND f.ProductId = i.ProductId AND f.WarehouseId = i.WarehouseId
                   AND f.TargetDate < DATEADD(DAY, sr.LeadTimeDays, @Sim)) AS fc
    CROSS APPLY (SELECT LeadDemand = CAST(ISNULL(fc.Fc, d.AvgDaily90 * sr.LeadTimeDays) AS float),
                        Z = dbo.fn_ZScore(CASE g.AbcClass WHEN 'A' THEN 0.99 WHEN 'B' THEN 0.95 ELSE 0.90 END)) AS x
    CROSS APPLY (SELECT SafetyStock = CAST(CEILING(x.Z * d.StdDaily90 * SQRT(CAST(sr.LeadTimeDays AS float))) AS int)) AS c;

    SET @Items = @@ROWCOUNT;
END
GO

-- ------------------------------------------------------------------ Procurement recommendations
CREATE OR ALTER PROCEDURE dbo.usp_GenerateRecommendations
    @Quiet bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Sim date = (SELECT SimDate FROM dbo.SimClock WHERE ClockId = 1);
    DECLARE @n int;

    EXEC dbo.usp_RecomputeStockParams @Items = @n OUTPUT;

    BEGIN TRY
        BEGIN TRANSACTION;

        DELETE FROM dbo.Recommendation WHERE Status = 'OPEN';

        ;WITH base AS (
            SELECT i.ProductId, i.WarehouseId, i.OnHand, i.Reserved,
                   ISNULL(oo.OnOrderQty, 0)                                   AS OnOrder,
                   i.OnHand + ISNULL(oo.OnOrderQty, 0) - i.Reserved            AS Position,
                   i.ReorderPoint, i.SafetyStock,
                   sr.SupplierId, sr.SupplierName, sr.LeadTimeDays, sr.MinOrderQty, sr.OrderingCost,
                   d.AvgDaily90, d.AvgDaily28,
                   p.UnitCost, w.HoldingCostPct
            FROM dbo.Inventory AS i
            JOIN dbo.Product   AS p ON p.ProductId   = i.ProductId
            JOIN dbo.Warehouse AS w ON w.WarehouseId = i.WarehouseId
            JOIN dbo.vw_SupplierRank    AS sr ON sr.ProductId = i.ProductId AND sr.SupplierRank = 1
            JOIN dbo.vw_ItemDemandStats AS d  ON d.ProductId = i.ProductId AND d.WarehouseId = i.WarehouseId
            LEFT JOIN dbo.vw_OnOrder    AS oo ON oo.ProductId = i.ProductId AND oo.WarehouseId = i.WarehouseId
        ),
        calc AS (
            SELECT b.*,
                   ISNULL(CAST(CEILING(SQRT(2.0 * (b.AvgDaily90 * 365.0) * b.OrderingCost
                                            / NULLIF(b.UnitCost * b.HoldingCostPct / 100.0, 0))) AS int), 0) AS Eoq,
                   CASE WHEN b.AvgDaily28 > 0 THEN b.OnHand / b.AvgDaily28 END AS DaysCover
            FROM base AS b
        ),
        act AS (
            SELECT c.*,
                   CASE WHEN c.AvgDaily90 > 0 AND c.Position <= c.ReorderPoint        THEN 'ORDER'
                        WHEN c.AvgDaily90 > 0 AND c.Position <= c.ReorderPoint * 1.25 THEN 'WATCH'
                        WHEN c.DaysCover > 60                                          THEN 'OVERSTOCK' END AS Action,
                   c.ReorderPoint + c.Eoq - c.Position AS Need
            FROM calc AS c
        )
        INSERT dbo.Recommendation (ProductId, WarehouseId, SupplierId, Action, OrderQty, Priority, Reason, Status, SimDate)
        SELECT a.ProductId, a.WarehouseId,
               CASE WHEN a.Action = 'ORDER' THEN a.SupplierId END,
               a.Action,
               CASE WHEN a.Action <> 'ORDER' THEN 0
                    WHEN a.Need < a.MinOrderQty THEN a.MinOrderQty
                    ELSE CAST(a.Need AS int) END,
               CASE WHEN a.Action = 'ORDER' AND (a.OnHand = 0 OR a.OnHand < a.AvgDaily28 * a.LeadTimeDays) THEN 1
                    WHEN a.Action = 'ORDER'  THEN 2
                    WHEN a.Action = 'WATCH'  THEN 3
                    ELSE 4 END,
               CASE a.Action
                   WHEN 'ORDER' THEN CONCAT(N'Position ', a.Position, N' (on hand ', a.OnHand, N' + on order ', a.OnOrder,
                                            N') is at or below reorder point ', a.ReorderPoint,
                                            N' (safety stock ', a.SafetyStock, N'). Best supplier: ', a.SupplierName,
                                            N', lead time ', a.LeadTimeDays, N' days, EOQ ', a.Eoq, N'.')
                   WHEN 'WATCH' THEN CONCAT(N'Position ', a.Position, N' is within 25% of reorder point ', a.ReorderPoint,
                                            N'. Will need an order soon.')
                   ELSE CONCAT(N'About ', CAST(a.DaysCover AS decimal(8,0)), N' days of stock on hand (',
                               a.OnHand, N' units). Pause purchasing.')
               END,
               'OPEN',
               @Sim
        FROM act AS a
        WHERE a.Action IS NOT NULL;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    IF @Quiet = 0
        SELECT Action, COUNT(*) AS Items, SUM(OrderQty) AS UnitsToOrder
        FROM dbo.Recommendation
        WHERE Status = 'OPEN'
        GROUP BY Action
        ORDER BY CASE Action WHEN 'ORDER' THEN 1 WHEN 'WATCH' THEN 2 ELSE 3 END;
END
GO

-- ------------------------------------------------------------------ Turn an ORDER recommendation into an approved purchase order
-- One transaction: lock the recommendation, create PO and line, mark the recommendation approved. All or nothing.
CREATE OR ALTER PROCEDURE dbo.usp_CreatePoFromRecommendation
    @RecId  int,
    @UserId int = NULL,
    @PoId   int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Sim date = (SELECT SimDate FROM dbo.SimClock WHERE ClockId = 1);
    DECLARE @Prod int, @Wh int, @Sup int, @Qty int, @Act varchar(10), @Status varchar(10);
    DECLARE @Lead int, @Price decimal(10,2);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Prod = ProductId, @Wh = WarehouseId, @Sup = SupplierId,
               @Qty = OrderQty, @Act = Action, @Status = Status
        FROM dbo.Recommendation WITH (UPDLOCK, HOLDLOCK)
        WHERE RecId = @RecId;

        IF @Prod IS NULL                 THROW 50010, 'Recommendation not found.', 1;
        IF @Status <> 'OPEN'             THROW 50011, 'Recommendation is not open.', 1;
        IF @Act <> 'ORDER' OR @Qty <= 0  THROW 50012, 'Only ORDER recommendations can become purchase orders.', 1;

        SELECT @Lead = sr.LeadTimeDays,
               @Price = CAST(ROUND(sr.UnitPrice * (1 - sr.DiscountPct / 100.0), 2) AS decimal(10,2))
        FROM dbo.vw_SupplierRank AS sr
        WHERE sr.SupplierId = @Sup AND sr.ProductId = @Prod;

        INSERT dbo.PurchaseOrder (SupplierId, WarehouseId, Status, OrderDate, ExpectedDate, TotalCost, CreatedBy)
        VALUES (@Sup, @Wh, 'APPROVED', @Sim, DATEADD(DAY, @Lead, @Sim), @Qty * @Price, @UserId);

        SET @PoId = SCOPE_IDENTITY();

        INSERT dbo.PurchaseOrderLine (PoId, LineNumber, ProductId, Quantity, UnitPrice)
        VALUES (@PoId, 1, @Prod, @Qty, @Price);

        UPDATE dbo.Recommendation SET Status = 'APPROVED' WHERE RecId = @RecId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END
GO

-- ------------------------------------------------------------------ Receive a purchase order into stock (atomic)
CREATE OR ALTER PROCEDURE dbo.usp_ReceivePo
    @PoId int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Sim date = (SELECT SimDate FROM dbo.SimClock WHERE ClockId = 1);
    DECLARE @Status varchar(12), @Wh int;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status, @Wh = WarehouseId
        FROM dbo.PurchaseOrder WITH (UPDLOCK, HOLDLOCK)
        WHERE PoId = @PoId;

        IF @Status IS NULL THROW 50020, 'Purchase order not found.', 1;
        IF @Status NOT IN ('APPROVED', 'IN_TRANSIT') THROW 50021, 'Purchase order cannot be received in its current status.', 1;

        UPDATE i
        SET OnHand = i.OnHand + l.Quantity, LastUpdated = SYSUTCDATETIME()
        FROM dbo.Inventory AS i
        JOIN dbo.PurchaseOrderLine AS l ON l.ProductId = i.ProductId
        WHERE l.PoId = @PoId AND i.WarehouseId = @Wh;

        INSERT dbo.StockMovement (MovementDate, ProductId, WarehouseId, MovementType, Quantity, RefType, RefId)
        SELECT @Sim, l.ProductId, @Wh, 'RECEIPT', l.Quantity, 'PO', @PoId
        FROM dbo.PurchaseOrderLine AS l
        WHERE l.PoId = @PoId;

        UPDATE dbo.PurchaseOrder SET Status = 'RECEIVED', ReceivedDate = @Sim WHERE PoId = @PoId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END
GO
