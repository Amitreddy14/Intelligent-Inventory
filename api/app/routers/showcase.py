import time

from fastapi import APIRouter, Depends, HTTPException

from .. import db, security
from ..showcase import BY_KEY, ITEMS

router = APIRouter(prefix="/api/showcase", tags=["SQL Showcase"])

MAX_ROWS = 50


@router.get("")
def list_items(ctx: security.Ctx = Depends(security.viewer)):
    """Every showcase item with its SQL text (for the 'View SQL' buttons)."""
    return ITEMS


@router.post("/{key}/run")
def run_item(key: str, ctx: security.Ctx = Depends(security.viewer)):
    """Run the curated read-only queries of one item and report elapsed time for each."""
    item = BY_KEY.get(key)
    if not item:
        raise HTTPException(404, "Unknown showcase item")

    results = []
    for q in item["queries"]:
        if item.get("warmup"):
            db.rows(ctx.conn, q["sql"])             # warm the cache so timings compare like with like
        started = time.perf_counter()
        data = db.rows(ctx.conn, q["sql"])
        elapsed_ms = round((time.perf_counter() - started) * 1000, 1)
        results.append({
            "label": q["label"],
            "sql": q["sql"],
            "elapsed_ms": elapsed_ms,
            "row_count": len(data),
            "columns": list(data[0].keys()) if data else [],
            "rows": data[:MAX_ROWS],
        })
    return {"key": key, "title": item["title"], "results": results}
