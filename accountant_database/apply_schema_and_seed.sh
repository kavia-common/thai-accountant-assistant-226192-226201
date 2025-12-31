#!/bin/bash
set -euo pipefail

# Platform-friendly schema/seed applicator for the Accountant app.
# - Does NOT run automatically from startup.sh (to avoid changing preview behavior).
# - Reads connection info from db_connection.txt (required by container rules).
# - Executes SQL ONE STATEMENT AT A TIME via mysql CLI.
#
# Idempotency strategy:
# - CREATE TABLE IF NOT EXISTS ...
# - Seed data via INSERT ... ON DUPLICATE KEY UPDATE ...
# - Indexes are defined in CREATE TABLE (so no ALTER TABLE needed)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONN_FILE="${SCRIPT_DIR}/db_connection.txt"

if [ ! -f "${CONN_FILE}" ]; then
  echo "ERROR: ${CONN_FILE} not found. Start the DB container first (startup.sh) so it can generate db_connection.txt."
  exit 1
fi

# db_connection.txt contains a full mysql command (including user/pass/host/port/db).
# Example: mysql -u appuser -pdbuser123 -h localhost -P 5000 myapp
MYSQL_CMD="$(cat "${CONN_FILE}")"
echo "Using connection: ${MYSQL_CMD}"

run_sql () {
  local sql="$1"
  # Execute statement as a single line; show the statement if it fails for easier diagnosis.
  if ! eval "${MYSQL_CMD} --protocol=TCP -e \"${sql}\"" >/dev/null; then
    echo "ERROR applying SQL statement:"
    echo "${sql}"
    exit 1
  fi
}

echo "Creating tables (idempotent)..."

# ---- users (optional; kept minimal for attribution) ----
run_sql "CREATE TABLE IF NOT EXISTS users (id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, email VARCHAR(255) NOT NULL, full_name VARCHAR(255) NULL, role ENUM('admin','accountant','user') NOT NULL DEFAULT 'user', is_active TINYINT(1) NOT NULL DEFAULT 1, created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, PRIMARY KEY (id), UNIQUE KEY uniq_users_email (email), KEY idx_users_active (is_active) ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"

# ---- uploads ----
# Requested fields: id, type (bank_statement|receipt), filename, mime, size, upload_time, status
# We keep both original_filename and stored_filename for future-proofing; upload_time uses created_at.
run_sql "CREATE TABLE IF NOT EXISTS uploads (id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, uploaded_by_user_id BIGINT UNSIGNED NULL, upload_type ENUM('bank_statement','receipt','other') NOT NULL, original_filename VARCHAR(255) NOT NULL, stored_filename VARCHAR(255) NULL, mime_type VARCHAR(127) NULL, file_size_bytes BIGINT UNSIGNED NULL, sha256 CHAR(64) NULL, upload_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, status ENUM('uploaded','processing','processed','failed') NOT NULL DEFAULT 'uploaded', error_message TEXT NULL, created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, PRIMARY KEY (id), KEY idx_uploads_upload_time (upload_time), KEY idx_uploads_type_time (upload_type, upload_time), KEY idx_uploads_sha256 (sha256), KEY idx_uploads_uploaded_by (uploaded_by_user_id), CONSTRAINT fk_uploads_user FOREIGN KEY (uploaded_by_user_id) REFERENCES users(id) ON DELETE SET NULL ON UPDATE RESTRICT ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"

# ---- categories (Thai chart of accounts) ----
# Requested: id, name_th, name_en, type (income|expense|cogs|other), parent_id nullable
# Note: name_th is unique per parent to keep demo simple; type+name_en also indexed.
run_sql "CREATE TABLE IF NOT EXISTS categories (id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, name_th VARCHAR(255) NOT NULL, name_en VARCHAR(255) NULL, type ENUM('income','expense','cogs','other') NOT NULL DEFAULT 'expense', parent_id BIGINT UNSIGNED NULL, created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, PRIMARY KEY (id), UNIQUE KEY uniq_categories_parent_name_th (parent_id, name_th), KEY idx_categories_type (type), KEY idx_categories_parent (parent_id), CONSTRAINT fk_categories_parent FOREIGN KEY (parent_id) REFERENCES categories(id) ON DELETE SET NULL ON UPDATE RESTRICT ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"

