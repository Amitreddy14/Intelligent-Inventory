-- Phase 2 demo (NOT run by init.sh). Run section by section in VS Code / SSMS.
-- Product 42 in warehouse 4 is a stocked item; swap in any (ProductId, WarehouseId) that exists in dbo.Inventory.

USE InventoryDB;
GO

-- ============================================================ A. Window functions: moving averages and LAG
SELECT TOP (14) SaleDate, Quantity, MovingAvg7, MovingAvg28, QtySameDayLastWeek, RunningUnits
FROM dbo.vw_DemandMovingAvg
WHERE ProductId = 42 AND WarehouseId = 4
ORDER BY SaleDate DESC;
GO

-- ============================================================ B. ABC / XYZ matrix (cumulative SUM OVER + coefficient of variation)
SELECT AbcClass, XyzClass, COUNT(*) AS Products, SUM(Revenue1Y) AS Revenue1Y
FROM dbo.vw_ABC_XYZ
GROUP BY AbcClass, XyzClass
ORDER BY AbcClass, XyzClass;
GO

-- ============================================================ C. Recursive CTE: category tree roll-up
SELECT * FROM dbo.vw_CategoryRollup ORDER BY Revenue90 DESC;
GO

-- ============================================================ D. Forecast vs actual (backtest of the last 28 days)
SELECT Method, Observations, WapePct, BiasPct, MapePct
FROM dbo.vw_ForecastAccuracy
WHERE RunType = 'BACKTEST';
GO

-- One item: forecast next to what really happened, day by day
SELECT TargetDate, Method, ForecastQty, ActualQty, SignedError
FROM dbo.vw_ForecastErrorDaily
WHERE RunType = 'BACKTEST' AND ProductId = 42 AND WarehouseId = 4
ORDER BY TargetDate, Method;
GO

-- ============================================================ E. Supplier ranking (JSON_VALUE + ROW_NUMBER)
SELECT ProductId, SupplierRank, SupplierName, UnitPrice, DiscountPct, ReliabilityPct, LeadTimeDays, AdjustedUnitCost
FROM dbo.vw_SupplierRank
WHERE ProductId = 42
ORDER BY SupplierRank;
GO

-- ============================================================ F. Inventory health and the most urgent items
SELECT TOP (15) ProductName, City, OnHand, ReorderPoint, SafetyStock, AvgDaily28, DaysOfCover, StockStatus
FROM dbo.vw_StockHealth
WHERE StockStatus IN ('STOCKOUT', 'CRITICAL')
ORDER BY DaysOfCover;
GO

-- ============================================================ G. Recommendations: what to order, from whom, how many, why
SELECT TOP (15) r.RecId, p.Name AS Product, w.City, r.Action, r.Priority, r.OrderQty, s.Name AS Supplier, r.Reason
FROM dbo.Recommendation AS r
JOIN dbo.Product   AS p ON p.ProductId   = r.ProductId
JOIN dbo.Warehouse AS w ON w.WarehouseId = r.WarehouseId
LEFT JOIN dbo.Supplier AS s ON s.SupplierId = r.SupplierId
WHERE r.Status = 'OPEN'
ORDER BY r.Priority, r.OrderQty DESC;
GO

-- ============================================================ H. Transaction: approve a recommendation, then receive the goods
-- Creates a purchase order (trigger writes the audit trail), then books the stock receipt atomically.
DECLARE @RecId int = (SELECT TOP (1) RecId FROM dbo.Recommendation
                      WHERE Action = 'ORDER' AND Status = 'OPEN' ORDER BY Priority, RecId);
DECLARE @Po int;
EXEC dbo.usp_CreatePoFromRecommendation @RecId = @RecId, @PoId = @Po OUTPUT;
SELECT @Po AS NewPoId;

SELECT * FROM dbo.PurchaseOrder     WHERE PoId = @Po;
SELECT * FROM dbo.PurchaseOrderLine WHERE PoId = @Po;

EXEC dbo.usp_ReceivePo @PoId = @Po;
SELECT * FROM dbo.PurchaseOrder WHERE PoId = @Po;
SELECT TOP (5) * FROM dbo.StockMovement WHERE RefType = 'PO' AND RefId = @Po;
GO

-- ============================================================ I. Triggers: audit trail and business rule
SELECT TOP (10) AuditId, EventTime, UserName, TableName, Operation, KeyValue, OldValues, NewValues
FROM dbo.AuditLog ORDER BY AuditId DESC;
GO

-- Rule: reserved stock can never exceed on-hand stock. This statement is rejected by trg_Inventory_Rules.
BEGIN TRY
    UPDATE dbo.Inventory SET Reserved = OnHand + 1 WHERE ProductId = 42 AND WarehouseId = 4;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
GO
