#!/usr/bin/env bash
# Genera la configuración de monitoreo de PRODUCCIÓN a partir de la de laboratorio (SCRUM-61).
#
#   bash infra/monitoring/generar-prod.sh
#
# Los originales (prometheus.yml, alerts/gymhub.rules.yml, dashboards/gymhub-overview.json) siguen
# siendo la fuente de verdad del equipo. Este script solo reemplaza los destinos de laboratorio por
# los del stack de producción (proyecto Compose "gymhub", redes gymhub_prod_*):
#
#   http://host.docker.internal:3000/api/health  → http://backend:3000/api/health   (backend)
#   http://host.docker.internal:8081/api/health  → http://frontend:8080/api/health  (Nginx)
#   base demo_hia                                → base gymhub
#   métricas del túnel por host.docker.internal  → cloudflared-rapido:2000 (red de producción)
#
# Volver a ejecutarlo después de cambiar cualquiera de los originales.
set -euo pipefail
cd "$(dirname "$0")"

BACK_DEV='http://host.docker.internal:3000/api/health'
FRONT_DEV='http://host.docker.internal:8081/api/health'
BACK_PROD='http://backend:3000/api/health'
FRONT_PROD='http://frontend:8080/api/health'

reemplazar() { sed -e "s#$BACK_DEV#$BACK_PROD#g" -e "s#$FRONT_DEV#$FRONT_PROD#g" "$@"; }

# 1. Prometheus
{
  echo "# GENERADO por infra/monitoring/generar-prod.sh a partir de prometheus.yml. No editar a mano."
  reemplazar prometheus/prometheus.yml \
    | sed -e 's#/etc/prometheus/alerts/gymhub.rules.yml#/etc/prometheus/alerts/gymhub.rules.prod.yml#' \
    | awk '
        /- job_name: cloudflared/ { print; print "    static_configs:"; print "      - targets: [\x27cloudflared-rapido:2000\x27]"; skip=1; next }
        skip && /^  - job_name:/ { skip=0 }
        skip && /^[^ ]/ { skip=0 }
        !skip { print }'
} > prometheus/prometheus.prod.yml

# 2. Reglas de alerta
{
  echo "# GENERADO por infra/monitoring/generar-prod.sh a partir de gymhub.rules.yml. No editar a mano."
  reemplazar prometheus/alerts/gymhub.rules.yml | sed -e 's/datname="demo_hia"/datname="gymhub"/g'
} > prometheus/alerts/gymhub.rules.prod.yml

# 3. Dashboard de Grafana (uid y título propios para convivir con el de laboratorio)
reemplazar grafana/dashboards/gymhub-overview.json \
  | sed -e 's/demo_hia/gymhub/g' \
  | node -e '
      const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
      d.uid = "gymhub-overview-prod";
      d.title = "GymHub | Producción";
      d.id = null;
      process.stdout.write(JSON.stringify(d, null, 2) + "\n");' \
  > grafana/dashboards/gymhub-overview-prod.json

echo "✔ Generados: prometheus/prometheus.prod.yml, prometheus/alerts/gymhub.rules.prod.yml, grafana/dashboards/gymhub-overview-prod.json"