# ---- transactions ----
# Requested: id, upload_id, txn_date, amount, currency, description, account, counterparty, source_ref, normalized fields
# We include both raw and normalized fields as separate columns.
run_sql "CREATE TABLE IF NOT EXISTS transactions (id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, upload_id BIGINT UNSIGNED NOT NULL, txn_date DATE NOT NULL, posted_at DATETIME NULL, amount DECIMAL(18,2) NOT NULL, currency CHAR(3) NOT NULL DEFAULT 'THB', description VARCHAR(1024) NOT NULL, account VARCHAR(255) NULL, counterparty VARCHAR(255) NULL, source_ref VARCHAR(255) NULL, normalized_description VARCHAR(1024) NULL, normalized_counterparty VARCHAR(255) NULL, normalized_account VARCHAR(255) NULL, normalized_memo VARCHAR(1024) NULL, raw_text TEXT NULL, created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, PRIMARY KEY (id), KEY idx_transactions_upload (upload_id), KEY idx_transactions_date (txn_date), KEY idx_transactions_amount (amount), KEY idx_transactions_currency_date (currency, txn_date), KEY idx_transactions_counterparty (counterparty), KEY idx_transactions_source_ref (source_ref), KEY idx_transactions_date_amount (txn_date, amount), CONSTRAINT fk_transactions_upload FOREIGN KEY (upload_id) REFERENCES uploads(id) ON DELETE CASCADE ON UPDATE RESTRICT ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"

# ---- classifications ----
# Requested: id, transaction_id, category_id, subcategory_id, vendor, tax_tag, confidence, source (manual|ai|rule), updated_at
# We enforce one classification row per transaction via UNIQUE(transaction_id).
run_sql "CREATE TABLE IF NOT EXISTS classifications (id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, transaction_id BIGINT UNSIGNED NOT NULL, category_id BIGINT UNSIGNED NULL, subcategory_id BIGINT UNSIGNED NULL, vendor VARCHAR(255) NULL, tax_tag VARCHAR(64) NULL, confidence DECIMAL(5,4) NULL, source ENUM('manual','ai','rule') NOT NULL DEFAULT 'ai', notes TEXT NULL, created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, PRIMARY KEY (id), UNIQUE KEY uniq_classifications_transaction (transaction_id), KEY idx_classifications_category (category_id), KEY idx_classifications_subcategory (subcategory_id), KEY idx_classifications_vendor (vendor), KEY idx_classifications_source (source), KEY idx_classifications_tax_tag (tax_tag), CONSTRAINT fk_classifications_transaction FOREIGN KEY (transaction_id) REFERENCES transactions(id) ON DELETE CASCADE ON UPDATE RESTRICT, CONSTRAINT fk_classifications_category FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE SET NULL ON UPDATE RESTRICT, CONSTRAINT fk_classifications_subcategory FOREIGN KEY (subcategory_id) REFERENCES categories(id) ON DELETE SET NULL ON UPDATE RESTRICT ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"

# ---- reports ----
# Requested: id, report_type (summary|pnl), period_start, period_end, generated_at, payload_json
run_sql "CREATE TABLE IF NOT EXISTS reports (id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, report_type ENUM('summary','pnl') NOT NULL, period_start DATE NOT NULL, period_end DATE NOT NULL, generated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, payload_json JSON NOT NULL, created_by_user_id BIGINT UNSIGNED NULL, PRIMARY KEY (id), KEY idx_reports_type_period (report_type, period_start, period_end), KEY idx_reports_generated_at (generated_at), KEY idx_reports_created_by (created_by_user_id), CONSTRAINT fk_reports_created_by FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON DELETE SET NULL ON UPDATE RESTRICT ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"

# ---- reports_summary (explicit table requested) ----
# Summary snapshot convenience table. payload_json holds the full summary object.
run_sql "CREATE TABLE IF NOT EXISTS reports_summary (id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, period_start DATE NOT NULL, period_end DATE NOT NULL, generated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, payload_json JSON NOT NULL, created_by_user_id BIGINT UNSIGNED NULL, PRIMARY KEY (id), UNIQUE KEY uniq_reports_summary_period (period_start, period_end), KEY idx_reports_summary_generated_at (generated_at), KEY idx_reports_summary_created_by (created_by_user_id), CONSTRAINT fk_reports_summary_created_by FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON DELETE SET NULL ON UPDATE RESTRICT ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"

