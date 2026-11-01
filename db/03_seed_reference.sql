-- 03_seed_reference.sql
-- Categories (2-level hierarchy), 500 products, 5 warehouses, 8 suppliers, supplier-product offers.
-- Everything is deterministic: CHECKSUM(...) of fixed inputs replaces RAND(), so every run builds the same data.

USE InventoryDB;
GO
SET NOCOUNT ON;
GO

-- ---------------------------------------------------------------- Categories
INSERT dbo.Category (CategoryId, ParentCategoryId, Name) VALUES
(1, NULL, N'Electronics'),
(2, NULL, N'Home & Kitchen'),
(3, NULL, N'Office Supplies'),
(4, NULL, N'Health & Personal Care'),
(5, NULL, N'Sports & Outdoors'),
(6, NULL, N'Grocery & Beverages');

CREATE TABLE #Leaf (
    LeafId int PRIMARY KEY, ParentId int, LeafName nvarchar(60), Noun nvarchar(40), BaseCost decimal(10,2)
);
INSERT #Leaf (LeafId, ParentId, LeafName, Noun, BaseCost) VALUES
( 7, 1, N'Mobile Accessories',   N'Fast Charger',   250),
( 8, 1, N'Audio',                N'Headphones',    1200),
( 9, 1, N'Computer Peripherals', N'Wireless Mouse', 450),
(10, 1, N'Smart Home',           N'Smart Plug',     600),
(11, 2, N'Cookware',             N'Frying Pan',     700),
(12, 2, N'Storage',              N'Container Set',  300),
(13, 2, N'Cleaning',             N'Spin Mop',       400),
(14, 2, N'Kitchen Appliances',   N'Blender',       1800),
(15, 3, N'Stationery',           N'Notebook',        80),
(16, 3, N'Paper Products',       N'Copier Paper',   350),
(17, 3, N'Writing',              N'Gel Pen Pack',    40),
(18, 3, N'Desk Organizers',      N'Desk Organizer', 250),
(19, 4, N'Vitamins',             N'Multivitamin',   500),
(20, 4, N'Skin Care',            N'Moisturizer',    350),
(21, 4, N'Hair Care',            N'Shampoo',        280),
(22, 4, N'Hygiene',              N'Hand Sanitizer', 120),
(23, 5, N'Fitness',              N'Yoga Mat',       650),
(24, 5, N'Cycling',              N'Cycling Helmet',1400),
(25, 5, N'Camping',              N'LED Flashlight', 300),
(26, 5, N'Hydration',            N'Steel Bottle',   350),
(27, 6, N'Snacks',               N'Granola Bars',   150),
(28, 6, N'Tea and Coffee',       N'Coffee Beans',   600),
(29, 6, N'Staples',              N'Basmati Rice',   900),
(30, 6, N'Beverages',            N'Sparkling Water', 60);

INSERT dbo.Category (CategoryId, ParentCategoryId, Name)
SELECT LeafId, ParentId, LeafName FROM #Leaf;
GO

-- ---------------------------------------------------------------- Warehouses and suppliers
INSERT dbo.Warehouse (WarehouseId, Name, City, DemandFactor, HoldingCostPct) VALUES
(1, N'Chennai Hub',      N'Chennai',   1.10, 18.00),
(2, N'Bengaluru DC',     N'Bengaluru', 1.20, 20.00),
(3, N'Mumbai Central',   N'Mumbai',    1.30, 22.00),
(4, N'Delhi NCR Depot',  N'Delhi',     1.15, 21.00),
(5, N'Hyderabad DC',     N'Hyderabad', 0.95, 19.00);

