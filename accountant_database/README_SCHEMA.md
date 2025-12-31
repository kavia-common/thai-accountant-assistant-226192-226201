# Accountant App - MySQL Schema (Step 2.1)

This container runs MySQL and creates the base database/user in `startup.sh`.

To avoid changing preview startup behavior, the app schema **is not applied automatically** on startup.

## Apply schema + seed data (idempotent)

1. Start the DB container (this generates `db_connection.txt`):
   - `./startup.sh`

2. Apply the accountant schema and seed data (safe to re-run):
   - `./apply_schema_and_seed.sh`

The apply script is platform-friendly:
- Reads connection settings from `db_connection.txt`
- Executes SQL **one statement at a time** via the MySQL CLI
- Is **idempotent**:
  - `CREATE TABLE IF NOT EXISTS ...`
  - Seed data uses `INSERT ... ON DUPLICATE KEY UPDATE ...` for safe re-runs

## Core tables

### `users` (optional)
Minimal user table for attribution.

Key columns:
- `email` (unique)
- `role`: `admin | accountant | user`

Referenced by:
- `uploads.uploaded_by_user_id` (nullable)
- `reports.created_by_user_id` (nullable)
- `reconciliation_runs.created_by_user_id` (nullable)

---

### `uploads`
File metadata for bank statements, receipts, and other uploads.

Key columns (requested):
- `id`
- `upload_type`: `bank_statement | receipt | other`
- `original_filename` (filename)
- `mime_type` (mime)
- `file_size_bytes` (size)
- `upload_time` (upload_time)
- `status`: `uploaded | processing | processed | failed`

Notes:
- `stored_filename`, `sha256` included for future-proofing.

---

### `transactions`
Extracted line items from bank statement uploads (and potentially other sources).

Key columns (requested):
- `upload_id` (FK → `uploads.id`)
- `txn_date`
- `amount` (DECIMAL)
- `currency` (default `THB`)
- `description`
- `account`
- `counterparty`
- `source_ref`

Normalized fields (for backend normalization/search):
- `normalized_description`, `normalized_counterparty`, `normalized_account`, `normalized_memo`

---

### `categories`
Thai chart-of-accounts / category tree used for classification and reporting.

Key columns (requested):
- `name_th`, `name_en`
- `type`: `income | expense | cogs | other`
- `parent_id` (self FK, nullable)

Uniqueness:
- `UNIQUE(parent_id, name_th)` to avoid duplicate Thai names under the same parent.

---

### `classifications`
One row per transaction (enforced via unique constraint).

Key columns (requested):
- `transaction_id` (unique FK → `transactions.id`)
- `category_id` (FK → `categories.id`)
- `subcategory_id` (FK → `categories.id`)
- `vendor` (string label)
- `tax_tag` (string label)
- `confidence`
- `source`: `manual | ai | rule`
- `updated_at`

---

### `reports`
Stores report snapshots as JSON.

Key columns (requested):
- `report_type`: `summary | pnl`
- `period_start`, `period_end`
- `generated_at`
- `payload_json` (JSON)

---

### `reconciliation_runs`
Tracks a reconciliation process.

Key columns (requested):
- `started_at`
- `finished_at`
- `status`: `running | completed | failed`
- `notes`

---

### `reconciliation_results`
Per-transaction reconciliation outcomes for a given run.

Key columns (requested):
- `run_id` (FK → `reconciliation_runs.id`)
- `transaction_id` (FK → `transactions.id`)
- `receipt_upload_id` (FK → `uploads.id`, nullable)
- `match_status`: `matched | unmatched | partial`
- `confidence`
- `notes`

Constraints:
- Unique per (run, transaction): `UNIQUE(run_id, transaction_id)`

## Seed data (minimal Thai demo set)

Seed includes a minimal Thai category tree suitable for demos:
- Revenue (รายได้) → Sales (รายได้จากการขาย)
- COGS (ต้นทุนขาย) → Purchases (ซื้อสินค้า/วัตถุดิบ)
- Expenses (ค่าใช้จ่าย) → Utilities, Rent, Office Supplies, Transportation, Meals/Entertainment
- VAT (ภาษีมูลค่าเพิ่ม) → VAT Input/Output
- Misc (อื่นๆ)

### Important MySQL idempotency note (top-level categories)
MySQL UNIQUE indexes allow multiple rows with `NULL` values. That means `UNIQUE(parent_id, name_th)` **does not** prevent duplicates for top-level categories where `parent_id IS NULL`.

To make the seed idempotent, the schema uses a generated column:
- `parent_id_key GENERATED ALWAYS AS (COALESCE(parent_id,0))`
and enforces:
- `UNIQUE(parent_id_key, name_th)`

This ensures top-level category seeds (where `parent_id` is NULL) do not duplicate across repeated runs.

### Note on categories self-FK
In some environments the self-referential foreign key on `categories.parent_id` may fail to (re-)add with `ERROR 1215`. The application logic primarily requires stable IDs + uniqueness for seeding; the FK is optional and can be re-enabled later if needed.

Also seeds minimal optional demo users:
- `admin@example.com`
- `accountant@example.com`

## Quick verification queries

After running `./apply_schema_and_seed.sh`:

- List tables:
  - `SHOW TABLES;`

- Verify categories (top-level):
  - `SELECT id, name_th, name_en, type FROM categories WHERE parent_id IS NULL ORDER BY type, name_th;`

- Verify category tree (children):
  - `SELECT c2.name_th AS child_th, c1.name_th AS parent_th, c2.type FROM categories c2 LEFT JOIN categories c1 ON c2.parent_id=c1.id WHERE c2.parent_id IS NOT NULL ORDER BY parent_th, child_th;`

- Verify report snapshot tables exist (requested: summary + P&L snapshots):
  - `SHOW TABLES LIKE 'reports_%';`
  - `DESCRIBE reports_summary;`
  - `DESCRIBE reports_pnl_snapshots;`

- Verify constraints exist (examples):
  - `SHOW CREATE TABLE classifications;`
  - `SHOW CREATE TABLE reconciliation_results;`

- Verify idempotency quickly:
  1) Run `./apply_schema_and_seed.sh` twice
  2) Confirm seed duplicates were not created:
     - `SELECT parent_id, name_th, COUNT(*) AS cnt FROM categories GROUP BY parent_id, name_th HAVING cnt > 1;`
     - `SELECT email, COUNT(*) AS cnt FROM users GROUP BY email HAVING cnt > 1;`
