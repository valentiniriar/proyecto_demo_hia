#!/usr/bin/env bash
# Registra la URL pública de GymHub y las métricas del túnel como targets de Prometheus (SCRUM-85).
#
#   bash infra/monitoring/publicar-target.sh                 # detecta la URL del túnel rápido
#   bash infra/monitoring/publicar-target.sh https://gymhub.midominio.com   # túnel con nombre
#   bash infra/monitoring/publicar-target.sh --limpiar       # deja de monitorear la URL pública
#
# Los archivos de targets/ no se versionan (.gitignore). Sin archivos, Prometheus simplemente
# no tiene targets en esos jobs.
#
# Prometheus relee estos archivos cada 30 s (file_sd): no hace falta reiniciarlo.
set -euo pipefail
export MSYS_NO_PATHCONV=1

DIR="$(cd "$(dirname "$0")" && pwd)"
T="$DIR/prometheus/targets"
mkdir -p "$T"

escribir() { # $1 archivo, $2 target (vacío = lista vacía), $3 etiqueta
  {
    echo "# Generado por infra/monitoring/publicar-target.sh el $(date '+%Y-%m-%d %H:%M') (SCRUM-85)."
    if [ -z "$2" ]; then echo "[]"; else
      echo "- targets: ['$2']"
      echo "  labels:"
      echo "    origen: '$3'"
    fi
  } > "$1"
}

if [ "${1:-}" = "--limpiar" ]; then
  escribir "$T/publico.yml" "" ""; escribir "$T/cloudflared.yml" "" ""
  echo "✔ Targets públicos vaciados."; exit 0
fi

URL="${1:-}"
ORIGEN="tunel-con-nombre"
if [ -z "$URL" ]; then
  URL=$(docker logs gymhub_cloudflared_rapido 2>&1 | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | tail -1 || true)
  ORIGEN="tunel-rapido"
  [ -n "$URL" ] || { echo "✖ No encontré la URL del túnel rápido. ¿Está levantado gymhub_cloudflared_rapido?"; exit 1; }
fi
URL="${URL%/}"

escribir "$T/publico.yml" "$URL/api/health" "$ORIGEN"
# Las métricas de cloudflared se publican en 127.0.0.1:2000 del host (compose.tunnel.yaml).
escribir "$T/cloudflared.yml" "host.docker.internal:${CLOUDFLARED_METRICS_PORT:-2000}" "$ORIGEN"

echo "✔ Monitoreando $URL/api/health (blackbox-publico) y las métricas de cloudflared."
echo "  Verificar en http://localhost:9090/targets (puede tardar hasta 30 s)."
