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

if [ ! -d "sites/$SITE_NAME" ]; then
    echo "==> Sitio '$SITE_NAME' no existe. Creando..."
    bench new-site "$SITE_NAME" \
        --db-root-username "$DB_ROOT_USER" \
        --db-root-password "$DB_ROOT_PASSWORD" \
        --db-name "$DB_NAME" \
        --db-user "$DB_USER" \
        --db-password "$DB_PASSWORD" \
        --admin-password "$ADMIN_PASSWORD" \
        --db-host "$DB_HOST" \
        --no-mariadb-socket

    echo "==> Instalando app ERPNext en el sitio..."
    bench --site "$SITE_NAME" install-app erpnext

    echo "==> Configurando scheduler..."
    bench --site "$SITE_NAME" enable-scheduler

    echo "==> Sitio '$SITE_NAME' creado e instalado correctamente."
else
    echo "==> Sitio '$SITE_NAME' ya existe. Ejecutando migrate..."
    bench --site "$SITE_NAME" migrate
    bench setup requirements
fi

echo "==> Iniciando ERPNext en puerto 8000..."
exec bench serve --host 0.0.0.0 --port 8000
