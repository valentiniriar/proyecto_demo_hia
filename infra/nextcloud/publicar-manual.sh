#!/usr/bin/env bash
# Publica el manual de errores en Nextcloud (carpeta de equipo Manual-Operaciones), de donde lo lee el flujo 05
# de n8n. Idempotente: reemplaza la versión anterior (Nextcloud guarda las versiones viejas).
#
#   bash infra/nextcloud/publicar-manual.sh
#
# Se copia como administrador del contenedor (docker cp + groupfolders:scan) porque n8n-bot solo tiene LECTURA
# en esa carpeta: el robot no puede modificar las instrucciones que sigue. Lo llama infra/n8n/configurar.sh.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
CONT=gymhub-nextcloud
CARPETA=Manual-Operaciones
occ() { docker exec -u www-data "$CONT" php occ --no-interaction "$@"; }

node infra/n8n/workflows/generar.js >/dev/null   # regenera manual-errores.md desde el JSON
node -e 'JSON.parse(require("fs").readFileSync("infra/n8n/manual/manual-errores.json","utf8"))' \
  || { echo "✖ manual-errores.json no es JSON válido"; exit 1; }

id=$(occ groupfolders:list --output=json | docker exec -i "$CONT" php -r '
  foreach (json_decode(stream_get_contents(STDIN), true) as $f)
    if (($f["mountPoint"] ?? $f["mount_point"] ?? null) === $argv[1]) { echo $f["id"]; break; }' "$CARPETA")
[ -n "$id" ] || { echo "✖ No existe la carpeta $CARPETA: correr bash infra/nextcloud/cloud/bootstrap.sh"; exit 1; }

destino="/var/www/html/data/__groupfolders/$id/files"
docker exec "$CONT" mkdir -p "$destino"
for f in manual-errores.json manual-errores.md; do
  docker cp "infra/n8n/manual/$f" "$CONT:$destino/$f"
done
docker exec "$CONT" chown -R www-data:www-data "$destino"
occ groupfolders:scan "$id" >/dev/null
echo "✔ Manual publicado en Nextcloud › $CARPETA (manual-errores.json y manual-errores.md)"
