# Intelligent Inventory Control & Demand Forecasting Platform

Course: 21CSE742P, Advanced SQL and Modern Database Features (3 credits)
Review date: 3 Nov 2026

## 1. Locked decisions

| Area | Choice |
|---|---|
| Database | SQL Server 2022 (T-SQL) in Docker, local only |
| Backend | Python FastAPI (pyodbc), JWT auth |
| Frontend | React + Vite, dark analytics dashboard, Recharts |
| Forecasting | SQL-first (window functions, CTEs) + small Python Holt-Winters for comparison |
| Data | Public retail dataset as base + live "new day" simulator |
| Scale | ~500 SKUs, 5 warehouses, ~2 years of daily sales |
| Run | `docker compose up` |
| Roles | Admin, Manager, Viewer |

## 2. Architecture

```
React UI  --->  FastAPI  --->  SQL Server
(dashboards)    (auth, REST)   (tables, views, procs, triggers, indexes)
                                   ^
                 Python job -------+  (Holt-Winters comparison, data seeding)
```

Principle: business logic lives in the database. The API is a thin layer that calls stored procedures and views.

## 3. Schema (core tables)

- `Category`, `Product` (SKU, unit cost, price, lead-time class)
- `Warehouse`, `Supplier`, `SupplierProduct` (price, lead time days, MOQ, terms as JSON)
- `Inventory` (product, warehouse, on_hand, reserved, reorder_point, safety_stock)
- `SalesDaily` (date, product, warehouse, qty, revenue, promo_flag), partitioned by month
- `StockMovement` (receipt, sale, adjustment, transfer), written by procs only
- `PurchaseOrder`, `PurchaseOrderLine`
- `Forecast` (product, warehouse, target_date, method, qty, run_id)
- `Recommendation` (product, warehouse, action, order_qty, supplier, reason, created_at)
- `AppUser`, `AuditLog`, `SimClock`

## 4. Advanced SQL showcase map

| Feature | Where it appears |
|---|---|
| Window functions | 7/28-day moving average, LAG/LEAD growth, running stock balance, RANK of top sellers, NTILE for ABC classes |
| CTEs (incl. recursive) | Seasonality index build, calendar generation, category hierarchy roll-up |
| Stored procedures | `usp_RunForecast`, `usp_GenerateRecommendations`, `usp_AdvanceDay` (simulation), `usp_ReceivePO` |
| Triggers | Block negative stock, auto-log to `AuditLog`, flag stockout on `Inventory` update |
| Views / indexed views | `vw_StockHealth`, `vw_ABC_XYZ`, `vw_ForecastAccuracy` (MAPE), indexed view for daily totals |
| Indexing | Non-clustered covering indexes, columnstore on `SalesDaily`; before/after execution plan demo |
| Partitioning | `SalesDaily` partitioned by month with partition function and scheme |
| Transactions | Atomic PO receive and stock update with error handling (TRY/CATCH) |

## 5. Procurement logic (in SQL)

- Forecast demand per day over the lead time
- Safety stock = z * stddev(daily demand) * sqrt(lead time)
- Reorder point = lead-time demand + safety stock
- EOQ = sqrt(2 * D * S / H)
- Supplier choice: lowest landed cost where lead time fits, ranked with window functions

## 6. UI pages

1. Login (JWT, role-based routes)
2. Overview dashboard: KPIs, stock health, stockout risk
3. Forecast explorer: actual vs forecast vs Holt-Winters, MAPE
4. Inventory: filter by warehouse, ABC/XYZ matrix
5. Procurement: recommendations, approve to create PO
6. Simulation: advance 1/7/30 days, inject demand spike or supplier delay, watch stock react
7. SQL Showcase: "View SQL" for each card, feature tag, execution plan note
8. Admin: users, audit log

## 7. Phases

| Phase | Goal |
|---|---|
| 1 | Docker Compose, schema, partitioning, seed data, indexes |
| 2 | Forecast procs/views, EOQ, safety stock, recommendations, triggers |
| 3 | FastAPI, JWT auth, role guards, endpoints |
| 4 | React UI, dashboards, simulation, SQL Showcase |
| 5 | Polish, demo script, README, GitHub push |
| Buffer | Rehearsal on 3 Nov |

## 8. Repo layout

```
inventory-platform/
  docker-compose.yml
  db/        01_schema.sql  02_partitions.sql  03_seed.sql  04_views.sql
             05_procs.sql   06_triggers.sql    07_indexes.sql
  api/       FastAPI app
  web/       React app
  data/      dataset + generator
  docs/      PLAN.md, demo script, screenshots
```
