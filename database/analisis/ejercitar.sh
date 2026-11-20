#!/usr/bin/env bash
# =====================================================================
#  SCRUM-39 - Ejercitar la app con el dataset de 6M y analizar las consultas
#
#  Requisitos:
#    - Dataset de SCRUM-35 cargado en el cluster de dev (docker compose -f docker-compose.yml --profile dev)
#    - El contenedor reiniciado DESPUES de agregar pg_stat_statements a
#      shared_preload_libraries:  docker restart demo_hia_pg_1 (si es el único nodo; con réplicas usar patronictl restart)
#    - Node >= 18 y backend/node_modules instalado (npm ci en backend/)
#    - Sin el perfil "cluster" levantado (ver docs/SCRUM-35-dataset-6m.md)
#
#  Uso (raiz del repo, Git Bash en Windows o bash en Linux/macOS):
#     ./database/analisis/ejercitar.sh
#
#  Variables opcionales:
#     CONTAINER     contenedor de PostgreSQL       (default: demo_hia_pg_1, debe ser el líder)
#     PASO_MUESTRA  1 socio cada N ids             (default: 20000 -> ~270 socios; se arranca en 1037
#                   porque ds_rol hace admin a los ids multiplos de 1000)
#     CONCURRENCIA  requests HTTP en paralelo      (default: 4)
#     PUERTO        puerto del backend de prueba   (default: 3039)
#
#  Pasos: muestra de socios -> 00_habilitar -> backend propio (PGAPPNAME=gymhub-backend,
#  rate limit alto) -> workload.js -> consultas_psql.sql (PGAPPNAME=scrum39-psql) ->
#  top_consultas.sql -> docker logs -> pgBadger -> 99_restaurar.
#  Salidas en docs/evidencias/SCRUM-39/.
# =====================================================================
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR_SQL="$RAIZ/database/analisis"
DIR_EV="$RAIZ/docs/evidencias/SCRUM-39"
# Con Patroni tiene que ser el nodo LÍDER (ver "patronictl list"); por defecto pg-1.
CONTAINER="${CONTAINER:-demo_hia_pg_1}"
PASO_MUESTRA="${PASO_MUESTRA:-20000}"
CONCURRENCIA="${CONCURRENCIA:-4}"
PUERTO="${PUERTO:-3039}"
PREFIJO_LOG='%m [%p] %q%u@%d app=%a '
IMAGEN_PGBADGER="gymhub-pgbadger:13.1"

if [[ ! -f "$RAIZ/.env" ]]; then
    echo "ERROR: falta $RAIZ/.env (cp .env.example .env)" >&2
    exit 1
fi
leer_env() { grep -E "^$1=" "$RAIZ/.env" | tail -n1 | cut -d= -f2- | tr -d '\r'; }
DB_USER="$(leer_env DB_USER)"
DB_NAME="$(leer_env DB_NAME)"
DB_PORT_HOST="$(leer_env DB_PORT)"; DB_PORT_HOST="${DB_PORT_HOST:-5433}"
: "${DB_USER:?DB_USER no definida en .env}"
: "${DB_NAME:?DB_NAME no definida en .env}"

estado="$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo 'no existe')"
if [[ "$estado" != "healthy" ]]; then
    echo "ERROR: el contenedor $CONTAINER no esta healthy (estado: $estado)." >&2
    exit 1
fi

# psql dentro del contenedor; el SQL entra por stdin (sin rutas del host dentro del contenedor).
psql_app() {  # $1 = application_name, resto = opciones de psql
    local app="$1"; shift
    docker exec -i -e PGAPPNAME="$app" "$CONTAINER" psql -X -q -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" "$@"
}

# Ruta del host para "docker run -v" (Git Bash convierte rutas POSIX si no se lo impide).
ruta_docker() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else echo "$1"; fi; }

mkdir -p "$DIR_EV"
PID_BACKEND=""
restaurar() {
    if [[ -n "$PID_BACKEND" ]]; then kill "$PID_BACKEND" 2>/dev/null || true; fi
    echo "==> [99_restaurar]"
    psql_app scrum39-admin -f - < "$DIR_SQL/99_restaurar.sql" | tee "$DIR_EV/99_restaurar.log" || true
}