# ---- reports_pnl_snapshots (explicit table requested) ----
# P&L snapshot convenience table. payload_json holds lines/totals.
run_sql "CREATE TABLE IF NOT EXISTS reports_pnl_snapshots (id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, period_start DATE NOT NULL, period_end DATE NOT NULL, generated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, payload_json JSON NOT NULL, created_by_user_id BIGINT UNSIGNED NULL, PRIMARY KEY (id), UNIQUE KEY uniq_reports_pnl_period (period_start, period_end), KEY idx_reports_pnl_generated_at (generated_at), KEY idx_reports_pnl_created_by (created_by_user_id), CONSTRAINT fk_reports_pnl_created_by FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON DELETE SET NULL ON UPDATE RESTRICT ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"

# ---- reconciliation_runs ----
# Requested: id, started_at, finished_at, status, notes
run_sql "CREATE TABLE IF NOT EXISTS reconciliation_runs (id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, started_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, finished_at DATETIME NULL, status ENUM('running','completed','failed') NOT NULL DEFAULT 'running', notes TEXT NULL, created_by_user_id BIGINT UNSIGNED NULL, PRIMARY KEY (id), KEY idx_recon_runs_status_started (status, started_at), KEY idx_recon_runs_started_at (started_at), KEY idx_recon_runs_created_by (created_by_user_id), CONSTRAINT fk_recon_runs_created_by FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON DELETE SET NULL ON UPDATE RESTRICT ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"

# ---- reconciliation_results ----
# Requested: id, run_id, transaction_id, receipt_upload_id nullable, match_status (matched|unmatched|partial), confidence, notes
# Uniqueness: (run_id, transaction_id)
run_sql "CREATE TABLE IF NOT EXISTS reconciliation_results (id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, run_id BIGINT UNSIGNED NOT NULL, transaction_id BIGINT UNSIGNED NOT NULL, receipt_upload_id BIGINT UNSIGNED NULL, match_status ENUM('matched','unmatched','partial') NOT NULL DEFAULT 'unmatched', confidence DECIMAL(5,4) NULL, notes TEXT NULL, created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (id), UNIQUE KEY uniq_recon_run_transaction (run_id, transaction_id), KEY idx_recon_results_status (match_status), KEY idx_recon_results_transaction (transaction_id), KEY idx_recon_results_receipt (receipt_upload_id), CONSTRAINT fk_recon_results_run FOREIGN KEY (run_id) REFERENCES reconciliation_runs(id) ON DELETE CASCADE ON UPDATE RESTRICT, CONSTRAINT fk_recon_results_transaction FOREIGN KEY (transaction_id) REFERENCES transactions(id) ON DELETE CASCADE ON UPDATE RESTRICT, CONSTRAINT fk_recon_results_receipt_upload FOREIGN KEY (receipt_upload_id) REFERENCES uploads(id) ON DELETE SET NULL ON UPDATE RESTRICT ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"

echo "Seeding reference data (idempotent)..."

# Minimal demo users (optional)
run_sql "INSERT INTO users (email, full_name, role, is_active) VALUES ('admin@example.com','Admin','admin',1) ON DUPLICATE KEY UPDATE full_name=VALUES(full_name), role=VALUES(role), is_active=VALUES(is_active);"
run_sql "INSERT INTO users (email, full_name, role, is_active) VALUES ('accountant@example.com','Accountant','accountant',1) ON DUPLICATE KEY UPDATE full_name=VALUES(full_name), role=VALUES(role), is_active=VALUES(is_active);"

# Minimal Thai chart of accounts/categories for demos
# Parents
run_sql "INSERT INTO categories (name_th, name_en, type, parent_id) VALUES ('รายได้','Revenue','income',NULL) ON DUPLICATE KEY UPDATE name_en=VALUES(name_en), type=VALUES(type), parent_id=VALUES(parent_id);"
run_sql "INSERT INTO categories (name_th, name_en, type, parent_id) VALUES ('ต้นทุนขาย','COGS','cogs',NULL) ON DUPLICATE KEY UPDATE name_en=VALUES(name_en), type=VALUES(type), parent_id=VALUES(parent_id);"
run_sql "INSERT INTO categories (name_th, name_en, type, parent_id) VALUES ('ค่าใช้จ่าย','Expenses','expense',NULL) ON DUPLICATE KEY UPDATE name_en=VALUES(name_en), type=VALUES(type), parent_id=VALUES(parent_id);"
run_sql "INSERT INTO categories (name_th, name_en, type, parent_id) VALUES ('ภาษีมูลค่าเพิ่ม','VAT','other',NULL) ON DUPLICATE KEY UPDATE name_en=VALUES(name_en), type=VALUES(type), parent_id=VALUES(parent_id);"
run_sql "INSERT INTO categories (name_th, name_en, type, parent_id) VALUES ('อื่นๆ','Misc','other',NULL) ON DUPLICATE KEY UPDATE name_en=VALUES(name_en), type=VALUES(type), parent_id=VALUES(parent_id);"

