#!/bin/bash
# ERPNext Production Entrypoint — role-based process dispatch.
#
# The PROCESS_ROLE environment variable selects which process this
# container runs.  Supported roles:
#
#   configurator    Bootstrap site on first run; migrate on subsequent runs.
#                   Retries up to CONFIGURATOR_RETRIES times on transient
#                   failures, then exits non-zero to block dependent services.
#   web             Production WSGI server (explicit gunicorn invocation).
#   socketio        Node.js SocketIO server for real-time events.
#   worker-default  Background worker — default queue.
#   worker-short    Background worker — short queue.
#   worker-long     Background worker — long queue.
#   scheduler       Frappe scheduler for periodic tasks.
#
# All roles write the production common_site_config.json (idempotent)
# before dispatching.

set -e

# ------------------------------------------------------------------
# Environment defaults (override via docker-compose or .env)
#
# CREDENTIAL POLICY: Sensitive variables (passwords) have NO default
# fallback.  If they are unset, empty, or still contain placeholder
# values, validate_credentials() fails fast in the configurator role.
# Non-sensitive infrastructure variables retain safe defaults.
# ------------------------------------------------------------------
SITE_NAME="${SITE_NAME:-erp.saharapro.team}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"          # REQUIRED — no default
DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-3306}"
DB_ROOT_USER="${DB_ROOT_USER:-root}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-}"      # REQUIRED — no default
DB_NAME="${DB_NAME:-erpnext}"
DB_USER="${DB_USER:-erpnext}"
DB_PASSWORD="${DB_PASSWORD:-}"                # REQUIRED — no default
REDIS_CACHE_HOST="${REDIS_CACHE_HOST:-redis-cache}"
REDIS_QUEUE_HOST="${REDIS_QUEUE_HOST:-redis-queue}"
GUNICORN_WORKERS="${GUNICORN_WORKERS:-4}"
PROCESS_ROLE="${PROCESS_ROLE:-web}"
CONFIGURATOR_RETRIES="${CONFIGURATOR_RETRIES:-5}"
CONFIGURATOR_RETRY_DELAY="${CONFIGURATOR_RETRY_DELAY:-10}"

# Sentinel file marks a COMPLETED bootstrap (all steps succeeded).
BOOTSTRAP_SENTINEL="sites/${SITE_NAME}/.bootstrapped"

cd /home/frappe/frappe-bench

# ------------------------------------------------------------------
# Ensure required directories exist
# ------------------------------------------------------------------
mkdir -p sites
mkdir -p /home/frappe/logs

# ------------------------------------------------------------------
# Write production common_site_config.json (idempotent)
# ------------------------------------------------------------------
echo "==> [${PROCESS_ROLE}] Configuring common_site_config.json..."
bench set-config -g db_host "$DB_HOST"
bench set-config -g db_port "$DB_PORT"
bench set-config -g redis_cache "redis://${REDIS_CACHE_HOST}:6379"
bench set-config -g redis_queue "redis://${REDIS_QUEUE_HOST}:6379"
bench set-config -g redis_socketio "redis://${REDIS_QUEUE_HOST}:6379"
bench set-config -g socketio_port "9000"
bench set-config -g developer_mode 0
bench set-config -g server_script_enabled 1
bench set-config -g serve_default_site 1
bench set-config -g http_timeout 120

# ------------------------------------------------------------------
# Helper: drop a partial site database (used during bootstrap)
# ------------------------------------------------------------------
drop_site_database() {
	/home/frappe/frappe-bench/env/bin/python - <<'PY'
import os
import MySQLdb

host = os.environ.get("DB_HOST", "db")
port = int(os.environ.get("DB_PORT", "3306"))
user = os.environ.get("DB_ROOT_USER", "root")
password = os.environ.get("DB_ROOT_PASSWORD", "")
database = os.environ.get("DB_NAME", "erpnext")

conn = MySQLdb.connect(host=host, port=port, user=user, passwd=password, charset="utf8mb4")
try:
	cur = conn.cursor()
	cur.execute(f"DROP DATABASE IF EXISTS `{database}`")
	conn.commit()
finally:
	conn.close()
PY
}

# ------------------------------------------------------------------
# Helper: fix asset permissions so nginx (UID 101) can read them
# from the shared volume.  Frappe creates files as the 'frappe' user
# (UID 1000); this ensures world-readability.
# ------------------------------------------------------------------
fix_asset_permissions() {
	echo "==> [configurator] Setting permissions on shared site assets..."
	chmod -R a+rX sites/ 2>/dev/null || true
}

