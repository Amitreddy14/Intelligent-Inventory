-- 10_triggers.sql
-- Business rules and an audit trail, enforced inside the database.
-- The API sets the acting user with:  EXEC sp_set_session_context 'app_user', N'admin';
-- The triggers read it back with SESSION_CONTEXT, falling back to the SQL login.

USE InventoryDB;
GO

-- ------------------------------------------------------------------ Inventory: reserved <= on hand, and stockout alert
CREATE OR ALTER TRIGGER dbo.trg_Inventory_Rules
ON dbo.Inventory
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM inserted WHERE Reserved > OnHand)
    BEGIN
        ROLLBACK TRANSACTION;
        THROW 50030, 'Reserved quantity cannot exceed on-hand stock.', 1;
    END;

    -- Stock just hit zero: write an alert to the audit log
    IF UPDATE(OnHand)
    BEGIN
        INSERT dbo.AuditLog (UserName, TableName, Operation, KeyValue, OldValues, NewValues)
        SELECT COALESCE(CONVERT(nvarchar(128), SESSION_CONTEXT(N'app_user')), SUSER_SNAME()),
               'Inventory', 'STOCKOUT',
               CONCAT('P', i.ProductId, '/W', i.WarehouseId),
               CONCAT('{"OnHand":', d.OnHand, '}'),
               CONCAT('{"OnHand":', i.OnHand, '}')
        FROM inserted AS i
        JOIN deleted  AS d ON d.ProductId = i.ProductId AND d.WarehouseId = i.WarehouseId
        WHERE d.OnHand > 0 AND i.OnHand = 0;
    END;
END
GO

-- ------------------------------------------------------------------ Product: log price and cost changes (old and new as JSON)
CREATE OR ALTER TRIGGER dbo.trg_Product_Audit
ON dbo.Product
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF UPDATE(UnitCost) OR UPDATE(UnitPrice)
    BEGIN
        INSERT dbo.AuditLog (UserName, TableName, Operation, KeyValue, OldValues, NewValues)
        SELECT COALESCE(CONVERT(nvarchar(128), SESSION_CONTEXT(N'app_user')), SUSER_SNAME()),
               'Product', 'UPDATE',
               CAST(i.ProductId AS nvarchar(100)),
               (SELECT d.UnitCost, d.UnitPrice FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
               (SELECT i.UnitCost, i.UnitPrice FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
        FROM inserted AS i
        JOIN deleted  AS d ON d.ProductId = i.ProductId
        WHERE i.UnitCost <> d.UnitCost OR i.UnitPrice <> d.UnitPrice;
    END;
END
GO

-- ------------------------------------------------------------------ Purchase orders: log creation and every status change
CREATE OR ALTER TRIGGER dbo.trg_PurchaseOrder_Audit
ON dbo.PurchaseOrder
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    INSERT dbo.AuditLog (UserName, TableName, Operation, KeyValue, OldValues, NewValues)
    SELECT COALESCE(CONVERT(nvarchar(128), SESSION_CONTEXT(N'app_user')), SUSER_SNAME()),
           'PurchaseOrder',
           CASE WHEN d.PoId IS NULL THEN 'INSERT' ELSE 'STATUS' END,
           CAST(i.PoId AS nvarchar(100)),
           CASE WHEN d.PoId IS NULL THEN NULL ELSE CONCAT('{"Status":"', d.Status, '"}') END,
           CONCAT('{"Status":"', i.Status, '","TotalCost":', i.TotalCost, '}')
    FROM inserted AS i
    LEFT JOIN deleted AS d ON d.PoId = i.PoId
    WHERE d.PoId IS NULL OR d.Status <> i.Status;
END
GO

-- ------------------------------------------------------------------ Users: log new accounts, role changes and (de)activation
CREATE OR ALTER TRIGGER dbo.trg_AppUser_Audit
ON dbo.AppUser
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    INSERT dbo.AuditLog (UserName, TableName, Operation, KeyValue, OldValues, NewValues)
    SELECT COALESCE(CONVERT(nvarchar(128), SESSION_CONTEXT(N'app_user')), SUSER_SNAME()),
           'AppUser',
           CASE WHEN d.UserId IS NULL THEN 'INSERT' ELSE 'UPDATE' END,
           i.Username,
           CASE WHEN d.UserId IS NULL THEN NULL ELSE CONCAT('{"Role":"', d.Role, '","IsActive":', d.IsActive, '}') END,
           CONCAT('{"Role":"', i.Role, '","IsActive":', i.IsActive, '}')
    FROM inserted AS i
    LEFT JOIN deleted AS d ON d.UserId = i.UserId
    WHERE d.UserId IS NULL OR d.Role <> i.Role OR d.IsActive <> i.IsActive;
END
GO
