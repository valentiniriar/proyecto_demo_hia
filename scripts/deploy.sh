#!/usr/bin/env bash
# Despliegue de GymHub en el servidor con rollback automático (SCRUM-57 / SCRUM-59).
#
#   bash scripts/deploy.sh <tag>        # despliega esa versión (tag = SHA del commit publicado en GHCR)
#   bash scripts/deploy.sh --estado     # muestra la versión desplegada y el historial
#   bash scripts/deploy.sh --tunel      # levanta el túnel rápido de Cloudflare sin tocar la app
#
# Lo ejecuta el job "desplegar" de .github/workflows/cd.yml en el runner self-hosted,
# pero también se puede correr a mano en el servidor (por ejemplo, para un rollback).
#
# Secretos y estado del servidor (versión desplegada, historial): carpeta produccion/ del repo
# del servidor (ignorada por Git, ver produccion/LEEME.md). Se busca, en orden:
#   1. GYMHUB_ENV_FILE   ruta explícita (el runner la recibe de C:\actions-runner\gymhub-env.cmd,
#                        porque el job corre en su propia copia del repo, no en la carpeta del proyecto)
#   2. ./produccion/.env.prod   cuando se ejecuta a mano desde la carpeta del proyecto
#   3. C:/gymhub/.env.prod      ubicación anterior (compatibilidad)
#
# Otras variables (opcionales):
#   HEALTH_URL       URL que se verifica tras desplegar (default http://127.0.0.1/api/health, pasa por Nginx)
#   SKIP_PULL=1      no descarga de GHCR (para probar con imágenes construidas localmente)
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash en Windows: no reescribir rutas tipo /api/health
cd "$(dirname "$0")/.."
# Ruta del repo en formato que entiende Docker en Windows (C:/...); en Linux/macOS, la de siempre.
REPO_DIR="$(pwd -W 2>/dev/null || pwd)"

ENV_FILE="${GYMHUB_ENV_FILE:-}"
if [ -z "$ENV_FILE" ]; then
  for candidato in "$REPO_DIR/produccion/.env.prod" "C:/gymhub/.env.prod"; do
    [ -f "$candidato" ] && { ENV_FILE="$candidato"; break; }
  done
fi
ENV_FILE="${ENV_FILE:-$REPO_DIR/produccion/.env.prod}"
ESTADO_DIR="$(dirname "$ENV_FILE")"
ACTUAL="$ESTADO_DIR/version-desplegada.txt"
HISTORIAL="$ESTADO_DIR/historial-despliegues.log"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1/api/health}"

# Proyecto Compose = grupo "gymhub-produccion" en Docker Desktop: app + cluster de base + backup + túnel.
COMPOSE=(docker compose -p gymhub-produccion --env-file "$ENV_FILE"
         -f compose.yaml -f compose.prod.yaml -f compose.tunnel.yaml --profile prod)
