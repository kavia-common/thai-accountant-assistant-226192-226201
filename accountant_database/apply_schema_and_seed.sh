#!/bin/bash
set -euo pipefail

# Platform-friendly schema/seed applicator for the Accountant app.
# - Does NOT run automatically from startup.sh (to avoid changing preview behavior).
# - Reads connection info from db_connection.txt (required by container rules).
# - Executes SQL ONE STATEMENT AT A TIME.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONN_FILE="${SCRIPT_DIR}/db_connection.txt"

if [ ! -f "${CONN_FILE}" ]; then
  echo "ERROR: ${CONN_FILE} not found. Start the DB container first (startup.sh) so it can generate db_connection.txt."
  exit 1
fi

MYSQL_CMD="$(cat "${CONN_FILE}")"
echo "Using connection: ${MYSQL_CMD}"

run_sql () {
  local sql="$1"
  # Execute statement as a single line
  eval "${MYSQL_CMD} -e \"${sql}\"" >/dev/null
}

echo "Creating tables (idempotent)..."

# ---- uploads (files metadata for bank statements and receipts) ----
run_sql "CREATE TABLE IF NOT EXISTS uploads (id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, uploaded_by_user_id BIGINT UNSIGNED NULL, upload_type ENUM('bank_statement','receipt','other') NOT NULL, original_filename VARCHAR(255) NOT NULL, stored_filename VARCHAR(255) NULL, mime_type VARCHAR(127) NULL, file_size_bytes BIGINT UNSIGNED NULL, sha256 CHAR(64) NULL, source_system VARCHAR(64) NULL, statement_period_start DATE NULL, statement_period_end DATE NULL, status ENUM('uploaded','processing','processed','failed') NOT NULL DEFAULT 'uploaded', error_message TEXT NULL, created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, PRIMARY KEY (id), KEY idx_uploads_created_at (created_at), KEY idx_uploads_type_created (upload_type, created_at), KEY idx_uploads_sha256 (sha256) ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"

# ---- transactions (extracted line items) ----
run_sql "CREATE TABLE IF NOT EXISTS transactions (id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, source_upload_id BIGINT UNSIGNED NOT NULL, txn_date DATE NOT NULL, posted_at DATETIME NULL, amount DECIMAL(18,2) NOT NULL, currency CHAR(3) NOT NULL DEFAULT 'THB', description VARCHAR(1024) NOT NULL, counterparty VARCHAR(255) NULL, reference_no VARCHAR(128) NULL, raw_text TEXT NULL, created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, PRIMARY KEY (id), KEY idx_transactions_date (txn_date), KEY idx_transactions_amount (amount), KEY idx_transactions_currency_date (currency, txn_date), KEY idx_transactions_source_upload (source_upload_id), KEY idx_transactions_date_amount (txn_date, amount), CONSTRAINT fk_transactions_source_upload FOREIGN KEY (source_upload_id) REFERENCES uploads(id) ON DELETE CASCADE ON UPDATE RESTRICT ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"

# ---- category reference (Thai accounting categories) ----
run_sql "CREATE TABLE IF NOT EXISTS thai_accounting_categories (id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, code VARCHAR(32) NOT NULL, name_th VARCHAR(255) NOT NULL, name_en VARCHAR(255) NULL, type ENUM('income','expense','asset','liability','equity','tax') NOT NULL DEFAULT 'expense', is_active TINYINT(1) NOT NULL DEFAULT 1, created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (id), UNIQUE KEY uniq_thai_categories_code (code), KEY idx_thai_categories_type (type), KEY idx_thai_categories_active (is_active) ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"

# ---- vendors reference (common vendors) ----
run_sql "CREATE TABLE IF NOT EXISTS vendors (id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, name VARCHAR(255) NOT NULL, name_th VARCHAR(255) NULL, name_en VARCHAR(255) NULL, tax_id VARCHAR(32) NULL, default_category_id BIGINT UNSIGNED NULL, created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (id), UNIQUE KEY uniq_vendors_name (name), KEY idx_vendors_default_category (default_category_id), CONSTRAINT fk_vendors_default_category FOREIGN KEY (default_category_id) REFERENCES thai_accounting_categories(id) ON DELETE SET NULL ON UPDATE RESTRICT ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"

