-- 08_forecasting.sql
-- Demand forecasting entirely in T-SQL.
--   MA28_DOW : last-28-day average demand x day-of-week index
--   SEASONAL : MA28_DOW x month-of-year seasonal factor (clamped to 0.7 .. 1.4)
-- A BACKTEST run forecasts the 28 days before "today" using only older data, so it can be scored against
-- what actually happened. A LIVE run forecasts the next 28 days.

USE InventoryDB;
GO

CREATE TABLE dbo.ForecastRun (
    RunId      int          NOT NULL CONSTRAINT PK_ForecastRun PRIMARY KEY,
    RunType    varchar(10)  NOT NULL CONSTRAINT CK_FR_Type CHECK (RunType IN ('LIVE', 'BACKTEST')),
    AsOfDate   date         NOT NULL,      -- last day of history used
    Horizon    smallint     NOT NULL,
    SimDate    date         NOT NULL,      -- simulated "today" when the run was made
    RowCnt     int          NOT NULL CONSTRAINT DF_FR_Rows DEFAULT (0),
    CreatedAt  datetime2(0) NOT NULL CONSTRAINT DF_FR_Created DEFAULT (SYSUTCDATETIME())
);
GO

ALTER TABLE dbo.Forecast
    ADD CONSTRAINT FK_Forecast_Run FOREIGN KEY (RunId) REFERENCES dbo.ForecastRun (RunId);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RunForecast
    @RunType  varchar(10) = 'LIVE',
    @AsOfDate date        = NULL,
    @Horizon  smallint    = 28,
    @Quiet    bit         = 0,
    @RunIdOut int         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Sim date = (SELECT SimDate FROM dbo.SimClock WHERE ClockId = 1);

    IF @RunType NOT IN ('LIVE', 'BACKTEST')
        THROW 50001, 'RunType must be LIVE or BACKTEST.', 1;

    IF @AsOfDate IS NULL
        SET @AsOfDate = CASE WHEN @RunType = 'BACKTEST'
                             THEN DATEADD(DAY, -@Horizon - 1, @Sim)   -- targets end on the day before @Sim
                             ELSE DATEADD(DAY, -1, @Sim) END;

    IF @AsOfDate >= @Sim
        THROW 50002, 'AsOfDate must be before the simulated date.', 1;

    DECLARE @RunId  int  = ISNULL((SELECT MAX(RunId) FROM dbo.ForecastRun), 0) + 1;
    DECLARE @From365 date = DATEADD(DAY, -364, @AsOfDate);
    DECLARE @From91  date = DATEADD(DAY,  -90, @AsOfDate);
    DECLARE @From28  date = DATEADD(DAY,  -27, @AsOfDate);
    DECLARE @Rows int;

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT dbo.ForecastRun (RunId, RunType, AsOfDate, Horizon, SimDate)
        VALUES (@RunId, @RunType, @AsOfDate, @Horizon, @Sim);

        -- 1. One year of history
        SELECT ProductId, WarehouseId, SaleDate,
               CAST(Quantity + LostQty AS float)           AS Demand,
               DATEDIFF(DAY, '19000101', SaleDate) % 7      AS Dow,
               MONTH(SaleDate)                              AS MonthNo
        INTO #Hist
        FROM dbo.SalesDaily
        WHERE SaleDate BETWEEN @From365 AND @AsOfDate;

        CREATE CLUSTERED INDEX IX_Hist ON #Hist (ProductId, WarehouseId, SaleDate);

        -- 2. Level and spread per item
        SELECT ProductId, WarehouseId,
               AVG(Demand)                                                   AS Avg365,
               AVG(CASE WHEN SaleDate >= @From91 THEN Demand END)            AS Avg91,
               AVG(CASE WHEN SaleDate >= @From28 THEN Demand END)            AS Avg28,
               ISNULL(STDEV(CASE WHEN SaleDate >= @From91 THEN Demand END), 0) AS Std91
        INTO #Level
        FROM #Hist
        GROUP BY ProductId, WarehouseId;

        CREATE UNIQUE CLUSTERED INDEX IX_Level ON #Level (ProductId, WarehouseId);

        -- 3. Day-of-week index: average demand on that weekday / average demand overall (last 13 weeks)
        SELECT h.ProductId, h.WarehouseId, h.Dow,
               CASE WHEN l.Avg91 > 0 THEN AVG(h.Demand) / l.Avg91 ELSE 1.0 END AS Idx
        INTO #DowIdx
        FROM #Hist AS h
        JOIN #Level AS l ON l.ProductId = h.ProductId AND l.WarehouseId = h.WarehouseId
        WHERE h.SaleDate >= @From91
        GROUP BY h.ProductId, h.WarehouseId, h.Dow, l.Avg91;

        CREATE UNIQUE CLUSTERED INDEX IX_DowIdx ON #DowIdx (ProductId, WarehouseId, Dow);

        -- 4. Month-of-year index: average demand in that month / average demand over the whole year
        SELECT h.ProductId, h.WarehouseId, h.MonthNo,
               CASE WHEN l.Avg365 > 0 THEN AVG(h.Demand) / l.Avg365 ELSE 1.0 END AS Idx
        INTO #MonthIdx
        FROM #Hist AS h
        JOIN #Level AS l ON l.ProductId = h.ProductId AND l.WarehouseId = h.WarehouseId
        GROUP BY h.ProductId, h.WarehouseId, h.MonthNo, l.Avg365;

        CREATE UNIQUE CLUSTERED INDEX IX_MonthIdx ON #MonthIdx (ProductId, WarehouseId, MonthNo);

        -- 5. Seasonal level of the last 28 days, so the level can be re-scaled to the target month
        SELECT h.ProductId, h.WarehouseId, AVG(mi.Idx) AS SeasAtOrigin
        INTO #SeasOrigin
        FROM #Hist AS h
        JOIN #MonthIdx AS mi
          ON mi.ProductId = h.ProductId AND mi.WarehouseId = h.WarehouseId AND mi.MonthNo = h.MonthNo
        WHERE h.SaleDate >= @From28
        GROUP BY h.ProductId, h.WarehouseId;

        CREATE UNIQUE CLUSTERED INDEX IX_SeasOrigin ON #SeasOrigin (ProductId, WarehouseId);

        -- 6. Forecast rows: items x horizon days x 2 methods. 80% band = +/- 1.28 standard deviations.
        ;WITH steps AS (
            SELECT 1 AS Step
            UNION ALL
            SELECT Step + 1 FROM steps WHERE Step < @Horizon
        )
        INSERT dbo.Forecast (RunId, ProductId, WarehouseId, TargetDate, Method, ForecastQty, LowerBound, UpperBound)
        SELECT @RunId, l.ProductId, l.WarehouseId, t.TargetDate, m.Method,
               CAST(m.QtyRaw AS decimal(10,2)),
               CAST(CASE WHEN m.QtyRaw - 1.28 * l.Std91 < 0 THEN 0 ELSE m.QtyRaw - 1.28 * l.Std91 END AS decimal(10,2)),
               CAST(m.QtyRaw + 1.28 * l.Std91 AS decimal(10,2))
        FROM #Level AS l
        CROSS JOIN steps AS st
        CROSS APPLY (SELECT TargetDate = DATEADD(DAY, st.Step, @AsOfDate)) AS t
        LEFT JOIN #DowIdx AS d
               ON d.ProductId = l.ProductId AND d.WarehouseId = l.WarehouseId
              AND d.Dow = DATEDIFF(DAY, '19000101', t.TargetDate) % 7
        LEFT JOIN #MonthIdx AS mi
               ON mi.ProductId = l.ProductId AND mi.WarehouseId = l.WarehouseId
              AND mi.MonthNo = MONTH(t.TargetDate)
        LEFT JOIN #SeasOrigin AS so
               ON so.ProductId = l.ProductId AND so.WarehouseId = l.WarehouseId
        CROSS APPLY (SELECT Base = ISNULL(l.Avg28, 0) * ISNULL(d.Idx, 1.0),
                            Seas = CASE WHEN so.SeasAtOrigin > 0 AND mi.Idx IS NOT NULL
                                        THEN CASE WHEN mi.Idx / so.SeasAtOrigin < 0.7 THEN 0.7
                                                  WHEN mi.Idx / so.SeasAtOrigin > 1.4 THEN 1.4
                                                  ELSE mi.Idx / so.SeasAtOrigin END
                                        ELSE 1.0 END) AS b
        CROSS APPLY (VALUES ('MA28_DOW', b.Base),
                            ('SEASONAL', b.Base * b.Seas)) AS m (Method, QtyRaw)
        OPTION (MAXRECURSION 400);

        SET @Rows = @@ROWCOUNT;

        UPDATE dbo.ForecastRun SET RowCnt = @Rows WHERE RunId = @RunId;

        -- 7. Retention: keep the two newest runs of this type
        DECLARE @Cut int = (SELECT MIN(RunId)
                            FROM (SELECT TOP (2) RunId FROM dbo.ForecastRun
                                  WHERE RunType = @RunType ORDER BY RunId DESC) AS x);
        DELETE FROM dbo.Forecast
        WHERE RunId IN (SELECT RunId FROM dbo.ForecastRun WHERE RunType = @RunType AND RunId < @Cut);
        DELETE FROM dbo.ForecastRun WHERE RunType = @RunType AND RunId < @Cut;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SET @RunIdOut = @RunId;
    IF @Quiet = 0
        SELECT @RunId AS RunId, @RunType AS RunType, @AsOfDate AS AsOfDate, @Horizon AS Horizon, @Rows AS RowsWritten;
