#!/bin/sh
set -e

CRON_SCHEDULE="${BACKUP_CRON_SCHEDULE:-0 3 * * *}"
# Segundos que el backup inicial espera a que la base acepte consultas.
ESPERA_MAX="${BACKUP_STARTUP_WAIT:-300}"

echo "Configurando cron para backups con expresión: $CRON_SCHEDULE"
echo "$CRON_SCHEDULE /scripts/backup.sh" > /etc/crontabs/root

# Espera a que la base RESPONDA una consulta (no solo a que el puerto esté abierto).
# Al reiniciar el servidor, Docker levanta todos los contenedores a la vez sin respetar depends_on:
# el backup arrancaba en el mismo segundo que la base, antes de que Patroni eligiera líder, y fallaba
# con "Connection refused" (20/11/2026). HAProxy acepta la conexión aunque no haya líder, por eso se
# prueba con un SELECT y no con pg_isready.
esperar_base() {
    inicio=$(date +%s)
    while :; do
        if PGPASSWORD="${DB_PASS:-demo_hia_pass}" psql -h "${DB_HOST:-db}" -p "${DB_PORT:-5432}" \
            -U "${DB_USER:-demo_hia}" -d "${DB_NAME:-demo_hia}" -XAtqc 'SELECT 1' >/dev/null 2>&1; then
            echo "Base disponible tras $(( $(date +%s) - inicio )) s."
            return 0
        fi
        if [ $(( $(date +%s) - inicio )) -ge "$ESPERA_MAX" ]; then
            echo "La base no respondió en ${ESPERA_MAX} s."
            return 1
        fi
        sleep 5
    done
}

if [ "${RUN_BACKUP_ON_STARTUP:-true}" = "true" ]; then
    echo "Ejecutando backup inicial al levantar contenedor (esperando a la base, máx. ${ESPERA_MAX} s)..."
    if esperar_base; then
        /scripts/backup.sh || echo "Aviso: el backup inicial falló (ver /backups/backup.log). El próximo corre según el cron."
    else
        echo "Aviso: backup inicial omitido porque la base no estuvo disponible. El próximo corre según el cron."
    fi
fi

echo "Iniciando servicio cron en primer plano..."
exec crond -f -l 2
