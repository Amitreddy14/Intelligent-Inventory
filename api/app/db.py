"""Thin SQL Server access layer. All business logic lives in the database; this only sends SQL and returns rows."""
import re
from contextlib import contextmanager

import pyodbc

from . import config


def _conn_str() -> str:
    return (
        "DRIVER={ODBC Driver 18 for SQL Server};"
        f"SERVER={config.DB_SERVER};DATABASE={config.DB_NAME};"
        f"UID={config.DB_USER};PWD={config.DB_PASSWORD};"
        "Encrypt=yes;TrustServerCertificate=yes;"
    )


def connect(app_user: str | None = None) -> pyodbc.Connection:
    """Open a connection. The acting user is stored in SESSION_CONTEXT so database triggers can audit who did what."""
    conn = pyodbc.connect(_conn_str(), autocommit=True, timeout=15)
    if app_user:
        cur = conn.cursor()
        cur.execute("EXEC sp_set_session_context @key = N'app_user', @value = ?", app_user)
        cur.close()
    return conn


@contextmanager
def session(app_user: str | None = None):
    conn = connect(app_user)
    try:
        yield conn
    finally:
        conn.close()


def rows(conn, sql: str, params=()) -> list[dict]:
    cur = conn.cursor()
    try:
        cur.execute(sql, *params)
        # Skip row-count-only results (e.g. from an UPDATE) until the first real result set
        while cur.description is None:
            if not cur.nextset():
                return []
        cols = [c[0] for c in cur.description]
        return [dict(zip(cols, r)) for r in cur.fetchall()]
    finally:
        cur.close()


def one(conn, sql: str, params=()) -> dict | None:
    result = rows(conn, sql, params)
    return result[0] if result else None


def run(conn, sql: str, params=()) -> None:
    cur = conn.cursor()
    try:
        cur.execute(sql, *params)
        while cur.nextset():
            pass
    finally:
        cur.close()


def sql_message(exc: Exception) -> str:
    """Turn a pyodbc error into the plain message raised by the database (e.g. a THROW text)."""
    text = str(exc)
    if "[SQL Server]" in text:
        text = text.rsplit("[SQL Server]", 1)[1]
    text = re.sub(r"\s*\(SQLExec\w+\)\W*$", "", text)   # trailing "(SQLExecDirectW)"
    text = re.sub(r"\s*\(\d+\)\s*$", "", text)           # trailing error number, e.g. "(50011)"
    return text.strip().strip("\"')")