# ---- classifications (category/vendor/tax tags/confidence/override flags) ----
run_sql "CREATE TABLE IF NOT EXISTS classifications (id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, transaction_id BIGINT UNSIGNED NOT NULL, category_id BIGINT UNSIGNED NULL, vendor_id BIGINT UNSIGNED NULL, tax_tags JSON NULL, confidence DECIMAL(5,4) NULL, is_overridden TINYINT(1) NOT NULL DEFAULT 0, overridden_by_user_id BIGINT UNSIGNED NULL, notes TEXT NULL, created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, PRIMARY KEY (id), UNIQUE KEY uniq_classifications_transaction (transaction_id), KEY idx_classifications_category (category_id), KEY idx_classifications_vendor (vendor_id), KEY idx_classifications_confidence (confidence), CONSTRAINT fk_classifications_transaction FOREIGN KEY (transaction_id) REFERENCES transactions(id) ON DELETE CASCADE ON UPDATE RESTRICT, CONSTRAINT fk_classifications_category FOREIGN KEY (category_id) REFERENCES thai_accounting_categories(id) ON DELETE SET NULL ON UPDATE RESTRICT, CONSTRAINT fk_classifications_vendor FOREIGN KEY (vendor_id) REFERENCES vendors(id) ON DELETE SET NULL ON UPDATE RESTRICT ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"

# ---- reports (summary snapshots and P&L snapshots with period) ----
run_sql "CREATE TABLE IF NOT EXISTS reports (id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, report_type ENUM('summary','pnl') NOT NULL, period_start DATE NOT NULL, period_end DATE NOT NULL, generated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, parameters JSON NULL, snapshot JSON NOT NULL, created_by_user_id BIGINT UNSIGNED NULL, source_reconciliation_run_id BIGINT UNSIGNED NULL, PRIMARY KEY (id), KEY idx_reports_type_period (report_type, period_start, period_end), KEY idx_reports_generated_at (generated_at) ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"

# ---- reconciliation_runs (start/end/strategy) ----
run_sql "CREATE TABLE IF NOT EXISTS reconciliation_runs (id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, started_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, ended_at DATETIME NULL, strategy ENUM('exact_amount_date','fuzzy','manual','hybrid') NOT NULL DEFAULT 'hybrid', parameters JSON NULL, status ENUM('running','completed','failed') NOT NULL DEFAULT 'running', created_by_user_id BIGINT UNSIGNED NULL, notes TEXT NULL, PRIMARY KEY (id), KEY idx_recon_runs_status_started (status, started_at), KEY idx_recon_runs_started_at (started_at) ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"

# ---- reconciliation_results (transaction_id, matched_receipt_id, status, notes) ----
run_sql "CREATE TABLE IF NOT EXISTS reconciliation_results (id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, reconciliation_run_id BIGINT UNSIGNED NOT NULL, transaction_id BIGINT UNSIGNED NOT NULL, matched_receipt_upload_id BIGINT UNSIGNED NULL, status ENUM('matched','unmatched','ambiguous','ignored') NOT NULL DEFAULT 'unmatched', match_score DECIMAL(5,4) NULL, notes TEXT NULL, created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (id), UNIQUE KEY uniq_recon_run_transaction (reconciliation_run_id, transaction_id), KEY idx_recon_results_status (status), KEY idx_recon_results_transaction (transaction_id), KEY idx_recon_results_matched_receipt (matched_receipt_upload_id), CONSTRAINT fk_recon_results_run FOREIGN KEY (reconciliation_run_id) REFERENCES reconciliation_runs(id) ON DELETE CASCADE ON UPDATE RESTRICT, CONSTRAINT fk_recon_results_transaction FOREIGN KEY (transaction_id) REFERENCES transactions(id) ON DELETE CASCADE ON UPDATE RESTRICT, CONSTRAINT fk_recon_results_receipt_upload FOREIGN KEY (matched_receipt_upload_id) REFERENCES uploads(id) ON DELETE SET NULL ON UPDATE RESTRICT ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"