# El túnel (cloudflared) NO está en la lista: si se recreara, el túnel rápido cambiaría de URL.
# Base: cluster Patroni (etcd + 3 nodos + HAProxy). Ver docs/implementacion-patroni.MD.
SERVICIOS=(etcd pg-1 pg-2 pg-3 haproxy backup backend frontend)
# Contenedores de la topología anterior (primario + réplica fijos). Si siguen existiendo, Compose no los
# borra (quedan "huérfanos") y pg-1 arrancaría sobre el MISMO volumen que gymhub_db_prod: dos PostgreSQL
# escribiendo los mismos archivos corrompen la base. Hay que migrar primero (docs/implementacion-patroni.MD).
CONTENEDORES_VIEJOS=(gymhub_db_prod gymhub_db_replica_prod)

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
registrar() { printf '%s | %-40s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$HISTORIAL"; }

if [ "${1:-}" = "--estado" ]; then
  echo "Versión desplegada: $(cat "$ACTUAL" 2>/dev/null || echo 'ninguna')"
  echo "Últimos despliegues:"; tail -n 10 "$HISTORIAL" 2>/dev/null || echo "  (sin historial)"
  exit 0
fi

[ -f "$ENV_FILE" ] || { log "✖ Falta $ENV_FILE (secretos de producción). Ver produccion/LEEME.md"; exit 1; }

if [ "${1:-}" = "--tunel" ]; then
  # --no-deps: no recrea el frontend; solo agrega el túnel apuntando a frontend:8080.
  "${COMPOSE[@]}" --profile tunel-rapido up -d --no-deps cloudflared-rapido
  for _ in $(seq 1 30); do
    URL=$(docker logs gymhub_cloudflared_rapido 2>&1 | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | tail -1 || true)
    [ -n "$URL" ] && { echo "✔ GymHub publicado en $URL"; exit 0; }
    sleep 2
  done
  log "✖ El túnel no informó una URL. Ver: docker logs gymhub_cloudflared_rapido"; exit 1
fi

TAG="${1:?Uso: bash scripts/deploy.sh <tag> | --estado | --tunel}"

for viejo in "${CONTENEDORES_VIEJOS[@]}"; do
  if docker container inspect "$viejo" >/dev/null 2>&1; then
    log "✖ Existe el contenedor $viejo de la base anterior (sin Patroni)."
    log "  Hacer primero la migración a Patroni: docs/implementacion-patroni.MD, sección \"Migrar producción\"."
    exit 1
  fi
done
ANTERIOR="$(cat "$ACTUAL" 2>/dev/null || true)"

desplegar() {
  local tag="$1"
  if [ "${SKIP_PULL:-0}" != 1 ]; then
    log "→ Descargando imágenes $tag de GHCR"
    IMAGE_TAG="$tag" "${COMPOSE[@]}" pull backend frontend
  fi
  # Imágenes que se construyen en el servidor (no están en GHCR): sin este build, un cambio en
  # database/backup/ o database/patroni/ nunca llegaba a producción, porque "up" reutiliza la imagen
  # local existente. Con caché, si no cambió nada no recrea ningún contenedor. pg-1 construye la imagen
  # que comparten los 3 nodos de Patroni.
  log "→ Construyendo imágenes locales (backup, Patroni)"
  IMAGE_TAG="$tag" "${COMPOSE[@]}" build backup pg-1
  log "→ Levantando servicios con IMAGE_TAG=$tag"
  # --wait: espera a que los servicios con healthcheck (db, réplica, backend) estén healthy.
  IMAGE_TAG="$tag" "${COMPOSE[@]}" up -d --wait --wait-timeout 240 "${SERVICIOS[@]}"
}

verificar() {
  # Verificación de punta a punta: Nginx (frontend) → backend → base de datos.
  local codigo=000
  for _ in $(seq 1 20); do
    codigo=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$HEALTH_URL" || true)
    [ "$codigo" = 200 ] && { log "✔ $HEALTH_URL respondió 200"; return 0; }
    sleep 3
  done
  log "✖ $HEALTH_URL respondió $codigo"
  return 1
}

log "Versión actual: ${ANTERIOR:-ninguna} · versión a desplegar: $TAG"

if desplegar "$TAG" && verificar; then
  echo "$TAG" > "$ACTUAL"
  registrar "$TAG" "OK"
  log "✔ Despliegue de $TAG completado"
  exit 0
fi

registrar "$TAG" "FALLÓ"
log "✖ El despliegue de $TAG falló"
docker logs --tail 30 gymhub_backend_prod 2>&1 || true

if [ -n "$ANTERIOR" ] && [ "$ANTERIOR" != "$TAG" ]; then
  log "↩ Rollback automático a $ANTERIOR"
  if desplegar "$ANTERIOR" && verificar; then
    registrar "$ANTERIOR" "ROLLBACK OK (tras fallo de $TAG)"
    log "✔ Servicio restaurado en $ANTERIOR"
  else
    registrar "$ANTERIOR" "ROLLBACK FALLÓ"
    log "✖ El rollback también falló: intervención manual necesaria"
  fi
fi
# Sale con error para que el pipeline marque el despliegue como fallido.
exit 1
