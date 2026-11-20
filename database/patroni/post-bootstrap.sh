#!/bin/sh
# Lo ejecuta Patroni UNA sola vez, en el primer líder de un cluster NUEVO (volumen vacío), después del initdb.
# Reemplaza a /docker-entrypoint-initdb.d de la imagen oficial: crea la base de la app y carga esquema y seed.
# Si Patroni adopta un volumen con datos, este script no corre.
# $1 = cadena de conexión del superusuario que arma Patroni.
set -eu

CONN="$1"
DB="${DB_NAME:?Falta DB_NAME}"

echo ">>> post-bootstrap: creando la base $DB"
psql "$CONN" -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$DB\""

# Misma conexión, pero a la base nueva. Patroni la pasa como "clave=valor" (dbname=postgres user=… host=…):
# en libpq, si una clave se repite gana la última. Si llegara como URL (postgres://…/postgres), se reemplaza.
case "$CONN" in
  postgres://*|postgresql://*) CONN_DB=$(echo "$CONN" | sed "s#/postgres\([?]\|\$\)#/$DB\1#") ;;
  *) CONN_DB="$CONN dbname=$DB" ;;
esac
for sql in /scripts/sql/01_schema.sql /scripts/sql/02_seed.sql; do
  echo ">>> post-bootstrap: ejecutando $sql"
  psql "$CONN_DB" -v ON_ERROR_STOP=1 -f "$sql"
done
echo ">>> post-bootstrap: listo"
