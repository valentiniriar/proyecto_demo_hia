#!/usr/bin/env bash
# =====================================================================
#  SCRUM-39.1 - Comparativa de consultas sin indice vs con indice
#
#  Requisitos:
#    - Dataset de SCRUM-35 cargado en el cluster de dev (docker compose -f docker-compose.yml --profile dev)
#    - Sin el perfil "cluster" levantado: crear indices genera ~0,6-0,9 GB de WAL
#    - SOLO en la base de desarrollo: el paso 1 BORRA los indices de SCRUM-39.1
#
#  Uso (raiz del repo, Git Bash en Windows o bash en Linux/macOS):
#     ./database/analisis/indices/comparar.sh
#
#  Variables opcionales:
#     CONTAINER     contenedor de PostgreSQL                  (default: demo_hia_pg_1, debe ser el líder)
#     USUARIO_ID    socio de la muestra para C1/C2/C3         (default: 21037, el de SCRUM-39)
#     CORRIDAS      repeticiones de cada lectura              (default: 3)
#     REINICIAR     1 = reiniciar la base antes de cada fase  (default: 1, vacia shared_buffers)
#     CONDICIONALES 1 = crear y medir tambien los condicionales (default: 1)
#     ESCRITURAS    1 = medir INSERT/UPDATE/DELETE (con ROLLBACK) (default: 1)
#
#  Pasos:
#    1. Fase SIN: eliminar_indices -> VACUUM ANALYZE -> reinicio -> lecturas x CORRIDAS -> escrituras
#    2. Fase CON: crear_indices    -> VACUUM ANALYZE -> reinicio -> lecturas x CORRIDAS -> escrituras
#    3. Tamanos, resumen de tiempos y borrado de los condicionales (quedan los de prioridad 1)
#  Salidas en docs/evidencias/SCRUM-39/indices/.
# =====================================================================
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DIR_SQL="$RAIZ/database/analisis/indices"
DIR_EV="$RAIZ/docs/evidencias/SCRUM-39/indices"
# Con Patroni tiene que ser el nodo LÍDER (ver "patronictl list"); por defecto pg-1.
CONTAINER="${CONTAINER:-demo_hia_pg_1}"
USUARIO_ID="${USUARIO_ID:-21037}"
CORRIDAS="${CORRIDAS:-3}"
REINICIAR="${REINICIAR:-1}"
CONDICIONALES="${CONDICIONALES:-1}"
ESCRITURAS="${ESCRITURAS:-1}"

if [[ ! -f "$RAIZ/.env" ]]; then
    echo "ERROR: falta $RAIZ/.env (cp .env.example .env)" >&2
    exit 1
fi
leer_env() { grep -E "^$1=" "$RAIZ/.env" | tail -n1 | cut -d= -f2- | tr -d '\r'; }
DB_USER="$(leer_env DB_USER)"
DB_NAME="$(leer_env DB_NAME)"
: "${DB_USER:?DB_USER no definida en .env}"
: "${DB_NAME:?DB_NAME no definida en .env}"

estado_db() { docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo 'no existe'; }
if [[ "$(estado_db)" != "healthy" ]]; then
    echo "ERROR: el contenedor $CONTAINER no esta healthy (estado: $(estado_db))." >&2
    exit 1
fi

