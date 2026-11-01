-- 02_schema.sql
-- All tables. SalesDaily is partitioned by month on ps_SalesMonthly.

USE InventoryDB;
GO

-- ---------------------------------------------------------------- Reference data
CREATE TABLE dbo.Category (
    CategoryId       int           NOT NULL CONSTRAINT PK_Category PRIMARY KEY,
    ParentCategoryId int           NULL     CONSTRAINT FK_Category_Parent REFERENCES dbo.Category (CategoryId),
    Name             nvarchar(60)  NOT NULL CONSTRAINT UQ_Category_Name UNIQUE
);
GO

CREATE TABLE dbo.Product (
    ProductId   int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Product PRIMARY KEY,
    Sku         varchar(20)    NOT NULL CONSTRAINT UQ_Product_Sku UNIQUE,
    Name        nvarchar(120)  NOT NULL,
    CategoryId  int            NOT NULL CONSTRAINT FK_Product_Category REFERENCES dbo.Category (CategoryId),
    UnitCost    decimal(10,2)  NOT NULL CONSTRAINT CK_Product_Cost  CHECK (UnitCost > 0),
    UnitPrice   decimal(10,2)  NOT NULL,
    IsActive    bit            NOT NULL CONSTRAINT DF_Product_Active DEFAULT (1),
    CreatedAt   datetime2(0)   NOT NULL CONSTRAINT DF_Product_Created DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT CK_Product_Margin CHECK (UnitPrice >= UnitCost)
);
GO

CREATE TABLE dbo.Warehouse (
    WarehouseId     int           NOT NULL CONSTRAINT PK_Warehouse PRIMARY KEY,
    Name            nvarchar(60)  NOT NULL CONSTRAINT UQ_Warehouse_Name UNIQUE,
    City            nvarchar(60)  NOT NULL,
    DemandFactor    decimal(4,2)  NOT NULL,          -- regional demand multiplier used by the data generator
    HoldingCostPct  decimal(5,2)  NOT NULL           -- annual holding cost as % of unit cost (EOQ input)
);
GO

CREATE TABLE dbo.Supplier (
    SupplierId      int           NOT NULL CONSTRAINT PK_Supplier PRIMARY KEY,
    Name            nvarchar(80)  NOT NULL CONSTRAINT UQ_Supplier_Name UNIQUE,
    City            nvarchar(60)  NOT NULL,
    OrderingCost    decimal(10,2) NOT NULL,          -- fixed cost per purchase order (EOQ input)
    ReliabilityPct  tinyint       NOT NULL CONSTRAINT CK_Supplier_Rel CHECK (ReliabilityPct BETWEEN 0 AND 100)
);
GO

CREATE TABLE dbo.SupplierProduct (
    SupplierId    int            NOT NULL CONSTRAINT FK_SP_Supplier REFERENCES dbo.Supplier (SupplierId),
    ProductId     int            NOT NULL CONSTRAINT FK_SP_Product  REFERENCES dbo.Product (ProductId),
    UnitPrice     decimal(10,2)  NOT NULL,
    LeadTimeDays  smallint       NOT NULL CONSTRAINT CK_SP_Lead CHECK (LeadTimeDays > 0),
    MinOrderQty   int            NOT NULL CONSTRAINT CK_SP_Moq  CHECK (MinOrderQty > 0),
    TermsJson     nvarchar(max)  NOT NULL CONSTRAINT CK_SP_Json CHECK (ISJSON(TermsJson) = 1),
    CONSTRAINT PK_SupplierProduct PRIMARY KEY (SupplierId, ProductId)
);
GO

-- ---------------------------------------------------------------- Stock
CREATE TABLE dbo.Inventory (
    ProductId     int           NOT NULL CONSTRAINT FK_Inv_Product   REFERENCES dbo.Product (ProductId),
    WarehouseId   int           NOT NULL CONSTRAINT FK_Inv_Warehouse REFERENCES dbo.Warehouse (WarehouseId),
    OnHand        int           NOT NULL CONSTRAINT DF_Inv_OnHand  DEFAULT (0) CONSTRAINT CK_Inv_OnHand  CHECK (OnHand  >= 0),
    Reserved      int           NOT NULL CONSTRAINT DF_Inv_Reserved DEFAULT (0) CONSTRAINT CK_Inv_Reserved CHECK (Reserved >= 0),
    ReorderPoint  int           NOT NULL CONSTRAINT DF_Inv_ROP     DEFAULT (0),
    SafetyStock   int           NOT NULL CONSTRAINT DF_Inv_SS      DEFAULT (0),
    LastUpdated   datetime2(0)  NOT NULL CONSTRAINT DF_Inv_Updated DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_Inventory PRIMARY KEY (ProductId, WarehouseId)
);
GO

