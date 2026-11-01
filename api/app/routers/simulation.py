from decimal import Decimal
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from .. import db, security

router = APIRouter(prefix="/api/simulation", tags=["Simulation"])


class AdvanceBody(BaseModel):
    days: int = Field(1, ge=1, le=60, description="How many simulated days to move forward")


class SpikeBody(BaseModel):
    product_id: Optional[int] = Field(None, description="Target one product (wins over category)")
    category_id: Optional[int] = Field(None, description="Target a category; a top-level category includes its children")
    multiplier: float = Field(2.0, ge=0.1, le=10)
    days: int = Field(7, ge=1, le=60)


class DelayBody(BaseModel):
    supplier_id: int
    delay_days: int = Field(7, ge=1, le=30)


class PriceBody(BaseModel):
    product_id: int
    new_cost: Optional[Decimal] = Field(None, gt=0, max_digits=10, decimal_places=2)
    new_price: Optional[Decimal] = Field(None, gt=0, max_digits=10, decimal_places=2)


@router.get("/state")
def state(ctx: security.Ctx = Depends(security.viewer)):
    clock = db.one(ctx.conn, "SELECT SimDate, UpdatedAt FROM dbo.SimClock WHERE ClockId = 1")
    active = db.rows(ctx.conn, """
        SELECT e.EventId, e.EventType, e.StartDate, e.EndDate, e.Multiplier, e.Description
        FROM dbo.SimEvent AS e CROSS JOIN dbo.SimClock AS k
        WHERE e.EventType = 'DEMAND_SPIKE' AND e.StartDate <= k.SimDate AND e.EndDate >= k.SimDate
        ORDER BY e.EventId""")
    open_orders = db.one(ctx.conn, """
        SELECT COUNT(*) AS Orders, MIN(ExpectedDate) AS NextArrival
        FROM dbo.PurchaseOrder WHERE Status IN ('APPROVED', 'IN_TRANSIT')""")
    return {"sim_date": clock["SimDate"], "active_spikes": active, "open_orders": open_orders}


@router.get("/events")
def events(ctx: security.Ctx = Depends(security.viewer)):
    return db.rows(ctx.conn, """
        SELECT TOP (100) EventId, EventType, SimDate, StartDate, EndDate, Multiplier, DelayDays, Description, CreatedBy, CreatedAt
        FROM dbo.SimEvent ORDER BY EventId DESC""")


@router.post("/advance")
def advance(body: AdvanceBody, ctx: security.Ctx = Depends(security.manager)):
    """Move the simulated clock forward. Orders arrive, customers buy, stock falls, forecasts and recommendations refresh."""
    return db.one(ctx.conn, "EXEC dbo.usp_AdvanceDays @Days = ?, @Refresh = 1", (body.days,))


@router.post("/demand-spike")
def demand_spike(body: SpikeBody, ctx: security.Ctx = Depends(security.manager)):
    return db.one(ctx.conn, "EXEC dbo.usp_AddDemandSpike @ProductId = ?, @CategoryId = ?, @Multiplier = ?, @Days = ?",
                  (body.product_id, body.category_id, body.multiplier, body.days))


@router.post("/supplier-delay")
def supplier_delay(body: DelayBody, ctx: security.Ctx = Depends(security.manager)):
    return db.one(ctx.conn, "EXEC dbo.usp_DelaySupplier @SupplierId = ?, @DelayDays = ?",
                  (body.supplier_id, body.delay_days))


@router.post("/price-change")
def price_change(body: PriceBody, ctx: security.Ctx = Depends(security.manager)):
    if body.new_cost is None and body.new_price is None:
        raise HTTPException(422, "Provide new_cost or new_price")
    return db.one(ctx.conn, "EXEC dbo.usp_ChangePrice @ProductId = ?, @NewCost = ?, @NewPrice = ?",
                  (body.product_id, body.new_cost, body.new_price))


@router.post("/reset")
def reset(ctx: security.Ctx = Depends(security.admin)):
    """Admin only: restore the starting state (sales after 1 Nov 2026, orders, stock, prices and events are undone)."""
    return db.one(ctx.conn, "EXEC dbo.usp_ResetSimulation")
