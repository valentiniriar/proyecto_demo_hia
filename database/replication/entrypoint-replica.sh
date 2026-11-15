#!/bin/sh
set -e

PRIMARY_HOST="${PRIMARY_HOST:-db-primary}"
PRIMARY_PORT="${PRIMARY_PORT:-5432}"
REPL_USER="${POSTGRES_REPLICA_USER:-replicator}"
REPL_PASS="${POSTGRES_REPLICA_PASSWORD:-replicator_pass}"
SLOT_NAME="${REPLICATION_SLOT:-standby_slot_1}"

echo ">>> Esperando a que el nodo primario ($PRIMARY_HOST:$PRIMARY_PORT) esté disponible..."
until PGPASSWORD="$REPL_PASS" pg_isready -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$REPL_USER"; do
    sleep 2
done

# Si el directorio de datos no contiene base de datos inicializada
if [ ! -s "$PGDATA/PG_VERSION" ]; then
    echo ">>> Clonando base de datos desde el nodo primario con pg_basebackup..."
    rm -rf "$PGDATA"/*
    PGPASSWORD="$REPL_PASS" pg_basebackup \
        -h "$PRIMARY_HOST" \
        -p "$PRIMARY_PORT" \
        -D "$PGDATA" \
        -U "$REPL_USER" \
        -vP \
        -R \
        --slot="$SLOT_NAME"

    # En PostgreSQL 16, el flag -R genera standby.signal y agrega primary_conninfo / primary_slot_name a postgresql.auto.conf
    echo "hot_standby = on" >> "$PGDATA/postgresql.auto.conf"
    echo "primary_slot_name = '$SLOT_NAME'" >> "$PGDATA/postgresql.auto.conf"
    chmod 700 "$PGDATA"
    echo ">>> pg_basebackup completado. Nodo réplica sincronizado e inicializado como standby."
fi

exec docker-entrypoint.sh postgres
