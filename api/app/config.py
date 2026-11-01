"""Settings, read from environment variables (set in docker-compose.yml)."""
import os

DB_SERVER = os.getenv("DB_SERVER", "localhost,1433")
DB_NAME = os.getenv("DB_NAME", "InventoryDB")
DB_USER = os.getenv("DB_USER", "sa")
DB_PASSWORD = os.getenv("DB_PASSWORD", "Inventory@2026")

JWT_SECRET = os.getenv("JWT_SECRET", "change-this-demo-secret-to-something-long-32+")
JWT_ALGORITHM = "HS256"
JWT_EXPIRE_MINUTES = int(os.getenv("JWT_EXPIRE_MINUTES", "480"))

CORS_ORIGINS = [o.strip() for o in os.getenv(
    "CORS_ORIGINS", "http://localhost:5173,http://localhost:3000,http://127.0.0.1:5173"
).split(",") if o.strip()]

# Demo accounts created on first start (passwords are stored as bcrypt hashes)
DEFAULT_USERS = [
    ("admin", "Admin@123", "Asha Admin", "ADMIN"),
    ("manager", "Manager@123", "Mohan Manager", "MANAGER"),
    ("viewer", "Viewer@123", "Vani Viewer", "VIEWER"),
]
