#!/usr/bin/env bash
# Backup de Nextcloud (SCRUM-73/74): base PostgreSQL + archivos (volumen gymhub_nextcloud_data).
#   bash infra/nextcloud/db/backup.sh            → backups/nextcloud/<fecha>/  (backups/ está ignorado por Git)
#
# Pone Nextcloud en modo mantenimiento mientras copia, para que la BD y los archivos queden consistentes.
# Restaurar (con Nextcloud detenido o en mantenimiento):
#   gunzip -c nextcloud-db.sql.gz | docker exec -i gymhub-nextcloud-db psql -U nextcloud -d nextcloud
#   docker run --rm -v gymhub_nextcloud_data:/datos -v "$PWD":/b alpine tar xzf /b/nextcloud-archivos.tar.gz -C /datos
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../../.."

DESTINO="backups/nextcloud/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DESTINO"
DEST_ABS="$(cd "$DESTINO" && (pwd -W 2>/dev/null || pwd))"
occ() { docker exec -u www-data gymhub-nextcloud php occ "$@"; }

occ maintenance:mode --on >/dev/null
trap 'occ maintenance:mode --off >/dev/null' EXIT

echo "→ Base de datos"
docker exec gymhub-nextcloud-db pg_dump -U nextcloud -d nextcloud --clean --if-exists | gzip > "$DESTINO/nextcloud-db.sql.gz"
echo "→ Archivos y configuración (volumen gymhub_nextcloud_data)"
docker run --rm -v gymhub_nextcloud_data:/datos:ro -v "$DEST_ABS":/b alpine:3.21 \
  tar czf /b/nextcloud-archivos.tar.gz -C /datos config data custom_apps

ls -lh "$DESTINO"
echo "✔ Backup en $DESTINO (no se sube al repo: contiene datos y la config con secretos)"
