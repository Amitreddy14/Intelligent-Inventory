-- 04_seed_sales.sql
-- Generates 2 years of daily sales (2024-11-01 .. 2026-10-31) for every stocked product/warehouse pair,
-- then sets opening stock for the simulated "today" (2026-11-01).
-- Demand = base * trend * yearly seasonality * day-of-week * promo uplift * noise. Fully deterministic.

USE InventoryDB;
GO
SET NOCOUNT ON;
GO

-- ---------------------------------------------------------------- 1. Which products are stocked where
-- Each product is stocked in exactly 3 of the 5 warehouses (residues 0,1,2 of (ProductId + WarehouseId) mod 5).
INSERT dbo.Inventory (ProductId, WarehouseId)
SELECT p.ProductId, w.WarehouseId
FROM dbo.Product p
CROSS JOIN dbo.Warehouse w
WHERE (p.ProductId + w.WarehouseId) % 5 IN (0, 1, 2);
GO

-- ---------------------------------------------------------------- 2. Calendar (recursive CTE, 730 days)
;WITH d AS (
    SELECT 0 AS DayNo, CAST('2024-11-01' AS date) AS SaleDate
    UNION ALL
    SELECT DayNo + 1, DATEADD(DAY, 1, SaleDate) FROM d WHERE DayNo < 729
)
SELECT DayNo,
       SaleDate,
       DATEDIFF(DAY, '19000101', SaleDate) % 7 AS Dow,      -- 0 = Monday ... 6 = Sunday (1900-01-01 was a Monday)
       MONTH(SaleDate)                         AS MonthNo
INTO #Cal
FROM d
OPTION (MAXRECURSION 800);

CREATE UNIQUE CLUSTERED INDEX IX_Cal ON #Cal (DayNo);
GO

-- ---------------------------------------------------------------- 3. Per product/warehouse demand profile
SELECT
    i.ProductId,
    i.WarehouseId,
    CAST((0.4 + 22.0 * POWER(pop.R, 3)) * w.DemandFactor * (0.8 + 0.4 * pv.R) AS float)       AS Base,        -- few fast movers, many slow ones
    CAST(((CAST(ABS(CAST(CHECKSUM(i.ProductId, 33) AS bigint)) % 60 AS int)) - 20) / 100.0 AS float) AS TrendG,     -- -20% .. +39% over 2 years
    CAST(0.05 + 0.25 * ((ABS(CAST(CHECKSUM(i.ProductId, 34) AS bigint)) % 100) / 100.0) AS float)    AS SeasonAmp,  -- seasonal swing 5%..30%
    CAST(1 + ABS(CAST(CHECKSUM(i.ProductId, 35) AS bigint)) % 12 AS int)                              AS SeasonPeak, -- peak month 1..12
    p.UnitPrice
INTO #Pair
FROM dbo.Inventory i
JOIN dbo.Product   p ON p.ProductId   = i.ProductId
JOIN dbo.Warehouse w ON w.WarehouseId = i.WarehouseId
CROSS APPLY (SELECT R = (ABS(CAST(CHECKSUM(i.ProductId, 31) AS bigint)) % 1000) / 1000.0) pop
CROSS APPLY (SELECT R = (ABS(CAST(CHECKSUM(i.ProductId, i.WarehouseId, 32) AS bigint)) % 1000) / 1000.0) pv;

CREATE UNIQUE CLUSTERED INDEX IX_Pair ON #Pair (ProductId, WarehouseId);
GO

-- ---------------------------------------------------------------- 4. Sales facts (~1.1 million rows)
INSERT dbo.SalesDaily (SaleDate, ProductId, WarehouseId, Quantity, LostQty, Revenue, PromoFlag)
SELECT
    c.SaleDate,
    x.ProductId,
    x.WarehouseId,
    q.Qty,
    0,
    CAST(q.Qty * x.UnitPrice * CASE WHEN pr.Promo = 1 THEN 0.90 ELSE 1.0 END AS decimal(12,2)),
    pr.Promo
FROM #Cal c
CROSS JOIN #Pair x
-- A product is "on promo" for whole weeks: roughly 8% of weeks.
CROSS APPLY (SELECT Promo = CAST(CASE WHEN ABS(CAST(CHECKSUM(x.ProductId, c.DayNo / 7, 41) AS bigint)) % 100 < 8 THEN 1 ELSE 0 END AS bit)) pr
CROSS APPLY (SELECT Qty = CAST(ROUND(
        x.Base
        * (1.0 + x.TrendG * c.DayNo / 729.0)
        * (1.0 + x.SeasonAmp * COS(2.0 * PI() * (c.MonthNo - x.SeasonPeak) / 12.0))
        * CASE c.Dow WHEN 4 THEN 1.10 WHEN 5 THEN 1.30 WHEN 6 THEN 1.25 ELSE 1.0 END
        * CASE WHEN pr.Promo = 1 THEN 1.6 ELSE 1.0 END
        * (0.65 + 0.70 * ((ABS(CAST(CHECKSUM(x.ProductId, x.WarehouseId, c.DayNo, 42) AS bigint)) % 1000) / 1000.0))
    , 0) AS int)) q
ORDER BY c.SaleDate, x.ProductId, x.WarehouseId;
GO

-- ---------------------------------------------------------------- 5. Opening stock for 2026-11-01
-- Cover (days of stock) is skewed so about a quarter of items are low and need ordering. Phase 2 recomputes
-- ReorderPoint and SafetyStock properly; these are simple starting values.
;WITH recent AS (
    SELECT ProductId, WarehouseId, AVG(CAST(Quantity AS float)) AS Avg30
    FROM dbo.SalesDaily
    WHERE SaleDate >= '2026-10-02'
    GROUP BY ProductId, WarehouseId
)
UPDATE i
SET OnHand       = CAST(ROUND(r.Avg30 * (3 + 45.0 * POWER(h.R, 1.3)), 0) AS int),
    SafetyStock  = CAST(CEILING(r.Avg30 * 3)  AS int),
    ReorderPoint = CAST(CEILING(r.Avg30 * 10) AS int),
    LastUpdated  = SYSUTCDATETIME()
FROM dbo.Inventory i
JOIN recent r ON r.ProductId = i.ProductId AND r.WarehouseId = i.WarehouseId
CROSS APPLY (SELECT R = (ABS(CAST(CHECKSUM(i.ProductId, i.WarehouseId, 51) AS bigint)) % 1000) / 1000.0) h;
GO

INSERT dbo.StockMovement (MovementDate, ProductId, WarehouseId, MovementType, Quantity)
SELECT '2026-11-01', ProductId, WarehouseId, 'OPENING', OnHand
FROM dbo.Inventory;
GO

INSERT dbo.SimClock (ClockId, SimDate) VALUES (1, '2026-11-01');
GO

DROP TABLE #Cal;
DROP TABLE #Pair;
GO
