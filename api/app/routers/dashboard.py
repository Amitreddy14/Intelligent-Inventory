from fastapi import APIRouter, Depends, Query

from .. import db, security

router = APIRouter(prefix="/api/dashboard", tags=["Dashboard"])


@router.get("/summary")
def summary(ctx: security.Ctx = Depends(security.viewer)):
    """Headline numbers for the overview page."""
    c = ctx.conn
    clock = db.one(c, "SELECT SimDate FROM dbo.SimClock WHERE ClockId = 1")
    stock = db.one(c, """
        SELECT COUNT(*) AS Items,
               ISNULL(SUM(StockValue), 0) AS StockValue,
               SUM(CASE WHEN StockStatus = 'STOCKOUT'  THEN 1 ELSE 0 END) AS Stockouts,
               SUM(CASE WHEN StockStatus = 'CRITICAL'  THEN 1 ELSE 0 END) AS Critical,
               SUM(CASE WHEN StockStatus = 'LOW'       THEN 1 ELSE 0 END) AS Low,
               SUM(CASE WHEN StockStatus = 'HEALTHY'   THEN 1 ELSE 0 END) AS Healthy,
               SUM(CASE WHEN StockStatus = 'OVERSTOCK' THEN 1 ELSE 0 END) AS Overstock
        FROM dbo.vw_StockHealth""")
    sales = db.one(c, """
        SELECT ISNULL(SUM(s.Revenue), 0)  AS Revenue30,
               ISNULL(SUM(s.Quantity), 0) AS Units30,
               ISNULL(SUM(s.LostQty), 0)  AS LostUnits30,
               CAST(100.0 * SUM(s.Quantity) / NULLIF(SUM(s.Quantity + s.LostQty), 0) AS decimal(5,2)) AS FillRatePct
        FROM dbo.SalesDaily AS s CROSS JOIN dbo.SimClock AS k
        WHERE s.SaleDate >= DATEADD(DAY, -30, k.SimDate) AND s.SaleDate < k.SimDate""")
    work = db.one(c, """
        SELECT (SELECT COUNT(*) FROM dbo.Recommendation WHERE Status = 'OPEN' AND Action = 'ORDER')     AS OpenOrderRecs,
               (SELECT COUNT(*) FROM dbo.Recommendation WHERE Status = 'OPEN' AND Priority = 1)         AS UrgentRecs,
               (SELECT COUNT(*) FROM dbo.PurchaseOrder  WHERE Status IN ('APPROVED', 'IN_TRANSIT'))      AS OpenPurchaseOrders""")
    acc = db.one(c, """
        SELECT TOP (1) Method, WapePct, BiasPct FROM dbo.vw_ForecastAccuracy
        WHERE RunType = 'BACKTEST' AND Method = 'SEASONAL' ORDER BY RunId DESC""")
    return {"sim_date": clock["SimDate"], "stock": stock, "sales30": sales, "work": work, "forecast_accuracy": acc}


@router.get("/sales-trend")
def sales_trend(days: int = Query(90, ge=7, le=365), ctx: security.Ctx = Depends(security.viewer)):
    """Daily units, revenue and lost units over the last N simulated days."""
    return db.rows(ctx.conn, """
        SELECT s.SaleDate, SUM(s.Quantity) AS Units, SUM(s.Revenue) AS Revenue, SUM(s.LostQty) AS LostUnits
        FROM dbo.SalesDaily AS s CROSS JOIN dbo.SimClock AS k
        WHERE s.SaleDate >= DATEADD(DAY, ?, k.SimDate) AND s.SaleDate < k.SimDate
        GROUP BY s.SaleDate ORDER BY s.SaleDate""", (-days,))


@router.get("/stock-by-warehouse")
def stock_by_warehouse(ctx: security.Ctx = Depends(security.viewer)):
    return db.rows(ctx.conn, """
        SELECT WarehouseId, WarehouseName, City, StockStatus, COUNT(*) AS Items, SUM(StockValue) AS StockValue
        FROM dbo.vw_StockHealth
        GROUP BY WarehouseId, WarehouseName, City, StockStatus
        ORDER BY WarehouseId, StockStatus""")


@router.get("/category-rollup")
def category_rollup(ctx: security.Ctx = Depends(security.viewer)):
    return db.rows(ctx.conn, "SELECT * FROM dbo.vw_CategoryRollup ORDER BY Revenue90 DESC")


@router.get("/abc-xyz")
def abc_xyz(ctx: security.Ctx = Depends(security.viewer)):
    return db.rows(ctx.conn, """
        SELECT AbcClass, XyzClass, COUNT(*) AS Products, SUM(Revenue1Y) AS Revenue1Y
        FROM dbo.vw_ABC_XYZ GROUP BY AbcClass, XyzClass ORDER BY AbcClass, XyzClass""")


@router.get("/top-sellers")
def top_sellers(limit: int = Query(10, ge=1, le=50), ctx: security.Ctx = Depends(security.viewer)):
    return db.rows(ctx.conn, """
        SELECT TOP (?) ProductId, Sku, ProductName, CategoryName, Revenue90, Units90
        FROM dbo.vw_TopSellersByCategory ORDER BY Revenue90 DESC""", (limit,))


@router.get("/monthly-sales")
def monthly_sales(ctx: security.Ctx = Depends(security.viewer)):
    return db.rows(ctx.conn, """
        SELECT MonthStart, WarehouseId, City, Units, Revenue, RevenueGrowthPct
        FROM dbo.vw_SalesMonthly ORDER BY MonthStart, WarehouseId""")
