#!/usr/bin/env bash
# Vigilante del túnel rápido de Cloudflare (SCRUM-57 / SCRUM-85).
#
#   bash scripts/vigilar-tunel.sh            # una revisión (la corre una tarea programada cada 5 min)
#   bash scripts/vigilar-tunel.sh --forzar   # reinicia el túnel aunque parezca sano
#
# Problema que resuelve: si la conexión del túnel rápido se corta un rato, Cloudflare borra el túnel
# y cloudflared queda reintentando para siempre con "Unauthorized: Tunnel not found": la web pública
# se cae y no vuelve sola. Este script lo detecta, reinicia el contenedor (que pide una URL NUEVA),
# avisa a Prometheus (publicar-target.sh) y lo anota en produccion/historial-tunel.log.
#
# La URL vigente se consulta desde la tailnet en http://gymhub-servidor.tailec3350.ts.net:2000/quicktunnel
set -uo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
REPO_DIR="$(pwd -W 2>/dev/null || pwd)"
ESTADO_DIR="$(dirname "${GYMHUB_ENV_FILE:-$REPO_DIR/produccion/.env.prod}")"
LOG="$ESTADO_DIR/historial-tunel.log"
C=gymhub_cloudflared_rapido
GRACIA="${GRACIA:-300}"   # segundos tras arrancar el túnel en los que no se lo juzga (la URL nueva tarda en propagarse)

log() { printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
url() { curl -s --max-time 5 http://127.0.0.1:2000/quicktunnel | grep -o '[a-z0-9-]*\.trycloudflare\.com' || true; }

docker info >/dev/null 2>&1 || exit 0   # Docker todavía no arrancó (por ejemplo, tras reiniciar la PC)

reiniciar() {
  log "↻ Reiniciando el túnel: $1"
  if docker inspect "$C" >/dev/null 2>&1; then docker restart "$C" >/dev/null
  else bash scripts/deploy.sh --tunel >/dev/null; fi
  local h=""
  for _ in $(seq 1 30); do h=$(url); [ -n "$h" ] && break; sleep 2; done
  if [ -z "$h" ]; then log "✖ El túnel no informó una URL nueva (docker logs $C)"; exit 1; fi
  bash infra/monitoring/publicar-target.sh >/dev/null 2>&1 || log "⚠ No se pudo avisar a Prometheus"
  log "✔ Nueva URL pública: https://$h"
  exit 0
}

[ "${1:-}" = "--forzar" ] && reiniciar "pedido manual"

if [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" != true ]; then
  reiniciar "el contenedor no está corriendo"
fi

inicio=$(docker inspect -f '{{.State.StartedAt}}' "$C")
edad=$(( $(date +%s) - $(date -d "$inicio" +%s 2>/dev/null || date +%s) ))
[ "$edad" -lt "$GRACIA" ] && exit 0

if docker logs --since 3m "$C" 2>&1 | grep -q 'Tunnel not found'; then
  reiniciar "Cloudflare dio de baja el túnel (Tunnel not found)"
fi

# Prueba desde Internet. Solo cuenta como caída del TÚNEL: sin DNS/conexión (000) o 530 (error de
# túnel de Cloudflare). Otros códigos (p. ej. 502 si el backend está caído) no se arreglan reiniciando
# el túnel y cambiarían la URL sin motivo. DNS por 1.1.1.1 para no depender de la caché local.
h=$(url)
for _ in 1 2 3; do
  codigo=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 --doh-url https://1.1.1.1/dns-query "https://$h/api/health" || true)
  case "$codigo" in 000|530) sleep 20 ;; *) exit 0 ;; esac
done
reiniciar "la URL pública https://$h no responde (código $codigo)"
