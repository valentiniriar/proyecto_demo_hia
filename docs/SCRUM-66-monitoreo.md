# SCRUM-66 — Monitoreo de GymHub en Docker

## Alcance
- Stack aislado en `infra/monitoring/docker-compose.yml`: Prometheus, Grafana, node-exporter, cAdvisor, postgres-exporter para BD primaria y blackbox-exporter.
- Interfaces de Prometheus y Grafana publicadas **solo en 127.0.0.1** y protegidas de exposición accidental a Internet; no se publican puertos de exporters.
- Volúmenes persistentes propios: `gymhub-scrum66_prometheus_data` y `gymhub-scrum66_grafana_data`.
- Usuario administrador de Grafana y contraseña en `infra/monitoring/.env` **ignorado por Git**. No capturar ni subir ese archivo.
- Datasource Prometheus provisionado automáticamente desde YAML.
- Conexión al PostgreSQL principal preexistente por `host.docker.internal` (Docker Desktop macOS) sin cambiar el contenedor o sus tablas.
- Disponibilidad local consultada mediante blackbox en endpoints `http://host.docker.internal:3000/api/health` y `http://host.docker.internal:8081/api/health`.

## Precaución sobre métricas de Docker Desktop macOS
node-exporter y cAdvisor dentro de Docker Desktop observan principalmente la VM Linux / contenedores de Docker. Sus cifras **NO son medición completa del hardware macOS**. cAdvisor puede tener limitaciones de métricas/mounts; se debe verificar el target de Prometheus antes de declararlo operativo.

## Requisitos pendientes de la consigna
- **Réplica PostgreSQL:** aún no confirmada en el entorno; integrar `postgres-exporter-replica` y el target una vez que el equipo la despliegue, y comprobar `pg_up`.
- **URL pública:** aún no confirmada; agregar la URL HTTPS pública al job de blackbox cuando se configure el túnel/deploy, y verificar `probe_success`.
- Para una instalación escalable, emplear un usuario PostgreSQL de monitoreo con permisos mínimos en lugar de credenciales de desarrollo reutilizadas temporalmente.

## Instalación y pruebas
```bash
bash ~/Downloads/SCRUM66_instalar_monitoreo.sh
# Revisar targets de Prometheus, todos los servicios principales deberían figurar UP.
# Verificar en Prometheus: pg_up, probe_success, up.
```
El script da las URL y muestra el resumen de targets. Verificar también `docker compose -f infra/monitoring/docker-compose.yml ps` y que Grafana tenga su datasource verde, sin mostrar la contraseña en evidencias.

**No usar** `docker compose down -v` ni borrar los volúmenes del stack. En caso de reinicio: `cd infra/monitoring && docker compose up -d` (desde la raíz del repositorio; así se carga el `.env` local de ese directorio).

## Estado de prueba
Instalación y pruebas realizadas el 12/11/2026: Grafana conectada a Prometheus, PostgreSQL con pg_up=1, sondas locales con probe_success=1 y cAdvisor v0.60.6 con métricas individuales. Pendiente completar réplica PostgreSQL y URL pública.


## Actualización de cAdvisor (12/11/2026)

Se actualizó cAdvisor de v0.52.1 a v0.60.6 para resolver
la incompatibilidad con el almacenamiento containerd de Docker Desktop.

Prometheus detectó 9 series individuales de CPU correspondientes
a identificadores de contenedores Docker.

Se verificaron PostgreSQL Exporter (pg_up=1), Blackbox para las
rutas locales de salud, Grafana y Prometheus.

La evidencia de verificación se conserva localmente.

### Limitaciones pendientes
- Agregar el monitoreo de la réplica PostgreSQL cuando esté disponible.
- Agregar la URL pública cuando el despliegue esté preparado.
- El montaje del socket Docker es exclusivo del laboratorio local.
  No debe utilizarse sin una revisión de seguridad en producción.
