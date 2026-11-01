from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import OAuth2PasswordRequestForm

from .. import db, security

router = APIRouter(prefix="/api/auth", tags=["Auth"])


@router.post("/login")
def login(form: OAuth2PasswordRequestForm = Depends()):
    """Form login (works with the Authorize button on /docs). Returns a bearer token."""
    with db.session(form.username) as conn:
        user = db.one(
            conn,
            "SELECT UserId, Username, PasswordHash, FullName, Role, IsActive FROM dbo.AppUser WHERE Username = ?",
            (form.username,),
        )
        if not user or not user["IsActive"] or not security.verify_password(form.password, user["PasswordHash"]):
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Incorrect username or password")
        db.run(conn, "UPDATE dbo.AppUser SET LastLoginAt = SYSUTCDATETIME() WHERE UserId = ?", (user["UserId"],))
    return {
        "access_token": security.create_token(user["Username"], user["Role"]),
        "token_type": "bearer",
        "user": {"username": user["Username"], "full_name": user["FullName"], "role": user["Role"]},
    }


@router.get("/me")
def me(ctx: security.Ctx = Depends(security.viewer)):
    u = ctx.user
    return {"username": u["Username"], "full_name": u["FullName"], "role": u["Role"]}