# ---- minimal optional users table (kept optional; not used by FKs above except nullable IDs) ----
run_sql "CREATE TABLE IF NOT EXISTS users (id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, email VARCHAR(255) NOT NULL, full_name VARCHAR(255) NULL, role ENUM('admin','accountant','user') NOT NULL DEFAULT 'user', is_active TINYINT(1) NOT NULL DEFAULT 1, created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, PRIMARY KEY (id), UNIQUE KEY uniq_users_email (email), KEY idx_users_active (is_active) ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"

echo "Seeding reference data (idempotent)..."

# Thai accounting categories (common, minimal baseline for P&L)
run_sql "INSERT INTO thai_accounting_categories (code, name_th, name_en, type) VALUES ('REV_SALES','รายได้จากการขาย','Sales revenue','income') ON DUPLICATE KEY UPDATE name_th=VALUES(name_th), name_en=VALUES(name_en), type=VALUES(type);"
run_sql "INSERT INTO thai_accounting_categories (code, name_th, name_en, type) VALUES ('REV_SERVICE','รายได้จากการให้บริการ','Service revenue','income') ON DUPLICATE KEY UPDATE name_th=VALUES(name_th), name_en=VALUES(name_en), type=VALUES(type);"

run_sql "INSERT INTO thai_accounting_categories (code, name_th, name_en, type) VALUES ('EXP_RENT','ค่าเช่า','Rent expense','expense') ON DUPLICATE KEY UPDATE name_th=VALUES(name_th), name_en=VALUES(name_en), type=VALUES(type);"
run_sql "INSERT INTO thai_accounting_categories (code, name_th, name_en, type) VALUES ('EXP_UTIL','ค่าสาธารณูปโภค','Utilities','expense') ON DUPLICATE KEY UPDATE name_th=VALUES(name_th), name_en=VALUES(name_en), type=VALUES(type);"
run_sql "INSERT INTO thai_accounting_categories (code, name_th, name_en, type) VALUES ('EXP_SALARY','เงินเดือนและค่าจ้าง','Salaries & wages','expense') ON DUPLICATE KEY UPDATE name_th=VALUES(name_th), name_en=VALUES(name_en), type=VALUES(type);"
run_sql "INSERT INTO thai_accounting_categories (code, name_th, name_en, type) VALUES ('EXP_TRAVEL','ค่าเดินทาง','Travel','expense') ON DUPLICATE KEY UPDATE name_th=VALUES(name_th), name_en=VALUES(name_en), type=VALUES(type);"
run_sql "INSERT INTO thai_accounting_categories (code, name_th, name_en, type) VALUES ('EXP_MEALS','ค่าอาหารและรับรอง','Meals & entertainment','expense') ON DUPLICATE KEY UPDATE name_th=VALUES(name_th), name_en=VALUES(name_en), type=VALUES(type);"
run_sql "INSERT INTO thai_accounting_categories (code, name_th, name_en, type) VALUES ('EXP_SUPPLIES','ค่าวัสดุสำนักงาน','Office supplies','expense') ON DUPLICATE KEY UPDATE name_th=VALUES(name_th), name_en=VALUES(name_en), type=VALUES(type);"
run_sql "INSERT INTO thai_accounting_categories (code, name_th, name_en, type) VALUES ('EXP_MARKETING','ค่าโฆษณาและการตลาด','Marketing','expense') ON DUPLICATE KEY UPDATE name_th=VALUES(name_th), name_en=VALUES(name_en), type=VALUES(type);"
run_sql "INSERT INTO thai_accounting_categories (code, name_th, name_en, type) VALUES ('EXP_BANK_FEE','ค่าธรรมเนียมธนาคาร','Bank fees','expense') ON DUPLICATE KEY UPDATE name_th=VALUES(name_th), name_en=VALUES(name_en), type=VALUES(type);"

run_sql "INSERT INTO thai_accounting_categories (code, name_th, name_en, type) VALUES ('TAX_VAT_IN','ภาษีซื้อ (VAT Input)','VAT input','tax') ON DUPLICATE KEY UPDATE name_th=VALUES(name_th), name_en=VALUES(name_en), type=VALUES(type);"
run_sql "INSERT INTO thai_accounting_categories (code, name_th, name_en, type) VALUES ('TAX_VAT_OUT','ภาษีขาย (VAT Output)','VAT output','tax') ON DUPLICATE KEY UPDATE name_th=VALUES(name_th), name_en=VALUES(name_en), type=VALUES(type);"
run_sql "INSERT INTO thai_accounting_categories (code, name_th, name_en, type) VALUES ('TAX_WHT','ภาษีหัก ณ ที่จ่าย','Withholding tax','tax') ON DUPLICATE KEY UPDATE name_th=VALUES(name_th), name_en=VALUES(name_en), type=VALUES(type);"

