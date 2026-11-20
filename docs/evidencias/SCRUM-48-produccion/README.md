# SCRUM-48 — Migración de producción a Patroni y prueba de failover

Migración de la base de **producción** de primaria + réplica fija (streaming replication manual) al clúster **Patroni** de Enzo (etcd + 3 nodos PostgreSQL 16 + HAProxy), siguiendo la sección 8 de [docs/implementacion-patroni.MD](../../implementacion-patroni.MD). Fecha: **20/11/2026**, en el servidor del equipo, con el dataset de 6M filas por tabla (base de ~7,8 GB).

## Línea de tiempo

| Paso | Qué se hizo | Resultado |
|---|---|---|
| Preparación (app arriba) | PR #104 (rama de Enzo + `develop`) con CI en verde. `PATRONI_RESTAPI_*` agregado a `produccion/.env.prod`. Imagen `gymhub-patroni:16` construida | Patroni 4.1.4 sobre PostgreSQL 16.15, uid 70 (igual que la base anterior) |
| 1. Backup lógico | `docker exec gymhub_backup_prod /scripts/backup.sh` | **708 MB en 104 s**, `status: success`; `pg_restore --list` → 9 tablas con datos |
| **Inicio del corte** 02:08:56 | `docker stop` de backend, backup, réplica y primaria | Apagado limpio (checkpoint completo, LSN `1/A36BAD38`) |
| 2. Copia en frío | `gymhub_prod_db_data` → `gymhub_prod_db_data_pre_patroni` (plan de vuelta atrás) | 7,8 GB en **54 s** |
| 3. Limpieza | `docker rm` de los contenedores viejos y `docker volume rm gymhub_prod_db_replica_data` | — |
| 4. Líder | `up etcd pg-1`: `pg-1` **adopta** el volumen de siempre | Líder en **9 s** (timeline 2). 6M usuarios y pagos, los 4 índices de SCRUM-42 y los roles intactos. Patroni borró solo el slot viejo `standby_slot_1` |
| 5. App | `up haproxy backup backend frontend` con la versión desplegada | `/api/health` 200 en 23 s |
| **Fin del corte** 02:12:13 | | **Corte total: 3 min 17 s** |
| 6. Réplicas (app arriba) | `up pg-2 pg-3`: se clonan solas del líder | **2 réplicas en streaming, lag 0, en 52 s** |
| 7. Release | PR #105 → `main`; el CD desplegó `b062277` sobre el clúster ya sano | CD OK. Los nodos no se recrearon (el clúster se levantó desde la misma carpeta del runner que usa el CD) |
| 8. Monitoreo | `bash scripts/infra.sh levantar` y borrado del exporter de la réplica vieja | Prometheus mide `pg-1..3:8008` (job `patroni`), todos `up` |

**Por qué por etapas y no solo con el CD:** `deploy.sh` espera como máximo 240 s a que todos los servicios estén sanos. Si el clonado de las réplicas tardaba más, el CD marcaba el despliegue como fallido e intentaba un rollback en plena migración. Levantar primero el líder y la app, y después las réplicas, además acortó el corte: la app volvió antes de clonar.

## Verificación posterior

- `patronictl list`: `pg-1` Leader · `pg-2` y `pg-3` Replica `streaming`, lag 0.
- `pg-2` y `pg-3`: 6.000.000 usuarios cada una.
- App: login de admin y de socio OK; `/usuarios`, `/pagos` y `mis-rutinas` en 17–40 ms; URL pública (Funnel) 200.
- Puente de pgAdmin (`127.0.0.1:5436` → `db:5432`): llega a HAProxy y de ahí al líder (`pg_is_in_recovery = false`), sin cambiar nada del puente.
- La página de estado de HAProxy (`:7000`) no queda expuesta al host.

## Prueba de failover en producción

`bash database/patroni/failover-demo.sh prod --sin-pausa` ([failover-demo.txt](failover-demo.txt)), con un sondeo de `/api/health` cada segundo en paralelo ([sondeo-health.txt](sondeo-health.txt)).

| Medición | Resultado |
|---|---|
| Caída simulada | `docker stop gymhub_pg_1_prod` (el líder) |
| Nuevo líder | **pg-2, en 23 s** (timeline 3), sin intervención |
| Escrituras por `db:5432` | De nuevo aceptadas **25 s** después de la caída, sin cambiar configuración |
| Viejo líder | Volvió solo como **réplica en streaming** (lag 0) |
| `/api/health` durante toda la prueba | **150 de 150 respuestas 200** (las lecturas siguieron por las réplicas) |
| Monitoreo | Alerta `GymHubFailoverOcurrido` en *firing*; `changes(patroni_primary)` = 1 en pg-1 y pg-2 |

En desarrollo Enzo midió ~6 s con `docker stop`. En producción tardó 23 s: con una base de 7,8 GB y el líder bajo `docker stop` (10 s de gracia), el lock en etcd venció por `ttl` (20 s) en lugar de liberarse al apagar. Queda dentro de lo esperado para una caída abrupta (~25 s, sección 7 de la documentación).

## Estado final y limpieza pendiente

- Líder actual: **pg-2** (después de la prueba). Es indistinto: la app siempre entra por HAProxy.
- Copia de seguridad del volumen: `gymhub_prod_db_data_pre_patroni` (7,8 GB). Borrar cuando el clúster lleve unos días estable: `docker volume rm gymhub_prod_db_data_pre_patroni`.
- Backup de la configuración anterior: `produccion/.env.prod.antes-patroni` (no versionado).