# psql dentro del contenedor; el SQL entra por stdin.
psql_db() { docker exec -i -e PGAPPNAME=scrum39-indices "$CONTAINER" psql -X -q -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" "$@"; }

reiniciar_db() {
    [[ "$REINICIAR" == "1" ]] || return 0
    echo "    reiniciando $CONTAINER (shared_buffers vacio)"
    # Con Patroni, "docker restart" del líder dispararía un failover: patronictl reinicia PostgreSQL en el
    # mismo nodo sin cambiar de líder.
    docker exec "$CONTAINER" sh -c 'patronictl -c /etc/patroni/patroni.yml restart --force "$PATRONI_SCOPE" "$PATRONI_NAME"' >/dev/null
    for _ in $(seq 1 60); do
        [[ "$(estado_db)" == "healthy" ]] && return 0
        sleep 2
    done
    echo "ERROR: $CONTAINER no volvio a healthy" >&2
    exit 1
}

vacuum_analyze() {
    # Mismas estadisticas en las dos fases, y visibility map al dia para los index-only scan.
    for t in usuarios usuario_roles rutinas suscripciones tarifas pagos; do
        psql_db -c "VACUUM (ANALYZE) $t;"
    done
}

fase() {  # $1 = sin | con
    local nombre="$1" salida="$DIR_EV/explain_$1_indices.txt"
    echo "==> [fase $nombre] reinicio y lecturas x$CORRIDAS"
    reiniciar_db
    : > "$salida"
    for c in $(seq 1 "$CORRIDAS"); do
        psql_db -v uid="$USUARIO_ID" -v corrida="$c" -f - < "$DIR_SQL/explain_lecturas.sql" >> "$salida"
    done
    if [[ "$ESCRITURAS" == "1" ]]; then
        echo "==> [fase $nombre] escrituras (BEGIN ... ROLLBACK)"
        psql_db -v uid="$USUARIO_ID" -v sid="$SID" -v corrida=1 -f - < "$DIR_SQL/explain_escrituras.sql" >> "$salida"
    fi
}

mkdir -p "$DIR_EV"

# Suscripcion del socio para E5. Se calcula antes de todo para no calentar la cache dentro de una fase.
SID="$(psql_db -A -t -c "SELECT coalesce(min(id), 0) FROM suscripciones WHERE \"usuarioId\" = $USUARIO_ID" | tr -d '\r[:space:]')"
{
    echo "inicio: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "usuario_id: $USUARIO_ID  suscripcion_id: $SID  corridas: $CORRIDAS  reiniciar: $REINICIAR  condicionales: $CONDICIONALES"
    psql_db -A -t -c "SELECT version()"
    psql_db -A -t -c "SELECT name || ' = ' || setting FROM pg_settings WHERE name IN ('shared_buffers','work_mem','jit','max_parallel_workers_per_gather','random_page_cost','effective_cache_size') ORDER BY name"
} | tr -d '\r' > "$DIR_EV/entorno.txt"

# ---------- Fase SIN indices ----------
echo "==> [sin] borrando indices de SCRUM-39.1 (si existen)"
psql_db -f - < "$DIR_SQL/eliminar_indices.sql" | tee "$DIR_EV/eliminar_indices.log"
vacuum_analyze
fase sin

# ---------- Fase CON indices ----------
echo "==> [con] creando indices"
opts=()
[[ "$CONDICIONALES" == "1" ]] && opts=(-v condicionales=1)
psql_db "${opts[@]}" -f - < "$DIR_SQL/crear_indices.sql" 2>&1 | tee "$DIR_EV/crear_indices.log"
vacuum_analyze
psql_db -f - < "$DIR_SQL/tamanio_indices.sql" > "$DIR_EV/tamanio_indices.txt"
fase con

# ---------- Resumen ----------
# fase, id, consulta, corrida, ms (Execution Time de cada EXPLAIN)
echo "==> [resumen] tiempos en resumen_tiempos.tsv"
{
    printf 'fase\tid\tconsulta\tcorrida\texecution_ms\n'
    for f in sin con; do
        awk -v fase="$f" '
            /^######## / {
                n = split($0, a, " [|] ")
                id = a[1]; sub(/^######## /, "", id)
                consulta = a[2]
                corrida = a[3]; sub(/^corrida /, "", corrida)
            }
            /Execution Time:/ { printf "%s\t%s\t%s\t%s\t%s\n", fase, id, consulta, corrida, $3 }
        ' "$DIR_EV/explain_${f}_indices.txt"
    done
} | tr -d '\r' > "$DIR_EV/resumen_tiempos.tsv"
column -t -s $'\t' "$DIR_EV/resumen_tiempos.tsv" 2>/dev/null || cat "$DIR_EV/resumen_tiempos.tsv"

# ---------- Estado final: solo prioridad 1 ----------
echo "==> [final] borrando condicionales (quedan los de prioridad 1)"
psql_db -v solo_condicionales=1 -f - < "$DIR_SQL/eliminar_indices.sql"
psql_db -c "VACUUM tarifas;" -c "VACUUM pagos;" -c "VACUUM usuarios;" -c "VACUUM suscripciones;"

echo "fin: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "$DIR_EV/entorno.txt"
echo "==> Listo. Evidencias en $DIR_EV"
