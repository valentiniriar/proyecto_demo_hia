# SCRUM-67 — Métrica observacional de cambios de inicio de contenedores

**Generado:** 2026-11-14T14:33:59-03:00

## Verificaciones automáticas (solo lectura)

- Prometheus local consultado mediante API HTTP GET.
- Consulta de inspección: `changes(container_start_time_seconds{job="cadvisor"}[1h])`.
- Series con muestra devuelta: **26**.
- Valor agregado al momento de la verificación: **0**.
- El cambio del dashboard afecta exclusivamente al panel ID 17; se conservan los demás paneles, UID y variable de datasource.
- Consulta del panel: `sum(changes(container_start_time_seconds{job="cadvisor"}[1h]))`.
- Grafana no se reinició ni recargó; el cambio se publica en el repositorio y debe aplicarse al entorno de laboratorio de forma controlada.

## Limitación importante

Este indicador cuenta **cambios observados en las series actuales**, no los reinicios reales de todos los contenedores. Cuando cambia el ID, se pierde una serie, hay discontinuidades de scraping o el contenedor queda fuera del target, algunos reinicios pueden no verse. Un valor 0 **no** significa cero reinicios reales. Para declarar cumplido el criterio de reinicios se necesita cruzarlo con una fuente fiable, como `docker inspect` y su `RestartCount` por contenedor o un exporter especializado, y documentar una prueba reproducible no destructiva.

## Pendientes ajenos a este PR

- Panel de consultas lentas: todavía no hay series comprobadas de `pg_stat_statements`.
- Panel de réplica: aún no existe el exporter/job `postgres-replica` operativo.
- Este PR **no** cierra SCRUM-67, ni reinicia contenedores, ni inventa eventos.
