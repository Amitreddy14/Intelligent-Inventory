import logging
import time
from contextlib import asynccontextmanager

import pyodbc
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from . import config, db, security
from .routers import admin, auth, dashboard, forecast, inventory, procurement, showcase, simulation

log = logging.getLogger("inventory-api")


def seed_default_users() -> None:
    """Create the demo accounts if they do not exist yet. Retries while the database finishes starting."""
    for attempt in range(30):
        try:
            with db.session("system") as conn:
                for username, password, full_name, role in config.DEFAULT_USERS:
                    if not db.one(conn, "SELECT 1 AS X FROM dbo.AppUser WHERE Username = ?", (username,)):
                        db.run(conn,
                               "INSERT dbo.AppUser (Username, PasswordHash, FullName, Role) VALUES (?, ?, ?, ?)",
                               (username, security.hash_password(password), full_name, role))
                        log.info("Created demo user %s (%s)", username, role)
            return
        except pyodbc.Error as exc:
            log.warning("Database not ready (attempt %d/30): %s", attempt + 1, db.sql_message(exc))
            time.sleep(2)
    log.error("Could not seed demo users: database never became reachable")


@asynccontextmanager
async def lifespan(_: FastAPI):
    seed_default_users()
    yield


app = FastAPI(
    title="Inventory Intelligence API",
    description="Forecasting, inventory optimisation and procurement recommendations on SQL Server. "
                "Sign in with the Authorize button (demo users: admin / manager / viewer, see README).",
    version="0.3.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=config.CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.exception_handler(pyodbc.OperationalError)
async def db_unreachable(_: Request, exc: pyodbc.OperationalError):
    return JSONResponse(status_code=503, content={"detail": "Database unavailable: " + db.sql_message(exc)})


@app.exception_handler(pyodbc.Error)
async def db_error(_: Request, exc: pyodbc.Error):
    """Messages raised inside T-SQL with THROW (business rules, validation) become HTTP 400 with the original text."""
    return JSONResponse(status_code=400, content={"detail": db.sql_message(exc)})


@app.get("/api/health", tags=["Health"])
def health():
    try:
        with db.session() as conn:
            db.one(conn, "SELECT 1 AS Ok")
        return {"status": "ok", "database": "reachable"}
    except pyodbc.Error as exc:
        return JSONResponse(status_code=503, content={"status": "degraded", "database": db.sql_message(exc)})


for module in (auth, dashboard, inventory, forecast, procurement, simulation, showcase, admin):
    app.include_router(module.router)
