# Intelligent Inventory Control & Demand Forecasting Platform

Course project: **21CSE742P Advanced SQL and Modern Database Features**

Forecasting, inventory optimization and procurement recommendation on SQL Server (T-SQL), with a FastAPI backend and a React dashboard. The database does the heavy lifting; the application layer is thin.

## Status

| Phase | Scope | State |
|---|---|---|
| 1 | Docker, schema, monthly partitioning, seed data (~1.1M sales rows), indexes | Done |
| 2 | Analytics views, SQL forecasting, EOQ, safety stock, recommendations, PO procedures, triggers | Done |
| 3 | Simulation procedures, FastAPI backend, JWT login, roles | Done |
| 4 | React dashboard: overview, forecast, inventory, procurement, simulation, SQL Showcase, admin | Done |
| 5 | Polish, demo script | Done, see `docs/DEMO_SCRIPT.md` |

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
| `db/07_analytics_views.sql` | Demand stats, moving averages (window frames, LAG), ABC/XYZ, top sellers (RANK), category roll-up (recursive CTE), monthly growth |
| `db/08_forecasting.sql` | `ForecastRun`, `usp_RunForecast` (two SQL methods, LIVE and BACKTEST), forecast accuracy views (WAPE, bias, MAPE) |
| `db/09_procurement.sql` | z-score function, supplier ranking from JSON terms, stock health view, `usp_RecomputeStockParams` (safety stock, reorder point), `usp_GenerateRecommendations` (EOQ), `usp_CreatePoFromRecommendation`, `usp_ReceivePo` |
| `db/10_triggers.sql` | Reserved <= on-hand rule, stockout alert, audit trail for products, purchase orders and users |
| `db/11_bootstrap.sql` | Runs the backtest forecast and generates the first recommendations |
| `db/12_simulation.sql` | Simulation clock: `usp_AdvanceDays`, demand spike, supplier delay, price change, reset |
| `db/99_ready.sql` | Prints forecast accuracy and segment counts, then marks setup complete |
| `db/demos/` | Scripts to run live in the review (partitioning, columnstore, forecasting, procurement, triggers) |

## Upgrading from Phase 1

The setup marker moved to `99_ready.sql`, so an existing Phase 1 database will be skipped. Rebuild once:

```bash
docker compose down -v
docker compose up
```

## Data model in one picture

```
Category (self-referencing) --< Product >-- SupplierProduct >-- Supplier
                                   |
                                   +--< Inventory >-- Warehouse
                                           |
                       SalesDaily (partitioned by month), StockMovement
Forecast, Recommendation, PurchaseOrder(+Line), AppUser, AuditLog, SimClock
```

## API (Phase 3)

Started by `docker compose up` together with the database. Interactive documentation: **http://localhost:8000/docs**
(click **Authorize** and sign in). Health check: http://localhost:8000/api/health

Demo accounts (created on first start, stored as bcrypt hashes):

| Username | Password | Role | Can do |
|---|---|---|---|
| `admin` | `Admin@123` | ADMIN | Everything, plus users, audit log and simulation reset |
| `manager` | `Manager@123` | MANAGER | Read everything, approve recommendations, receive orders, run the simulation |
| `viewer` | `Viewer@123` | VIEWER | Read-only |

| Area | Endpoints |
|---|---|
| Auth | `POST /api/auth/login`, `GET /api/auth/me` |
| Dashboard | `/api/dashboard/summary`, `sales-trend`, `stock-by-warehouse`, `category-rollup`, `abc-xyz`, `top-sellers`, `monthly-sales` |
| Inventory | `/api/inventory`, `/api/products`, `/api/products/{id}`, `/api/stock-movements`, `/api/warehouses`, `/api/suppliers`, `/api/categories` |
| Forecast | `/api/forecast/item`, `/api/forecast/accuracy`, `POST /api/forecast/run` |
| Procurement | `/api/recommendations`, `POST .../refresh`, `POST .../{id}/approve`, `POST .../{id}/dismiss`, `/api/purchase-orders`, `POST .../{id}/receive` |
| Simulation | `/api/simulation/state`, `events`, `POST advance`, `demand-spike`, `supplier-delay`, `price-change`, `reset` (admin) |
| SQL Showcase | `GET /api/showcase`, `POST /api/showcase/{key}/run` |
| Admin | `/api/admin/users` (GET, POST, PATCH), `/api/admin/audit` |

Design notes: the API sends SQL and calls stored procedures only. Business rules raised inside T-SQL with `THROW`
come back as HTTP 400 with the original message. Every request tags its connection with the signed-in user via
`sp_set_session_context`, so the audit triggers record who made each change. Demo setup uses the `sa` login for
simplicity; a real deployment would use a least-privilege database user.

## Upgrading from Phase 2

New database objects were added (`12_simulation.sql`), so rebuild once:

```bash
docker compose down -v
docker compose up --build
```

## Web UI (Phase 4)

`docker compose up --build` now also starts the dashboard: **http://localhost:3000** (nginx serves the React build and forwards `/api` to FastAPI).
Sign in with `admin / Admin@123`, `manager / Manager@123` or `viewer / Viewer@123`.

| Page | What it shows | SQL features behind it |
|---|---|---|
| Overview | KPIs, sales trend, stock health, ABC/XYZ grid | views, window functions, recursive CTE |
| Forecast | History, backtest and 14-day forecast with range | `usp_RunForecast`, WAPE and bias views |
| Inventory | Filterable stock list, supplier ranking, movements | `vw_StockHealth`, `ROW_NUMBER`, JSON terms |
| Procurement | Recommendations, approve to create a PO, receive orders | EOQ, safety stock, transactional procedures |
| Simulation | Advance days, demand spike, supplier delay, price change | `usp_AdvanceDays`, triggers |
| SQL Showcase | "View SQL" plus live results and timings | partitioning, columnstore, plans |
| Admin | Users, roles, audit log | triggers, `SESSION_CONTEXT` |

Frontend development with hot reload: `cd web && npm install && npm run dev` (http://localhost:5173, proxies to the API on port 8000).
Only the `web` image changes in this phase, so no database rebuild is needed.

## Demo

Step-by-step presentation script, pre-demo checklist and likely questions: `docs/DEMO_SCRIPT.md`.
