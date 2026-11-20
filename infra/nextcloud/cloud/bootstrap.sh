#!/usr/bin/env bash
# Configuración de Nextcloud para GymHub (SCRUM-73/74) con occ. Idempotente: lo que ya existe no se toca.
# Lo invoca infra/nextcloud/setup.sh; también se puede correr solo con el contenedor levantado:
#   bash infra/nextcloud/cloud/bootstrap.sh               # crea lo que falte
#   bash infra/nextcloud/cloud/bootstrap.sh --regenerar   # además: contraseñas nuevas a todos y rota la app password de n8n
#
# Cada credencial NUEVA se agrega en el momento a $CRED_PARCIAL (una línea JSON por credencial, ignorado por Git),
# así no se pierde nada si el script se corta a mitad de camino. setup.sh la convierte en credenciales.local.json.
set -euo pipefail
export MSYS_NO_PATHCONV=1

DIR="$(cd "$(dirname "$0")" && (pwd -W 2>/dev/null || pwd))"
CRED_PARCIAL="${CRED_PARCIAL:-$DIR/../credenciales.local.parcial.json}"
REGENERAR=""; [ "${1:-}" = "--regenerar" ] && REGENERAR=1

CONT=gymhub-nextcloud
occ() { docker exec -u www-data "$CONT" php occ --no-interaction "$@"; }
occ_env() { local v="$1"; shift; docker exec -u www-data -e OC_PASS="$v" "$CONT" php occ --no-interaction "$@"; }
log() { echo "  $*" >&2; }
rand() { openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-"$1"; }
guardar() { (umask 077; echo "$1" >> "$CRED_PARCIAL"); }

# ── Estructura (SCRUM-73/74) ──────────────────────────────────────────────────────────────────────
CARPETAS=(
  01-Diagnóstico 02-Scrum 03-Git 04-BD-Docker 05-Optimización 06-Replicación 07-Contenedores 08-CICD
  09-Publicación 10-Monitoreo 11-Incidencias 12-Documental 13-n8n 14-Seguridad 15-Final
)
CARPETA_IA=Informes-IA
# Manual de errores (lo lee el flujo 05 de n8n) y diagnósticos que genera ese flujo.
CARPETA_MANUAL=Manual-Operaciones
CARPETA_DIAG=Diagnosticos

# usuario | nombre visible | grupo ("" = sin grupo)
USUARIOS=(
  "viriarte|Valentín Iriarte|equipo"
  "fparedes|Francisco Paredes|equipo"
  "vlozano|Valentín Lozano|equipo"
  "evillagran|Enzo Villagrán|equipo"
  "tgallo|Tiziano Gallo|equipo"
  "docente|Docente (solo lectura)|docentes-lectura"
  "n8n-bot|n8n (cuenta de servicio)|n8n-servicio"
  "sin-acceso|Usuario de prueba sin permisos|"
)

# 0. Configuración versionada (cloud/gymhub.config.php): se copia en cada corrida para aplicar cambios del repo.
docker cp "$DIR/gymhub.config.php" "$CONT:/var/www/html/config/gymhub.config.php" >/dev/null
docker exec "$CONT" chown www-data:www-data /var/www/html/config/gymhub.config.php
docker exec "$CONT" chmod 640 /var/www/html/config/gymhub.config.php
log "→ configuración cloud/gymhub.config.php aplicada"

# 1. App de carpetas de grupo (Team folders): permisos por grupo en cada carpeta.
if ! occ app:list --output=json | grep -q '"groupfolders"'; then
  log "→ Instalando la app groupfolders (Team folders)"
  occ app:install groupfolders >&2
fi
occ app:enable groupfolders >/dev/null
# Apps que no aportan a un repositorio de informes.
for app in firstrunwizard recommendations survey_client support dashboard weather_status user_status; do
  occ app:disable "$app" >/dev/null 2>&1 || true
done

# 2. Grupos.
for g in equipo docentes-lectura n8n-servicio; do
  if occ group:info "$g" >/dev/null 2>&1; then log "· grupo $g ya existe"
  else occ group:add "$g" >/dev/null; log "→ grupo $g creado"; fi
done

# 3. Usuarios (contraseña aleatoria; cada integrante la cambia al entrar).
for fila in "${USUARIOS[@]}"; do
  IFS='|' read -r usuario nombre grupo <<<"$fila"
  pass=$(rand 24)
  if ! occ user:info "$usuario" >/dev/null 2>&1; then
    args=(user:add --password-from-env --display-name "$nombre")
    [ -n "$grupo" ] && args+=(--group "$grupo")
    occ_env "$pass" "${args[@]}" "$usuario" >/dev/null
    log "→ usuario $usuario creado${grupo:+ (grupo $grupo)}"
  elif [ -n "$REGENERAR" ]; then
    occ_env "$pass" user:resetpassword --password-from-env "$usuario" >/dev/null
    log "→ usuario $usuario: contraseña regenerada"
  else
    log "· usuario $usuario ya existe"; pass=""
  fi
  [ -n "$pass" ] && guardar "{\"tipo\": \"usuario\", \"usuario\": \"$usuario\", \"nombre\": \"$nombre\", \"grupo\": \"${grupo:-(ninguno)}\", \"password\": \"$pass\"}"
  # Asegura la pertenencia aunque el usuario ya existiera.
  if [ -n "$grupo" ]; then occ group:adduser "$grupo" "$usuario" >/dev/null 2>&1 || true; fi
