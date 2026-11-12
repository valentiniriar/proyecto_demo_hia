#!/bin/sh
set -e

PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-demo_hia_db}"
REPLICA_CONTAINER="${REPLICA_CONTAINER:-demo_hia_db_replica}"
DB_USER="${DB_USER:-demo_hia}"
DB_NAME="${DB_NAME:-demo_hia}"

echo "=========================================================================="
echo " SIMULACIÓN DE FAILOVER Y PROMOCIÓN DE RÉPLICA POSTGRESQL (SCRUM-48)"
echo "=========================================================================="

echo "\n[1] Simulando caída abrupta del nodo primario ($PRIMARY_CONTAINER)..."
docker stop "$PRIMARY_CONTAINER"

echo "\n[2] Estado de la aplicación mientras el primario está caído:"
echo "    - Peticiones de escritura arrojan error de conexión / timeout (SequelizeConnectionRefusedError)."
echo "    - El healthcheck (/api/health) responde con HTTP 503 ({ status: 'error', db: 'down' })."

echo "\n[3] Promoviendo nodo réplica ($REPLICA_CONTAINER) a nuevo primario..."
docker exec "$REPLICA_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c "SELECT pg_promote();"

sleep 2

echo "\n[4] Verificando que la réplica promovida acepta lecturas y escrituras:"
IS_IN_RECOVERY=$(docker exec "$REPLICA_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT pg_is_in_recovery();" | tr -d ' ')
echo "    pg_is_in_recovery: $IS_IN_RECOVERY (esperado: 'f' indicando nodo primario Read-Write)"

docker exec "$REPLICA_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c "
  INSERT INTO usuarios (nombre, apellido, dni, email, password_hash, estado, \"createdAt\", \"updatedAt\")
  VALUES ('Promoted', 'Master', '99999999', 'failover_success@gymhub.com', 'test_hash', true, NOW(), NOW());
"
echo "✓ Transacción de escritura aceptada con éxito en el nuevo nodo primario."

echo "\nProcedimiento de prueba completado exitosamente."
