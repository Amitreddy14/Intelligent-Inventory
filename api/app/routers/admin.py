from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from .. import db, security

router = APIRouter(prefix="/api/admin", tags=["Admin"])


class NewUser(BaseModel):
    username: str = Field(min_length=3, max_length=50, pattern=r"^[A-Za-z0-9_.-]+$")
    password: str = Field(min_length=8, max_length=72)
    full_name: str = Field(min_length=1, max_length=80)
    role: str = Field(pattern="^(ADMIN|MANAGER|VIEWER)$")


class UserPatch(BaseModel):
    full_name: Optional[str] = Field(None, min_length=1, max_length=80)
    role: Optional[str] = Field(None, pattern="^(ADMIN|MANAGER|VIEWER)$")
    is_active: Optional[bool] = None
    password: Optional[str] = Field(None, min_length=8, max_length=72)


@router.get("/users")
def users(ctx: security.Ctx = Depends(security.admin)):
    return db.rows(ctx.conn, """
        SELECT UserId, Username, FullName, Role, IsActive, CreatedAt, LastLoginAt
        FROM dbo.AppUser ORDER BY UserId""")


@router.post("/users", status_code=201)
def create_user(body: NewUser, ctx: security.Ctx = Depends(security.admin)):
    if db.one(ctx.conn, "SELECT 1 AS X FROM dbo.AppUser WHERE Username = ?", (body.username,)):
        raise HTTPException(409, "Username already exists")
    row = db.one(ctx.conn, """
        INSERT dbo.AppUser (Username, PasswordHash, FullName, Role) VALUES (?, ?, ?, ?);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS UserId;""",
        (body.username, security.hash_password(body.password), body.full_name, body.role))
    return {"user_id": row["UserId"], "username": body.username}


@router.patch("/users/{user_id}")
def update_user(user_id: int, body: UserPatch, ctx: security.Ctx = Depends(security.admin)):
    target = db.one(ctx.conn, "SELECT UserId, Username FROM dbo.AppUser WHERE UserId = ?", (user_id,))
    if not target:
        raise HTTPException(404, "User not found")
    if user_id == ctx.user["UserId"] and (body.is_active is False or (body.role and body.role != "ADMIN")):
        raise HTTPException(400, "You cannot disable or demote your own account")

    sets, params = [], []
    if body.full_name is not None:
        sets.append("FullName = ?"); params.append(body.full_name)
    if body.role is not None:
        sets.append("Role = ?"); params.append(body.role)
    if body.is_active is not None:
        sets.append("IsActive = ?"); params.append(1 if body.is_active else 0)
    if body.password is not None:
        sets.append("PasswordHash = ?"); params.append(security.hash_password(body.password))
    if not sets:
        raise HTTPException(422, "Nothing to update")
    db.run(ctx.conn, f"UPDATE dbo.AppUser SET {', '.join(sets)} WHERE UserId = ?", tuple(params) + (user_id,))
    return {"updated": target["Username"]}


@router.get("/audit")
def audit_log(
    table_name: Optional[str] = Query(None, pattern="^(Inventory|Product|PurchaseOrder|AppUser)$"),
    limit: int = Query(100, ge=1, le=500),
    ctx: security.Ctx = Depends(security.admin),
):
    """Rows written by database triggers, newest first."""
    clause, params = ("WHERE TableName = ?", [table_name]) if table_name else ("", [])
    return db.rows(ctx.conn, f"""
        SELECT TOP (?) AuditId, EventTime, UserName, TableName, Operation, KeyValue, OldValues, NewValues
        FROM dbo.AuditLog {clause} ORDER BY AuditId DESC""", (limit, *params))
