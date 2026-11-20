#!/usr/bin/env bash
# Deja n8n de producción listo (SCRUM-75/76/77/79/84). Idempotente: correrlo de nuevo actualiza los
# flujos y las credenciales.
#
#   bash infra/n8n/configurar.sh
#
# Qué hace:
#   1. Genera (si faltan) los secretos de los webhooks en infra/n8n/.env y la URL pública de n8n.
#   2. Escribe el token que usa Alertmanager (infra/monitoring/secrets/, ignorado por Git) y sincroniza el
#      secreto de eventos de seguridad del backend en produccion/.env.prod.
#   3. Levanta n8n, Mailpit y el analizador Python.
#   4. Crea la cuenta owner si no existe (N8N_OWNER_EMAIL / N8N_OWNER_PASSWORD de infra/n8n/.env).
#   5. Publica el manual de errores en Nextcloud (infra/nextcloud/publicar-manual.sh).
#   6. Importa las credenciales (n8n las CIFRA con N8N_ENCRYPTION_KEY; el archivo temporal se borra) y los
#      flujos de infra/n8n/workflows/0*.json, publica los que tienen disparador y reinicia n8n.
#
# Secretos que lee (no versionados): token de Mantis del usuario n8n-bot (infra/mantis/credenciales.local.json)
# y app password de Nextcloud de n8n-bot (infra/nextcloud/credenciales.local.json).
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
RAIZ="$(pwd -W 2>/dev/null || pwd)"
ENV=infra/n8n/.env
C=gymhub-n8n-scrum75
N8N=(docker compose -f infra/n8n/docker-compose.yml --env-file "$ENV")
export COMPOSE_IGNORE_ORPHANS=true

