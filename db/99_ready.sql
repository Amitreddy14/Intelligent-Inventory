-- 99_ready.sql
-- Final checks, then the SetupInfo marker. init.sh skips seeding only when this table exists,
-- so a setup that failed halfway is rebuilt from scratch on the next start.

USE InventoryDB;
GO
SET NOCOUNT ON;
GO

PRINT 'Forecast accuracy of the 28-day backtest (lower WAPE is better):';
SELECT Method, Observations, WapePct, BiasPct, MapePct
FROM dbo.vw_ForecastAccuracy
WHERE RunType = 'BACKTEST'
ORDER BY Method;
GO

PRINT 'ABC / XYZ segments (products):';
SELECT AbcClass, XyzClass, COUNT(*) AS Products
FROM dbo.vw_ABC_XYZ
GROUP BY AbcClass, XyzClass
ORDER BY AbcClass, XyzClass;
GO

PRINT 'Stock status across all items:';
SELECT StockStatus, COUNT(*) AS Items
FROM dbo.vw_StockHealth
GROUP BY StockStatus
ORDER BY Items DESC;
GO

CREATE TABLE dbo.SetupInfo (
    InfoKey   varchar(40)   NOT NULL CONSTRAINT PK_SetupInfo PRIMARY KEY,
    InfoValue nvarchar(200) NOT NULL,
    SetAt     datetime2(0)  NOT NULL CONSTRAINT DF_SetupInfo DEFAULT (SYSUTCDATETIME())
);
INSERT dbo.SetupInfo (InfoKey, InfoValue)
VALUES ('seed_complete', CONCAT('SalesDaily rows: ', (SELECT COUNT(*) FROM dbo.SalesDaily)));
GO
