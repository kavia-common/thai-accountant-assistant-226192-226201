# Accountant App - MySQL Schema

This container runs MySQL and creates the base database/user in `startup.sh`.

To avoid changing preview startup behavior, the app schema **is not applied automatically** on startup.

## Apply schema + seed data

1. Start the DB container (this generates `db_connection.txt`):
   - `./startup.sh`

2. Apply the accountant schema and seed data:
   - `./apply_schema_and_seed.sh`

The script:
- Reads connection settings from `db_connection.txt`
- Executes SQL **one statement at a time**
- Is **idempotent** (safe to run multiple times)
- Creates tables + indexes + foreign keys, and inserts baseline reference data:
  - Thai accounting categories (`thai_accounting_categories`)
  - Common vendors (`vendors`)

## Tables created

- `users` (optional; basic user table)
- `uploads` (file metadata for bank statements/receipts)
- `transactions` (extracted line items)
- `classifications` (category/vendor/tax tags/confidence/override flags)
- `reports` (summary and P&L snapshots)
- `reconciliation_runs` (run metadata)
- `reconciliation_results` (match results per transaction)

Plus reference tables:
- `thai_accounting_categories`
- `vendors`
