-- 07_analytics_views.sql
-- Analytical views. Everything is relative to the simulated "today" in dbo.SimClock, so the views
-- change automatically when the simulation advances.
-- Showcases: window functions (moving average, LAG, RANK, running/cumulative SUM), recursive CTE, aggregates over windows.

USE InventoryDB;
GO

-- ------------------------------------------------------------------ Demand statistics per item (last 90 days)
-- Demand = units sold + units lost to stockouts, so a stockout does not make demand look lower than it was.
CREATE OR ALTER VIEW dbo.vw_ItemDemandStats AS
SELECT
    s.ProductId,
    s.WarehouseId,
    AVG(CAST(s.Quantity + s.LostQty AS float))                                    AS AvgDaily90,
    ISNULL(STDEV(CAST(s.Quantity + s.LostQty AS float)), 0)                       AS StdDaily90,
    AVG(CASE WHEN s.SaleDate >= DATEADD(DAY, -28, c.SimDate)
             THEN CAST(s.Quantity + s.LostQty AS float) END)                      AS AvgDaily28,
    SUM(s.Quantity)                                                               AS Units90,
    SUM(s.Revenue)                                                                AS Revenue90
FROM dbo.SalesDaily AS s
CROSS JOIN dbo.SimClock AS c
WHERE s.SaleDate >= DATEADD(DAY, -90, c.SimDate)
  AND s.SaleDate <  c.SimDate
GROUP BY s.ProductId, s.WarehouseId;
GO

-- ------------------------------------------------------------------ Moving averages with window frames
-- Always filter by ProductId and WarehouseId (and ideally SaleDate) when querying: the windows are
-- partitioned per item, so the optimizer only computes the rows you ask about.
CREATE OR ALTER VIEW dbo.vw_DemandMovingAvg AS
SELECT
    s.SaleDate,
    s.ProductId,
    s.WarehouseId,
    s.Quantity,
    AVG(CAST(s.Quantity AS float)) OVER (PARTITION BY s.ProductId, s.WarehouseId
                                         ORDER BY s.SaleDate
                                         ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)   AS MovingAvg7,
    AVG(CAST(s.Quantity AS float)) OVER (PARTITION BY s.ProductId, s.WarehouseId
                                         ORDER BY s.SaleDate
                                         ROWS BETWEEN 27 PRECEDING AND CURRENT ROW)  AS MovingAvg28,
    LAG(s.Quantity, 7) OVER (PARTITION BY s.ProductId, s.WarehouseId
                             ORDER BY s.SaleDate)                                    AS QtySameDayLastWeek,
    SUM(s.Quantity) OVER (PARTITION BY s.ProductId, s.WarehouseId
                          ORDER BY s.SaleDate
                          ROWS UNBOUNDED PRECEDING)                                  AS RunningUnits
FROM dbo.SalesDaily AS s;
GO

