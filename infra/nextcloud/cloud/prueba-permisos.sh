#!/usr/bin/env bash
# Prueba de la matriz de permisos de Nextcloud (SCRUM-73/74) por WebDAV, con las cuentas reales.
#   bash infra/nextcloud/cloud/prueba-permisos.sh
#
# Lee las contraseñas de infra/nextcloud/credenciales.local.json (generado por setup.sh) y guarda el resultado,
# SIN contraseñas, en docs/evidencias/SCRUM-73-74/prueba-permisos-<fecha>.txt. Sale con error si algo no da lo esperado.
# Deja todo como estaba: borra los archivos de prueba que crea.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../../.."

CRED=infra/nextcloud/credenciales.local.json
PORT=$(grep -E '^NEXTCLOUD_HOST_PORT=' infra/nextcloud/.env 2>/dev/null | cut -d= -f2-)
BASE="http://127.0.0.1:${PORT:-8082}/remote.php/dav/files"
[ -f "$CRED" ] || { echo "✖ Falta $CRED: correr bash infra/nextcloud/setup.sh (o --regenerar)"; exit 1; }

pass_de() { grep "\"tipo\": \"usuario\", \"usuario\": \"$1\"" "$CRED" | sed -E 's/.*"password": "([^"]+)".*/\1/'; }
APP=$(grep '"tipo": "n8n"' "$CRED" | sed -E 's/.*"app_password": "([^"]+)".*/\1/')
P_EQUIPO=$(pass_de evillagran); P_DOCENTE=$(pass_de docente); P_SIN=$(pass_de sin-acceso)
for v in APP P_EQUIPO P_DOCENTE P_SIN; do
  [ -n "${!v}" ] || { echo "✖ Falta una credencial en $CRED: correr bash infra/nextcloud/setup.sh --regenerar"; exit 1; }
done

DIAG='01-Diagn%C3%B3stico'; OPT='05-Optimizaci%C3%B3n'; IA='Informes-IA'
MARCA=$(date +%Y%m%d-%H%M%S)
SALIDA_DIR=docs/evidencias/SCRUM-73-74; mkdir -p "$SALIDA_DIR"
SALIDA="$SALIDA_DIR/prueba-permisos-$MARCA.txt"
fallas=0

# dav usuario contraseña método ruta [archivo-de-cuerpo] → código HTTP
dav() {
  local u="$1" p="$2" m="$3" r="$4" cuerpo="${5:-}" extra=()
  [ "$m" = PROPFIND ] && extra=(-H 'Depth: 1')
  [ -n "$cuerpo" ] && extra+=(--data-binary "@$cuerpo")
  curl -s -o /dev/null -w '%{http_code}' --max-time 20 -u "$u:$p" -X "$m" "${extra[@]}" "$BASE/$u/$r"
}
# caso descripción esperados(regex) obtenido
caso() {
  local estado="OK"
  [[ "$3" =~ ^($2)$ ]] || { estado="FALLA"; fallas=$((fallas + 1)); }
  printf '%-6s %-78s esperado %-11s obtenido %s\n' "$estado" "$1" "$2" "$3" | tee -a "$SALIDA"
}

TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
printf '# Informe IA de prueba (SCRUM-73/74)\nGenerado por prueba-permisos.sh el %s.\n' "$MARCA" > "$TMP"
F="prueba-permisos-$MARCA.md"

{
  echo "Prueba de matriz de permisos · Nextcloud GymHub · $(date '+%d/%m/%Y %H:%M')"
  echo "Servidor: $BASE  ·  Contraseñas leídas de $CRED (no se registran)"
  echo
} > "$SALIDA"

