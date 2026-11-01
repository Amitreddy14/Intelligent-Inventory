-- 05_indexes.sql
-- Supporting indexes. The clustered PK on SalesDaily is (SaleDate, ProductId, WarehouseId), so the
-- indexes below serve queries that start from a product or warehouse, plus a columnstore for analytics.

USE InventoryDB;
GO

-- Time series per product/warehouse (forecasting reads exactly this shape). Partition-aligned on SaleDate.
CREATE NONCLUSTERED INDEX IX_Sales_Product_Warehouse_Date
    ON dbo.SalesDaily (ProductId, WarehouseId, SaleDate)
    INCLUDE (Quantity, LostQty, Revenue, PromoFlag)
    ON ps_SalesMonthly (SaleDate);
GO

-- Analytical scans (totals by month, warehouse, category). Updatable nonclustered columnstore.
CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_SalesDaily
    ON dbo.SalesDaily (SaleDate, ProductId, WarehouseId, Quantity, LostQty, Revenue, PromoFlag)
    ON ps_SalesMonthly (SaleDate);
GO

CREATE NONCLUSTERED INDEX IX_Inventory_Warehouse
    ON dbo.Inventory (WarehouseId)
    INCLUDE (OnHand, Reserved, ReorderPoint, SafetyStock);
GO

CREATE NONCLUSTERED INDEX IX_Product_Category
    ON dbo.Product (CategoryId)
    INCLUDE (Sku, Name, UnitCost, UnitPrice);
GO

CREATE NONCLUSTERED INDEX IX_SupplierProduct_Product
    ON dbo.SupplierProduct (ProductId)
    INCLUDE (SupplierId, UnitPrice, LeadTimeDays, MinOrderQty);
GO

CREATE NONCLUSTERED INDEX IX_StockMovement_Item_Date
    ON dbo.StockMovement (ProductId, WarehouseId, MovementDate)
    INCLUDE (MovementType, Quantity);
GO

CREATE NONCLUSTERED INDEX IX_Forecast_Item_Target
    ON dbo.Forecast (ProductId, WarehouseId, TargetDate)
    INCLUDE (Method, ForecastQty, RunId);
GO

CREATE NONCLUSTERED INDEX IX_Recommendation_Status
    ON dbo.Recommendation (Status, Priority)
    INCLUDE (ProductId, WarehouseId, Action, OrderQty);
GO

CREATE NONCLUSTERED INDEX IX_PO_Status
    ON dbo.PurchaseOrder (Status, ExpectedDate)
    INCLUDE (SupplierId, WarehouseId, TotalCost);
GO
