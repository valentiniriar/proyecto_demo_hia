#!/usr/bin/env bash
# Reporte de disponibilidad y errores de la publicación en Internet (SCRUM-85).
#
#   bash infra/monitoring/reporte-disponibilidad.sh [ventana] [archivo_salida]
#   ej.: bash infra/monitoring/reporte-disponibilidad.sh 48h docs/evidencias/SCRUM-85/reporte-48h.md
#
# Fuentes: Prometheus (sondas blackbox de la URL pública y métricas de cloudflared) y
# los logs de Docker de Nginx (5xx) y cloudflared (cortes del túnel).
set -euo pipefail
export MSYS_NO_PATHCONV=1

VENTANA="${1:-48h}"
SALIDA="${2:-/dev/stdout}"
PROM="${PROM_URL:-http://localhost:9090}"
FRONT="${FRONT_CONTAINER:-gymhub_frontend_dev}"
TUNEL="${TUNEL_CONTAINER:-$(docker ps --format '{{.Names}}' | grep -E '^gymhub_cloudflared(_rapido)?$' | head -1 || true)}"

q() { # consulta instantánea a Prometheus → primer valor o "sin datos"
  curl -s --get "$PROM/api/v1/query" --data-urlencode "query=$1" |
    node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{const r=JSON.parse(s).data.result;console.log(r.length?r[0].value[1]:'sin datos')}catch{console.log('sin datos')}})"
}
num() { node -e "const v=process.argv[1];console.log(isNaN(+v)?v:(+v).toFixed(+process.argv[2]))" "$1" "${2:-2}"; }

INST=$(curl -s "$PROM/api/v1/targets?state=active" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{const t=JSON.parse(s).data.activeTargets.filter(t=>t.labels.job==='blackbox-publico');console.log(t.map(x=>x.labels.instance+' ('+x.health+')').join(', ')||'ninguno')}catch{console.log('Prometheus no disponible')}})")

DISP=$(num "$(q "avg_over_time(probe_success{job=\"blackbox-publico\"}[$VENTANA]) * 100")" 3)
SONDAS=$(num "$(q "count_over_time(probe_success{job=\"blackbox-publico\"}[$VENTANA])")" 0)
FALLAS=$(num "$(q "count_over_time((probe_success{job=\"blackbox-publico\"} == 0)[$VENTANA:30s])")" 0)
LAT_AVG=$(num "$(q "avg_over_time(probe_duration_seconds{job=\"blackbox-publico\"}[$VENTANA])")" 3)
LAT_MAX=$(num "$(q "max_over_time(probe_duration_seconds{job=\"blackbox-publico\"}[$VENTANA])")" 3)
CERT=$(num "$(q "(probe_ssl_earliest_cert_expiry{job=\"blackbox-publico\"} - time()) / 86400")" 1)
CONEX=$(num "$(q "cloudflared_tunnel_ha_connections")" 0)
REQS=$(num "$(q "increase(cloudflared_tunnel_total_requests[$VENTANA])")" 0)
ERRS=$(num "$(q "increase(cloudflared_tunnel_request_errors[$VENTANA])")" 0)
ALERTAS=$(curl -s "$PROM/api/v1/alerts" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{const a=JSON.parse(s).data.alerts.filter(a=>a.labels.component==='publicacion');console.log(a.map(x=>x.labels.alertname+'='+x.state).join(', ')||'ninguna')}catch{console.log('-')}})")

SINCE="${VENTANA}"
E5XX=$(docker logs --since "$SINCE" "$FRONT" 2>/dev/null | grep -cE '" 5[0-9]{2} ' || true)
E5XX_DET=$(docker logs --since "$SINCE" "$FRONT" 2>/dev/null | grep -E '" 5[0-9]{2} ' | tail -5 | sed -E 's/^[0-9.]+ /<ip> /' || true)
if [ -n "$TUNEL" ]; then
  CORTES=$(docker logs --since "$SINCE" "$TUNEL" 2>&1 | grep -ciE 'Connection terminated|Unregistered tunnel connection|failed to (dial|serve)|Retrying connection' || true)
  CORTES_DET=$(docker logs --since "$SINCE" "$TUNEL" 2>&1 | grep -iE 'Connection terminated|Unregistered tunnel connection|failed to (dial|serve)|Retrying connection|Registered tunnel connection' | tail -8 || true)
  # Errores hacia el origen (Nginx caído o inalcanzable): Cloudflare responde 502 al visitante.
  ORIGEN=$(docker logs --since "$SINCE" "$TUNEL" 2>&1 | grep -c 'ERR Request failed' || true)
  ORIGEN_DET=$(docker logs --since "$SINCE" "$TUNEL" 2>&1 | grep 'ERR Request failed' | cut -c1-150 | tail -5 || true)
else
  CORTES="(túnel no levantado)"; CORTES_DET=""; ORIGEN="-"; ORIGEN_DET=""
fi

{
cat <<EOF
# Reporte de disponibilidad de la publicación — ventana $VENTANA

Generado: $(date '+%Y-%m-%d %H:%M %Z') con \`infra/monitoring/reporte-disponibilidad.sh\`

| Indicador | Valor |
|---|---|
| URL monitoreada (blackbox-publico) | $INST |
| **Disponibilidad** (\`avg_over_time(probe_success)\`) | **$DISP %** |
| Sondas realizadas / fallidas (cada 30 s) | $SONDAS / $FALLAS |
| Latencia de la sonda: promedio / máxima | $LAT_AVG s / $LAT_MAX s |
| Días hasta el vencimiento del certificado HTTPS | $CERT |
| Conexiones activas del túnel con Cloudflare | $CONEX |
| Requests servidos por el túnel / con error hacia el origen | $REQS / $ERRS |
| Respuestas 5xx registradas por Nginx | $E5XX |
| Requests que el túnel no pudo entregar al origen (cloudflared → 502 al visitante) | $ORIGEN |
| Eventos de corte/reconexión del túnel (logs de cloudflared) | $CORTES |
| Alertas de publicación activas ahora | $ALERTAS |

## Últimas respuestas 5xx (Nginx)

\`\`\`
${E5XX_DET:-(ninguna)}
\`\`\`

## Errores hacia el origen (cloudflared)

\`\`\`
${ORIGEN_DET:-(ninguno)}
\`\`\`

## Eventos del túnel (cloudflared)

\`\`\`
${CORTES_DET:-(ninguno)}
\`\`\`
EOF
} > "$SALIDA"
[ "$SALIDA" = /dev/stdout ] || echo "✔ Reporte escrito en $SALIDA"
