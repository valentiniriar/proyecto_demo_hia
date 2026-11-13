# SCRUM-68 — Alertas Prometheus + Alertmanager (GymHub)

## Alcance de esta primera versión

- Ocho reglas versionadas para disponibilidad (API, frontend, exporters, PostgreSQL)
  y capacidad (CPU, RAM y disco de Linux de Docker Desktop; conexiones de PostgreSQL).
- Umbrales iniciales: disponibilidad 1-2 min, CPU > 85%/10 min,
  RAM > 90%/10 min, disco > 90%/10 min, conexiones > 80/5 min.
- Alertmanager en red interna `monitoring`, interfaz solo en `127.0.0.1:9093`,
  datos persistentes en volumen. Sin credenciales versionadas.
- Receptor de laboratorio **sin notificaciones externas**. No se afirma
  integración con n8n/Mantis hasta que exista el webhook autenticado de SCRUM-76.

## Métricas y límites

- `probe_success` se obtiene de blackbox (dos URL locales), `pg_up` de postgres exporter;
  `up` detecta fallos de scraping de exporters.
- CPU/RAM/disco miden principalmente la VM Linux de Docker Desktop, no todo macOS.
- **Pendiente**: reinicios reales de contenedores; no hay un contador validado.
- **Pendiente**: replica desconectada y lag alto. Las métricas de réplica todavía
  no están integradas al stack de monitoreo local (SCRUM-45/46/66).
- Si un exporter no publica una serie, la regla basada en esa serie no dispara.
  Validar disponibilidad real de métricas antes de afirmar cobertura.

## Validación segura

Desde la raíz del repo:

```bash
docker compose -f infra/monitoring/docker-compose.yml config --quiet

docker run --rm --entrypoint /bin/promtool \
  -v "$PWD/infra/monitoring/prometheus:/etc/prometheus:ro" \
  prom/prometheus:v3.5.0 check config /etc/prometheus/prometheus.yml

docker run --rm --entrypoint /bin/amtool \
  -v "$PWD/infra/monitoring/alertmanager:/etc/alertmanager:ro" \
  prom/alertmanager:v0.28.1 check-config /etc/alertmanager/alertmanager.yml
```

Luego de comprobar sintaxis, incorporar Alertmanager y recargar solo Prometheus;
antes de la demo no detener la aplicación ni forzar alta carga real. La prueba
controlada de alerta y recuperación se documentará con evidencias.

## Pendiente de integración

Conectar Alertmanager a webhook **autenticado** de n8n (SCRUM-76), con validación
por cabecera, deduplicación `fingerprint`, creación Mantis y notificación.
No publicar credenciales ni URLs con tokens en el repositorio.

## Seguridad

No correr `docker compose down -v`, no borrar volúmenes, no modificar PostgreSQL.
Alertmanager solo escucha en `127.0.0.1` para acceso al navegador local.