-- ------------------------------------------------------------------ ABC (value) and XYZ (variability) classification
-- ABC: products ordered by revenue; A = the products that make the first 80% of revenue, B = next 15%, C = rest.
-- XYZ: coefficient of variation (stddev / mean) of WEEKLY units. X steady, Y moderate, Z erratic.
CREATE OR ALTER VIEW dbo.vw_ABC_XYZ AS
WITH rev AS (
    SELECT s.ProductId,
           SUM(s.Revenue)  AS Revenue1Y,
           SUM(s.Quantity) AS Units1Y
    FROM dbo.SalesDaily AS s
    CROSS JOIN dbo.SimClock AS c
    WHERE s.SaleDate >= DATEADD(DAY, -364, c.SimDate) AND s.SaleDate < c.SimDate
    GROUP BY s.ProductId
),
cum AS (
    SELECT r.ProductId, r.Revenue1Y, r.Units1Y,
           RANK() OVER (ORDER BY r.Revenue1Y DESC) AS RevenueRank,
           CAST(SUM(r.Revenue1Y) OVER (ORDER BY r.Revenue1Y DESC, r.ProductId
                                       ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS float)
               / CAST(SUM(r.Revenue1Y) OVER () AS float)                                   AS CumShareAfter,
           (CAST(SUM(r.Revenue1Y) OVER (ORDER BY r.Revenue1Y DESC, r.ProductId
                                        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS float)
               - CAST(r.Revenue1Y AS float))
               / CAST(SUM(r.Revenue1Y) OVER () AS float)                                   AS CumShareBefore
    FROM rev AS r
),
weekly AS (
    -- 52 exact 7-day blocks counted backwards from yesterday
    SELECT s.ProductId,
           DATEDIFF(DAY, s.SaleDate, DATEADD(DAY, -1, c.SimDate)) / 7 AS WeekBlock,
           CAST(SUM(s.Quantity + s.LostQty) AS float)                  AS WeekUnits
    FROM dbo.SalesDaily AS s
    CROSS JOIN dbo.SimClock AS c
    WHERE s.SaleDate >= DATEADD(DAY, -364, c.SimDate) AND s.SaleDate < c.SimDate
    GROUP BY s.ProductId, DATEDIFF(DAY, s.SaleDate, DATEADD(DAY, -1, c.SimDate)) / 7
),
variability AS (
    SELECT ProductId, STDEV(WeekUnits) / NULLIF(AVG(WeekUnits), 0) AS WeeklyCV
    FROM weekly
    GROUP BY ProductId
)
SELECT
    p.ProductId,
    p.Sku,
    p.Name        AS ProductName,
    p.CategoryId,
    cm.Revenue1Y,
    cm.Units1Y,
    cm.RevenueRank,
    CAST(100.0 * cm.CumShareAfter AS decimal(5,2))                                   AS CumRevenuePct,
    CASE WHEN cm.CumShareBefore < 0.80 THEN 'A'
         WHEN cm.CumShareBefore < 0.95 THEN 'B' ELSE 'C' END                         AS AbcClass,
    CAST(v.WeeklyCV AS decimal(6,3))                                                 AS WeeklyCV,
    CASE WHEN v.WeeklyCV < 0.25 THEN 'X'
         WHEN v.WeeklyCV < 0.40 THEN 'Y' ELSE 'Z' END                                AS XyzClass
FROM cum AS cm
JOIN dbo.Product AS p ON p.ProductId = cm.ProductId
LEFT JOIN variability AS v ON v.ProductId = cm.ProductId;
GO

-- ------------------------------------------------------------------ Top sellers inside each category (RANK per partition)
CREATE OR ALTER VIEW dbo.vw_TopSellersByCategory AS
SELECT
    p.CategoryId,
    cat.Name AS CategoryName,
    p.ProductId,
    p.Sku,
    p.Name   AS ProductName,
    SUM(s.Revenue)  AS Revenue90,
    SUM(s.Quantity) AS Units90,
    RANK() OVER (PARTITION BY p.CategoryId ORDER BY SUM(s.Revenue) DESC) AS RankInCategory
FROM dbo.SalesDaily AS s
CROSS JOIN dbo.SimClock AS c
JOIN dbo.Product  AS p   ON p.ProductId  = s.ProductId
JOIN dbo.Category AS cat ON cat.CategoryId = p.CategoryId
WHERE s.SaleDate >= DATEADD(DAY, -90, c.SimDate) AND s.SaleDate < c.SimDate
GROUP BY p.CategoryId, cat.Name, p.ProductId, p.Sku, p.Name;
GO

-- ------------------------------------------------------------------ Category hierarchy roll-up (recursive CTE)
-- The tree walks from each top-level category down to its children, then sales roll up to the top level.
CREATE OR ALTER VIEW dbo.vw_CategoryRollup AS
WITH tree AS (
    SELECT CategoryId AS RootId, CategoryId, Name AS RootName, 0 AS Depth
    FROM dbo.Category
    WHERE ParentCategoryId IS NULL
    UNION ALL
    SELECT t.RootId, ch.CategoryId, t.RootName, t.Depth + 1
    FROM tree AS t
    JOIN dbo.Category AS ch ON ch.ParentCategoryId = t.CategoryId
),
sales AS (
    SELECT p.CategoryId, SUM(s.Revenue) AS Revenue90, SUM(s.Quantity) AS Units90
    FROM dbo.SalesDaily AS s
    CROSS JOIN dbo.SimClock AS c
    JOIN dbo.Product AS p ON p.ProductId = s.ProductId
    WHERE s.SaleDate >= DATEADD(DAY, -90, c.SimDate) AND s.SaleDate < c.SimDate
    GROUP BY p.CategoryId
)
SELECT
    t.RootId   AS TopCategoryId,
    t.RootName AS TopCategory,
    COUNT(DISTINCT CASE WHEN t.Depth = 1 THEN t.CategoryId END) AS SubCategories,
    SUM(ISNULL(sa.Revenue90, 0)) AS Revenue90,
    SUM(ISNULL(sa.Units90, 0))   AS Units90
FROM tree AS t
LEFT JOIN sales AS sa ON sa.CategoryId = t.CategoryId
GROUP BY t.RootId, t.RootName;
GO

-- ------------------------------------------------------------------ Monthly sales by warehouse with month-over-month growth (LAG over an aggregate)
CREATE OR ALTER VIEW dbo.vw_SalesMonthly AS
SELECT
    DATEFROMPARTS(YEAR(s.SaleDate), MONTH(s.SaleDate), 1) AS MonthStart,
    w.WarehouseId,
    w.City,
    SUM(s.Quantity) AS Units,
    SUM(s.Revenue)  AS Revenue,
    CAST(100.0 * (SUM(s.Revenue) - LAG(SUM(s.Revenue)) OVER (PARTITION BY w.WarehouseId
                                                             ORDER BY DATEFROMPARTS(YEAR(s.SaleDate), MONTH(s.SaleDate), 1)))
          / NULLIF(LAG(SUM(s.Revenue)) OVER (PARTITION BY w.WarehouseId
                                             ORDER BY DATEFROMPARTS(YEAR(s.SaleDate), MONTH(s.SaleDate), 1)), 0)
         AS decimal(7,2)) AS RevenueGrowthPct
FROM dbo.SalesDaily AS s
JOIN dbo.Warehouse AS w ON w.WarehouseId = s.WarehouseId
GROUP BY DATEFROMPARTS(YEAR(s.SaleDate), MONTH(s.SaleDate), 1), w.WarehouseId, w.City;
GO
