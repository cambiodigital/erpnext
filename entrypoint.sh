#!/bin/bash
set -e

SITE_NAME=${SITE_NAME:-"erp.saharapro.team"}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-"admin"}
DB_HOST=${DB_HOST:-"db"}
DB_PORT=${DB_PORT:-"3306"}
DB_ROOT_USER=${DB_ROOT_USER:-"root"}
DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD:-""}
DB_NAME=${DB_NAME:-"erpnext"}
DB_USER=${DB_USER:-"erpnext"}
DB_PASSWORD=${DB_PASSWORD:-"erpnext"}

# Sentinel file that marks a COMPLETED bootstrap (all steps succeeded).
# Using a marker file instead of checking the site directory prevents
# the bootstrap loop: bench new-site creates sites/$SITE_NAME/ on the
# filesystem BEFORE finishing the database setup.  If the DB setup fails,
# the directory persists on the Docker volume and the old directory-only
# check would incorrectly enter the migrate branch on restart.
BOOTSTRAP_SENTINEL="sites/$SITE_NAME/.bootstrapped"

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

cd /home/frappe/frappe-bench

echo "==> Configurando common_site_config.json..."
bench set-config -g db_host "$DB_HOST"
bench set-config -g db_port "$DB_PORT"
bench set-config -g redis_cache "redis://${REDIS_CACHE_HOST:-redis-cache}:6379"
bench set-config -g redis_queue "redis://${REDIS_QUEUE_HOST:-redis-queue}:6379"
bench set-config -g redis_socketio "redis://${REDIS_QUEUE_HOST:-redis-queue}:6379"
bench set-config -g socketio_port "9000"
bench set-config -g developer_mode 0
bench set-config -g server_script_enabled 1

# ------------------------------------------------------------------
# Bootstrap decision: use the sentinel file, NOT the directory.
# ------------------------------------------------------------------
if [ ! -f "$BOOTSTRAP_SENTINEL" ]; then
	if [ -d "sites/$SITE_NAME" ] && bench --site "$SITE_NAME" list-apps >/dev/null 2>&1; then
		echo "==> Sitio '$SITE_NAME' existe y está sano, pero no tenía sentinel. Marcándolo como instalado."
		touch "$BOOTSTRAP_SENTINEL"
	fi
fi

if [ ! -f "$BOOTSTRAP_SENTINEL" ]; then
    # Clean up any partial site left by a previously failed bootstrap.
    # bench new-site creates the directory before completing DB setup;
    # if it crashed after creating the directory but before creating tables,
    # we must start fresh.
    if [ -d "sites/$SITE_NAME" ]; then
        echo "==> Found partial site '$SITE_NAME' from an incomplete bootstrap. Removing..."
        rm -rf "sites/$SITE_NAME"
    fi

	echo "==> Eliminando base de datos parcial '$DB_NAME' si existe..."
	drop_site_database

    echo "==> Sitio '$SITE_NAME' no existe o no está completamente instalado. Creando..."
    bench new-site "$SITE_NAME" \
        --db-root-username "$DB_ROOT_USER" \
        --db-root-password "$DB_ROOT_PASSWORD" \
        --db-name "$DB_NAME" \
        --db-user "$DB_USER" \
        --db-password "$DB_PASSWORD" \
        --admin-password "$ADMIN_PASSWORD" \
        --db-host "$DB_HOST"

    echo "==> Instalando app ERPNext en el sitio..."
    bench --site "$SITE_NAME" install-app erpnext

    echo "==> Configurando scheduler..."
    bench --site "$SITE_NAME" enable-scheduler
	bench use "$SITE_NAME"

    # Only now mark bootstrap as complete.  The sentinel lives on the
    # sites_data Docker volume and survives container restarts.
    touch "$BOOTSTRAP_SENTINEL"

    echo "==> Sitio '$SITE_NAME' creado e instalado correctamente."
else
    echo "==> Sitio '$SITE_NAME' completamente instalado. Ejecutando migrate..."
    bench --site "$SITE_NAME" migrate
    bench use "$SITE_NAME"

    # Idempotent safety nets — if a previous bootstrap completed bench
    # new-site but missed install-app or enable-scheduler, these
    # no-op on an already-installed site.
    bench --site "$SITE_NAME" install-app erpnext 2>/dev/null || true
    bench --site "$SITE_NAME" enable-scheduler 2>/dev/null || true
fi

echo "==> Iniciando ERPNext en puerto 8000..."
exec bench serve --port 8000
