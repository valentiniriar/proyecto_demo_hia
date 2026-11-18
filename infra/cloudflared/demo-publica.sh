#!/usr/bin/env bash
# Publica GymHub en Internet para una demo o para la prueba de acceso externo (SCRUM-62).
#
#   bash infra/cloudflared/demo-publica.sh            # levanta app + túnel rápido y muestra la URL
#   bash infra/cloudflared/demo-publica.sh --detener  # baja el túnel (la app sigue en localhost)
#
# Si el monitoreo (infra/monitoring) está levantado, registra la URL para medir disponibilidad.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."

COMPOSE=(docker compose -f compose.yaml -f compose.dev.yaml -f compose.tunnel.yaml --profile tunel-rapido)

if [ "${1:-}" = "--detener" ]; then
  # Se elimina (no solo se detiene): un túnel rápido no se puede reanudar, Cloudflare lo borra.
  docker rm -f gymhub_cloudflared_rapido >/dev/null 2>&1 || true
  bash infra/monitoring/publicar-target.sh --limpiar >/dev/null 2>&1 || true
  echo "✔ Túnel detenido: la URL pública deja de responder (Cloudflare devuelve error)."
  exit 0
fi

echo "→ Levantando base de datos, backend, frontend y túnel rápido…"
LOG="$(mktemp)"
if ! "${COMPOSE[@]}" up -d --build db backend frontend >"$LOG" 2>&1; then
  cat "$LOG"; echo "✖ No se pudo levantar el stack."; exit 1
fi
# El túnel rápido se crea siempre de cero: un contenedor viejo reintentaría un túnel que ya no existe.
docker rm -f gymhub_cloudflared_rapido >/dev/null 2>&1 || true
if ! "${COMPOSE[@]}" up -d --force-recreate cloudflared-rapido >"$LOG" 2>&1; then
  cat "$LOG"; echo "✖ No se pudo levantar el túnel."; exit 1
fi
rm -f "$LOG"

URL=""
for _ in $(seq 1 30); do
  URL=$(docker logs gymhub_cloudflared_rapido 2>&1 | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | tail -1 || true)
  [ -n "$URL" ] && break
  sleep 2
done
[ -n "$URL" ] || { echo "✖ El túnel no informó una URL. Ver: docker logs gymhub_cloudflared_rapido"; exit 1; }

echo "→ Esperando a que la app responda por la URL pública…"
ESTADO=000
for _ in $(seq 1 30); do
  ESTADO=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL/api/health" || true)
  [ "$ESTADO" = 200 ] && break
  sleep 3
done
if [ "$ESTADO" != 200 ]; then
  echo "⚠ La URL pública responde $ESTADO en /api/health."
  echo "  Revisar: curl localhost:8080/api/health · docker logs gymhub_backend_dev · docker logs gymhub_cloudflared_rapido"
fi

if docker ps --format '{{.Names}}' | grep -q '^gymhub-prometheus'; then
  bash infra/monitoring/publicar-target.sh "$URL" >/dev/null && echo "→ URL registrada en Prometheus (blackbox-publico)."
fi

cat <<EOF

✔ GymHub publicado en:  $URL
  Salud de la API:       $URL/api/health
  Hora de publicación:   $(date '+%d/%m/%Y %H:%M:%S %Z')

Prueba desde fuera de la LAN (SCRUM-62): abrir la URL en un celular con DATOS MÓVILES
(Wi-Fi apagado), iniciar sesión como socio y recorrer Mis Rutinas / Mis Pagos.
Usuarios demo: ver README (sección "Usuarios Demo"). Al terminar:
  bash infra/cloudflared/demo-publica.sh --detener
EOF
