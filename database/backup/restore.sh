#!/bin/sh
set -e

BACKUP_FILE="$1"

if [ -z "$BACKUP_FILE" ]; then
    BACKUP_FILE="/backups/latest.dump"
fi

if [ ! -f "$BACKUP_FILE" ]; then
    echo "Error: El archivo de backup '$BACKUP_FILE' no existe."
    exit 1
fi

echo "[$(date -Iseconds)] Iniciando restauración desde '$BACKUP_FILE' hacia '${DB_HOST:-db}:${DB_PORT:-5432}/${DB_NAME:-demo_hia}'..."
START_TIME=$(date +%s)

export PGPASSWORD="${DB_PASS:-demo_hia_pass}"

# Restauración con pg_restore (limpia objetos existentes antes de recrear: -c --if-exists)
pg_restore -h "${DB_HOST:-db}" -p "${DB_PORT:-5432}" -U "${DB_USER:-demo_hia}" -d "${DB_NAME:-demo_hia}" --clean --if-exists -v "$BACKUP_FILE" || true

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "[$(date -Iseconds)] Restauración finalizada en ${DURATION}s."