-- Partitioned fact table: one row per product, warehouse and day.
-- The clustered PK includes SaleDate (the partitioning column), so it is partition-aligned.
CREATE TABLE dbo.SalesDaily (
    SaleDate     date           NOT NULL,
    ProductId    int            NOT NULL,
    WarehouseId  int            NOT NULL,
    Quantity     int            NOT NULL CONSTRAINT CK_Sales_Qty CHECK (Quantity >= 0),
    LostQty      int            NOT NULL CONSTRAINT DF_Sales_Lost DEFAULT (0),   -- demand missed because of stockout
    Revenue      decimal(12,2)  NOT NULL,
    PromoFlag    bit            NOT NULL CONSTRAINT DF_Sales_Promo DEFAULT (0),
    CONSTRAINT PK_SalesDaily PRIMARY KEY CLUSTERED (SaleDate, ProductId, WarehouseId)
        ON ps_SalesMonthly (SaleDate),
    CONSTRAINT FK_Sales_Inventory FOREIGN KEY (ProductId, WarehouseId)
        REFERENCES dbo.Inventory (ProductId, WarehouseId)
) ON ps_SalesMonthly (SaleDate);
GO

CREATE TABLE dbo.StockMovement (
    MovementId    bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_StockMovement PRIMARY KEY,
    MovementDate  date          NOT NULL,
    ProductId     int           NOT NULL,
    WarehouseId   int           NOT NULL,
    MovementType  varchar(12)   NOT NULL
        CONSTRAINT CK_SM_Type CHECK (MovementType IN ('OPENING','SALE','RECEIPT','ADJUSTMENT','TRANSFER_IN','TRANSFER_OUT')),
    Quantity      int           NOT NULL,                 -- signed: receipts positive, sales negative
    RefType       varchar(10)   NULL,                     -- e.g. 'PO'
    RefId         int           NULL,
    CreatedAt     datetime2(0)  NOT NULL CONSTRAINT DF_SM_Created DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT FK_SM_Inventory FOREIGN KEY (ProductId, WarehouseId)
        REFERENCES dbo.Inventory (ProductId, WarehouseId)
);
GO

-- ---------------------------------------------------------------- Procurement
CREATE TABLE dbo.AppUser (
    UserId        int IDENTITY(1,1) NOT NULL CONSTRAINT PK_AppUser PRIMARY KEY,
    Username      varchar(50)   NOT NULL CONSTRAINT UQ_AppUser_Username UNIQUE,
    PasswordHash  varchar(100)  NOT NULL,
    FullName      nvarchar(80)  NOT NULL,
    Role          varchar(10)   NOT NULL CONSTRAINT CK_AppUser_Role CHECK (Role IN ('ADMIN','MANAGER','VIEWER')),
    IsActive      bit           NOT NULL CONSTRAINT DF_AppUser_Active DEFAULT (1),
    CreatedAt     datetime2(0)  NOT NULL CONSTRAINT DF_AppUser_Created DEFAULT (SYSUTCDATETIME()),
    LastLoginAt   datetime2(0)  NULL
);
GO

CREATE TABLE dbo.PurchaseOrder (
    PoId          int IDENTITY(1,1) NOT NULL CONSTRAINT PK_PurchaseOrder PRIMARY KEY,
    SupplierId    int           NOT NULL CONSTRAINT FK_PO_Supplier  REFERENCES dbo.Supplier (SupplierId),
    WarehouseId   int           NOT NULL CONSTRAINT FK_PO_Warehouse REFERENCES dbo.Warehouse (WarehouseId),
    Status        varchar(12)   NOT NULL CONSTRAINT DF_PO_Status DEFAULT ('DRAFT')
        CONSTRAINT CK_PO_Status CHECK (Status IN ('DRAFT','APPROVED','IN_TRANSIT','RECEIVED','CANCELLED')),
    OrderDate     date          NOT NULL,
    ExpectedDate  date          NOT NULL,
    ReceivedDate  date          NULL,
    TotalCost     decimal(14,2) NOT NULL CONSTRAINT DF_PO_Total DEFAULT (0),
    CreatedBy     int           NULL CONSTRAINT FK_PO_User REFERENCES dbo.AppUser (UserId),
    CreatedAt     datetime2(0)  NOT NULL CONSTRAINT DF_PO_Created DEFAULT (SYSUTCDATETIME())
);
GO