# ------------------------------------------------------------------
# Role: configurator — bootstrap or migrate, then exit.
# Returns 0 on success, non-zero on failure (no internal exit call
# so the retry loop can control flow).
# ------------------------------------------------------------------
run_configurator() {
	echo "==> [configurator] Checking site '${SITE_NAME}'..."

	# If a healthy site exists but lacks the sentinel (e.g. migrated from
	# an older setup), mark it as bootstrapped.
	if [ ! -f "$BOOTSTRAP_SENTINEL" ]; then
		if [ -d "sites/${SITE_NAME}" ] && bench --site "$SITE_NAME" list-apps >/dev/null 2>&1; then
			echo "==> [configurator] Site exists and is healthy — marking as bootstrapped."
			touch "$BOOTSTRAP_SENTINEL"
		fi
	fi

	if [ ! -f "$BOOTSTRAP_SENTINEL" ]; then
		# Clean up any partial site left by a previously failed bootstrap.
		if [ -d "sites/${SITE_NAME}" ]; then
			echo "==> [configurator] Removing partial site '${SITE_NAME}' from incomplete bootstrap..."
			rm -rf "sites/${SITE_NAME}"
		fi

		echo "==> [configurator] Dropping partial database '${DB_NAME}' if it exists..."
		drop_site_database

		echo "==> [configurator] Creating site '${SITE_NAME}'..."
		bench new-site "$SITE_NAME" \
			--db-root-username "$DB_ROOT_USER" \
			--db-root-password "$DB_ROOT_PASSWORD" \
			--db-name "$DB_NAME" \
			--db-user "$DB_USER" \
			--db-password "$DB_PASSWORD" \
			--admin-password "$ADMIN_PASSWORD" \
			--db-host "$DB_HOST"

		echo "==> [configurator] Installing ERPNext app..."
		bench --site "$SITE_NAME" install-app erpnext

		echo "==> [configurator] Enabling scheduler..."
		bench --site "$SITE_NAME" enable-scheduler
		bench use "$SITE_NAME"

		touch "$BOOTSTRAP_SENTINEL"
		echo "==> [configurator] Site '${SITE_NAME}' created and bootstrapped successfully."
	else
		echo "==> [configurator] Site already bootstrapped. Running migrate..."
		bench --site "$SITE_NAME" migrate
		bench use "$SITE_NAME"

		# Idempotent safety nets — no-op on an already-installed site.
		bench --site "$SITE_NAME" install-app erpnext 2>/dev/null || true
		bench --site "$SITE_NAME" enable-scheduler 2>/dev/null || true
	fi

	# Build assets into the shared volume so nginx can serve them.
	# Uses --app erpnext (matching the Dockerfile) to avoid crashing
	# on frappe which lacks a .git directory in the bench image.
	# The erpnext build also pulls in any frappe dependency bundles.
	# Failure here MUST propagate — stale assets cause 404s for
	# login/website JS bundles.
	echo "==> [configurator] Building frontend assets (erpnext only)..."
	bench build --app erpnext || { echo "==> [configurator] ERROR: Asset build failed."; return 1; }

	# Fix permissions so the nginx container (UID 101) can read assets
	# from the shared sites volume.
	fix_asset_permissions

	echo "==> [configurator] Done. Site is ready."
}

