#!/usr/bin/env bash
# Despliegue y configuración inicial de Nextcloud para GymHub (SCRUM-73/74). Idempotente.
#   bash infra/nextcloud/setup.sh               # primera vez / aplicar cambios de la estructura
#   bash infra/nextcloud/setup.sh --regenerar   # rotar contraseñas de usuarios y app password de n8n
#
# 1. Crea infra/nextcloud/.env con claves aleatorias (si no existe).
# 2. Levanta Nextcloud + PostgreSQL (la imagen instala Nextcloud en el primer arranque).
# 3. Ejecuta cloud/bootstrap.sh: grupos, usuarios, carpetas, matriz de permisos y app password de n8n.
# 4. Guarda las credenciales NUEVAS en infra/nextcloud/credenciales.local.json (ignorado por Git).
set -euo pipefail
export MSYS_NO_PATHCONV=1

DIR="$(cd "$(dirname "$0")" && (pwd -W 2>/dev/null || pwd))"
COMPOSE=(docker compose -f "$DIR/docker-compose.yml" --env-file "$DIR/.env")
export COMPOSE_IGNORE_ORPHANS=true   # comparte el proyecto gymhub-herramientas con Mantis y n8n

rand() { openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-"$1"; }

if [ ! -f "$DIR/.env" ]; then
  echo "→ Generando $DIR/.env con claves aleatorias"
  umask 077
  cat > "$DIR/.env" <<EOF
NEXTCLOUD_HOST_PORT=8082
NEXTCLOUD_DB_PASS=$(rand 32)
NEXTCLOUD_ADMIN_PASS=$(rand 32)
EOF
  nuevo_admin=1
fi
# --regenerar: contraseñas nuevas para todos los usuarios y nueva app password de n8n (se pasa a bootstrap.sh).
# shellcheck disable=SC1091
set -a; . "$DIR/.env"; set +a

echo "→ Levantando Nextcloud"
"${COMPOSE[@]}" up -d

echo "→ Esperando a que Nextcloud termine de instalarse (la primera vez tarda 1-3 minutos)"
for _ in $(seq 1 100); do
  if docker exec -u www-data gymhub-nextcloud php occ status --output=json 2>/dev/null | grep -q '"installed":true'; then
    listo=1; break
  fi
  sleep 3
done
[ -n "${listo:-}" ] || { echo "✖ Nextcloud no terminó de instalarse: docker logs gymhub-nextcloud"; exit 1; }

# Las credenciales nuevas se juntan aunque el bootstrap falle a mitad de camino.
CRED_PARCIAL="$DIR/credenciales.local.parcial.json"; export CRED_PARCIAL
rm -f "$CRED_PARCIAL"
[ -n "${nuevo_admin:-}" ] && (umask 077; echo "{\"tipo\": \"admin\", \"usuario\": \"admin\", \"password\": \"$NEXTCLOUD_ADMIN_PASS\"}" > "$CRED_PARCIAL")

guardar_credenciales() {
  [ -s "$CRED_PARCIAL" ] || { echo "→ No se generaron credenciales nuevas (todo ya existía)."; return; }
  umask 077
  local marca; marca=$(date +%Y%m%d-%H%M%S)
  {
    echo "{"
    echo "  \"url\": \"http://localhost:${NEXTCLOUD_HOST_PORT:-8082}\","
    echo "  \"generado\": \"$marca\","
    echo "  \"credenciales_nuevas\": ["
    sed '$!s/$/,/; s/^/    /' "$CRED_PARCIAL"
    echo "  ]"
    echo "}"
  } > "$DIR/credenciales.local.json"
  cp "$DIR/credenciales.local.json" "$DIR/credenciales.local.$marca.json"
  rm -f "$CRED_PARCIAL"
  echo "→ Credenciales NUEVAS guardadas en infra/nextcloud/credenciales.local.json (no se suben al repo)."
  echo "  Repartí cada contraseña a su integrante por un canal privado y pedí que la cambie al entrar."
  echo "  La app password de n8n va en Credentials de n8n (WebDAV), nunca en un nodo ni en un JSON exportado."
}
trap guardar_credenciales EXIT

echo "→ Configurando grupos, usuarios, carpetas y permisos"
bash "$DIR/cloud/bootstrap.sh" "$@"
trap - EXIT
guardar_credenciales

echo "✔ Nextcloud listo en http://localhost:${NEXTCLOUD_HOST_PORT:-8082}"
