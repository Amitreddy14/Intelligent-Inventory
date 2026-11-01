# Intelligent Inventory Control & Demand Forecasting Platform

Course project: **21CSE742P Advanced SQL and Modern Database Features**

Forecasting, inventory optimization and procurement recommendation on SQL Server (T-SQL), with a FastAPI backend and a React dashboard (later phases). The database does the heavy lifting; the application layer is thin.

## Status

| Phase | Scope | State |
|---|---|---|
| 1 | Docker, schema, monthly partitioning, seed data (~1.1M sales rows), indexes | Done |
| 2 | Forecast procs/views, EOQ, safety stock, recommendations, triggers | Next |
| 3 | FastAPI, JWT login, roles | |
| 4 | React UI, simulation, SQL Showcase | |
| 5 | Polish, demo script | |

## Run it (Phase 1)

Requirements: Docker Desktop (give it at least 4 GB RAM; SQL Server needs 2 GB minimum).

```bash
docker compose up
```

The first run pulls the SQL Server image, starts the database and runs `db/01..06_*.sql` once. Seeding takes about 1 to 2 minutes. Watch for `Done. InventoryDB is ready` in the `inv-db-init` log. After that the init container exits; this is normal.

Connect with SSMS, Azure Data Studio or the VS Code SQL extension:

| Field | Value |
|---|---|
| Server | `localhost,1433` |
| Login | `sa` |
| Password | `Inventory@2026` (change it in `.env`, see `.env.example`) |
| Database | `InventoryDB` |
| Trust server certificate | Yes |

Reset to a clean database: `docker compose down -v` then `docker compose up`.

## Database scripts

| File | Purpose |
|---|---|
| `db/01_database.sql` | Create database, monthly partition function and scheme |
| `db/02_schema.sql` | Tables, constraints (CHECK, FK, `ISJSON`), partitioned `SalesDaily` |
| `db/03_seed_reference.sql` | Categories (hierarchy), 500 products, warehouses, suppliers, supplier offers with JSON terms |
| `db/04_seed_sales.sql` | Deterministic 2-year sales generator (recursive CTE calendar, set-based insert), opening stock |
| `db/05_indexes.sql` | Covering indexes and a nonclustered columnstore index |
| `db/06_verify.sql` | Row counts, rows per partition, stock health snapshot |
| `db/demos/` | Scripts to run live in the review (partition elimination, row store vs columnstore) |

## Data model in one picture

```
Category (self-referencing) --< Product >-- SupplierProduct >-- Supplier
                                   |
                                   +--< Inventory >-- Warehouse
                                           |
                       SalesDaily (partitioned by month), StockMovement
Forecast, Recommendation, PurchaseOrder(+Line), AppUser, AuditLog, SimClock
```
