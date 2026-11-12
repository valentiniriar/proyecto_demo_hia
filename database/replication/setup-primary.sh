#!/bin/sh
set -e

echo ">>> Configurando usuario y permisos de replicación en nodo primario..."

REPL_USER="${POSTGRES_REPLICA_USER:-replicator}"
REPL_PASS="${POSTGRES_REPLICA_PASSWORD:-replicator_pass}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER $REPL_USER WITH REPLICATION ENCRYPTED PASSWORD '$REPL_PASS';
    SELECT pg_create_physical_replication_slot('standby_slot_1') WHERE NOT EXISTS (
        SELECT 1 FROM pg_replication_slots WHERE slot_name = 'standby_slot_1'
    );
EOSQL

echo "host replication $REPL_USER all md5" >> "$PGDATA/pg_hba.conf"
echo "host replication $REPL_USER all scram-sha-256" >> "$PGDATA/pg_hba.conf"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -c "SELECT pg_reload_conf();"
echo ">>> Nodo primario configurado y listo para streaming replication."
