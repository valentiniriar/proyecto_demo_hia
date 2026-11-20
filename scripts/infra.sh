#!/usr/bin/env bash
# Servicios de operación de GymHub en el servidor (SCRUM-61). Todo escucha SOLO en 127.0.0.1; el acceso
# remoto es por Tailscale (scripts/tailscale-serve.sh), nunca por Cloudflare.
#
#   bash scripts/infra.sh levantar      # levanta monitoreo y herramientas (idempotente)
#   bash scripts/infra.sh estado        # grupos de contenedores, accesos y si responden
#   bash scripts/infra.sh credenciales  # junta todas las credenciales en produccion/CREDENCIALES.txt
#   bash scripts/infra.sh bajar         # detiene monitoreo y herramientas (los datos quedan en volúmenes)
#
# Grupos (proyectos Compose) que muestra Docker Desktop:
#   gymhub-produccion   app + cluster de base (primario/réplica) + backup + túnel  → scripts/deploy.sh / CD
#   gymhub-monitoreo    Prometheus, Grafana, Alertmanager y exporters             → este script
#   gymhub-herramientas Mantis y Nextcloud (+ sus bases), n8n y el puente a la base → este script
#
# Primera vez: bash infra/mantis/setup.sh y bash infra/nextcloud/setup.sh (crean sus .env y credenciales).
set -euo pipefail
export MSYS_NO_PATHCONV=1
# Mantis, Nextcloud, n8n y el puente comparten el proyecto gymhub-herramientas desde archivos distintos:
# cada uno ve a los otros como "huérfanos". Es esperado; no se eliminan.
export COMPOSE_IGNORE_ORPHANS=true
cd "$(dirname "$0")/.."

PROD_DIR="$PWD/produccion"
PROD_ENV="$PROD_DIR/.env.prod"

MON=(docker compose -f infra/monitoring/docker-compose.yml -f infra/monitoring/docker-compose.prod.yml --env-file infra/monitoring/.env)
MANTIS=(docker compose -f infra/mantis/docker-compose.yml --env-file infra/mantis/.env)
N8N=(docker compose -f infra/n8n/docker-compose.yml --env-file infra/n8n/.env)
ADMIN=(docker compose -f infra/admin/docker-compose.yml)
NC=(docker compose -f infra/nextcloud/docker-compose.yml --env-file infra/nextcloud/.env)

