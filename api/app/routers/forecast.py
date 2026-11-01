from fastapi import APIRouter, Depends, Query

from .. import db, security

router = APIRouter(prefix="/api/forecast", tags=["Forecast"])


@router.get("/item")
def item_forecast(
    product_id: int,
    warehouse_id: int,
    history_days: int = Query(60, ge=14, le=365),
    ctx: security.Ctx = Depends(security.viewer),
):
    """History, the live 28-day forecast (both methods) and the backtest scored against actuals, for one item."""
    c = ctx.conn
    history = db.rows(c, """
        SELECT s.SaleDate, s.Quantity, s.LostQty
        FROM dbo.SalesDaily AS s CROSS JOIN dbo.SimClock AS k
        WHERE s.ProductId = ? AND s.WarehouseId = ?
          AND s.SaleDate >= DATEADD(DAY, ?, k.SimDate) AND s.SaleDate < k.SimDate
        ORDER BY s.SaleDate""", (product_id, warehouse_id, -history_days))
    live = db.rows(c, """
        SELECT f.TargetDate, f.Method, f.ForecastQty, f.LowerBound, f.UpperBound
        FROM dbo.Forecast AS f
        WHERE f.RunId = (SELECT MAX(RunId) FROM dbo.ForecastRun WHERE RunType = 'LIVE')
          AND f.ProductId = ? AND f.WarehouseId = ?
        ORDER BY f.TargetDate, f.Method""", (product_id, warehouse_id))
    backtest = db.rows(c, """
        SELECT e.TargetDate, e.Method, e.ForecastQty, e.ActualQty
        FROM dbo.vw_ForecastErrorDaily AS e
        WHERE e.RunId = (SELECT MAX(RunId) FROM dbo.ForecastRun WHERE RunType = 'BACKTEST')
          AND e.ProductId = ? AND e.WarehouseId = ?
        ORDER BY e.TargetDate, e.Method""", (product_id, warehouse_id))
    params = db.one(c, """
        SELECT OnHand, ReorderPoint, SafetyStock FROM dbo.Inventory WHERE ProductId = ? AND WarehouseId = ?""",
        (product_id, warehouse_id))
    return {"history": history, "live_forecast": live, "backtest": backtest, "stock_params": params}


@router.get("/accuracy")
def accuracy(ctx: security.Ctx = Depends(security.viewer)):
    return db.rows(ctx.conn, """
        SELECT RunId, RunType, AsOfDate, Method, Observations, WapePct, BiasPct, MapePct
        FROM dbo.vw_ForecastAccuracy ORDER BY RunId DESC, Method""")


@router.post("/run")
def run_forecast(ctx: security.Ctx = Depends(security.manager)):
    """Re-run the live 28-day forecast for today's simulated date."""
    row = db.one(ctx.conn, "EXEC dbo.usp_RunForecast @RunType = 'LIVE'")
    return row
