-- 06_verify.sql
-- Sanity checks for the Phase 1 data. (The "setup complete" marker is created by 99_ready.sql.)

USE InventoryDB;
GO
SET NOCOUNT ON;
GO

SELECT 'Category' AS TableName, COUNT(*) AS RowCnt FROM dbo.Category
UNION ALL SELECT 'Product',         COUNT(*) FROM dbo.Product
UNION ALL SELECT 'Warehouse',       COUNT(*) FROM dbo.Warehouse
UNION ALL SELECT 'Supplier',        COUNT(*) FROM dbo.Supplier
UNION ALL SELECT 'SupplierProduct', COUNT(*) FROM dbo.SupplierProduct
UNION ALL SELECT 'Inventory',       COUNT(*) FROM dbo.Inventory
UNION ALL SELECT 'SalesDaily',      COUNT(*) FROM dbo.SalesDaily
UNION ALL SELECT 'StockMovement',   COUNT(*) FROM dbo.StockMovement;
GO

-- Rows per monthly partition of SalesDaily (RANGE RIGHT: lower bound of partition n is boundary n-1).
SELECT p.partition_number AS PartitionNo,
       CAST(rv.value AS date) AS FromDate,
       p.[rows] AS RowCnt
FROM sys.partitions p
LEFT JOIN sys.partition_range_values rv
       ON rv.function_id = (SELECT function_id FROM sys.partition_functions WHERE name = 'pf_SalesMonthly')
      AND rv.boundary_id = p.partition_number - 1
WHERE p.object_id = OBJECT_ID('dbo.SalesDaily')
  AND p.index_id = 1
  AND p.[rows] > 0
ORDER BY p.partition_number;
GO

-- Stock health snapshot: how many items are at or below their reorder point right now.
SELECT COUNT(*) AS StockedItems,
       SUM(CASE WHEN OnHand <= ReorderPoint THEN 1 ELSE 0 END) AS AtOrBelowReorderPoint,
       SUM(CASE WHEN OnHand = 0 THEN 1 ELSE 0 END)             AS OutOfStock
FROM dbo.Inventory;
GO
