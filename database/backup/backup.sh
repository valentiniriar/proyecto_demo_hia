#!/bin/sh
set -e

BACKUP_DIR="${BACKUP_DIR:-/backups}"
LOG_FILE="${BACKUP_DIR}/backup.log"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
FILENAME="gymhub_${DB_NAME:-demo_hia}_${TIMESTAMP}.dump"
FILEPATH="${BACKUP_DIR}/${FILENAME}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"

mkdir -p "$BACKUP_DIR"

echo "[$(date -Iseconds)] Iniciando backup de la base de datos '${DB_NAME:-demo_hia}' en '${DB_HOST:-db}:${DB_PORT:-5432}'..." | tee -a "$LOG_FILE"
START_TIME=$(date +%s)

export PGPASSWORD="${DB_PASS:-demo_hia_pass}"

if pg_dump -h "${DB_HOST:-db}" -p "${DB_PORT:-5432}" -U "${DB_USER:-demo_hia}" -d "${DB_NAME:-demo_hia}" -F c -b -v -f "$FILEPATH" 2>> "$LOG_FILE"; then
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    FILESIZE=$(ls -lh "$FILEPATH" | awk '{print $5}')
    
    # Crear un symlink al backup más reciente para verificación rápida de scripts/n8n
    ln -sf "$FILEPATH" "${BACKUP_DIR}/latest.dump"

    # Metadata en formato JSON estructurado para el flujo de n8n
    cat << JSONEOF > "${BACKUP_DIR}/latest_status.json"
{
  "status": "success",
  "filename": "${FILENAME}",
  "timestamp": "$(date -Iseconds)",
  "duration_seconds": ${DURATION},
  "size": "${FILESIZE}",
  "database": "${DB_NAME:-demo_hia}"
}
JSONEOF

    echo "[$(date -Iseconds)] Backup completado con éxito: ${FILENAME} | Tamaño: ${FILESIZE} | Duración: ${DURATION}s" | tee -a "$LOG_FILE"
else
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    cat << JSONEOF > "${BACKUP_DIR}/latest_status.json"
{
  "status": "error",
  "filename": "${FILENAME}",
  "timestamp": "$(date -Iseconds)",
  "duration_seconds": ${DURATION},
  "database": "${DB_NAME:-demo_hia}"
}
JSONEOF
    echo "[$(date -Iseconds)] ERROR al realizar el backup de la base de datos." | tee -a "$LOG_FILE"
    exit 1
fi

# Limpieza por política de retención
echo "[$(date -Iseconds)] Aplicando política de retención (${RETENTION_DAYS} días)..." | tee -a "$LOG_FILE"
find "$BACKUP_DIR" -name "gymhub_*.dump" -type f -mtime +"$RETENTION_DAYS" -exec rm -f {} \;
echo "[$(date -Iseconds)] Proceso finalizado." | tee -a "$LOG_FILE"