valor() { grep -E "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r' || true; }
poner() {   # poner archivo clave valor  (reemplaza o agrega)
  local tmp; tmp=$(mktemp)
  { grep -vE "^$2=" "$1" 2>/dev/null || true; echo "$2=$3"; } > "$tmp" && cat "$tmp" > "$1" && rm -f "$tmp"
}
# Falta si está vacío o con el marcador GENERAR de .env.example.
falta() { local v; v=$(valor "$ENV" "$1"); [ -z "$v" ] || [ "$v" = GENERAR ]; }
aleatorio() { node -e "console.log(require('crypto').randomBytes(${1:-32}).toString('hex'))"; }

[ -f "$ENV" ] || { echo "✖ Falta $ENV (ver infra/n8n/.env.example)"; exit 1; }
[ -n "$(valor "$ENV" N8N_ENCRYPTION_KEY)" ] || { echo "✖ $ENV sin N8N_ENCRYPTION_KEY"; exit 1; }

echo "→ 1. Secretos y URL pública"
falta N8N_ALERTAS_WEBHOOK_TOKEN && poner "$ENV" N8N_ALERTAS_WEBHOOK_TOKEN "$(aleatorio)"
falta N8N_EVENTOS_SECRET && poner "$ENV" N8N_EVENTOS_SECRET "$(aleatorio)"
falta N8N_OWNER_EMAIL && poner "$ENV" N8N_OWNER_EMAIL admin@gymhub.local
falta N8N_OWNER_PASSWORD && poner "$ENV" N8N_OWNER_PASSWORD "Gh$(aleatorio 12)9"
falta N8N_DIAGNOSTICO_PASSWORD && poner "$ENV" N8N_DIAGNOSTICO_PASSWORD "$(aleatorio 12)"
TS="$(command -v tailscale || echo '/c/Program Files/Tailscale/tailscale.exe')"
IP=$("$TS" ip -4 2>/dev/null | head -1 || true)
[ -n "$IP" ] && poner "$ENV" N8N_PUBLIC_BASE_URL "http://$IP:$(valor "$ENV" N8N_HOST_PORT || echo 5679)/"

echo "→ 2. Token de Alertmanager y secreto del backend"
mkdir -p infra/monitoring/secrets
( umask 077; printf '%s' "$(valor "$ENV" N8N_ALERTAS_WEBHOOK_TOKEN)" > infra/monitoring/secrets/alertmanager_n8n_token )
PROD_ENV=${GYMHUB_ENV_FILE:-produccion/.env.prod}
if [ -f "$PROD_ENV" ]; then
  poner "$PROD_ENV" SECURITY_EVENTS_WEBHOOK_SECRET "$(valor "$ENV" N8N_EVENTOS_SECRET)"
else
  echo "  (no hay $PROD_ENV: el backend no enviará eventos de seguridad hasta que exista)"
fi

echo "→ 3. Levantando n8n, Mailpit y el analizador"
"${N8N[@]}" up -d --build 2>&1 | tail -3
for _ in $(seq 1 60); do curl -fsS "http://127.0.0.1:$(valor "$ENV" N8N_HOST_PORT || echo 5679)/healthz" >/dev/null 2>&1 && break; sleep 2; done
URL="http://127.0.0.1:$(valor "$ENV" N8N_HOST_PORT || echo 5679)"

echo "→ 4. Cuenta owner"
if curl -fsS "$URL/rest/settings" | grep -q '"showSetupOnFirstLoad":true'; then
  curl -fsS -X POST "$URL/rest/owner/setup" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$(valor "$ENV" N8N_OWNER_EMAIL)\",\"firstName\":\"GymHub\",\"lastName\":\"Admin\",\"password\":\"$(valor "$ENV" N8N_OWNER_PASSWORD)\"}" >/dev/null
  echo "  creada: $(valor "$ENV" N8N_OWNER_EMAIL)"
else
  echo "  ya existía"
fi

echo "→ 5. Manual de errores en Nextcloud (lo lee el flujo 05)"
bash infra/nextcloud/publicar-manual.sh || echo "  ⚠ no se pudo publicar el manual: el flujo 05 va a fallar hasta que exista"

echo "→ 6. Credenciales (cifradas por n8n) y flujos"
# Carpeta temporal DENTRO del proyecto (ignorada por Git): en Windows, Node y docker cp no ven /tmp de Git Bash.
TMP=infra/n8n/.tmp-configurar
rm -rf "$TMP"; ( umask 077; mkdir -p "$TMP" )
trap 'rm -rf "$TMP"; docker exec "$C" rm -rf /tmp/gymhub-n8n 2>/dev/null || true' EXIT
GYMHUB_ALERTAS="$(valor "$ENV" N8N_ALERTAS_WEBHOOK_TOKEN)" GYMHUB_EVENTOS="$(valor "$ENV" N8N_EVENTOS_SECRET)" \
GYMHUB_DIAGNOSTICO="$(valor "$ENV" N8N_DIAGNOSTICO_PASSWORD)" \
node -e '
  const fs = require("fs");
  const leer = (f) => JSON.parse(fs.readFileSync(f, "utf8"));
  const mantis = leer("infra/mantis/credenciales.local.json").n8n_token;
  const nc = (leer("infra/nextcloud/credenciales.local.json").credenciales_nuevas || []).find((c) => c.tipo === "n8n");
  if (!mantis) throw new Error("Falta n8n_token en infra/mantis/credenciales.local.json");
  if (!nc) throw new Error("Falta la app password de n8n-bot en infra/nextcloud/credenciales.local.json");
  const creds = [
    { id: "gymhubAlertasWh1", name: "Webhook Alertmanager (Bearer)", type: "httpHeaderAuth",
      data: { name: "Authorization", value: "Bearer " + process.env.GYMHUB_ALERTAS } },
    { id: "gymhubEventosSeg", name: "GymHub - secreto de eventos de seguridad", type: "httpHeaderAuth",
      data: { name: "X-GymHub-Secret", value: process.env.GYMHUB_EVENTOS } },
    { id: "gymhubMantisBot", name: "Mantis - token n8n-bot", type: "httpHeaderAuth",
      data: { name: "Authorization", value: mantis } },   // Mantis REST: el token va SIN "Bearer"
    { id: "gymhubMailpit01", name: "SMTP Mailpit (interno)", type: "smtp",
      data: { host: "mailpit", port: 1025, secure: false, disableStartTls: true, user: "", password: "" } },
    { id: "gymhubNextcloud1", name: "Nextcloud - n8n-bot (app password)", type: "httpBasicAuth",
      data: { user: "n8n-bot", password: nc.app_password } },
    // Usuario y clave de la página de diagnóstico del flujo 05 (Basic Auth del webhook).
    { id: "gymhubDiagnost01", name: "Diagnóstico - usuario y clave de la página", type: "httpBasicAuth",
      data: { user: "diagnostico", password: process.env.GYMHUB_DIAGNOSTICO } },
  ];
  fs.writeFileSync(process.argv[1], JSON.stringify(creds), { mode: 0o600 });
' "$TMP/credenciales.json"
mkdir -p "$TMP/flujos" && cp infra/n8n/workflows/0*.json "$TMP/flujos/"
docker exec "$C" mkdir -p /tmp/gymhub-n8n
docker cp "$TMP/credenciales.json" "$C:/tmp/gymhub-n8n/credenciales.json"
docker cp "$TMP/flujos" "$C:/tmp/gymhub-n8n/"
docker exec "$C" n8n import:credentials --input=/tmp/gymhub-n8n/credenciales.json 2>&1 | grep -iE 'import|error' || true
docker exec "$C" n8n import:workflow --separate --input=/tmp/gymhub-n8n/flujos 2>&1 | grep -iE 'import|error' || true
# Se publican todos, incluido 00: en n8n 2.x el Error Workflow también tiene que estar activo, si no los
# demás no pueden invocarlo ("Workflow GymHubErrores001 is not active and cannot be executed").
# El 05 antes que el 01: n8n no publica un flujo que llama a un subflujo sin publicar.
for id in GymHubErrores001 GymHubDiagnost1 GymHubAlertas001 GymHubBackups001 GymHubInforme001 GymHubSeguridad1; do
  docker exec "$C" n8n publish:workflow --id="$id" 2>&1 | grep -iE 'publish|error' || true
done
docker restart "$C" >/dev/null
for _ in $(seq 1 60); do curl -fsS "$URL/healthz" >/dev/null 2>&1 && break; sleep 2; done

echo "✔ n8n listo en $URL (owner: $(valor "$ENV" N8N_OWNER_EMAIL))"
echo "  Flujos:  $(docker exec "$C" n8n list:workflow 2>/dev/null | grep -c '|') importados"
echo "  Diagnóstico: $URL/webhook/gymhub-diagnostico  (usuario diagnostico, clave N8N_DIAGNOSTICO_PASSWORD de $ENV)"
echo "  Mailpit: http://127.0.0.1:$(p=$(valor "$ENV" MAILPIT_HOST_PORT); echo "${p:-8026}")  (correos de los flujos)"
echo "  Falta, si es la primera vez: bash scripts/infra.sh levantar (Alertmanager con el webhook) y un"
echo "  despliegue del backend (SECURITY_EVENTS_WEBHOOK_SECRET) para que lleguen los eventos de seguridad."
