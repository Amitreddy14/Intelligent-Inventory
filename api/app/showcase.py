"""Curated, read-only queries for the SQL Showcase page.

Each item shows the exact T-SQL behind a feature next to its live result. The SQL is fixed (never taken from
the client), so this endpoint cannot be used to run arbitrary statements.
"""

ITEMS = [
    {
        "key": "moving-average",
        "title": "Moving averages and week-over-week comparison",
        "tags": ["Window functions", "Frame clauses", "LAG"],
        "explanation": "AVG() OVER with ROWS BETWEEN gives 7- and 28-day moving averages per item without self-joins; "
                       "LAG(7) pulls the same weekday from last week; a running SUM accumulates units sold.",
        "plan_note": "Seek on IX_Sales_Product_Warehouse_Date (covering index), then a Window Spool/Stream Aggregate.",
        "queries": [{"label": "Last 14 days for product 42, warehouse 4", "sql": """SELECT TOP (14)
       SaleDate, Quantity, MovingAvg7, MovingAvg28, QtySameDayLastWeek, RunningUnits
FROM   dbo.vw_DemandMovingAvg
WHERE  ProductId = 42 AND WarehouseId = 4
ORDER  BY SaleDate DESC;"""}],
    },
    {
        "key": "abc-xyz",
        "title": "ABC / XYZ classification",
        "tags": ["Window functions", "Cumulative SUM OVER", "CTEs", "STDEV"],
        "explanation": "ABC ranks products by revenue and uses a cumulative share (SUM OVER ... UNBOUNDED PRECEDING) so A "
                       "products make the first 80%. XYZ uses the coefficient of variation of weekly demand.",
        "plan_note": "Several aggregate passes over the last 364 days of SalesDaily; the columnstore index serves the scans.",
        "queries": [{"label": "Products and revenue per segment", "sql": """SELECT AbcClass, XyzClass,
       COUNT(*)        AS Products,
       SUM(Revenue1Y)  AS Revenue1Y
FROM   dbo.vw_ABC_XYZ
GROUP  BY AbcClass, XyzClass
ORDER  BY AbcClass, XyzClass;"""}],
    },
    {
        "key": "category-tree",
        "title": "Category hierarchy roll-up",
        "tags": ["Recursive CTE", "Self-referencing table"],
        "explanation": "A recursive CTE walks from each top-level category to its children so that sales roll up the tree.",
        "plan_note": "Look for the Index Spool (recursive part) feeding a Nested Loops join to Category.",
        "queries": [{"label": "Categories rolled up under each top-level category", "sql": """WITH tree AS (
    SELECT CategoryId AS RootId, CategoryId, Name AS RootName, 0 AS Depth
    FROM   dbo.Category WHERE ParentCategoryId IS NULL
    UNION ALL
    SELECT t.RootId, c.CategoryId, t.RootName, t.Depth + 1
    FROM   tree t JOIN dbo.Category c ON c.ParentCategoryId = t.CategoryId
)
SELECT t.RootName AS TopCategory, COUNT(*) AS CategoriesInTree
FROM   tree t
GROUP  BY t.RootName
ORDER  BY t.RootName;"""}],
    },
    {
        "key": "partition-elimination",
        "title": "Monthly partitioning and partition elimination",
        "tags": ["Partitioning", "Partition function", "RANGE RIGHT"],
        "explanation": "SalesDaily is partitioned by month. A query that filters on one month reads only that partition; "
                       "$PARTITION shows which partition each row lives in.",
        "plan_note": "In the actual execution plan, the scan shows 'Actual Partition Count = 1' for the single-month query.",
        "queries": [
            {"label": "Rows per partition (last 6 months of data)", "sql": """SELECT TOP (6)
       $PARTITION.pf_SalesMonthly(SaleDate) AS PartitionNo,
       MIN(SaleDate) AS FirstDay, MAX(SaleDate) AS LastDay, COUNT(*) AS RowCnt
FROM   dbo.SalesDaily
GROUP  BY $PARTITION.pf_SalesMonthly(SaleDate)
ORDER  BY PartitionNo DESC;"""},
            {"label": "One month only: October 2026 by warehouse", "sql": """SELECT w.City, SUM(s.Quantity) AS Units, SUM(s.Revenue) AS Revenue
FROM   dbo.SalesDaily s
JOIN   dbo.Warehouse w ON w.WarehouseId = s.WarehouseId
WHERE  s.SaleDate >= '2026-10-01' AND s.SaleDate < '2026-11-01'
GROUP  BY w.City
ORDER  BY Revenue DESC;"""},
        ],
    },
    {
        "key": "columnstore",
        "title": "Row store vs columnstore index (same query, two plans)",
        "tags": ["Columnstore", "Batch mode", "Index tuning"],
        "explanation": "The same aggregate over 1.1 million rows, first forced onto the row store, then allowed to use the "
                       "nonclustered columnstore index NCCI_SalesDaily. Compare the elapsed times below.",
        "plan_note": "Second plan shows a Columnstore Index Scan with batch-mode operators; the first reads the clustered rowstore.",
        "warmup": True,
        "queries": [
            {"label": "Rowstore only (columnstore ignored)", "sql": """SELECT YEAR(s.SaleDate) AS Yr, MONTH(s.SaleDate) AS Mth, w.City,
       SUM(s.Quantity) AS Units, SUM(s.Revenue) AS Revenue
FROM   dbo.SalesDaily s
JOIN   dbo.Warehouse w ON w.WarehouseId = s.WarehouseId
GROUP  BY YEAR(s.SaleDate), MONTH(s.SaleDate), w.City
OPTION (IGNORE_NONCLUSTERED_COLUMNSTORE_INDEX);"""},
            {"label": "With columnstore index", "sql": """SELECT YEAR(s.SaleDate) AS Yr, MONTH(s.SaleDate) AS Mth, w.City,
       SUM(s.Quantity) AS Units, SUM(s.Revenue) AS Revenue
FROM   dbo.SalesDaily s
JOIN   dbo.Warehouse w ON w.WarehouseId = s.WarehouseId
GROUP  BY YEAR(s.SaleDate), MONTH(s.SaleDate), w.City;"""},
        ],
    },
    {
        "key": "forecast-accuracy",
        "title": "Forecast accuracy (28-day backtest)",
        "tags": ["Views", "Aggregation", "Set-based forecasting"],
        "explanation": "usp_RunForecast forecasts the last 28 days using only older data. The view joins forecasts to actual "
                       "demand and reports WAPE (error as a share of demand) and bias.",
        "plan_note": "Join between Forecast (items x days x methods) and SalesDaily on the clustered key.",
        "queries": [{"label": "Method comparison", "sql": """SELECT Method, Observations, WapePct, BiasPct, MapePct
FROM   dbo.vw_ForecastAccuracy
WHERE  RunType = 'BACKTEST'
ORDER  BY RunId DESC, Method;"""}],
    },
    {
        "key": "supplier-ranking",
        "title": "Supplier ranking from JSON contract terms",
        "tags": ["JSON_VALUE", "ROW_NUMBER", "CROSS APPLY"],
        "explanation": "Discount and payment terms are stored as JSON in SupplierProduct.TermsJson (validated with ISJSON). "
                       "JSON_VALUE extracts them, a cost adjusted for reliability is computed, and ROW_NUMBER picks the best supplier.",
        "plan_note": "Compute Scalar for JSON_VALUE, then a Segment/Sequence Project for ROW_NUMBER.",
        "queries": [{"label": "Supplier offers for product 42", "sql": """SELECT SupplierRank, SupplierName, UnitPrice, DiscountPct,
       ReliabilityPct, LeadTimeDays, AdjustedUnitCost
FROM   dbo.vw_SupplierRank
WHERE  ProductId = 42
ORDER  BY SupplierRank;"""}],
    },
    {
        "key": "stock-health",
        "title": "Stock health and reorder logic",
        "tags": ["Views", "CASE", "Safety stock", "Reorder point"],
        "explanation": "Reorder point = forecast demand over the supplier lead time + safety stock (z x std x sqrt(lead time)). "
                       "The view classifies every item as STOCKOUT, CRITICAL, LOW, HEALTHY or OVERSTOCK.",
        "plan_note": "Joins Inventory to demand statistics (90-day aggregate) and open purchase orders.",
        "queries": [{"label": "Most urgent items", "sql": """SELECT TOP (15) ProductName, City, OnHand, ReorderPoint, SafetyStock,
       AvgDaily28, DaysOfCover, StockStatus
FROM   dbo.vw_StockHealth
WHERE  StockStatus IN ('STOCKOUT', 'CRITICAL')
ORDER  BY DaysOfCover;"""}],
    },
    {
        "key": "recommendations",
        "title": "Procurement recommendations (EOQ)",
        "tags": ["Stored procedure", "EOQ", "Transactions"],
        "explanation": "usp_GenerateRecommendations compares inventory position (on hand + on order - reserved) with the reorder point "
                       "and sizes the order with EOQ = sqrt(2DS/H), respecting the supplier minimum order quantity.",
        "plan_note": "Set-based: one INSERT ... SELECT over all items, no cursors.",
        "queries": [{"label": "Most urgent open recommendations", "sql": """SELECT TOP (10) r.RecId, p.Name AS Product, w.City, r.Action, r.Priority,
       r.OrderQty, s.Name AS Supplier
FROM   dbo.Recommendation r
JOIN   dbo.Product   p ON p.ProductId   = r.ProductId
JOIN   dbo.Warehouse w ON w.WarehouseId = r.WarehouseId
LEFT JOIN dbo.Supplier s ON s.SupplierId = r.SupplierId
WHERE  r.Status = 'OPEN'
ORDER  BY r.Priority, r.OrderQty DESC;"""}],
    },
    {
        "key": "audit-triggers",
        "title": "Triggers and audit trail",
        "tags": ["Triggers", "SESSION_CONTEXT", "FOR JSON"],
        "explanation": "AFTER triggers on Inventory, Product, PurchaseOrder and AppUser write to AuditLog. The API stores the signed-in "
                       "user with sp_set_session_context, and the triggers read it back, so the log shows who made each change.",
        "plan_note": "Trigger work appears in the plan of the statement that fired it.",
        "queries": [{"label": "Latest audit entries", "sql": """SELECT TOP (10) AuditId, EventTime, UserName, TableName, Operation,
       KeyValue, OldValues, NewValues
FROM   dbo.AuditLog
ORDER  BY AuditId DESC;"""}],
    },
    {
        "key": "monthly-growth",
        "title": "Month-over-month growth per warehouse",
        "tags": ["Window functions", "LAG over aggregate", "PARTITION BY"],
        "explanation": "LAG() applied to a SUM() computes growth against the previous month inside each warehouse in a single pass.",
        "plan_note": "Hash/Stream Aggregate followed by a Window Spool partitioned by warehouse.",
        "queries": [{"label": "Latest months, Chennai Hub", "sql": """SELECT TOP (8) MonthStart, City, Units, Revenue, RevenueGrowthPct
FROM   dbo.vw_SalesMonthly
WHERE  WarehouseId = 1
ORDER  BY MonthStart DESC;"""}],
    },
]

BY_KEY = {item["key"]: item for item in ITEMS}
