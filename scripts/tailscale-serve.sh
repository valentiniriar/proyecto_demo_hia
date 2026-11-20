#!/usr/bin/env bash
# Acceso administrativo remoto por Tailscale (SCRUM-61).
#
#   bash scripts/tailscale-serve.sh            # publica los servicios en la tailnet + la app por Funnel
#   bash scripts/tailscale-serve.sh --estado   # muestra qué se publica
#   bash scripts/tailscale-serve.sh --quitar   # deja de publicarlos
#
# Tailscale Serve reenvía puertos de la tailnet a servicios de 127.0.0.1 de esta PC. Solo los
# dispositivos autenticados en la tailnet del equipo llegan; desde Internet o la LAN no se ve nada.
# La app pública sigue saliendo por Cloudflare Tunnel; esto es SOLO para administración.
#
# Requisitos: Tailscale instalado y logueado en el servidor (tailscale up) y en el dispositivo remoto.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

TS="$(command -v tailscale || echo '/c/Program Files/Tailscale/tailscale.exe')"
[ -x "$TS" ] || { echo "✖ Tailscale no está instalado"; exit 1; }
"$TS" status >/dev/null 2>&1 || { echo "✖ Tailscale no está conectado: ejecutar 'tailscale up'"; exit 1; }

valor() { grep -E "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true; }
PROM=$(valor infra/monitoring/.env PROM_HOST_PORT); GRAF=$(valor infra/monitoring/.env GRAFANA_HOST_PORT)
ALERT=$(valor infra/monitoring/.env ALERTMANAGER_HOST_PORT); MAN=$(valor infra/mantis/.env MANTIS_HOST_PORT)
N8NP=$(valor infra/n8n/.env N8N_HOST_PORT); NCP=$(valor infra/nextcloud/.env NEXTCLOUD_HOST_PORT)

# nombre  tipo  puerto-tailnet  destino-local
SERVICIOS=(
  "App-produccion  http 80                 http://127.0.0.1:80"
  "Grafana         http ${GRAF:-3001}      http://127.0.0.1:${GRAF:-3001}"
  "Prometheus      http ${PROM:-9091}      http://127.0.0.1:${PROM:-9091}"
  "Alertmanager    http ${ALERT:-9093}     http://127.0.0.1:${ALERT:-9093}"
  "Mantis          http ${MAN:-8990}       http://127.0.0.1:${MAN:-8990}"
  "n8n             http ${N8NP:-5679}      http://127.0.0.1:${N8NP:-5679}"
  "Nextcloud       http ${NCP:-8082}       http://127.0.0.1:${NCP:-8082}"
  # Métricas de cloudflared: /quicktunnel devuelve la URL pública vigente del túnel rápido.
  "Tunel-URL       http 2000               http://127.0.0.1:2000"
  # Página de estado de HAProxy: qué nodo de Patroni es el líder (en verde). Se actualiza cada 2 s.
  "HAProxy-Patroni http 7000               http://127.0.0.1:7000"
  "Base-produccion tcp  5436               tcp://127.0.0.1:5436"
)

NOMBRE=$("$TS" status --json | node -e 'const s=JSON.parse(require("fs").readFileSync(0));process.stdout.write((s.Self.DNSName||"").replace(/\.$/,""))')

case "${1:-}" in
  --quitar)
    "$TS" serve reset
    echo "✔ Servicios retirados de la tailnet."; exit 0 ;;
  --estado)
    "$TS" serve status; exit 0 ;;
esac

for s in "${SERVICIOS[@]}"; do
  read -r nombre tipo puerto destino <<<"$s"
  "$TS" serve --bg --"$tipo"="$puerto" "$destino" >/dev/null
done

# Tailscale Funnel: la APP (y solo la app) queda pública en Internet con URL FIJA y HTTPS:
# https://<nombre>.ts.net. A diferencia del túnel rápido de Cloudflare, no cambia al reiniciar.
# Requiere habilitar Funnel una vez en la tailnet (el comando muestra el link si falta).
# GYMHUB_FUNNEL=0 para no publicarla.
if [ "${GYMHUB_FUNNEL:-1}" = 1 ]; then
  "$TS" funnel --bg --https=443 http://127.0.0.1:80 >/dev/null
  echo "✔ App PÚBLICA en Internet (Funnel, URL fija): https://$NOMBRE/"
fi

echo "✔ Publicado SOLO en la tailnet (dispositivos logueados con la cuenta del equipo):"
for s in "${SERVICIOS[@]}"; do
  read -r nombre tipo puerto destino <<<"$s"
  if [ "$tipo" = tcp ]; then url="$NOMBRE:$puerto (PostgreSQL)"
  elif [ "$nombre" = Tunel-URL ]; then url="http://$NOMBRE:$puerto/quicktunnel"
  else url="http://$NOMBRE:$puerto/"; fi
  printf '  %-16s %s\n' "$nombre" "$url"
done
