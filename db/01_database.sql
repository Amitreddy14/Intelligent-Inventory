-- 01_database.sql
-- Creates InventoryDB and the monthly partition function/scheme used by SalesDaily.
-- Safe to re-run: drops a half-built database and starts clean.

USE master;
GO

IF DB_ID(N'InventoryDB') IS NOT NULL
BEGIN
    ALTER DATABASE InventoryDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE InventoryDB;
END
GO

CREATE DATABASE InventoryDB;
GO

ALTER DATABASE InventoryDB SET RECOVERY SIMPLE;
GO

USE InventoryDB;
GO

-- Monthly partitions, RANGE RIGHT: each boundary value is the FIRST day of a month,
-- so a row belongs to the partition whose boundary is <= its date.
-- Boundaries: 2024-11-01 .. 2028-01-01 (data starts Nov 2024; the simulator keeps going into 2027).
DECLARE @d date = '2024-11-01', @list nvarchar(max) = N'';
WHILE @d <= '2028-01-01'
BEGIN
    SET @list += CASE WHEN @list = N'' THEN N'' ELSE N', ' END
               + QUOTENAME(CONVERT(char(10), @d, 120), CHAR(39));
    SET @d = DATEADD(MONTH, 1, @d);
END;

EXEC (N'CREATE PARTITION FUNCTION pf_SalesMonthly (date) AS RANGE RIGHT FOR VALUES (' + @list + N');');
GO

-- All partitions on PRIMARY to keep the Docker setup simple (production would spread across filegroups).
CREATE PARTITION SCHEME ps_SalesMonthly AS PARTITION pf_SalesMonthly ALL TO ([PRIMARY]);
GO