# ------------------------------------------------------------------
# Security: validate credentials before any site operation.
# Fails fast if passwords are missing, empty, or still set to
# placeholder/default values from the .env template.
# Set SKIP_CREDENTIAL_VALIDATION=1 to bypass (development only).
# ------------------------------------------------------------------
validate_credentials() {
	if [ "${SKIP_CREDENTIAL_VALIDATION:-0}" = "1" ]; then
		echo "==> [configurator] SKIP_CREDENTIAL_VALIDATION=1 — bypassing credential checks."
		return 0
	fi

	local errors=0
	local insecure_list="admin password erpnext changeme test 123456 secret letmein"

	check_not_empty() {
		if [ -z "$1" ]; then
			echo "ERROR: $2 is empty or not set. Production requires a secure value."
			errors=$((errors + 1))
			return 1
		fi
		return 0
	}

	check_not_default() {
		local val="$1" name="$2"
		# Exact matches against known weak defaults
		for word in $insecure_list; do
			if [ "$val" = "$word" ]; then
				echo "ERROR: $name is set to insecure value '$word'. Change it to a strong, unique password."
				errors=$((errors + 1))
				return 1
			fi
		done
		# Placeholder-prefix patterns (Spanish + English "change this")
		case "$val" in
			cambiaEsta*|CambiaEsta*|cambia_esta*|\
			changeThis*|ChangeThis*|change_this*|\
			changeme*|placeholder*|CHANGEME*|PLACEHOLDER*|\
			your-password*|your_password*|replace-me*|replace_me*)
				echo "ERROR: $name starts with a placeholder prefix. Replace it with a real secret in .env."
				errors=$((errors + 1))
				return 1
				;;
		esac
		# Minimum length
		if [ "${#val}" -lt 8 ]; then
			echo "ERROR: $name is too short (${#val} chars, minimum 8 required)."
			errors=$((errors + 1))
			return 1
		fi
		return 0
	}

	echo "==> [configurator] Validating credentials..."
	check_not_empty   "$DB_ROOT_PASSWORD" "DB_ROOT_PASSWORD"
	check_not_default "$DB_ROOT_PASSWORD" "DB_ROOT_PASSWORD"
	check_not_empty   "$DB_PASSWORD"      "DB_PASSWORD"
	check_not_default "$DB_PASSWORD"      "DB_PASSWORD"
	check_not_empty   "$ADMIN_PASSWORD"   "ADMIN_PASSWORD"
	check_not_default "$ADMIN_PASSWORD"   "ADMIN_PASSWORD"

	if [ "$errors" -gt 0 ]; then
		echo ""
		echo "==> Security validation FAILED (${errors} error(s))."
		echo "==> Edit the .env file, replace all placeholder passwords with"
		echo "==> strong unique secrets, and redeploy."
		exit 1
	fi

	echo "==> [configurator] Credentials validated."
}

# ------------------------------------------------------------------
# Role dispatcher
# ------------------------------------------------------------------
case "$PROCESS_ROLE" in
	configurator)
		validate_credentials
		# Retry loop: transient failures (e.g. DB still warming up,
		# network glitch) are retried up to CONFIGURATOR_RETRIES times.
		# Persistent failures exit non-zero, blocking dependent services
		# via service_completed_successfully.
		for attempt in $(seq 1 "$CONFIGURATOR_RETRIES"); do
			echo "==> [configurator] Attempt ${attempt}/${CONFIGURATOR_RETRIES}..."
			set +e
			run_configurator
			rc=$?
			set -e
			if [ "$rc" -eq 0 ]; then
				echo "==> [configurator] Succeeded on attempt ${attempt}."
				exit 0
			fi
			if [ "$attempt" -lt "$CONFIGURATOR_RETRIES" ]; then
				echo "==> [configurator] Failed (exit code ${rc}). Retrying in ${CONFIGURATOR_RETRY_DELAY}s..."
				sleep "$CONFIGURATOR_RETRY_DELAY"
			fi
		done
		echo "==> [configurator] FAILED after ${CONFIGURATOR_RETRIES} attempts."
		exit 1
		;;

	web)
		echo "==> [web] Starting web server on 0.0.0.0:8000..."
		# Use bench serve (Frappe's production gunicorn wrapper).
		# Direct gunicorn omits Frappe's request-context initialisation
		# hooks, causing "RuntimeError: object is not bound" on every
		# request because frappe.local.request is never set up.
		# --no-reload disables the dev auto-reloader.
		# --port binds to the standard web port.
		exec bench serve \
			--port 8000 \
			--no-reload
		;;

	socketio)
		echo "==> [socketio] Starting SocketIO server on port 9000..."
		exec node /home/frappe/frappe-bench/apps/frappe/socketio.js
		;;

	worker-default)
		echo "==> [worker-default] Starting background worker (queue: default)..."
		echo $$ > /tmp/bench-worker-default.pid
		exec bench worker --queue default
		;;

	worker-short)
		echo "==> [worker-short] Starting background worker (queue: short)..."
		echo $$ > /tmp/bench-worker-short.pid
		exec bench worker --queue short
		;;

	worker-long)
		echo "==> [worker-long] Starting background worker (queue: long)..."
		echo $$ > /tmp/bench-worker-long.pid
		exec bench worker --queue long
		;;

	scheduler)
		echo "==> [scheduler] Starting scheduler..."
		echo $$ > /tmp/bench-scheduler.pid
		exec bench schedule
		;;

	*)
		echo "ERROR: Unknown PROCESS_ROLE '${PROCESS_ROLE}'"
		echo "Valid roles: configurator, web, socketio, worker-default, worker-short, worker-long, scheduler"
		exit 1
		;;
esac
