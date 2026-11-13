# SCRUM-67 — Dashboard de Grafana para GymHub

- Dashboard JSON: `infra/monitoring/grafana/dashboards/gymhub-overview.json`.
- Provisioning: `infra/monitoring/grafana/provisioning/dashboards/gymhub.yml`.
- Datasource: `Prometheus-GymHub`, enlazado por variable `DS_PROMETHEUS` para conservar el UID ya existente en Grafana.
- Endpoint local: `http://localhost:3001/d/gymhub-overview`.

## Métricas implementadas
- Disponibilidad de backend y frontend via Blackbox; `pg_up` primario.
- CPU, memoria, disco y red del entorno Linux de Docker Desktop (no todo el hardware macOS).
- CPU y memoria de contenedores identificados por `/docker/<ID>`.
- TPS, cache hit ratio, tamaño de BD y sesiones para PostgreSQL primario.

## Límites y métricas pendientes
- **Reinicios de contenedores**: aún no hay contador fiable verificado.
- **Consultas SQL lentas**: no hay integración `pg_stat_statements` verificada.
- **Replicación**: exporter de réplica y lag pendientes de integración y datos reales.
- Algunas métricas de `node-exporter` o `postgres-exporter` pueden dar "No data" por permisos o montajes. Verificar antes de afirmar que están cubiertas.

## Validación local
Desde la raíz del repo: `docker compose -f infra/monitoring/docker-compose.yml config --quiet`.
Para cargar los archivos **sin reiniciar otros servicios**, recrear solamente Grafana:
`docker compose -f infra/monitoring/docker-compose.yml up -d --no-deps --force-recreate grafana`.
Abrir `http://localhost:3001/d/gymhub-overview` y tomar capturas con métricas reales.

**Seguridad:** no subir `infra/monitoring/.env`, contraseñas ni códigos de recuperación. No exponer Grafana ni Prometheus a Internet.

## Corrección de compatibilidad
- Se conserva el datasource original de SCRUM-66 y su UID almacenado en Grafana.
- Se utiliza una variable de tipo datasource (`DS_PROMETHEUS`) para que el mismo dashboard funcione con instalaciones existentes y nuevas sin migrar ni borrar datos.
- No volver a ejecutar el script inicial `SCRUM67_crear_dashboard.py` porque reintroduce el UID incompatible.
