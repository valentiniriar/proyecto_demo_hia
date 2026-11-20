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
MPP=$(valor infra/n8n/.env MAILPIT_HOST_PORT)

# nombre  puerto  qué-es
# Todo se publica en modo TCP (no HTTP): Tailscale reenvía la conexión tal cual. En modo HTTP, Serve
# solo responde si se usa el NOMBRE (con la IP devuelve 404 vacío), y los navegadores fuerzan HTTPS en
# *.ts.net, así que http://<nombre>.ts.net:puerto tampoco carga: nadie podía abrir los paneles desde el
# navegador (20/11/2026). En TCP funciona con la IP: http://100.x.y.z:puerto.
SERVICIOS=(
  "App-produccion  80                 web"
  "Grafana         ${GRAF:-3001}      web"
  "Prometheus      ${PROM:-9091}      web"
  "Alertmanager    ${ALERT:-9093}     web"
  "Mantis          ${MAN:-8990}       web"
  "n8n             ${N8NP:-5679}      web"
  "Nextcloud       ${NCP:-8082}       web"
  # Mailpit: correos que mandan los flujos de n8n (no salen a Internet).
  "Mailpit         ${MPP:-8026}       web"
  # Métricas de cloudflared: /quicktunnel devuelve la URL pública vigente del túnel rápido.
  "Tunel-URL       2000               web"
  # Página de estado de HAProxy: qué nodo de Patroni es el líder (en verde). Se actualiza cada 2 s.
  "HAProxy-Patroni 7000               web"
  "Base-produccion 5436               postgres"
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
  read -r nombre puerto tipo <<<"$s"
  # Si el puerto estaba publicado en modo HTTP (versión anterior), se quita antes de pasarlo a TCP.
  "$TS" serve --http="$puerto" off >/dev/null 2>&1 || true
  "$TS" serve --bg --tcp="$puerto" "tcp://127.0.0.1:$puerto" >/dev/null
done
IP=$("$TS" ip -4 2>/dev/null | head -1)

# Tailscale Funnel: la APP (y solo la app) queda pública en Internet con URL FIJA y HTTPS:
# https://<nombre>.ts.net. A diferencia del túnel rápido de Cloudflare, no cambia al reiniciar.
# Requiere habilitar Funnel una vez en la tailnet (el comando muestra el link si falta).
# GYMHUB_FUNNEL=0 para no publicarla.
if [ "${GYMHUB_FUNNEL:-1}" = 1 ]; then
  "$TS" funnel --bg --https=443 http://127.0.0.1:80 >/dev/null
  echo "✔ App PÚBLICA en Internet (Funnel, URL fija): https://$NOMBRE/"
fi

echo "✔ Publicado SOLO en la tailnet (dispositivos logueados con la cuenta del equipo):"
echo "  (en el navegador usar la IP $IP; para pgAdmin y otros clientes también sirve $NOMBRE)"
for s in "${SERVICIOS[@]}"; do
  read -r nombre puerto tipo <<<"$s"
  if [ "$tipo" = postgres ]; then url="host $IP, puerto $puerto (PostgreSQL)"
  elif [ "$nombre" = Tunel-URL ]; then url="http://$IP:$puerto/quicktunnel"
  else url="http://$IP:$puerto/"; fi
  printf '  %-16s %s\n' "$nombre" "$url"
done