echo "── n8n-bot (grupo n8n-servicio, con app password) ──" | tee -a "$SALIDA"
raiz=$(curl -s --max-time 20 -u "n8n-bot:$APP" -X PROPFIND -H 'Depth: 1' "$BASE/n8n-bot/")
visibles=$(echo "$raiz" | grep -o '<d:href>[^<]*</d:href>' | sed -E 's#.*/n8n-bot/([^<]*)</d:href>#\1#; s#/$##' | grep -v '^$' | tr '\n' ' ')
echo "       Carpetas que ve en su raíz: ${visibles:-(ninguna)}" | tee -a "$SALIDA"
caso "n8n-bot ve SOLO Informes-IA en su raíz"                        "Informes-IA" "$(echo "$visibles" | xargs)"
caso "n8n-bot sube un informe a Informes-IA (PUT)"                   "201"         "$(dav n8n-bot "$APP" PUT "$IA/$F" "$TMP")"
caso "n8n-bot modifica su informe (PUT sobre el mismo archivo)"      "204"         "$(dav n8n-bot "$APP" PUT "$IA/$F" "$TMP")"
caso "n8n-bot NO puede borrar en Informes-IA (DELETE)"               "403"         "$(dav n8n-bot "$APP" DELETE "$IA/$F")"
caso "n8n-bot NO accede a 01-Diagnóstico (PROPFIND)"                 "404"         "$(dav n8n-bot "$APP" PROPFIND "$DIAG/")"
caso "n8n-bot NO puede escribir en 01-Diagnóstico (PUT)"             "403|404|409" "$(dav n8n-bot "$APP" PUT "$DIAG/x.md" "$TMP")"
comp=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -u "n8n-bot:$APP" -H 'OCS-APIRequest: true' \
  -X POST "${BASE%/remote.php/dav/files}/ocs/v2.php/apps/files_sharing/api/v1/shares" \
  --data-urlencode "path=/$IA/$F" -d shareType=3)
caso "n8n-bot NO puede crear un enlace público (OCS shares)"         "403|404"     "$comp"

echo "── docente (grupo docentes-lectura) ──" | tee -a "$SALIDA"
caso "docente lee el informe de Informes-IA (GET)"                   "200"         "$(dav docente "$P_DOCENTE" GET "$IA/$F")"
caso "docente lista 05-Optimización (PROPFIND)"                      "207"         "$(dav docente "$P_DOCENTE" PROPFIND "$OPT/")"
caso "docente NO puede subir a 05-Optimización (PUT)"                "403"         "$(dav docente "$P_DOCENTE" PUT "$OPT/$F" "$TMP")"
caso "docente NO puede borrar en Informes-IA (DELETE)"               "403"         "$(dav docente "$P_DOCENTE" DELETE "$IA/$F")"

echo "── sin-acceso (usuario válido sin ningún grupo): ACCESO DENEGADO ──" | tee -a "$SALIDA"
caso "sin-acceso se autentica pero su raíz está vacía (PROPFIND)"    "207"         "$(dav sin-acceso "$P_SIN" PROPFIND "")"
caso "sin-acceso NO ve Informes-IA (PROPFIND)"                       "404"         "$(dav sin-acceso "$P_SIN" PROPFIND "$IA/")"
caso "sin-acceso NO lee el informe (GET)"                            "404"         "$(dav sin-acceso "$P_SIN" GET "$IA/$F")"
caso "sin-acceso NO entra en el espacio de otro usuario (n8n-bot)"   "401|403|404" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -u "sin-acceso:$P_SIN" -X PROPFIND -H 'Depth: 1' "$BASE/n8n-bot/$IA/")"

echo "── evillagran (grupo equipo) ──" | tee -a "$SALIDA"
caso "equipo sube a 05-Optimización (PUT)"                           "201"         "$(dav evillagran "$P_EQUIPO" PUT "$OPT/$F" "$TMP")"
caso "equipo borra su archivo de 05-Optimización (DELETE)"           "204"         "$(dav evillagran "$P_EQUIPO" DELETE "$OPT/$F")"
caso "equipo borra el informe de n8n en Informes-IA (limpieza)"      "204"         "$(dav evillagran "$P_EQUIPO" DELETE "$IA/$F")"

{
  echo
  if [ "$fallas" -eq 0 ]; then echo "RESULTADO: todas las pruebas dieron lo esperado."
  else echo "RESULTADO: $fallas prueba(s) NO dieron lo esperado."; fi
} | tee -a "$SALIDA"
echo "Evidencia guardada en $SALIDA"
[ "$fallas" -eq 0 ]
