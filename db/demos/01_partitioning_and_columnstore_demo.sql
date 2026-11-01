-- Demo script for the review (NOT run by init.sh). Open in SSMS / Azure Data Studio and run section by section.
-- Turn on "Include Actual Execution Plan" (Ctrl+M in SSMS) to compare plans.

USE InventoryDB;
GO
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO

-- ============================================================ A. Partitioning: rows per monthly partition
SELECT $PARTITION.pf_SalesMonthly(SaleDate) AS PartitionNo,
       MIN(SaleDate) AS FirstDay, MAX(SaleDate) AS LastDay, COUNT(*) AS RowCnt
FROM dbo.SalesDaily
GROUP BY $PARTITION.pf_SalesMonthly(SaleDate)
ORDER BY PartitionNo;
GO

-- ============================================================ B. Partition elimination
-- Look at the plan: "Actual Partition Count" = 1, so only October 2026 is read.
SELECT w.City, SUM(s.Quantity) AS Units, SUM(s.Revenue) AS Revenue
FROM dbo.SalesDaily s
JOIN dbo.Warehouse w ON w.WarehouseId = s.WarehouseId
WHERE s.SaleDate >= '2026-10-01' AND s.SaleDate < '2026-11-01'
GROUP BY w.City;
GO

-- ============================================================ C. Row store vs columnstore (same query, two plans)
-- C1: force the row store (ignores the columnstore index). Note logical reads and elapsed time.
SELECT YEAR(s.SaleDate) AS Yr, MONTH(s.SaleDate) AS Mth, w.City,
       SUM(s.Quantity) AS Units, SUM(s.Revenue) AS Revenue
FROM dbo.SalesDaily s
JOIN dbo.Warehouse w ON w.WarehouseId = s.WarehouseId
GROUP BY YEAR(s.SaleDate), MONTH(s.SaleDate), w.City
OPTION (IGNORE_NONCLUSTERED_COLUMNSTORE_INDEX);
GO

-- C2: let the optimizer use NCCI_SalesDaily. Look for "Columnstore Index Scan" and batch-mode operators.
SELECT YEAR(s.SaleDate) AS Yr, MONTH(s.SaleDate) AS Mth, w.City,
       SUM(s.Quantity) AS Units, SUM(s.Revenue) AS Revenue
FROM dbo.SalesDaily s
JOIN dbo.Warehouse w ON w.WarehouseId = s.WarehouseId
GROUP BY YEAR(s.SaleDate), MONTH(s.SaleDate), w.City;
GO

-- ============================================================ D. Covering index for one item's time series
-- Seek on IX_Sales_Product_Warehouse_Date, no key lookup (all columns are INCLUDEd).
SELECT SaleDate, Quantity, Revenue, PromoFlag
FROM dbo.SalesDaily
WHERE ProductId = 42 AND WarehouseId = 1 AND SaleDate >= '2026-07-01'
ORDER BY SaleDate;
GO

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO
