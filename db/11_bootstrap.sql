-- 11_bootstrap.sql
-- Fills the forecast and recommendation tables so the dashboards have data on first start.
--   1. A BACKTEST run: forecast the last 28 days using only older data (scored against reality)
--   2. Recommendations: this also runs the LIVE forecast and recomputes safety stock / reorder points

USE InventoryDB;
GO
SET NOCOUNT ON;
GO

EXEC dbo.usp_RunForecast @RunType = 'BACKTEST', @Quiet = 1;
GO

PRINT 'Generating recommendations (runs the live forecast and recomputes reorder points)...';
EXEC dbo.usp_GenerateRecommendations;
GO