done

# 4. Carpetas de grupo y matriz de permisos (ver docs/SCRUM-73-74-nextcloud.md).
#    Permisos de groupfolders: read (sin argumentos), write (crear/modificar), share, delete.
id_carpeta() { # nombre → id (vacío si no existe)
  occ groupfolders:list --output=json | docker exec -i "$CONT" php -r '
    $n = $argv[1];
    foreach (json_decode(stream_get_contents(STDIN), true) as $f)   # mountPoint (v20+) o mount_point (anteriores)
      if (($f["mountPoint"] ?? $f["mount_point"] ?? null) === $n) { echo $f["id"]; break; }' "$1"
}
asegurar_carpeta() {
  local nombre="$1" id
  id=$(id_carpeta "$nombre")
  if [ -z "$id" ]; then
    id=$(occ groupfolders:create "$nombre" | tr -dc '0-9')
    log "→ carpeta $nombre creada (id $id)"
  else
    log "· carpeta $nombre ya existe (id $id)"
  fi
  [ -n "$id" ] || { echo "✖ No se pudo obtener el id de la carpeta $nombre" >&2; exit 1; }
  echo "$id"
}
# Se reaplica siempre: la matriz de este script es la fuente de verdad (corrige cambios hechos a mano en la UI).
permisos() { local id="$1" g="$2"; shift 2; occ groupfolders:group "$id" "$g" "$@" >/dev/null; }
quitar()   { occ groupfolders:group --delete "$1" "$2" >/dev/null 2>&1 || true; }

for c in "${CARPETAS[@]}"; do
  id=$(asegurar_carpeta "$c")
  permisos "$id" equipo           write share delete
  permisos "$id" docentes-lectura
  quitar   "$id" n8n-servicio
done
id=$(asegurar_carpeta "$CARPETA_IA")
permisos "$id" equipo           write share delete
permisos "$id" docentes-lectura
permisos "$id" n8n-servicio     write          # crear/modificar; sin borrar ni compartir
# El manual lo mantiene el equipo; n8n solo lo LEE (no puede alterar las instrucciones que sigue).
id=$(asegurar_carpeta "$CARPETA_MANUAL")
permisos "$id" equipo           write share delete
permisos "$id" docentes-lectura
permisos "$id" n8n-servicio
# Los diagnósticos los escribe n8n (sin borrar ni compartir).
id=$(asegurar_carpeta "$CARPETA_DIAG")
permisos "$id" equipo           write share delete
permisos "$id" docentes-lectura
permisos "$id" n8n-servicio     write
log "→ matriz de permisos aplicada a las ${#CARPETAS[@]} carpetas + $CARPETA_IA, $CARPETA_MANUAL y $CARPETA_DIAG"

# 5. Compartición: nadie publica enlaces; docentes y n8n no pueden compartir nada.
occ config:app:set core shareapi_allow_links --value=no >/dev/null
occ config:app:set core shareapi_exclude_groups --value=yes >/dev/null
occ config:app:set core shareapi_exclude_groups_list --value='["docentes-lectura","n8n-servicio"]' >/dev/null
log "→ compartición restringida (sin enlaces públicos; docentes y n8n excluidos)"

# 6. App password de n8n: token con nombre fijo y SIN la contraseña de login (no sirve para entrar a la web
#    ni para cambiar la cuenta; solo WebDAV/API). Si ya existe no se genera otro, salvo con --regenerar.
TOKEN_NOMBRE=n8n-informes-ia
ids_token() {
  occ user:auth-tokens:list n8n-bot --output=json | docker exec -i "$CONT" php -r '
    foreach (json_decode(stream_get_contents(STDIN), true) as $t)
      if ($t["name"] === $argv[1]) echo $t["id"], "\n";' "$TOKEN_NOMBRE"
}
existentes=$(ids_token)
if [ -n "$existentes" ] && [ -z "$REGENERAR" ]; then
  log "· app password de n8n ya existe (rotarla: bash infra/nextcloud/setup.sh --regenerar)"
else
  for t in $existentes; do occ user:auth-tokens:delete n8n-bot "$t" >/dev/null; done
  app_password=$(occ user:auth-tokens:add --name "$TOKEN_NOMBRE" n8n-bot </dev/null 2>/dev/null \
    | grep -Eo '^[A-Za-z0-9]{20,}$' | tail -1)
  [ -n "$app_password" ] || { echo "✖ No se pudo leer la app password de n8n" >&2; exit 1; }
  guardar "{\"tipo\": \"n8n\", \"usuario\": \"n8n-bot\", \"app_password\": \"$app_password\", \"webdav_url\": \"http://nextcloud/remote.php/dav/files/n8n-bot/$CARPETA_IA/\"}"
  log "→ app password de n8n generada ($TOKEN_NOMBRE)"
fi
