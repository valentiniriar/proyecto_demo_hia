#!/usr/bin/env bash
# Servicios de operación de GymHub en el servidor (SCRUM-61): monitoreo de producción, Mantis,
# n8n y el puente a la base de producción. Todo escucha SOLO en 127.0.0.1; el acceso remoto es por
# Tailscale (scripts/tailscale-serve.sh), nunca por Cloudflare.
#
#   bash scripts/infra.sh levantar   # levanta todo (idempotente)
#   bash scripts/infra.sh estado     # tabla de accesos y si responden
#   bash scripts/infra.sh bajar      # detiene todo (los datos quedan en sus volúmenes)
#
# Primera vez: bash infra/mantis/setup.sh (crea infra/mantis/.env y credenciales).
# La app de producción la despliega el CD (scripts/deploy.sh); este script no la toca.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

MON=(docker compose -f infra/monitoring/docker-compose.yml -f infra/monitoring/docker-compose.prod.yml --env-file infra/monitoring/.env)
MANTIS=(docker compose -f infra/mantis/docker-compose.yml --env-file infra/mantis/.env)
N8N=(docker compose -f infra/n8n/docker-compose.yml -f infra/n8n/SCRUM-76.n8n.override.example.yml --env-file infra/n8n/.env)
ADMIN=(docker compose -f infra/admin/docker-compose.yml)

valor() { grep -E "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true; }

requisitos() {
  local falta=0
  for f in infra/monitoring/.env infra/mantis/.env infra/n8n/.env; do
    [ -f "$f" ] || { echo "✖ Falta $f (ver docs/SCRUM-61-acceso-administrativo.md, sección 2)"; falta=1; }
  done
  docker network inspect gymhub_prod_db_net >/dev/null 2>&1 \
    || { echo "✖ No existe la red de producción: primero desplegar la app (scripts/deploy.sh)"; falta=1; }
  return $falta
}

case "${1:-estado}" in
  levantar)
    requisitos
    bash infra/monitoring/generar-prod.sh >/dev/null
    echo "→ Monitoreo de producción";  "${MON[@]}" up -d --quiet-pull 2>&1 | grep -vE "^\s*$" | tail -1
    echo "→ Mantis";                   "${MANTIS[@]}" up -d 2>&1 | tail -1
    echo "→ n8n";                      "${N8N[@]}" up -d 2>&1 | tail -1
    echo "→ Puente a la base";         "${ADMIN[@]}" up -d 2>&1 | tail -1
    # Si el túnel rápido está arriba, Prometheus mide la URL pública.
    if docker ps --format '{{.Names}}' | grep -q '^gymhub_cloudflared_rapido$'; then
      bash infra/monitoring/publicar-target.sh >/dev/null && echo "→ URL pública registrada en Prometheus"
    fi
    exec bash "$0" estado
    ;;
  bajar)
    "${ADMIN[@]}" down; "${N8N[@]}" down; "${MANTIS[@]}" down; "${MON[@]}" down
    echo "✔ Servicios de operación detenidos (datos conservados en sus volúmenes)."
    ;;
  estado)
    PROM=$(valor infra/monitoring/.env PROM_HOST_PORT); GRAF=$(valor infra/monitoring/.env GRAFANA_HOST_PORT)
    ALERT=$(valor infra/monitoring/.env ALERTMANAGER_HOST_PORT); MAN=$(valor infra/mantis/.env MANTIS_HOST_PORT)
    N8NP=$(valor infra/n8n/.env N8N_HOST_PORT)
    fila() { # nombre url credenciales
      local c; c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$2" || true)
      case "$c" in 2*|3*|401) e="✔";; *) e="✖ ($c)";; esac
      printf '%-4s %-22s %-34s %s\n' "$e" "$1" "$2" "$3"
    }
    echo "Servicio               URL local (solo esta PC)           Credenciales"
    fila "App (producción)"  "http://127.0.0.1/"                         "C:\\gymhub\\credenciales-produccion.txt"
    fila "Grafana"           "http://127.0.0.1:${GRAF:-3001}/"           "admin / GF_SECURITY_ADMIN_PASSWORD en infra/monitoring/.env"
    fila "Prometheus"        "http://127.0.0.1:${PROM:-9091}/"           "sin login (solo localhost)"
    fila "Alertmanager"      "http://127.0.0.1:${ALERT:-9093}/"          "sin login (solo localhost)"
    fila "Mantis"            "http://127.0.0.1:${MAN:-8990}/"            "infra/mantis/credenciales.local.json"
    fila "n8n"               "http://127.0.0.1:${N8NP:-5679}/"           "cuenta owner creada en el primer ingreso"
    if docker ps --format '{{.Names}}' | grep -q '^gymhub_db_puente$'; then
      printf '%-4s %-22s %-34s %s\n' "✔" "Base de producción" "postgresql://127.0.0.1:5436/gymhub" "DB_USER / DB_PASS en C:\\gymhub\\.env.prod"
    else
      printf '%-4s %-22s %-34s %s\n' "✖" "Base de producción" "puente apagado" "bash scripts/infra.sh levantar"
    fi
    URL=$(docker logs gymhub_cloudflared_rapido 2>&1 | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | tail -1 || true)
    echo; echo "Pública (Internet):  ${URL:-túnel apagado → bash scripts/deploy.sh --tunel}"
    if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
      echo "Remota (Tailscale):  ver 'tailscale serve status' (bash scripts/tailscale-serve.sh)"
    fi
    ;;
  *) echo "Uso: bash scripts/infra.sh levantar|estado|bajar"; exit 1 ;;
esac
