# Accountant App - MySQL Schema

This container runs MySQL and creates the base database/user in `startup.sh`.

To avoid changing preview startup behavior, the app schema **is not applied automatically** on startup.

## Apply schema + seed data

1. Start the DB container (this generates `db_connection.txt`):
   - `./startup.sh`

2. Apply the accountant schema and seed data (safe to re-run):
   - `./apply_schema_and_seed.sh`

The apply script is platform-friendly:
- Reads connection settings from `db_connection.txt`
- Executes SQL **one statement at a time** via the MySQL CLI
- Is **idempotent**:
  - `CREATE TABLE IF NOT EXISTS ...`
  - `INSERT ... ON DUPLICATE KEY UPDATE ...` for seed data

## How data flows (high level)

1. User uploads:
   - Bank statement PDF/CSV or receipt image/PDF → stored as an `uploads` row.
2. Extraction creates:
   - `transactions` rows (line items) referencing the source `uploads` row.
3. Classification assigns:
   - `classifications` row per `transactions` row with category/vendor/tax tags.
4. Reporting generates:
   - `reports` snapshots (JSON) for summary and P&L.
5. Reconciliation runs:
   - `reconciliation_runs` + `reconciliation_results` mapping transactions to receipt uploads.

## Tables (core)

### `users` (optional)
Minimal user table for attribution and overrides.

Key columns:
- `email` (unique)
- `role`: `admin | accountant | user`

Referenced by:
- `uploads.uploaded_by_user_id` (nullable)
- `classifications.overridden_by_user_id` (nullable)
- `reports.created_by_user_id` (nullable)
- `reconciliation_runs.created_by_user_id` (nullable)

### `uploads`
File metadata for bank statements, receipts, and other uploads.

Key columns:
- `upload_type`: `bank_statement | receipt | other`
- `original_filename`, `stored_filename`, `mime_type`, `file_size_bytes`, `sha256`
- Statement-specific fields: `statement_period_start`, `statement_period_end`
- `status`: `uploaded | processing | processed | failed`

Relationships:
- One `uploads` → many `transactions` (bank statement line items)
- Receipts are represented as `uploads` rows with `upload_type='receipt'`

### `transactions`
Extracted line items.

Key columns:
- `source_upload_id` (FK → `uploads.id`)
- `txn_date`, `posted_at`
- `amount` (DECIMAL), `currency` (default `THB`)
- `description`, `counterparty`, `reference_no`, `raw_text`

### `classifications`
One row per transaction (enforced by unique constraint).

Key columns:
- `transaction_id` (FK → `transactions.id`, unique)
- `category_id` (FK → `thai_accounting_categories.id`, nullable)
- `vendor_id` (FK → `vendors.id`, nullable)
- `tax_tags` (JSON), `confidence`, `is_overridden`, `overridden_by_user_id`, `notes`

### `reports`
Summary and P&L snapshots stored as JSON to keep the schema minimal and flexible.

Key columns:
- `report_type`: `summary | pnl`
- `period_start`, `period_end`
- `generated_at`
- `parameters` (JSON), `snapshot` (JSON)
- `created_by_user_id` (nullable)

### `reconciliation_runs`
Tracks a reconciliation process.

Key columns:
- `strategy`: `exact_amount_date | fuzzy | manual | hybrid`
- `parameters` (JSON)
- `status`: `running | completed | failed`
- `started_at`, `ended_at`, `created_by_user_id` (nullable)

### `reconciliation_results`
Per-transaction reconciliation outcomes for a given run.

Key columns:
- `reconciliation_run_id` (FK → `reconciliation_runs.id`)
- `transaction_id` (FK → `transactions.id`)
- `matched_receipt_upload_id` (FK → `uploads.id`, nullable)
- `status`: `matched | unmatched | ambiguous | ignored`
- `match_score`, `notes`

Constraints:
- Unique per (run, transaction): `UNIQUE(reconciliation_run_id, transaction_id)`

## Reference tables (seeded)

### `thai_accounting_categories`
Thai-friendly chart-of-accounts baseline used for classification and P&L grouping.

- Unique `code` (stable identifier)
- `name_th`, `name_en`
- `type`: `income | cogs | expense | asset | liability | equity | tax`

Seed includes common Thai categories such as:
- Income: Sales/Service/Interest
- COGS: Purchases, inbound shipping
- Operating expenses: Rent, Utilities, Internet/Phone, Salaries, Office supplies, Travel, Meals/Entertainment, Marketing, Professional fees, Repairs, Bank fees, Other
- Tax: VAT input/output, Withholding tax

### `vendors`
Common vendors (Thai + English labels) with optional default category.

## Quick verification queries

After running `./apply_schema_and_seed.sh`:

- List tables:
  - `SHOW TABLES;`
- Verify categories:
  - `SELECT code, name_th, type FROM thai_accounting_categories ORDER BY type, code;`
- Verify vendors:
  - `SELECT name, name_th, default_category_id FROM vendors ORDER BY name;`
