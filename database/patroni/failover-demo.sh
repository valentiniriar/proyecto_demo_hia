#!/usr/bin/env bash
# Demo de failover automático con Patroni (docs/implementacion-patroni.MD).
#
#   bash database/patroni/failover-demo.sh [dev|devb|prod] [--sin-pausa]
#
#     dev   Forma A, docker-compose.yml          (contenedores demo_hia_pg_1..3)   ← por defecto
#     devb  Forma B, compose.yaml + compose.dev  (contenedores gymhub_pg_N_dev)
#     prod  servidor de producción               (contenedores gymhub_pg_N_prod)   ¡solo en ventana acordada!
#
# Qué hace (no deja datos en la base):
#   1. Muestra el cluster y quién es el líder.
#   2. Detiene el contenedor del líder (simula que se cae el maestro).
#   3. Espera a que Patroni promueva una réplica y mide cuántos segundos tardó.
#   4. Prueba una escritura por HAProxy ("db:5432") con una tabla temporal: solo el líder la acepta.
#   5. Vuelve a encender el viejo líder y espera a que se reincorpore solo como réplica.
set -euo pipefail
# Git Bash (Windows) convierte rutas tipo /etc/patroni/... a C:/Program Files/Git/...: desactivarlo.
export MSYS_NO_PATHCONV=1

ENTORNO="${1:-dev}"
PAUSA=1; [ "${2:-}" = "--sin-pausa" ] && PAUSA=0
case "$ENTORNO" in
  dev)  contenedor() { echo "demo_hia_pg_${1#pg-}"; } ;;
  devb) contenedor() { echo "gymhub_pg_${1#pg-}_dev"; } ;;
  prod) contenedor() { echo "gymhub_pg_${1#pg-}_prod"; } ;;
  *) echo "Uso: $0 [dev|devb|prod] [--sin-pausa]"; exit 1 ;;
esac
NODOS=(pg-1 pg-2 pg-3)

paso() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
pausa() { [ "$PAUSA" = 1 ] && read -rp "   (Enter para seguir) " _ || true; }

# Corre patronictl en el primer nodo que esté encendido.
patronictl_en() {
  local n c
  for n in "${NODOS[@]}"; do
    c=$(contenedor "$n")
    if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ]; then
      docker exec "$c" patronictl -c /etc/patroni/patroni.yml "$@" && return 0
    fi
  done
  return 1
}
# Salida tsv de patronictl: Cluster, Member, Host, Role, State, TL, … (sin depender de python ni jq).
lider() {
  patronictl_en list -f tsv 2>/dev/null | awk -F'\t' '$4=="Leader" && $5=="running" {print $2; exit}'
}
estado_de() {
  patronictl_en list -f tsv 2>/dev/null | awk -F'\t' -v n="$1" '$2==n {print $4" "$5; f=1; exit} END {if (!f) print "ausente"}'
}

paso "1. Estado inicial del cluster"
patronictl_en list
VIEJO=$(lider)
[ -n "$VIEJO" ] || { echo "✖ No hay líder: revisar el cluster antes de la demo."; exit 1; }
echo "   Líder actual: $VIEJO ($(contenedor "$VIEJO"))"
pausa

paso "2. Se cae el maestro: docker stop $(contenedor "$VIEJO")"
INICIO=$(date +%s)
docker stop "$(contenedor "$VIEJO")" >/dev/null
echo "   Detenido. Las escrituras fallan hasta que Patroni elija un nuevo líder…"

paso "3. Esperando que una réplica tome el control"
NUEVO=""
for _ in $(seq 1 60); do
  NUEVO=$(lider || true)
  if [ -n "$NUEVO" ] && [ "$NUEVO" != "$VIEJO" ]; then break; fi
  printf '.'; sleep 1
done
echo
[ -n "$NUEVO" ] && [ "$NUEVO" != "$VIEJO" ] || { echo "✖ Nadie tomó el control en 60 s."; patronictl_en list || true; exit 1; }
echo "   ✔ Nuevo líder: $NUEVO, en $(( $(date +%s) - INICIO )) s"
patronictl_en list

paso "4. La app sigue escribiendo por HAProxy (db:5432), sin cambiar configuración"
# HAProxy marca al nuevo líder como activo después de 2 chequeos OK (inter 2s × rise 2): unos segundos.
ESCRIBIO=0
for _ in $(seq 1 15); do
  if docker exec "$(contenedor "$NUEVO")" sh -c '
      PGPASSWORD="$PATRONI_SUPERUSER_PASSWORD" psql -h db -p 5432 -U "$PATRONI_SUPERUSER_USERNAME" -d "$DB_NAME" -At -v ON_ERROR_STOP=1 \
        -c "CREATE TEMP TABLE prueba_failover (x int); INSERT INTO prueba_failover VALUES (1);" \
        -c "SELECT '"'"'   escritura OK en '"'"' || inet_server_addr() || '"'"' (en recuperación: '"'"' || pg_is_in_recovery() || '"'"')'"'"'"' 2>/dev/null; then
    ESCRIBIO=1; break
  fi
  printf '.'; sleep 1
done
[ "$ESCRIBIO" = 1 ] && echo "   ✔ La base volvió a aceptar escrituras $(( $(date +%s) - INICIO )) s después de la caída" \
  || echo "   ⚠ HAProxy todavía no enruta al nuevo líder: ver http://localhost:7000"
pausa

paso "5. Vuelve el viejo maestro: docker start $(contenedor "$VIEJO")"
docker start "$(contenedor "$VIEJO")" >/dev/null
for _ in $(seq 1 90); do
  ESTADO=$(estado_de "$VIEJO" || true)
  case "$ESTADO" in "Replica streaming") break ;; esac
  printf '.'; sleep 2
done
echo
echo "   $VIEJO quedó como: ${ESTADO:-desconocido}"
patronictl_en list
[ "${ESTADO:-}" = "Replica streaming" ] && echo "   ✔ Se reincorporó solo como réplica (pg_rewind o reclonado automático)." \
  || echo "   ⚠ Todavía no está en streaming: ver docker logs $(contenedor "$VIEJO")"
