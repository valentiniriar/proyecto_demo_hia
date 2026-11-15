# Documento técnico n.º 11 — Manual de monitoreo GymHub

## Arquitectura

Prometheus consulta a node-exporter, cAdvisor, postgres-exporter y blackbox-exporter; Grafana visualiza los datos; las reglas de Prometheus notifican a Alertmanager. En el laboratorio se verificó un receptor local de Alertmanager hacia n8n, que registra alertas en Mantis y envía correos a Mailpit. No asumir que el archivo de Alertmanager versionado activa esa ruta: el receptor local debe configurarse sin incorporar secretos al repositorio.

## Servicios y acceso (solo loopback)

- Prometheus: `http://127.0.0.1:9090` — pestañas Status > Targets y Alerts
- Grafana: `http://127.0.0.1:3001` — dashboard `gymhub-overview`
- Alertmanager: `http://127.0.0.1:9093` — alertas agrupadas y receptor
- n8n: `http://127.0.0.1:5679` — ejecuciones/error workflow
- Mantis: `http://127.0.0.1:8990` — incidencia generada
- Mailpit: `http://127.0.0.1:8026` — correo de laboratorio, no notificación externa

## Verificación reproducible (solo lectura)

1. Ejecutar `docker ps` y verificar que Prometheus, Grafana, Alertmanager y sus exporters estén en ejecución.
2. Abrir `/api/v1/targets` de Prometheus: target por target debe figurar `health=up`. Targets inexistentes NO cuentan como OK.
3. Consultar `pg_up{job="postgres-primary"}` y, una vez habilitado el cluster, `pg_up{job="postgres-replica"}`. Confirmar replicación con `pg_stat_replication` en primario y `pg_is_in_recovery()` en réplica, sin insertar registros de prueba.
4. Consultar `probe_success{job="blackbox-local-health"}`. URL pública requiere `probe_success{job="blackbox-publico"}` con series reales; sin series está pendiente.
5. En Grafana revisar datos reales de CPU, RAM, disco, red, contenedores, TPS, cache hit ratio y conexiones. Los indicadores basados en `container_start_time_seconds` **no** equivalen a todos los reinicios Docker.
6. En Prometheus comprobar reglas cargadas y su estado. `0 firing` sin incidente no demuestra que la regla haya disparado: se requiere evidencia de entrada a `firing` y recuperación, conservando el sistema disponible o coordinando la prueba.
7. En Alertmanager comprobar el receptor activo con `/api/v2/status`. El archivo local con credenciales no debe versionarse. Para n8n, comprobar logs de ejecución, incidencia Mantis y correo en Mailpit.

## Alertas y niveles

- Crítica: backend/frontend no disponible, PostgreSQL caído o réplica desconectada; avisar al responsable y verificar estado antes de intervenir.
- Advertencia: CPU/RAM/disco altos, conexiones PostgreSQL altas o latencia pública. Umbrales iniciales de laboratorio, sujetos a revisión.
- No se ejecutan automáticamente reinicios, restauraciones, eliminación de datos ni failover: requieren aprobación humana y plan de recuperación.

## Limitaciones y pendientes de aceptación

- Las capturas deben mostrar fecha, consulta, valor y fuente; no reemplazarlas por capturas de paneles sin datos.
- La réplica y el lag requieren exporter y métricas reales. `pg_up=1` solo confirma conexión; no es prueba de streaming o lag.
- `pg_stat_statements` necesita habilitación y exportación efectiva para consultas lentas.
- Reinicios Docker requieren comparación fiable con `RestartCount`, y la prueba de disparo real de regla Prometheus necesita un recorrido firing → Alertmanager → n8n → Mantis → resolved.
- La URL pública y el túnel pueden ser efímeros: registrar la fecha y sondeo realmente activo.

## Seguridad y operación

No subir `.env`, `Authorization`, tokens, capturas de 2FA ni credenciales. El script `GYMHUB_cierre_integral_auto.py` realiza comprobaciones de solo lectura y prepara cambios en otra rama únicamente si confirma una réplica operativa; no ejecuta la prueba de inserción incluida en `database/replication/verify-replication.sh`, no reinicia servicios y no sustituye un ensayo integral de la demo.

## SCRUM-66/67/68 — exporter de réplica independiente

El laboratorio inicializa un **standby externo al Compose del monitoreo**, denominado
`gymhub-replica-verificada`, en la red privada `proyecto_demo_hia-main_default`.
El primario existente `demo_hia_db` no se recrea ni se reinicia.

Cuando el standby ya está operativo, el exporter se incorpora **sin puertos publicados**
con el archivo `infra/monitoring/docker-compose.replica.yml`, siempre junto al
`docker-compose.yml` original. Debe existir en la misma carpeta un archivo local
`infra/monitoring/.env.replica` (IGNORADO POR GIT) con las credenciales de
monitorización autorizadas. **No copiar ese archivo al repositorio ni adjuntarlo**.

Desde `infra/monitoring/`, para reconstruir solamente el exporter en otro entorno
que tenga la misma red/nombre de réplica:

```bash
docker compose -f docker-compose.yml -f docker-compose.replica.yml --env-file .env up -d --no-deps postgres-exporter-replica
```

Verificar tanto `up{job="postgres-replica"}` como `pg_up{job="postgres-replica"}`
iguales a 1. El target puede estar UP sin acreditar que el servidor sea standby;
comprobar `pg_replication_is_replica{job="postgres-replica"}` y
`pg_stat_replication` desde el primario. La serie `pg_replication_lag_seconds`
solo se considera disponible si Prometheus devuelve un valor real.

El uso de `changes(container_start_time_seconds)` detecta cambios observados,
no es un contador fiable de reinicios históricos. Esta variante de laboratorio
requiere adaptar red/nombres para un equipo diferente; no sustituye un deployment
reproducible de la réplica real ni una prueba de failover. La prueba end-to-end
firing→resolved y los paneles SQL lentos siguen sujetos a datos y mantenimiento reales.