# Common vendors (minimal set; link to sensible default categories)
run_sql "INSERT INTO vendors (name, name_th, name_en, default_category_id) VALUES ('7-Eleven','7-Eleven','7-Eleven',(SELECT id FROM thai_accounting_categories WHERE code='EXP_MEALS' LIMIT 1)) ON DUPLICATE KEY UPDATE name_th=VALUES(name_th), name_en=VALUES(name_en), default_category_id=VALUES(default_category_id);"
run_sql "INSERT INTO vendors (name, name_th, name_en, default_category_id) VALUES ('Grab','แกร็บ','Grab',(SELECT id FROM thai_accounting_categories WHERE code='EXP_TRAVEL' LIMIT 1)) ON DUPLICATE KEY UPDATE name_th=VALUES(name_th), name_en=VALUES(name_en), default_category_id=VALUES(default_category_id);"
run_sql "INSERT INTO vendors (name, name_th, name_en, default_category_id) VALUES ('LINE MAN','ไลน์แมน','LINE MAN',(SELECT id FROM thai_accounting_categories WHERE code='EXP_MEALS' LIMIT 1)) ON DUPLICATE KEY UPDATE name_th=VALUES(name_th), name_en=VALUES(name_en), default_category_id=VALUES(default_category_id);"
run_sql "INSERT INTO vendors (name, name_th, name_en, default_category_id) VALUES ('Shopee','ช้อปปี้','Shopee',(SELECT id FROM thai_accounting_categories WHERE code='EXP_SUPPLIES' LIMIT 1)) ON DUPLICATE KEY UPDATE name_th=VALUES(name_th), name_en=VALUES(name_en), default_category_id=VALUES(default_category_id);"
run_sql "INSERT INTO vendors (name, name_th, name_en, default_category_id) VALUES ('Lazada','ลาซาด้า','Lazada',(SELECT id FROM thai_accounting_categories WHERE code='EXP_SUPPLIES' LIMIT 1)) ON DUPLICATE KEY UPDATE name_th=VALUES(name_th), name_en=VALUES(name_en), default_category_id=VALUES(default_category_id);"
run_sql "INSERT INTO vendors (name, name_th, name_en, default_category_id) VALUES ('PEA','การไฟฟ้าส่วนภูมิภาค','Provincial Electricity Authority',(SELECT id FROM thai_accounting_categories WHERE code='EXP_UTIL' LIMIT 1)) ON DUPLICATE KEY UPDATE name_th=VALUES(name_th), name_en=VALUES(name_en), default_category_id=VALUES(default_category_id);"
run_sql "INSERT INTO vendors (name, name_th, name_en, default_category_id) VALUES ('MEA','การไฟฟ้านครหลวง','Metropolitan Electricity Authority',(SELECT id FROM thai_accounting_categories WHERE code='EXP_UTIL' LIMIT 1)) ON DUPLICATE KEY UPDATE name_th=VALUES(name_th), name_en=VALUES(name_en), default_category_id=VALUES(default_category_id);"
run_sql "INSERT INTO vendors (name, name_th, name_en, default_category_id) VALUES ('TRUE','ทรู','TRUE',(SELECT id FROM thai_accounting_categories WHERE code='EXP_UTIL' LIMIT 1)) ON DUPLICATE KEY UPDATE name_th=VALUES(name_th), name_en=VALUES(name_en), default_category_id=VALUES(default_category_id);"
run_sql "INSERT INTO vendors (name, name_th, name_en, default_category_id) VALUES ('AIS','เอไอเอส','AIS',(SELECT id FROM thai_accounting_categories WHERE code='EXP_UTIL' LIMIT 1)) ON DUPLICATE KEY UPDATE name_th=VALUES(name_th), name_en=VALUES(name_en), default_category_id=VALUES(default_category_id);"

echo "Done."
echo "You can now inspect tables via db_visualizer, or query via mysql client."
