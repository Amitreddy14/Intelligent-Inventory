# Demo script (about 10 minutes)

Course 21CSE742P · Intelligent Inventory Control and Demand Forecasting Platform

## Before you present (do this the evening before and again 30 minutes before)

1. Start Docker Desktop, then `docker compose up -d` in the project folder. Wait about a minute.
2. Open http://localhost:3000 and sign in as `admin`. Check that Overview loads.
3. Go to **Simulation** and click **Reset simulation**. The date goes back to 2026-11-01 and stock is restored, so your demo always starts the same.
4. Open **SQL Showcase** and run *Row store vs columnstore index* once (the first run warms the cache).
5. Open VS Code with the SQL connection ready (`localhost,1433`, user `sa`, database `InventoryDB`) and the files in `db/demos/` open in tabs.
6. Close other heavy programs. Keep the laptop plugged in.

If something breaks on the day: `docker compose down` then `docker compose up -d`. Data is kept. Only `docker compose down -v` wipes it (a full rebuild takes about 5 minutes).

## The story in one sentence

"A retailer sells 500 products from 5 warehouses. The database forecasts demand, works out when and how much to reorder, and the app lets us simulate what happens next. All the logic is in SQL Server."

## Walkthrough

| Time | Where | Say and do |
|---|---|---|
| 0:00 | Slide or README diagram | Problem: stockouts lose sales, overstock ties up money. Show the data model picture from the README. Mention about 1.1 million sales rows, 500 products, 5 warehouses. |
| 1:00 | **Overview** | Point at KPIs: revenue, fill rate, stockouts, orders to place. "Every number is a SQL view." Show the sales trend, then the ABC/XYZ grid: ABC is revenue importance, XYZ is how unpredictable demand is. |
| 2:30 | **Forecast** | Search `charger`, pick one, choose Chennai or another warehouse that shows data. Explain the three lines: actual, backtest (what the model would have said), forecast with 90% range. Mention WAPE about 23.6% for SEASONAL against about 26.6% for the simpler method, so the seasonal index helps. |
| 4:00 | **Inventory** | Filter status = CRITICAL. Click a row: supplier ranking (ROW_NUMBER over adjusted cost using JSON terms) and stock movements. |
| 5:00 | **Procurement** | Show an ORDER recommendation and read the *Why* column. Explain safety stock = z × σ × √lead time, reorder point, EOQ = √(2DS/H). Click **Approve**: a stored procedure creates the purchase order in one transaction. |
| 6:30 | **Simulation** | Click +7 days. Show the sales and lost-sales result. Start a demand spike (category, ×2, 7 days), advance 7 days, return to Overview and Procurement and show new urgent orders. Optionally apply a supplier delay. |
| 8:00 | **SQL Showcase** (the graded part) | Open *Moving averages and week-over-week comparison*: show window frame `ROWS BETWEEN 27 PRECEDING AND CURRENT ROW`, click Run live. Open *Monthly partitioning and partition elimination*: show timing and explain monthly partitions. Open *Row store vs columnstore index*: the same query runs twice, once ignoring the columnstore index, so compare the milliseconds. |
| 9:00 | **Admin** | Audit log: "these rows were written by triggers, and the username comes from SESSION_CONTEXT." Show the role split (viewer cannot approve). |
| 9:30 | VS Code | Optional: run `db/demos/01_partitioning_and_columnstore_demo.sql` with *Include Actual Execution Plan* to show the plan difference. |
| 10:00 | Close | Summary: window functions + CTEs, stored procedures + triggers, indexing + partitioning + views, all driving a working application. |

## SQL features checklist (say these terms out loud)

| Feature | Where it lives |
|---|---|
| Window functions (AVG OVER with frames, LAG, RANK, cumulative SUM OVER) | `07_analytics_views.sql`, Showcase: moving averages, ABC/XYZ |
| Recursive CTE | `vw_CategoryRollup`, Showcase: category hierarchy roll-up |
| Stored procedures with TRY/CATCH, THROW, transactions, UPDLOCK | `usp_CreatePoFromRecommendation`, `usp_ReceivePo`, `usp_AdvanceDays` |
| Triggers (AFTER) and audit trail | `10_triggers.sql`, Admin: audit log |
| SESSION_CONTEXT | API sets `app_user`, triggers read it |
| Partitioning (RANGE RIGHT, monthly), partition elimination | `01_database.sql`, `02_schema.sql`, Showcase |
| Indexes: covering, partition-aligned, nonclustered columnstore | `05_indexes.sql` |
| Views | forecast accuracy, stock health, supplier rank |
| JSON in SQL (ISJSON, JSON_VALUE, FOR JSON) | supplier terms, `vw_SupplierRank` |
| User-defined function | `fn_ZScore` |
| Constraints (CHECK, FK) | `02_schema.sql` |

## Questions you may get

- **Why SQL Server and not Python for forecasting?** The assignment is about the database. Keeping the logic in T-SQL means one source of truth, it runs next to the data, and the app stays thin.
- **Is the data real?** It is synthetic but deterministic (same every rebuild), with weekday and seasonal patterns and noise, so the forecast accuracy is realistic. Real Kaggle data can be loaded into the same tables.
- **What is WAPE?** Total absolute error divided by total actual sales. It is not distorted by days with tiny sales like MAPE.
- **How do you stop two users approving the same recommendation?** UPDLOCK and HOLDLOCK inside the stored procedure transaction, plus a status check that THROWs an error.
- **What would you change for production?** A least-privilege database login instead of `sa`, a real secrets store, scheduled jobs for forecasts, and monitoring.