END
GO

-- ------------------------------------------------------------------ Forecast quality
-- Compares each forecast with what was actually demanded on that day. Live runs fill in as the simulation advances.
CREATE OR ALTER VIEW dbo.vw_ForecastErrorDaily AS
SELECT
    f.RunId,
    r.RunType,
    r.AsOfDate,
    f.Method,
    f.ProductId,
    f.WarehouseId,
    f.TargetDate,
    f.ForecastQty,
    CAST(s.Quantity + s.LostQty AS decimal(10,2))                       AS ActualQty,
    ABS(f.ForecastQty - (s.Quantity + s.LostQty))                       AS AbsError,
    f.ForecastQty - (s.Quantity + s.LostQty)                            AS SignedError
FROM dbo.Forecast AS f
JOIN dbo.ForecastRun AS r ON r.RunId = f.RunId
JOIN dbo.SalesDaily  AS s ON s.SaleDate = f.TargetDate
                         AND s.ProductId = f.ProductId
                         AND s.WarehouseId = f.WarehouseId;
GO

-- WAPE = sum of absolute errors / sum of actuals (robust when some days are zero). Bias > 0 means over-forecasting.
CREATE OR ALTER VIEW dbo.vw_ForecastAccuracy AS
SELECT
    e.RunId,
    e.RunType,
    e.AsOfDate,
    e.Method,
    COUNT(*) AS Observations,
    CAST(100.0 * SUM(e.AbsError)    / NULLIF(SUM(e.ActualQty), 0) AS decimal(6,2)) AS WapePct,
    CAST(100.0 * SUM(e.SignedError) / NULLIF(SUM(e.ActualQty), 0) AS decimal(6,2)) AS BiasPct,
    CAST(100.0 * SUM(CASE WHEN e.ActualQty > 0 THEN e.AbsError / e.ActualQty END)
               / NULLIF(COUNT(CASE WHEN e.ActualQty > 0 THEN 1 END), 0) AS decimal(7,2)) AS MapePct
FROM dbo.vw_ForecastErrorDaily AS e
GROUP BY e.RunId, e.RunType, e.AsOfDate, e.Method;
GO