CREATE TABLE dbo.PurchaseOrderLine (
    PoId        int            NOT NULL CONSTRAINT FK_POL_PO      REFERENCES dbo.PurchaseOrder (PoId),
    LineNumber  smallint       NOT NULL,
    ProductId   int            NOT NULL CONSTRAINT FK_POL_Product REFERENCES dbo.Product (ProductId),
    Quantity    int            NOT NULL CONSTRAINT CK_POL_Qty CHECK (Quantity > 0),
    UnitPrice   decimal(10,2)  NOT NULL,
    CONSTRAINT PK_PurchaseOrderLine PRIMARY KEY (PoId, LineNumber)
);
GO

-- ---------------------------------------------------------------- Forecasting output
CREATE TABLE dbo.Forecast (
    ForecastId   bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_Forecast PRIMARY KEY,
    RunId        int            NOT NULL,
    ProductId    int            NOT NULL CONSTRAINT FK_Fc_Product   REFERENCES dbo.Product (ProductId),
    WarehouseId  int            NOT NULL CONSTRAINT FK_Fc_Warehouse REFERENCES dbo.Warehouse (WarehouseId),
    TargetDate   date           NOT NULL,
    Method       varchar(20)    NOT NULL,                -- 'SQL_SEASONAL', 'HOLT_WINTERS', ...
    ForecastQty  decimal(10,2)  NOT NULL,
    LowerBound   decimal(10,2)  NULL,
    UpperBound   decimal(10,2)  NULL,
    CreatedAt    datetime2(0)   NOT NULL CONSTRAINT DF_Fc_Created DEFAULT (SYSUTCDATETIME())
);
GO

CREATE TABLE dbo.Recommendation (
    RecId        int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Recommendation PRIMARY KEY,
    ProductId    int            NOT NULL CONSTRAINT FK_Rec_Product   REFERENCES dbo.Product (ProductId),
    WarehouseId  int            NOT NULL CONSTRAINT FK_Rec_Warehouse REFERENCES dbo.Warehouse (WarehouseId),
    SupplierId   int            NULL     CONSTRAINT FK_Rec_Supplier  REFERENCES dbo.Supplier (SupplierId),
    Action       varchar(10)    NOT NULL CONSTRAINT CK_Rec_Action CHECK (Action IN ('ORDER','WATCH','OVERSTOCK','OK')),
    OrderQty     int            NOT NULL CONSTRAINT DF_Rec_Qty DEFAULT (0),
    Priority     tinyint        NOT NULL CONSTRAINT DF_Rec_Prio DEFAULT (3),
    Reason       nvarchar(400)  NOT NULL,
    Status       varchar(10)    NOT NULL CONSTRAINT DF_Rec_Status DEFAULT ('OPEN')
        CONSTRAINT CK_Rec_Status CHECK (Status IN ('OPEN','APPROVED','DISMISSED')),
    SimDate      date           NOT NULL,
    CreatedAt    datetime2(0)   NOT NULL CONSTRAINT DF_Rec_Created DEFAULT (SYSUTCDATETIME())
);
GO

-- ---------------------------------------------------------------- System
CREATE TABLE dbo.AuditLog (
    AuditId     bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_AuditLog PRIMARY KEY,
    EventTime   datetime2(0)  NOT NULL CONSTRAINT DF_Audit_Time DEFAULT (SYSUTCDATETIME()),
    UserName    nvarchar(128) NOT NULL CONSTRAINT DF_Audit_User DEFAULT (SUSER_SNAME()),
    TableName   sysname       NOT NULL,
    Operation   varchar(10)   NOT NULL,
    KeyValue    nvarchar(100) NULL,
    OldValues   nvarchar(max) NULL,
    NewValues   nvarchar(max) NULL
);
GO

-- Single-row table holding the simulated "today".
CREATE TABLE dbo.SimClock (
    ClockId    tinyint      NOT NULL CONSTRAINT PK_SimClock PRIMARY KEY CONSTRAINT CK_SimClock_One CHECK (ClockId = 1),
    SimDate    date         NOT NULL,
    UpdatedAt  datetime2(0) NOT NULL CONSTRAINT DF_SimClock_Updated DEFAULT (SYSUTCDATETIME())
);
GO
