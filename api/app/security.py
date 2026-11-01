"""Password hashing, JWT tokens, and role-based access.

Roles are ordered: VIEWER < MANAGER < ADMIN. Every request opens one database connection
(tagged with the user's name via SESSION_CONTEXT) and re-checks that the account is still active.
"""
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import bcrypt
import jwt
import pyodbc
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer

from . import config, db

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/auth/login")

ROLE_RANK = {"VIEWER": 1, "MANAGER": 2, "ADMIN": 3}


def hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")


def verify_password(password: str, hashed: str) -> bool:
    try:
        return bcrypt.checkpw(password.encode("utf-8"), hashed.encode("utf-8"))
    except ValueError:
        return False


def create_token(username: str, role: str) -> str:
    expires = datetime.now(timezone.utc) + timedelta(minutes=config.JWT_EXPIRE_MINUTES)
    return jwt.encode({"sub": username, "role": role, "exp": expires}, config.JWT_SECRET, algorithm=config.JWT_ALGORITHM)


def decode_token(token: str) -> dict:
    try:
        return jwt.decode(token, config.JWT_SECRET, algorithms=[config.JWT_ALGORITHM])
    except jwt.PyJWTError:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid or expired token",
                            headers={"WWW-Authenticate": "Bearer"})


@dataclass
class Ctx:
    """What every endpoint receives: an open DB connection and the signed-in user's row."""
    conn: pyodbc.Connection
    user: dict


def get_ctx(token: str = Depends(oauth2_scheme)):
    payload = decode_token(token)
    with db.session(payload["sub"]) as conn:
        user = db.one(
            conn,
            "SELECT UserId, Username, FullName, Role, IsActive FROM dbo.AppUser WHERE Username = ?",
            (payload["sub"],),
        )
        if not user or not user["IsActive"]:
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Account not found or disabled",
                                headers={"WWW-Authenticate": "Bearer"})
        yield Ctx(conn=conn, user=user)


def require(min_role: str):
    def dependency(ctx: Ctx = Depends(get_ctx)) -> Ctx:
        if ROLE_RANK[ctx.user["Role"]] < ROLE_RANK[min_role]:
            raise HTTPException(status.HTTP_403_FORBIDDEN, f"{min_role.title()} role required")
        return ctx
    return dependency


viewer = require("VIEWER")
manager = require("MANAGER")
admin = require("ADMIN")
