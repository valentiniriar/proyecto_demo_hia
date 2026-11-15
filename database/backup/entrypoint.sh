#!/bin/sh
set -e

CRON_SCHEDULE="${BACKUP_CRON_SCHEDULE:-0 3 * * *}"

echo "Configurando cron para backups con expresión: $CRON_SCHEDULE"
echo "$CRON_SCHEDULE /scripts/backup.sh" > /etc/crontabs/root

if [ "${RUN_BACKUP_ON_STARTUP:-true}" = "true" ]; then
    echo "Ejecutando backup inicial al levantar contenedor..."
    /scripts/backup.sh || echo "Aviso: Backup inicial no completado aún (esperando disponibilidad de BD)"
fi

echo "Iniciando servicio cron en primer plano..."
exec crond -f -l 2