echo "==> [muestra] 1 socio activo cada $PASO_MUESTRA ids"
psql_app scrum39-admin -A -t -F $'\t' -c "
    SELECT u.id, u.email, u.dni
    FROM usuarios u
    JOIN usuario_roles ur ON ur.id_usuario = u.id
    JOIN roles r ON r.id = ur.id_rol AND r.nombre = 'socio'
    WHERE u.id IN (SELECT generate_series(1037, 6000000, $PASO_MUESTRA)) AND u.estado
    ORDER BY u.id" | tr -d '\r' > "$DIR_EV/muestra_socios.tsv"
echo "    $(wc -l < "$DIR_EV/muestra_socios.tsv") socios"

INICIO="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "$INICIO" > "$DIR_EV/ventana.txt"
trap restaurar EXIT

echo "==> [00_habilitar] $INICIO"
psql_app scrum39-admin -f - < "$DIR_SQL/00_habilitar.sql" | tee "$DIR_EV/00_habilitar.log"

echo "==> [backend] puerto $PUERTO (PGAPPNAME=gymhub-backend)"
(
    cd "$RAIZ/backend"
    PORT="$PUERTO" DB_HOST=localhost DB_PORT="$DB_PORT_HOST" PGAPPNAME=gymhub-backend \
    AUTH_RATE_LIMIT_MAX=1000000 RATE_LIMIT_MAX=1000000 SECURITY_EVENTS_WEBHOOK_URL= \
    exec node index.js
) > "$DIR_EV/backend.log" 2>&1 &
PID_BACKEND=$!
for _ in $(seq 1 60); do
    if curl -fs "http://localhost:$PUERTO/api/health" >/dev/null 2>&1; then break; fi
    sleep 1
done
curl -fs "http://localhost:$PUERTO/api/health" >/dev/null || { echo "ERROR: el backend no levanto (ver $DIR_EV/backend.log)" >&2; exit 1; }

echo "==> [workload] HTTP"
inicio=$SECONDS
BASE_URL="http://localhost:$PUERTO" USUARIOS="$DIR_EV/muestra_socios.tsv" CONCURRENCIA="$CONCURRENCIA" \
    node "$DIR_SQL/workload.js" 2>&1 | tee "$DIR_EV/workload.log"
echo "    $((SECONDS - inicio)) s"
kill "$PID_BACKEND" 2>/dev/null || true; PID_BACKEND=""

echo "==> [consultas_psql] socios activos, dashboard, ILIKE, pagos por rango"
inicio=$SECONDS
psql_app scrum39-psql -f - < "$DIR_SQL/consultas_psql.sql" 2>&1 | tee "$DIR_EV/consultas_psql.log"
echo "    $((SECONDS - inicio)) s"

echo "==> [top_consultas]"
psql_app scrum39-admin -f - < "$DIR_SQL/top_consultas.sql" > "$DIR_EV/top_consultas.txt"
sed -n '1,40p' "$DIR_EV/top_consultas.txt"

echo "==> [log] docker logs --since $INICIO"
docker logs --since "$INICIO" "$CONTAINER" > "$DIR_EV/postgresql.log" 2>&1
echo "    $(wc -l < "$DIR_EV/postgresql.log") lineas"

echo "==> [pgbadger]"
if ! docker image inspect "$IMAGEN_PGBADGER" >/dev/null 2>&1; then
    docker build -t "$IMAGEN_PGBADGER" "$(ruta_docker "$DIR_SQL/pgbadger")"
fi
MSYS_NO_PATHCONV=1 docker run --rm -v "$(ruta_docker "$DIR_EV"):/data" "$IMAGEN_PGBADGER" \
    -f stderr --prefix "$PREFIJO_LOG" -T "GymHub SCRUM-39 - dataset 6M" \
    -o /data/pgbadger.html /data/postgresql.log 2>&1 | tee "$DIR_EV/pgbadger.log"

echo "==> Listo. Evidencias en docs/evidencias/SCRUM-39/ (pgbadger.html, top_consultas.txt)"
