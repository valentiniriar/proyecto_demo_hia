#!/usr/bin/env bash
# =====================================================================
#  SCRUM-35 - Carga del dataset de prueba (6.000.000 filas por tabla)
#
#  Uso (desde la raiz del repo, con Git Bash en Windows o bash en Linux/macOS):
#     docker compose --profile dev down -v && docker compose --profile dev up -d
#     ./database/dataset/cargar.sh            # pasos 1 a 4
#     ./database/dataset/cargar.sh 04_verificar   # solo un paso
#
#  Variables opcionales:
#     CONTAINER   contenedor de PostgreSQL (default: demo_hia_pg_1, debe ser el líder)
#
#  Requiere el .env de la raiz (DB_USER, DB_NAME). La salida de cada paso
#  queda en docs/evidencias/SCRUM-35/<paso>.log
#  Ver docs/SCRUM-35-dataset-6m.md (disco, tiempos y advertencias).
# =====================================================================
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR_SQL="$RAIZ/database/dataset"
DIR_LOG="$RAIZ/docs/evidencias/SCRUM-35"
# Con Patroni tiene que ser el nodo LÍDER (ver "patronictl list"); por defecto pg-1.
CONTAINER="${CONTAINER:-demo_hia_pg_1}"

if [[ ! -f "$RAIZ/.env" ]]; then
    echo "ERROR: falta $RAIZ/.env (cp .env.example .env)" >&2
    exit 1
fi
# Solo se leen las variables necesarias (no se ejecuta el .env).
DB_USER="$(grep -E '^DB_USER=' "$RAIZ/.env" | tail -n1 | cut -d= -f2- | tr -d '\r')"
DB_NAME="$(grep -E '^DB_NAME=' "$RAIZ/.env" | tail -n1 | cut -d= -f2- | tr -d '\r')"
: "${DB_USER:?DB_USER no definida en .env}"
: "${DB_NAME:?DB_NAME no definida en .env}"

estado="$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo 'no existe')"
if [[ "$estado" != "healthy" ]]; then
    echo "ERROR: el contenedor $CONTAINER no esta healthy (estado: $estado)." >&2
    echo "       docker compose --profile dev up -d  y esperar a 'healthy'." >&2
    exit 1
fi

if [[ $# -gt 0 ]]; then
    PASOS=("$@")
else
    PASOS=(01_preparar 02_generar 03_restaurar_indices 04_verificar)
fi

mkdir -p "$DIR_LOG"
inicio_total=$SECONDS

for paso in "${PASOS[@]}"; do
    archivo="$DIR_SQL/$paso.sql"
    if [[ ! -f "$archivo" ]]; then
        echo "ERROR: no existe $archivo" >&2
        exit 1
    fi

    echo "==> [$paso] $(date '+%Y-%m-%d %H:%M:%S')"
    inicio=$SECONDS
    # -X: ignora ~/.psqlrc   -q: sin ruido   el SQL entra por stdin (sin rutas dentro del contenedor)
    set +e
    docker exec -i "$CONTAINER" \
        psql -X -q -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" -f - \
        < "$archivo" 2>&1 | tee "$DIR_LOG/$paso.log"
    rc=${PIPESTATUS[0]}
    set -e

    if [[ $rc -ne 0 ]]; then
        echo "ERROR: el paso $paso fallo (codigo $rc). Log: $DIR_LOG/$paso.log" >&2
        if [[ "$paso" != "01_preparar" && "$paso" != "04_verificar" ]]; then
            echo "       Las restricciones pueden haber quedado eliminadas: recrear la base con" >&2
            echo "       docker compose --profile dev down -v && docker compose --profile dev up -d" >&2
        fi
        exit "$rc"
    fi
    echo "<== [$paso] OK en $((SECONDS - inicio)) s"
done

echo "Carga terminada en $(( (SECONDS - inicio_total) / 60 )) min $(( (SECONDS - inicio_total) % 60 )) s."