INSERT dbo.Supplier (SupplierId, Name, City, OrderingCost, ReliabilityPct) VALUES
(1, N'Apex Distributors',    N'Chennai',   900.00, 96),
(2, N'BlueStar Wholesale',   N'Mumbai',   1500.00, 91),
(3, N'Coastal Traders',      N'Kochi',     800.00, 88),
(4, N'Delta Supply Co',      N'Delhi',    2200.00, 94),
(5, N'Evergreen Imports',    N'Bengaluru',1800.00, 85),
(6, N'Falcon Logistics',     N'Hyderabad',1200.00, 98),
(7, N'Granite Sourcing',     N'Pune',     1000.00, 90),
(8, N'Horizon Merchants',    N'Kolkata',  2500.00, 82);
GO

-- ---------------------------------------------------------------- 500 products
-- A recursive CTE generates the numbers 1..500. The class/name/cost values are derived from n.
;WITH n AS (
    SELECT 1 AS n
    UNION ALL
    SELECT n + 1 FROM n WHERE n < 500
)
INSERT dbo.Product (Sku, Name, CategoryId, UnitCost, UnitPrice)
SELECT
    CONCAT('SKU-', RIGHT(CONCAT('0000', n.n), 4)),
    CONCAT(CHOOSE(1 + n.n % 8, N'Prime', N'Ultra', N'Eco', N'Smart', N'Classic', N'Pro', N'Lite', N'Max'),
           N' ', l.Noun, N' ', 100 + n.n),
    l.LeafId,
    c.Cost,
    CAST(ROUND(c.Cost * (1.25 + 0.5 * h.R2), 2) AS decimal(10,2))
FROM n
JOIN #Leaf l ON l.LeafId = 7 + (n.n - 1) % 24
CROSS APPLY (SELECT R1 = (ABS(CAST(CHECKSUM(n.n, 11) AS bigint)) % 1000) / 1000.0,
                    R2 = (ABS(CAST(CHECKSUM(n.n, 12) AS bigint)) % 1000) / 1000.0) h
CROSS APPLY (SELECT Cost = CAST(ROUND(l.BaseCost * (0.7 + 0.6 * h.R1), 2) AS decimal(10,2))) c
ORDER BY n.n
OPTION (MAXRECURSION 600);
GO

-- ---------------------------------------------------------------- Supplier offers (3 suppliers per product)
-- Offsets 0, 3, 5 modulo 8 are all different, so a product never gets the same supplier twice.
INSERT dbo.SupplierProduct (SupplierId, ProductId, UnitPrice, LeadTimeDays, MinOrderQty, TermsJson)
SELECT
    s.SupplierId,
    p.ProductId,
    CAST(ROUND(p.UnitCost * (0.92 + 0.16 * h.R), 2) AS decimal(10,2)),
    3 + h.L % 19,
    CHOOSE(1 + h.M % 4, 10, 20, 50, 100),
    CONCAT('{"payment_days":', CHOOSE(1 + h.P % 3, 15, 30, 45),
           ',"discount_pct":', CHOOSE(1 + h.D % 3, 0, 2, 3),
           ',"volume_break":{"min_qty":', CHOOSE(1 + h.M % 3, 150, 200, 300),
           ',"discount_pct":5}}')
FROM dbo.Product p
CROSS JOIN (VALUES (0), (3), (5)) k (Offset)
JOIN dbo.Supplier s ON s.SupplierId = ((p.ProductId + k.Offset) % 8) + 1
CROSS APPLY (SELECT
        R = (ABS(CAST(CHECKSUM(p.ProductId, s.SupplierId, 21) AS bigint)) % 1000) / 1000.0,
        L = CAST(ABS(CAST(CHECKSUM(p.ProductId, s.SupplierId, 22) AS bigint)) % 1000 AS int),
        M = CAST(ABS(CAST(CHECKSUM(p.ProductId, s.SupplierId, 23) AS bigint)) % 1000 AS int),
        P = CAST(ABS(CAST(CHECKSUM(p.ProductId, s.SupplierId, 24) AS bigint)) % 1000 AS int),
        D = CAST(ABS(CAST(CHECKSUM(p.ProductId, s.SupplierId, 25) AS bigint)) % 1000 AS int)) h;
GO