# Children under Revenue
run_sql "INSERT INTO categories (name_th, name_en, type, parent_id) VALUES ('รายได้จากการขาย','Sales','income',(SELECT id FROM categories WHERE parent_id IS NULL AND name_th='รายได้' LIMIT 1)) ON DUPLICATE KEY UPDATE name_en=VALUES(name_en), type=VALUES(type), parent_id=VALUES(parent_id);"

# Children under COGS
run_sql "INSERT INTO categories (name_th, name_en, type, parent_id) VALUES ('ซื้อสินค้า/วัตถุดิบ','Purchases','cogs',(SELECT id FROM categories WHERE parent_id IS NULL AND name_th='ต้นทุนขาย' LIMIT 1)) ON DUPLICATE KEY UPDATE name_en=VALUES(name_en), type=VALUES(type), parent_id=VALUES(parent_id);"

# Children under Expenses (requested examples)
run_sql "INSERT INTO categories (name_th, name_en, type, parent_id) VALUES ('ค่าสาธารณูปโภค','Utilities','expense',(SELECT id FROM categories WHERE parent_id IS NULL AND name_th='ค่าใช้จ่าย' LIMIT 1)) ON DUPLICATE KEY UPDATE name_en=VALUES(name_en), type=VALUES(type), parent_id=VALUES(parent_id);"
run_sql "INSERT INTO categories (name_th, name_en, type, parent_id) VALUES ('ค่าเช่า','Rent','expense',(SELECT id FROM categories WHERE parent_id IS NULL AND name_th='ค่าใช้จ่าย' LIMIT 1)) ON DUPLICATE KEY UPDATE name_en=VALUES(name_en), type=VALUES(type), parent_id=VALUES(parent_id);"
run_sql "INSERT INTO categories (name_th, name_en, type, parent_id) VALUES ('ค่าวัสดุสำนักงาน','Office Supplies','expense',(SELECT id FROM categories WHERE parent_id IS NULL AND name_th='ค่าใช้จ่าย' LIMIT 1)) ON DUPLICATE KEY UPDATE name_en=VALUES(name_en), type=VALUES(type), parent_id=VALUES(parent_id);"
run_sql "INSERT INTO categories (name_th, name_en, type, parent_id) VALUES ('ค่าเดินทาง/ขนส่ง','Transportation','expense',(SELECT id FROM categories WHERE parent_id IS NULL AND name_th='ค่าใช้จ่าย' LIMIT 1)) ON DUPLICATE KEY UPDATE name_en=VALUES(name_en), type=VALUES(type), parent_id=VALUES(parent_id);"
run_sql "INSERT INTO categories (name_th, name_en, type, parent_id) VALUES ('ค่าอาหารและรับรอง','Meals/Entertainment','expense',(SELECT id FROM categories WHERE parent_id IS NULL AND name_th='ค่าใช้จ่าย' LIMIT 1)) ON DUPLICATE KEY UPDATE name_en=VALUES(name_en), type=VALUES(type), parent_id=VALUES(parent_id);"

# VAT child tags (commonly used)
run_sql "INSERT INTO categories (name_th, name_en, type, parent_id) VALUES ('VAT ภาษีซื้อ','VAT Input','other',(SELECT id FROM categories WHERE parent_id IS NULL AND name_th='ภาษีมูลค่าเพิ่ม' LIMIT 1)) ON DUPLICATE KEY UPDATE name_en=VALUES(name_en), type=VALUES(type), parent_id=VALUES(parent_id);"
run_sql "INSERT INTO categories (name_th, name_en, type, parent_id) VALUES ('VAT ภาษีขาย','VAT Output','other',(SELECT id FROM categories WHERE parent_id IS NULL AND name_th='ภาษีมูลค่าเพิ่ม' LIMIT 1)) ON DUPLICATE KEY UPDATE name_en=VALUES(name_en), type=VALUES(type), parent_id=VALUES(parent_id);"

echo "Done."
echo "You can now inspect tables via db_visualizer, or query via mysql client."
