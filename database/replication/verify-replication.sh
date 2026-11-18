#!/bin/sh
set -e

PRIMARY_HOST="${PRIMARY_HOST:-db}"
REPLICA_HOST="${REPLICA_HOST:-db-replica}"
PRIMARY_PORT="${PRIMARY_PORT:-5432}"
REPLICA_PORT="${REPLICA_PORT:-5432}"
DB_USER="${DB_USER:-demo_hia}"
DB_NAME="${DB_NAME:-demo_hia}"
export PGPASSWORD="${DB_PASS:-demo_hia_pass}"

echo "================================================================="
echo " PRUEBA DE REPLICACIÓN, CONSISTENCIA Y MEDICIÓN DE LAG (SCRUM-46)"
echo "================================================================="

echo "\n[1] Verificando rechazo de escrituras en la réplica (Hot Standby)..."
if psql -h "$REPLICA_HOST" -p "$REPLICA_PORT" -U "$DB_USER" -d "$DB_NAME" -c "CREATE TABLE test_fail (id int);" 2>&1 | grep -q "read-only transaction"; then
    echo "✓ ÉXITO: La réplica rechazó la escritura correctamente (cannot execute CREATE TABLE in a read-only transaction)."
else
    echo "✗ ERROR: La réplica permitió escritura o no arrojó el error esperado."
fi

echo "\n[2] Insertando registro de prueba con timestamp en el primario..."
TEST_EMAIL="replication_test_$(date +%s)@gymhub.com"
psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$DB_USER" -d "$DB_NAME" -c "
  INSERT INTO usuarios (nombre, apellido, dni, email, password_hash, estado, \"createdAt\", \"updatedAt\")
  VALUES ('Test', 'Replicacion', '$(date +%s | cut -c3-10)', '$TEST_EMAIL', 'hash_test', true, NOW(), NOW());
"

echo "\n[3] Verificando propagación inmediata del registro en la réplica..."
sleep 1
RECORD_FOUND=$(psql -h "$REPLICA_HOST" -p "$REPLICA_PORT" -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT count(*) FROM usuarios WHERE email = '$TEST_EMAIL';")
if [ "$(echo $RECORD_FOUND | tr -d ' ')" = "1" ]; then
    echo "✓ ÉXITO: El registro insertado en el primario se sincronizó en la réplica."
else
    echo "✗ ERROR: El registro no se encontró en la réplica."
fi

echo "\n[4] Midiendo lag de replicación en bytes y tiempo en el primario..."
psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$DB_USER" -d "$DB_NAME" -x -c "
  SELECT 
    application_name,
    client_addr,
    state,
    sync_state,
    pg_wal_lsn_diff(pg_current_wal_lsn(), write_lsn) AS write_lag_bytes,
    pg_wal_lsn_diff(pg_current_wal_lsn(), flush_lsn) AS flush_lag_bytes,
    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_lag_bytes,
    write_lag,
    flush_lag,
    replay_lag
  FROM pg_stat_replication;
"

echo "\n[5] Comparación de conteos de tablas entre primario y réplica..."
PRIMARY_COUNTS=$(psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT count(*) FROM usuarios;")
REPLICA_COUNTS=$(psql -h "$REPLICA_HOST" -p "$REPLICA_PORT" -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT count(*) FROM usuarios;")
echo "Usuarios Primario: $(echo $PRIMARY_COUNTS | tr -d ' ') | Usuarios Réplica: $(echo $REPLICA_COUNTS | tr -d ' ')"

echo "\nPruebas finalizadas con éxito."
