from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query

from .. import db, security

router = APIRouter(prefix="/api", tags=["Procurement"])


@router.get("/recommendations")
def recommendations(
    status: str = Query("OPEN", pattern="^(OPEN|APPROVED|DISMISSED)$"),
    action: Optional[str] = Query(None, pattern="^(ORDER|WATCH|OVERSTOCK)$"),
    priority: Optional[int] = Query(None, ge=1, le=4),
    warehouse_id: Optional[int] = None,
    page: int = Query(1, ge=1),
    page_size: int = Query(25, ge=1, le=200),
    ctx: security.Ctx = Depends(security.viewer),
):
    where, params = ["r.Status = ?"], [status]
    if action:
        where.append("r.Action = ?"); params.append(action)
    if priority:
        where.append("r.Priority = ?"); params.append(priority)
    if warehouse_id is not None:
        where.append("r.WarehouseId = ?"); params.append(warehouse_id)
    clause = "WHERE " + " AND ".join(where)

    total = db.one(ctx.conn, f"SELECT COUNT(*) AS N FROM dbo.Recommendation AS r {clause}", tuple(params))["N"]
    items = db.rows(ctx.conn, f"""
        SELECT r.RecId, r.ProductId, p.Sku, p.Name AS ProductName, r.WarehouseId, w.City,
               r.SupplierId, s.Name AS SupplierName, r.Action, r.Priority, r.OrderQty, r.Reason, r.Status, r.SimDate,
               sr.LeadTimeDays,
               CAST(r.OrderQty * sr.UnitPrice * (1 - sr.DiscountPct / 100.0) AS decimal(14,2)) AS EstimatedCost
        FROM dbo.Recommendation AS r
        JOIN dbo.Product   AS p ON p.ProductId   = r.ProductId
        JOIN dbo.Warehouse AS w ON w.WarehouseId = r.WarehouseId
        LEFT JOIN dbo.Supplier AS s ON s.SupplierId = r.SupplierId
        LEFT JOIN dbo.vw_SupplierRank AS sr ON sr.ProductId = r.ProductId AND sr.SupplierId = r.SupplierId
        {clause}
        ORDER BY r.Priority, r.OrderQty DESC, r.RecId
        OFFSET ? ROWS FETCH NEXT ? ROWS ONLY""", tuple(params) + ((page - 1) * page_size, page_size))
    summary = db.rows(ctx.conn, """
        SELECT Action, Priority, COUNT(*) AS Items, SUM(OrderQty) AS Units
        FROM dbo.Recommendation WHERE Status = 'OPEN' GROUP BY Action, Priority ORDER BY Priority, Action""")
    return {"total": total, "page": page, "page_size": page_size, "items": items, "open_summary": summary}


@router.post("/recommendations/refresh")
def refresh_recommendations(ctx: security.Ctx = Depends(security.manager)):
    """Recompute safety stock, reorder points and all open recommendations for today's simulated date."""
    db.run(ctx.conn, "EXEC dbo.usp_GenerateRecommendations @Quiet = 1")
    return db.rows(ctx.conn, """
        SELECT Action, COUNT(*) AS Items, SUM(OrderQty) AS UnitsToOrder
        FROM dbo.Recommendation WHERE Status = 'OPEN' GROUP BY Action""")


@router.post("/recommendations/{rec_id}/approve")
def approve(rec_id: int, ctx: security.Ctx = Depends(security.manager)):
    """Create an approved purchase order from an ORDER recommendation (one database transaction)."""
    row = db.one(ctx.conn, """
        DECLARE @po int;
        EXEC dbo.usp_CreatePoFromRecommendation @RecId = ?, @UserId = ?, @PoId = @po OUTPUT;
        SELECT @po AS PoId;""", (rec_id, ctx.user["UserId"]))
    return {"po_id": row["PoId"]}


@router.post("/recommendations/{rec_id}/dismiss")
def dismiss(rec_id: int, ctx: security.Ctx = Depends(security.manager)):
    row = db.one(ctx.conn, """
        UPDATE dbo.Recommendation SET Status = 'DISMISSED' WHERE RecId = ? AND Status = 'OPEN';
        SELECT @@ROWCOUNT AS Changed;""", (rec_id,))
    if not row or row["Changed"] == 0:
        raise HTTPException(404, "Open recommendation not found")
    return {"dismissed": rec_id}


@router.get("/purchase-orders")
def purchase_orders(
    status: Optional[str] = Query(None, pattern="^(DRAFT|APPROVED|IN_TRANSIT|RECEIVED|CANCELLED)$"),
    page: int = Query(1, ge=1),
    page_size: int = Query(25, ge=1, le=200),
    ctx: security.Ctx = Depends(security.viewer),
):
    clause, params = ("WHERE po.Status = ?", [status]) if status else ("", [])
    total = db.one(ctx.conn, f"SELECT COUNT(*) AS N FROM dbo.PurchaseOrder AS po {clause}", tuple(params))["N"]
    items = db.rows(ctx.conn, f"""
        SELECT po.PoId, po.Status, po.OrderDate, po.ExpectedDate, po.ReceivedDate, po.TotalCost,
               s.Name AS SupplierName, w.City AS WarehouseCity,
               (SELECT COUNT(*) FROM dbo.PurchaseOrderLine AS l WHERE l.PoId = po.PoId) AS Lines,
               u.Username AS CreatedBy
        FROM dbo.PurchaseOrder AS po
        JOIN dbo.Supplier  AS s ON s.SupplierId  = po.SupplierId
        JOIN dbo.Warehouse AS w ON w.WarehouseId = po.WarehouseId
        LEFT JOIN dbo.AppUser AS u ON u.UserId = po.CreatedBy
        {clause}
        ORDER BY po.PoId DESC
        OFFSET ? ROWS FETCH NEXT ? ROWS ONLY""", tuple(params) + ((page - 1) * page_size, page_size))
    return {"total": total, "page": page, "page_size": page_size, "items": items}


@router.get("/purchase-orders/{po_id}")
def purchase_order(po_id: int, ctx: security.Ctx = Depends(security.viewer)):
    po = db.one(ctx.conn, """
        SELECT po.PoId, po.Status, po.OrderDate, po.ExpectedDate, po.ReceivedDate, po.TotalCost,
               s.Name AS SupplierName, w.City AS WarehouseCity
        FROM dbo.PurchaseOrder AS po
        JOIN dbo.Supplier AS s ON s.SupplierId = po.SupplierId
        JOIN dbo.Warehouse AS w ON w.WarehouseId = po.WarehouseId
        WHERE po.PoId = ?""", (po_id,))
    if not po:
        raise HTTPException(404, "Purchase order not found")
    lines = db.rows(ctx.conn, """
        SELECT l.LineNumber, l.ProductId, p.Sku, p.Name AS ProductName, l.Quantity, l.UnitPrice,
               CAST(l.Quantity * l.UnitPrice AS decimal(14,2)) AS LineTotal
        FROM dbo.PurchaseOrderLine AS l JOIN dbo.Product AS p ON p.ProductId = l.ProductId
        WHERE l.PoId = ? ORDER BY l.LineNumber""", (po_id,))
    return {"order": po, "lines": lines}


@router.post("/purchase-orders/{po_id}/receive")
def receive(po_id: int, ctx: security.Ctx = Depends(security.manager)):
    """Book the goods into stock (atomic: stock, movement log and order status change together)."""
    db.run(ctx.conn, "EXEC dbo.usp_ReceivePo @PoId = ?", (po_id,))
    return {"received": po_id}