valor() { grep -E "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true; }

requisitos() {
  local falta=0
  for f in infra/monitoring/.env infra/mantis/.env infra/n8n/.env infra/nextcloud/.env; do
    [ -f "$f" ] || { echo "✖ Falta $f (ver produccion/LEEME.md)"; falta=1; }
  done
  docker network inspect gymhub_prod_db_net >/dev/null 2>&1 \
    || { echo "✖ No existe la red de producción: primero desplegar la app (scripts/deploy.sh)"; falta=1; }
  return $falta
}

# Alertmanager de producción manda las alertas a n8n con un token (ver alertmanager.prod.yml). Si el
# archivo del secreto no existe, se crea a partir de infra/n8n/.env (o se genera el token).
asegurar_token_alertas() {
  local f=infra/monitoring/secrets/alertmanager_n8n_token t
  [ -s "$f" ] && return 0
  t=$(valor infra/n8n/.env N8N_ALERTAS_WEBHOOK_TOKEN | tr -d '\r')
  if [ -z "$t" ]; then
    t=$(node -e "console.log(require('crypto').randomBytes(32).toString('hex'))")
    printf '\nN8N_ALERTAS_WEBHOOK_TOKEN=%s\n' "$t" >> infra/n8n/.env
  fi
  mkdir -p infra/monitoring/secrets
  ( umask 077; printf '%s' "$t" > "$f" )
  echo "→ Token de Alertmanager → n8n creado (correr bash infra/n8n/configurar.sh para cargarlo en n8n)"
}

case "${1:-estado}" in
  levantar)
    requisitos
    asegurar_token_alertas
    bash infra/monitoring/generar-prod.sh >/dev/null
    echo "→ gymhub-monitoreo";               "${MON[@]}" up -d --quiet-pull 2>&1 | grep -vE "^\s*$" | tail -1
    echo "→ gymhub-herramientas: Mantis";    "${MANTIS[@]}" up -d 2>&1 | tail -1
    echo "→ gymhub-herramientas: Nextcloud"; "${NC[@]}" up -d 2>&1 | tail -1
    echo "→ gymhub-herramientas: n8n";       "${N8N[@]}" up -d 2>&1 | tail -1
    echo "→ gymhub-herramientas: puente BD"; "${ADMIN[@]}" up -d 2>&1 | tail -1
    # Si el túnel rápido está arriba, Prometheus mide la URL pública.
    if docker ps --format '{{.Names}}' | grep -q '^gymhub_cloudflared_rapido$'; then
      bash infra/monitoring/publicar-target.sh >/dev/null && echo "→ URL pública registrada en Prometheus"
    fi
    exec bash "$0" estado
    ;;

  bajar)
    "${ADMIN[@]}" down; "${N8N[@]}" down; "${NC[@]}" down; "${MANTIS[@]}" down; "${MON[@]}" down
    echo "✔ Monitoreo y herramientas detenidos (datos conservados en sus volúmenes)."
    ;;

  credenciales)
    # Junta en un solo archivo (ignorado por Git) las credenciales que viven en cada .env del servidor.
    SALIDA="$PROD_DIR/CREDENCIALES.txt"
    umask 077
    {
      echo "CREDENCIALES DE PRODUCCIÓN DE GYMHUB · generado $(date '+%d/%m/%Y %H:%M') por scripts/infra.sh credenciales"
      echo "NO VERSIONAR NI COMPARTIR POR CANALES PÚBLICOS. Regenerar tras cambiar cualquier contraseña."
      echo
      echo "== App de producción (usuarios de la web) =="
      grep -vE '^\s*#' "$PROD_DIR/credenciales-produccion.txt" 2>/dev/null || echo "  (falta produccion/credenciales-produccion.txt)"
      echo
      echo "== Base de datos de producción =="
      echo "  Host local:      127.0.0.1:5436   ·   por Tailscale: gymhub-servidor.tailec3350.ts.net:5436"
      echo "  Base:            $(valor "$PROD_ENV" DB_NAME)"
      echo "  Usuario (superusuario): $(valor "$PROD_ENV" DB_USER)"
      echo "  Contraseña:      $(valor "$PROD_ENV" DB_PASS)"
      echo "  Usuario de métricas: $(valor infra/monitoring/.env PG_EXPORTER_USER) / $(valor infra/monitoring/.env PG_EXPORTER_PASSWORD)"
      echo "  Replicación:     $(valor "$PROD_ENV" POSTGRES_REPLICA_USER) / $(valor "$PROD_ENV" POSTGRES_REPLICA_PASSWORD)"
      echo
      echo "== Backend =="
      echo "  JWT_SECRET:      $(valor "$PROD_ENV" JWT_SECRET)"
      echo
      echo "== Grafana (http://127.0.0.1:$(valor infra/monitoring/.env GRAFANA_HOST_PORT)/) =="
      echo "  $(valor infra/monitoring/.env GF_SECURITY_ADMIN_USER) / $(valor infra/monitoring/.env GF_SECURITY_ADMIN_PASSWORD)"
      echo
      echo "== Mantis (http://127.0.0.1:$(valor infra/mantis/.env MANTIS_HOST_PORT)/) =="
      node -e '
        const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        if (c.admin) console.log("  " + c.admin.usuario + " / " + c.admin.password + "   (administrador)");
        for (const u of c.usuarios_creados || []) console.log("  " + u.usuario + " / " + u.password + "   (" + u.nombre + ")");
        if (c.n8n_token) console.log("  Token de API para n8n: " + c.n8n_token);
      ' infra/mantis/credenciales.local.json 2>/dev/null || echo "  (falta infra/mantis/credenciales.local.json)"
      echo "  Base de Mantis:  mantis / $(valor infra/mantis/.env MANTIS_DB_PASS)   ·   root / $(valor infra/mantis/.env MANTIS_DB_ROOT_PASS)"
      echo
      echo "== Nextcloud (http://127.0.0.1:$(valor infra/nextcloud/.env NEXTCLOUD_HOST_PORT)/) =="
      echo "  admin / $(valor infra/nextcloud/.env NEXTCLOUD_ADMIN_PASS)   (administrador)"
      node -e '
        const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        for (const x of c.credenciales_nuevas || []) {
          if (x.tipo === "usuario") console.log("  " + x.usuario + " / " + x.password + "   (" + x.nombre + " · " + x.grupo + ")");
          if (x.tipo === "n8n") console.log("  App password de n8n-bot (WebDAV " + x.webdav_url + "): " + x.app_password);
        }
      ' infra/nextcloud/credenciales.local.json 2>/dev/null || echo "  (falta infra/nextcloud/credenciales.local.json)"
      echo "  Base de Nextcloud: nextcloud / $(valor infra/nextcloud/.env NEXTCLOUD_DB_PASS)"
      echo
      echo "== n8n (http://127.0.0.1:$(valor infra/n8n/.env N8N_HOST_PORT)/) =="
      echo "  Cuenta owner: $(valor infra/n8n/.env N8N_OWNER_EMAIL) / $(valor infra/n8n/.env N8N_OWNER_PASSWORD)"
      echo "  Mailpit (correos de los flujos): http://127.0.0.1:$(p=$(valor infra/n8n/.env MAILPIT_HOST_PORT); echo "${p:-8026}")/  (sin usuario)"
      echo "  N8N_ENCRYPTION_KEY: $(valor infra/n8n/.env N8N_ENCRYPTION_KEY)"
      echo
      echo "== Cloudflare Tunnel con nombre =="
      t=$(valor "$PROD_ENV" CLOUDFLARE_TUNNEL_TOKEN); echo "  Token: ${t:-(no configurado: se usa el túnel rápido)}"
    } > "$SALIDA"
    echo "✔ Credenciales consolidadas en produccion/CREDENCIALES.txt (ignorado por Git)."
    ;;

  estado)
    PROM=$(valor infra/monitoring/.env PROM_HOST_PORT); GRAF=$(valor infra/monitoring/.env GRAFANA_HOST_PORT)
    ALERT=$(valor infra/monitoring/.env ALERTMANAGER_HOST_PORT); MAN=$(valor infra/mantis/.env MANTIS_HOST_PORT)
    N8NP=$(valor infra/n8n/.env N8N_HOST_PORT); NCP=$(valor infra/nextcloud/.env NEXTCLOUD_HOST_PORT)

    echo "Grupos en Docker Desktop:"
    for g in gymhub-produccion gymhub-monitoreo gymhub-herramientas; do
      total=$(docker ps -a --filter "label=com.docker.compose.project=$g" -q | wc -l | tr -d ' ')
      arriba=$(docker ps --filter "label=com.docker.compose.project=$g" -q | wc -l | tr -d ' ')
      printf '  %-20s %s/%s contenedores en ejecución\n' "$g" "$arriba" "$total"
    done
    echo

    fila() { # nombre url credenciales
      local c; c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$2" || true)
      case "$c" in 2*|3*|401) e="OK";; *) e="X($c)";; esac
      printf '%-7s %-20s %-36s %s\n' "$e" "$1" "$2" "$3"
    }
    printf '%-7s %-20s %-36s %s\n' "Estado" "Servicio" "URL local (solo esta PC)" "Credenciales"
    fila "App de produccion" "http://127.0.0.1/"                "produccion/credenciales-produccion.txt"
    fila "Grafana"           "http://127.0.0.1:${GRAF:-3001}/"  "admin / GF_SECURITY_ADMIN_PASSWORD (infra/monitoring/.env)"
    fila "Prometheus"        "http://127.0.0.1:${PROM:-9091}/"  "sin login (solo localhost y Tailscale)"
    fila "Alertmanager"      "http://127.0.0.1:${ALERT:-9093}/" "sin login (solo localhost y Tailscale)"
    fila "Mantis"            "http://127.0.0.1:${MAN:-8990}/"   "infra/mantis/credenciales.local.json"
    fila "Nextcloud"         "http://127.0.0.1:${NCP:-8082}/status.php" "infra/nextcloud/credenciales.local.json"
    fila "n8n"               "http://127.0.0.1:${N8NP:-5679}/"  "cuenta owner creada en el primer ingreso"
    if docker ps --format '{{.Names}}' | grep -q '^gymhub_db_puente$'; then
      printf '%-7s %-20s %-36s %s\n' "OK" "Base de produccion" "postgresql://127.0.0.1:5436/gymhub" "DB_USER / DB_PASS (produccion/.env.prod)"
    else
      printf '%-7s %-20s %-36s %s\n' "X" "Base de produccion" "puente apagado" "bash scripts/infra.sh levantar"
    fi
    URL=$(docker logs gymhub_cloudflared_rapido 2>&1 | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | tail -1 || true)
    echo; echo "Pública (Internet):  ${URL:-túnel apagado → bash scripts/deploy.sh --tunel}"
    TS="$(command -v tailscale || echo '/c/Program Files/Tailscale/tailscale.exe')"
    if [ -x "$TS" ] && "$TS" status >/dev/null 2>&1; then
      echo "Remota (Tailscale):  http://gymhub-servidor.tailec3350.ts.net[:puerto]  (bash scripts/tailscale-serve.sh --estado)"
    fi
    echo "Todas las credenciales juntas: bash scripts/infra.sh credenciales → produccion/CREDENCIALES.txt"
    ;;

  *) echo "Uso: bash scripts/infra.sh levantar|estado|credenciales|bajar"; exit 1 ;;
esac
