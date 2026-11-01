#!/bin/bash
# Runs inside the db-init container. Executes db/0*.sql in order, once.
set -e

SQLCMD=$(ls /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd 2>/dev/null | head -1)
# -C trust cert, -b stop on error, -I QUOTED_IDENTIFIER ON (needed for indexed views and columnstore)
run() { "$SQLCMD" -S db -U sa -P "$MSSQL_SA_PASSWORD" -C -b -I "$@"; }

DONE=$(run -h -1 -W -Q "SET NOCOUNT ON; SELECT CASE WHEN DB_ID('InventoryDB') IS NOT NULL AND OBJECT_ID('InventoryDB.dbo.SetupInfo','U') IS NOT NULL THEN 1 ELSE 0 END" | tr -d '[:space:]')

if [ "$DONE" = "1" ]; then
  echo "InventoryDB already seeded. Skipping. (Use: docker compose down -v  to reset)"
  exit 0
fi

echo "Seeding InventoryDB. The sales generation step takes about 1 minute..."
for f in /scripts/[0-9]*.sql; do
  echo ">> Running $(basename "$f")"
  run -i "$f"
done
echo "Done. InventoryDB is ready on localhost,1433"
