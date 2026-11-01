from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query

from .. import db, security

router = APIRouter(prefix="/api", tags=["Inventory"])

_STATUS_ORDER = ("CASE StockStatus WHEN 'STOCKOUT' THEN 1 WHEN 'CRITICAL' THEN 2 WHEN 'LOW' THEN 3 "
                 "WHEN 'HEALTHY' THEN 4 ELSE 5 END")


@router.get("/warehouses")
def warehouses(ctx: security.Ctx = Depends(security.viewer)):
    return db.rows(ctx.conn, "SELECT WarehouseId, Name, City, HoldingCostPct FROM dbo.Warehouse ORDER BY WarehouseId")


@router.get("/suppliers")
def suppliers(ctx: security.Ctx = Depends(security.viewer)):
    return db.rows(ctx.conn, "SELECT SupplierId, Name, City, OrderingCost, ReliabilityPct FROM dbo.Supplier ORDER BY SupplierId")


@router.get("/categories")
def categories(ctx: security.Ctx = Depends(security.viewer)):
    return db.rows(ctx.conn, "SELECT CategoryId, ParentCategoryId, Name FROM dbo.Category ORDER BY CategoryId")


@router.get("/inventory")
def inventory(
    warehouse_id: Optional[int] = None,
    status: Optional[str] = Query(None, pattern="^(STOCKOUT|CRITICAL|LOW|HEALTHY|OVERSTOCK)$"),
    category_id: Optional[int] = None,
    search: Optional[str] = Query(None, max_length=60),
    page: int = Query(1, ge=1),
    page_size: int = Query(25, ge=1, le=200),
    ctx: security.Ctx = Depends(security.viewer),
):
    """Stock health per product and warehouse, most urgent first."""
    where, params = [], []
    if warehouse_id is not None:
        where.append("WarehouseId = ?"); params.append(warehouse_id)
    if status:
        where.append("StockStatus = ?"); params.append(status)
    if category_id is not None:
        where.append("CategoryId = ?"); params.append(category_id)
    if search:
        where.append("(ProductName LIKE ? OR Sku LIKE ?)"); params += [f"%{search}%", f"%{search}%"]
    clause = ("WHERE " + " AND ".join(where)) if where else ""

    total = db.one(ctx.conn, f"SELECT COUNT(*) AS N FROM dbo.vw_StockHealth {clause}", tuple(params))["N"]
    items = db.rows(
        ctx.conn,
        f"SELECT * FROM dbo.vw_StockHealth {clause} ORDER BY {_STATUS_ORDER}, DaysOfCover, ProductId, WarehouseId "
        "OFFSET ? ROWS FETCH NEXT ? ROWS ONLY",
        tuple(params) + ((page - 1) * page_size, page_size),
    )
    return {"total": total, "page": page, "page_size": page_size, "items": items}


@router.get("/products")
def products(
    search: Optional[str] = Query(None, max_length=60),
    category_id: Optional[int] = None,
    limit: int = Query(25, ge=1, le=100),
    ctx: security.Ctx = Depends(security.viewer),
):
    where, params = [], []
    if search:
        where.append("(p.Name LIKE ? OR p.Sku LIKE ?)"); params += [f"%{search}%", f"%{search}%"]
    if category_id is not None:
        where.append("p.CategoryId = ?"); params.append(category_id)
    clause = ("WHERE " + " AND ".join(where)) if where else ""
    return db.rows(
        ctx.conn,
        f"""SELECT TOP (?) p.ProductId, p.Sku, p.Name, p.CategoryId, c.Name AS Category, p.UnitCost, p.UnitPrice
            FROM dbo.Product AS p JOIN dbo.Category AS c ON c.CategoryId = p.CategoryId
            {clause} ORDER BY p.ProductId""",
        (limit, *params),
    )


@router.get("/products/{product_id}")
def product_detail(product_id: int, ctx: security.Ctx = Depends(security.viewer)):
    product = db.one(ctx.conn, """
        SELECT p.ProductId, p.Sku, p.Name, p.CategoryId, c.Name AS Category, p.UnitCost, p.UnitPrice
        FROM dbo.Product AS p JOIN dbo.Category AS c ON c.CategoryId = p.CategoryId
        WHERE p.ProductId = ?""", (product_id,))
    if not product:
        raise HTTPException(404, "Product not found")
    return {
        "product": product,
        "segment": db.one(ctx.conn, "SELECT AbcClass, XyzClass, WeeklyCV, Revenue1Y, RevenueRank FROM dbo.vw_ABC_XYZ WHERE ProductId = ?", (product_id,)),
        "stock": db.rows(ctx.conn, "SELECT * FROM dbo.vw_StockHealth WHERE ProductId = ? ORDER BY WarehouseId", (product_id,)),
        "suppliers": db.rows(ctx.conn, "SELECT * FROM dbo.vw_SupplierRank WHERE ProductId = ? ORDER BY SupplierRank", (product_id,)),
    }


@router.get("/stock-movements")
def stock_movements(product_id: int, warehouse_id: int, limit: int = Query(30, ge=1, le=200),
                    ctx: security.Ctx = Depends(security.viewer)):
    return db.rows(ctx.conn, """
        SELECT TOP (?) MovementId, MovementDate, MovementType, Quantity, RefType, RefId
        FROM dbo.StockMovement WHERE ProductId = ? AND WarehouseId = ?
        ORDER BY MovementDate DESC, MovementId DESC""", (limit, product_id, warehouse_id))
