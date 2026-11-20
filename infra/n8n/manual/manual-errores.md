# Manual de errores de GymHub (producción)

Versión 1.0 · actualizado 2026-11-20.

Cada error tiene un código (GH-XXX-NNN). El flujo 05 de n8n busca el código, lee esta entrada desde Nextcloud (Manual-Operaciones/manual-errores.json), consulta el estado actual en Prometheus y guarda el diagnóstico en Nextcloud (Diagnosticos/). Se le puede pasar el código o el número de incidencia de Mantis. Los comandos se corren en la PC servidor (PowerShell).

> Generado desde `infra/n8n/manual/manual-errores.json` (la versión que lee n8n). No editar este archivo a mano.

## Índice

| Código | Alerta / origen | Severidad | Error |
|---|---|---|---|
| GH-DB-001 | GymHubNodoPatroniCaido | warning | Un nodo del cluster PostgreSQL está caído |
| GH-DB-002 | GymHubSinLider | critical | El cluster PostgreSQL no tiene líder |
| GH-DB-003 | GymHubFailoverOcurrido | info | Cambió el líder del cluster PostgreSQL (failover o switchover) |
| GH-DB-004 | GymHubDosLideres | critical | Dos líderes en el cluster (split-brain) |
| GH-DB-005 | GymHubReplicasInsuficientes | warning | Menos de 2 réplicas replicando |
| GH-DB-006 | GymHubReplicaLagAlto | warning | Una réplica está atrasada más de 16 MB de WAL |
| GH-DB-007 | GymHubPostgresPrimaryUnavailable | critical | PostgreSQL primario no disponible (postgres-exporter) |
| GH-DB-008 | GymHubPostgresConnectionsHigh | warning | Muchas conexiones simultáneas a PostgreSQL |
| GH-APP-001 | GymHubBackendUnavailable | critical | La API de GymHub no responde |
| GH-APP-002 | GymHubFrontendUnavailable | critical | El frontend de GymHub no responde |
| GH-MON-001 | GymHubExporterUnavailable | warning | Un exporter de monitoreo está caído |
| GH-INF-001 | GymHubDockerCpuHigh | warning | CPU alta en la VM de Docker |
| GH-INF-002 | GymHubDockerMemoryHigh | warning | Memoria alta en la VM de Docker |
| GH-INF-003 | GymHubDockerDiskHigh | warning | Disco de la VM de Docker casi lleno |
| GH-INF-004 | GymHubReiniciosObservadosCadvisor | warning | Contenedores reiniciándose con frecuencia |
| GH-PUB-001 | GymHubUrlPublicaCaida | critical | La URL pública de GymHub no responde |
| GH-PUB-002 | GymHubUrlPublicaLenta | warning | La URL pública responde lento |
| GH-PUB-003 | GymHubCertificadoPorVencer | warning | El certificado HTTPS público vence en menos de 7 días |
| GH-PUB-004 | GymHubTunelCaido | critical | El contenedor de cloudflared no responde |
| GH-PUB-005 | GymHubTunelSinConexiones | critical | El túnel no tiene conexiones con Cloudflare |
| GH-PUB-006 | GymHubTunelErroresOrigen | warning | El túnel registra errores al llegar al frontend |
| GH-BKP-001 | (verificación del backup) | warning | Falló la verificación del backup diario |
| GH-SEG-001 | (Rate limit) | warning | Evento de seguridad del backend |
| GH-REN-001 | (Informe de rendimiento CRÍTICO) | warning | El informe de rendimiento salió crítico |

## GH-DB-001 · Un nodo del cluster PostgreSQL está caído

**Componente:** Base de datos (cluster Patroni) · **Severidad:** warning · **Alerta:** `GymHubNodoPatroniCaido`

**Qué significa.** Prometheus no llega a la API de Patroni (puerto 8008) de uno de los nodos pg-1, pg-2 o pg-3. Si el nodo caído era el LÍDER (maestro), Patroni promueve una réplica sola en unos 20-30 s (ttl de 20 s en etcd) y HAProxy pasa a mandar las escrituras al nuevo líder.

**Impacto.** Si era una réplica: ninguno para los usuarios, pero el cluster tiene menos redundancia. Si era el líder: 20-30 s de escrituras fallidas hasta que termina la elección; después la app sigue normal.

**Causas probables**

- El contenedor se detuvo (docker stop, reinicio de Docker Desktop o prueba de caída del maestro).
- PostgreSQL o Patroni dentro del contenedor terminaron con error (ver logs).
- Falta de memoria o disco en la VM de Docker.
- El nodo perdió la conexión con etcd y se bajó a sí mismo.

**Diagnóstico**

- Ver el estado del cluster: docker exec gymhub_pg_1_prod patronictl -c /etc/patroni/patroni.yml list (usar un nodo que esté vivo).
- Ver qué contenedor está parado: docker ps -a --filter name=gymhub_pg_
- Ver por qué se cayó: docker logs --tail 100 gymhub_pg_N_prod (N = número del nodo caído). Exited (137) = lo detuvieron a la fuerza; Exited (1) = error.
- Confirmar que HAProxy apunta al nuevo líder: http://100.65.22.99:7000 (en el bloque 5432 solo el líder está en verde).
- Confirmar que la app responde: https://gymhub-servidor.tailec3350.ts.net/api/health

**Solución**

- Volver a levantar el nodo: docker start gymhub_pg_N_prod
- El nodo vuelve como RÉPLICA (no recupera el liderazgo) y se sincroniza solo con el líder actual (pg_rewind si hace falta).
- Si no arranca, revisar los logs; como último recurso reinicializarlo: docker exec <nodo vivo> patronictl -c /etc/patroni/patroni.yml reinit gymhub-prod pg-N

**Verificación**

- patronictl list muestra 3 miembros: 1 Leader y 2 Replica en estado streaming con Lag 0.
- La alerta GymHubNodoPatroniCaido se resuelve sola y n8n agrega la nota de resolución en Mantis.

**Escalar.** Si el nodo no vuelve en 15 minutos o se cae de nuevo, avisar al responsable de base de datos.

**Lo que consulta n8n en Prometheus:** Líder actual del cluster; Nodos de Patroni sin responder; Nodos de Patroni respondiendo; Réplicas en streaming; Timeline del cluster (sube 1 con cada failover); API del backend (/api/health).

## GH-DB-002 · El cluster PostgreSQL no tiene líder

**Componente:** Base de datos (cluster Patroni) · **Severidad:** critical · **Alerta:** `GymHubSinLider`

**Qué significa.** Ningún nodo acepta escrituras. Durante un failover normal pasa unos segundos; si dura más de 30 s, la elección no puede completarse.

**Impacto.** La app no puede guardar nada (altas, pagos, rutinas). Las lecturas por el puerto 5433 pueden seguir funcionando.

**Causas probables**

- etcd caído o sin quórum: Patroni no puede tomar el bloqueo de líder.
- Todas las réplicas atrasadas más de 1 MB (maximum_lag_on_failover): Patroni no promueve ninguna para no perder datos.
- Los tres nodos caídos.
- Cluster en modo pausa (patronictl pause).

**Diagnóstico**

- Estado del cluster: docker exec gymhub_pg_1_prod patronictl -c /etc/patroni/patroni.yml list
- Salud de etcd: docker exec gymhub_etcd_prod etcdctl endpoint health
- Logs de Patroni: docker logs --tail 100 gymhub_pg_1_prod (buscar 'no action', 'failed to acquire', 'lag').
- Contenedores: docker ps -a --filter name=gymhub_

**Solución**

- Si etcd está caído: docker start gymhub_etcd_prod y esperar 30 s.
- Si el cluster está en pausa: docker exec gymhub_pg_1_prod patronictl -c /etc/patroni/patroni.yml resume
- Si todos los nodos están caídos: docker start gymhub_pg_1_prod gymhub_pg_2_prod gymhub_pg_3_prod
- Último recurso (puede perder las transacciones no replicadas): patronictl failover --candidate pg-N --force

**Verificación**

- patronictl list muestra un Leader.
- https://gymhub-servidor.tailec3350.ts.net/api/health responde 200.

**Escalar.** Inmediato: avisar al equipo completo. Es una caída de servicio.

**Lo que consulta n8n en Prometheus:** Líder actual del cluster; Nodos de Patroni sin responder; Nodos de Patroni respondiendo; Réplicas en streaming; API del backend (/api/health).

## GH-DB-003 · Cambió el líder del cluster PostgreSQL (failover o switchover)

**Componente:** Base de datos (cluster Patroni) · **Severidad:** info · **Alerta:** `GymHubFailoverOcurrido`

**Qué significa.** Patroni promovió otra réplica a líder en los últimos 10 minutos: el timeline subió. Es la consecuencia esperada de que se caiga el maestro (GH-DB-001) o de un switchover manual.

**Impacto.** Ninguno si el nuevo líder está sano: HAProxy ya redirigió las conexiones. Pudo haber unos segundos de errores de escritura durante el cambio.

**Causas probables**

- Se cayó o se detuvo el nodo que era líder.
- Switchover manual (patronictl switchover) por mantenimiento.
- El líder perdió la conexión con etcd más tiempo que el ttl (20 s).

**Diagnóstico**

- Quién es el líder ahora y el timeline: docker exec gymhub_pg_1_prod patronictl -c /etc/patroni/patroni.yml list
- Historial de cambios de líder: docker exec gymhub_pg_1_prod patronictl -c /etc/patroni/patroni.yml history
- Ver si el líder anterior sigue caído: docker ps -a --filter name=gymhub_pg_

**Solución**

- Levantar el nodo anterior si está caído (docker start gymhub_pg_N_prod): vuelve como réplica.
- No hace falta devolverle el liderazgo. Si se quiere: patronictl switchover --leader <actual> --candidate <otro>.

**Verificación**

- Un solo Leader y las réplicas en streaming con Lag 0.
- La app responde en /api/health.

**Escalar.** Solo informativo. Escalar si el failover se repite varias veces en una hora.

**Lo que consulta n8n en Prometheus:** Líder actual del cluster; Timeline del cluster (sube 1 con cada failover); Nodos de Patroni sin responder; Réplicas en streaming; API del backend (/api/health).

## GH-DB-004 · Dos líderes en el cluster (split-brain)

**Componente:** Base de datos (cluster Patroni) · **Severidad:** critical · **Alerta:** `GymHubDosLideres`

**Qué significa.** Dos nodos se reportan como primario al mismo tiempo. Las escrituras pueden quedar repartidas entre dos bases distintas.

**Impacto.** Riesgo de pérdida o inconsistencia de datos.

**Causas probables**

- Partición de red entre los nodos y etcd.
- Un nodo arrancado a mano fuera de Patroni (pg_ctl promote).

**Diagnóstico**

- docker exec gymhub_pg_1_prod patronictl -c /etc/patroni/patroni.yml list
- Revisar en HAProxy (http://100.65.22.99:7000) a cuál de los dos manda las escrituras.
- docker exec gymhub_etcd_prod etcdctl endpoint health

**Solución**

- Dejar como líder al que tiene HAProxy y detener el otro: docker stop gymhub_pg_N_prod
- Reinicializar el nodo detenido como réplica: docker start gymhub_pg_N_prod y, si no se sincroniza, patronictl reinit gymhub-prod pg-N
- Comparar los datos escritos durante el incidente y restaurar desde backup si hace falta (database/backup/restore.sh).

**Verificación**

- patronictl list muestra un único Leader.

**Escalar.** Inmediato.

**Lo que consulta n8n en Prometheus:** Líder actual del cluster; Nodos de Patroni respondiendo; Timeline del cluster (sube 1 con cada failover).

## GH-DB-005 · Menos de 2 réplicas replicando

**Componente:** Base de datos (cluster Patroni) · **Severidad:** warning · **Alerta:** `GymHubReplicasInsuficientes`

**Qué significa.** El cluster debería tener 2 réplicas en streaming y tiene menos. Suele aparecer 5 minutos después de que se cae un nodo (GH-DB-001), o mientras una réplica se resincroniza.

**Impacto.** Menos redundancia: si ahora se cae el líder, hay menos candidatos para reemplazarlo.

**Causas probables**

- Un nodo caído (ver GH-DB-001).
- Una réplica arrancando o resincronizándose después de un failover.
- Una réplica sin poder conectarse al líder (replicación cortada).

**Diagnóstico**

- docker exec gymhub_pg_1_prod patronictl -c /etc/patroni/patroni.yml list (estado de cada réplica: streaming, starting, stopped).
- docker ps -a --filter name=gymhub_pg_
- docker logs --tail 100 gymhub_pg_N_prod de la réplica que no está en streaming.

**Solución**

- Levantar el nodo caído: docker start gymhub_pg_N_prod
- Si la réplica no vuelve a streaming: patronictl reinit gymhub-prod pg-N

**Verificación**

- patronictl list: 2 réplicas en streaming con Lag 0.

**Escalar.** Si sigue así más de 30 minutos.

**Lo que consulta n8n en Prometheus:** Réplicas en streaming; Nodos de Patroni sin responder; Líder actual del cluster; Atraso de cada réplica (WAL).

## GH-DB-006 · Una réplica está atrasada más de 16 MB de WAL

**Componente:** Base de datos (cluster Patroni) · **Severidad:** warning · **Alerta:** `GymHubReplicaLagAlto`

**Qué significa.** La réplica no alcanza a aplicar los cambios del líder. Con más de 1 MB de atraso Patroni no la elige como líder en un failover.

**Impacto.** Las lecturas por el puerto 5433 pueden devolver datos viejos; menos candidatos para un failover.

**Causas probables**

- Carga de escritura muy alta (por ejemplo, la carga del dataset de 6 millones).
- CPU o disco saturados en la VM de Docker.
- Consultas largas en la réplica que frenan la aplicación del WAL.

**Diagnóstico**

- patronictl list (columnas Lag).
- CPU y disco en Grafana (http://100.65.22.99:3001) o docker stats.

**Solución**

- Esperar a que termine la carga pesada; el atraso baja solo.
- Si no baja: reiniciar la réplica (docker restart gymhub_pg_N_prod) o reinicializarla (patronictl reinit).

**Verificación**

- Lag 0 en patronictl list.

**Escalar.** Si el atraso crece durante más de 30 minutos.

**Lo que consulta n8n en Prometheus:** Atraso de cada réplica (WAL); Réplicas en streaming; CPU de la VM de Docker; Disco de la VM de Docker.

## GH-DB-007 · PostgreSQL primario no disponible (postgres-exporter)

**Componente:** Base de datos · **Severidad:** critical · **Alerta:** `GymHubPostgresPrimaryUnavailable`

**Qué significa.** postgres-exporter no puede conectarse a la base por HAProxy (db:5432) desde hace 1 minuto.

**Impacto.** Probable caída de escrituras de la app.

**Causas probables**

- Cluster sin líder (GH-DB-002).
- HAProxy caído.
- Credenciales del exporter cambiadas.

**Diagnóstico**

- patronictl list
- docker ps --filter name=gymhub_haproxy_prod y http://100.65.22.99:7000
- docker logs --tail 50 gymhub-postgres-exporter-scrum66

**Solución**

- Resolver primero GH-DB-002 si no hay líder.
- Si HAProxy está caído: docker start gymhub_haproxy_prod

**Verificación**

- pg_up = 1 en Prometheus y /api/health responde 200.

**Escalar.** Inmediato si la app no responde.

**Lo que consulta n8n en Prometheus:** PostgreSQL visto por postgres-exporter; Líder actual del cluster; API del backend (/api/health).

## GH-DB-008 · Muchas conexiones simultáneas a PostgreSQL

**Componente:** Base de datos · **Severidad:** warning · **Alerta:** `GymHubPostgresConnectionsHigh`

**Qué significa.** Más de 80 conexiones a la base gymhub durante 5 minutos.

**Impacto.** Si se llega a max_connections, las conexiones nuevas fallan.

**Causas probables**

- Pico de tráfico.
- Fuga de conexiones en el backend.
- Consultas lentas que dejan conexiones ocupadas.

**Diagnóstico**

- Ver quién está conectado (pgAdmin en 100.65.22.99:5436): SELECT state, count(*) FROM pg_stat_activity GROUP BY 1;
- docker logs --tail 100 gymhub_backend_prod

**Solución**

- Cortar consultas colgadas (pg_terminate_backend).
- Reiniciar el backend si pierde conexiones: docker restart gymhub_backend_prod

**Verificación**

- Conexiones por debajo de 80.

**Escalar.** Si se repite a diario.

**Lo que consulta n8n en Prometheus:** Conexiones a la base gymhub; API del backend (/api/health).

## GH-APP-001 · La API de GymHub no responde

**Componente:** Backend (API) · **Severidad:** critical · **Alerta:** `GymHubBackendUnavailable`

**Qué significa.** Blackbox no obtiene HTTP 2xx de http://backend:3000/api/health durante 1 minuto.

**Impacto.** La app no funciona (login, datos).

**Causas probables**

- Contenedor del backend caído.
- La base no responde (ver GH-DB-002).
- Error al arrancar después de un despliegue.

**Diagnóstico**

- docker ps -a --filter name=gymhub_backend_prod
- docker logs --tail 100 gymhub_backend_prod
- patronictl list

**Solución**

- docker start gymhub_backend_prod (o docker restart).
- Si fue un despliegue: volver a la versión anterior (scripts/deploy.sh con el SHA anterior).

**Verificación**

- /api/health responde 200.

**Escalar.** Inmediato.

**Lo que consulta n8n en Prometheus:** API del backend (/api/health); Frontend (Nginx → /api/health); Líder actual del cluster.

## GH-APP-002 · El frontend de GymHub no responde

**Componente:** Frontend (Nginx) · **Severidad:** critical · **Alerta:** `GymHubFrontendUnavailable`

**Qué significa.** Blackbox no obtiene HTTP 2xx a través del proxy Nginx durante 1 minuto.

**Impacto.** La página no carga.

**Causas probables**

- Contenedor del frontend caído.
- El backend no responde y Nginx devuelve 502.

**Diagnóstico**

- docker ps -a --filter name=gymhub_frontend_prod
- docker logs --tail 100 gymhub_frontend_prod

**Solución**

- docker start gymhub_frontend_prod
- Si el backend también está caído, ver GH-APP-001.

**Verificación**

- La URL pública carga.

**Escalar.** Inmediato.

**Lo que consulta n8n en Prometheus:** Frontend (Nginx → /api/health); API del backend (/api/health).

## GH-MON-001 · Un exporter de monitoreo está caído

**Componente:** Monitoreo · **Severidad:** warning · **Alerta:** `GymHubExporterUnavailable`

**Qué significa.** Prometheus no puede leer las métricas de un exporter.

**Impacto.** Se pierde visibilidad (y alertas) de ese componente.

**Causas probables**

- Contenedor del exporter detenido.
- Cambio de red de Docker.

**Diagnóstico**

- docker ps -a --filter name=scrum66
- http://100.65.22.99:9091/targets

**Solución**

- bash scripts/infra.sh levantar

**Verificación**

- Todos los targets en UP.

**Escalar.** Si no vuelve en 30 minutos.

**Lo que consulta n8n en Prometheus:** Exporters caídos.

## GH-INF-001 · CPU alta en la VM de Docker

**Componente:** Servidor (VM de Docker) · **Severidad:** warning · **Alerta:** `GymHubDockerCpuHigh`

**Qué significa.** CPU por encima del 85 % durante 10 minutos.

**Impacto.** La app responde más lento.

**Causas probables**

- Carga masiva de datos.
- Consultas pesadas sin índices.
- Un contenedor en bucle.

**Diagnóstico**

- docker stats --no-stream
- Grafana: dashboard de contenedores.

**Solución**

- Identificar el contenedor y reiniciarlo o esperar a que termine la tarea pesada.

**Verificación**

- CPU por debajo del 85 %.

**Escalar.** Si dura más de 1 hora.

**Lo que consulta n8n en Prometheus:** CPU de la VM de Docker; Memoria de la VM de Docker.

## GH-INF-002 · Memoria alta en la VM de Docker

**Componente:** Servidor (VM de Docker) · **Severidad:** warning · **Alerta:** `GymHubDockerMemoryHigh`

**Qué significa.** Memoria usada por encima del 90 % durante 10 minutos.

**Impacto.** Riesgo de que el sistema mate contenedores (OOM).

**Causas probables**

- Demasiados contenedores levantados (otros proyectos).
- Fuga de memoria.

**Diagnóstico**

- docker stats --no-stream
- docker ps (ver contenedores de otros proyectos).

**Solución**

- Detener contenedores que no son de GymHub.
- Reiniciar el contenedor que más consume.

**Verificación**

- Memoria por debajo del 90 %.

**Escalar.** Si un contenedor de producción se reinicia por OOM.

**Lo que consulta n8n en Prometheus:** Memoria de la VM de Docker; CPU de la VM de Docker.

## GH-INF-003 · Disco de la VM de Docker casi lleno

**Componente:** Servidor (VM de Docker) · **Severidad:** warning · **Alerta:** `GymHubDockerDiskHigh`

**Qué significa.** Más del 90 % del disco usado durante 10 minutos.

**Impacto.** Si se llena, PostgreSQL deja de escribir.

**Causas probables**

- Backups acumulados.
- Imágenes y volúmenes viejos.
- WAL acumulado por una réplica caída.

**Diagnóstico**

- docker system df
- Revisar el volumen de backups.

**Solución**

- docker image prune y borrar volúmenes que no se usan (por ejemplo gymhub_prod_db_data_pre_patroni).
- Levantar la réplica caída para liberar WAL.

**Verificación**

- Disco por debajo del 90 %.

**Escalar.** Inmediato si supera el 95 %.

**Lo que consulta n8n en Prometheus:** Disco de la VM de Docker.

## GH-INF-004 · Contenedores reiniciándose con frecuencia

**Componente:** Contenedores · **Severidad:** warning · **Alerta:** `GymHubReiniciosObservadosCadvisor`

**Qué significa.** cAdvisor vio más de 2 inicios de contenedores en 10 minutos.

**Impacto.** Posible contenedor en bucle de reinicio.

**Causas probables**

- Un contenedor que falla al arrancar y Docker lo reinicia.
- Despliegue o reinicio del servidor.

**Diagnóstico**

- docker ps -a (columna STATUS: Restarting).
- docker logs del contenedor afectado.

**Solución**

- Corregir la causa del error de arranque.

**Verificación**

- Sin reinicios en 10 minutos.

**Escalar.** Si un contenedor de producción no logra arrancar.

**Lo que consulta n8n en Prometheus:** Inicios de contenedores en 10 min.

## GH-PUB-001 · La URL pública de GymHub no responde

**Componente:** Publicación · **Severidad:** critical · **Alerta:** `GymHubUrlPublicaCaida`

**Qué significa.** La sonda externa falla desde hace 2 minutos (HTTPS, certificado o /api/health).

**Impacto.** Los usuarios de Internet no pueden entrar.

**Causas probables**

- Túnel de Cloudflare caído.
- Tailscale Funnel desactivado.
- Frontend o backend caídos.

**Diagnóstico**

- bash scripts/vigilar-tunel.sh --forzar
- tailscale funnel status
- docker ps --filter name=gymhub_

**Solución**

- Relanzar el túnel o el Funnel (bash scripts/tailscale-serve.sh).
- Ver GH-APP-001/002 si la app local tampoco responde.

**Verificación**

- https://gymhub-servidor.tailec3350.ts.net carga.

**Escalar.** Inmediato.

**Lo que consulta n8n en Prometheus:** URL pública (sonda externa); API del backend (/api/health); Frontend (Nginx → /api/health).

## GH-PUB-002 · La URL pública responde lento

**Componente:** Publicación · **Severidad:** warning · **Alerta:** `GymHubUrlPublicaLenta`

**Qué significa.** La sonda tarda más de 3 s durante 5 minutos.

**Impacto.** Mala experiencia de usuario.

**Causas probables**

- Conexión a Internet de la PC servidor lenta.
- Backend lento (CPU o consultas pesadas).

**Diagnóstico**

- Comparar con la latencia local de /api/health.
- docker stats --no-stream

**Solución**

- Si la latencia local es buena, el problema es la red o el túnel.

**Verificación**

- Latencia por debajo de 3 s.

**Escalar.** Si dura más de 1 hora.

**Lo que consulta n8n en Prometheus:** Latencia de la URL pública; CPU de la VM de Docker.

## GH-PUB-003 · El certificado HTTPS público vence en menos de 7 días

**Componente:** Publicación · **Severidad:** warning · **Alerta:** `GymHubCertificadoPorVencer`

**Qué significa.** El certificado que presenta la URL pública está por vencer.

**Impacto.** Si vence, los navegadores bloquean la página.

**Causas probables**

- Fallo en la renovación automática.

**Diagnóstico**

- Ver el certificado en el navegador.

**Solución**

- Relanzar el Funnel o el túnel para forzar la renovación.

**Verificación**

- Más de 30 días de validez.

**Escalar.** Si faltan menos de 2 días.

**Lo que consulta n8n en Prometheus:** Días hasta que vence el certificado.

## GH-PUB-004 · El contenedor de cloudflared no responde

**Componente:** Publicación · **Severidad:** critical · **Alerta:** `GymHubTunelCaido`

**Qué significa.** Prometheus no puede leer las métricas del túnel de respaldo.

**Impacto.** Se cae la URL de respaldo de Cloudflare (la de Funnel sigue).

**Causas probables**

- Contenedor detenido.
- Túnel rápido vencido ('Tunnel not found').

**Diagnóstico**

- docker logs --tail 50 gymhub_cloudflared_rapido

**Solución**

- bash scripts/vigilar-tunel.sh --forzar

**Verificación**

- up{job="cloudflared"} = 1

**Escalar.** Si Funnel también está caído.

**Lo que consulta n8n en Prometheus:** Contenedor cloudflared; Conexiones del túnel con Cloudflare.

## GH-PUB-005 · El túnel no tiene conexiones con Cloudflare

**Componente:** Publicación · **Severidad:** critical · **Alerta:** `GymHubTunelSinConexiones`

**Qué significa.** cloudflared está vivo pero sin conexiones al edge.

**Impacto.** La URL de respaldo no funciona.

**Causas probables**

- Corte de Internet de la PC servidor.
- Problema de Cloudflare.

**Diagnóstico**

- docker logs --tail 50 gymhub_cloudflared_rapido
- Probar Internet en la PC.

**Solución**

- bash scripts/vigilar-tunel.sh --forzar

**Verificación**

- Conexiones del túnel >= 1.

**Escalar.** Si dura más de 15 minutos.

**Lo que consulta n8n en Prometheus:** Conexiones del túnel con Cloudflare; Contenedor cloudflared.

## GH-PUB-006 · El túnel registra errores al llegar al frontend

**Componente:** Publicación · **Severidad:** warning · **Alerta:** `GymHubTunelErroresOrigen`

**Qué significa.** Más de 5 errores hacia Nginx en 5 minutos.

**Impacto.** Algunos usuarios ven errores 502.

**Causas probables**

- Frontend caído o reiniciándose.

**Diagnóstico**

- docker ps --filter name=gymhub_frontend_prod

**Solución**

- Ver GH-APP-002.

**Verificación**

- Sin errores nuevos en 5 minutos.

**Escalar.** Si persiste.

**Lo que consulta n8n en Prometheus:** Errores del túnel hacia el origen (5 min); Frontend (Nginx → /api/health).

## GH-BKP-001 · Falló la verificación del backup diario

**Componente:** Backups · **Severidad:** warning

**Qué significa.** El flujo 02 de n8n encontró el último backup fallido, vacío o con más de 26 horas.

**Impacto.** Si hay que restaurar, se perderían más datos de lo previsto.

**Causas probables**

- El contenedor de backup no pudo conectarse a la base.
- Disco lleno.
- Contenedor de backup detenido.

**Diagnóstico**

- docker logs --tail 50 gymhub_backup_prod
- Revisar /backups/backup.log y latest_status.json.

**Solución**

- Forzar un backup: docker exec gymhub_backup_prod /usr/local/bin/backup.sh

**Verificación**

- latest_status.json con status success y fecha de hoy.

**Escalar.** Si falla dos días seguidos.

**Lo que consulta n8n en Prometheus:** Líder actual del cluster; Disco de la VM de Docker.

## GH-SEG-001 · Evento de seguridad del backend

**Componente:** Seguridad · **Severidad:** warning

**Qué significa.** El backend reportó intentos de login fallidos repetidos, rate limit activado o un login de administrador (flujo 04 de n8n).

**Impacto.** Posible ataque de fuerza bruta.

**Causas probables**

- Intento de fuerza bruta.
- Usuario que olvidó la contraseña.
- Prueba del equipo.

**Diagnóstico**

- Ver la IP y el tipo en la incidencia de Mantis.
- docker logs gymhub_backend_prod | grep -i login

**Solución**

- Si la IP es externa y repetida, bloquearla.
- Avisar al usuario afectado.

**Verificación**

- Sin eventos nuevos de esa IP.

**Escalar.** Si hay login de administrador no reconocido.

**Lo que consulta n8n en Prometheus:** API del backend (/api/health).

## GH-REN-001 · El informe de rendimiento salió crítico

**Componente:** Rendimiento · **Severidad:** warning

**Qué significa.** El analizador Python del flujo 03 encontró métricas por encima del umbral al final de la ventana de 24 h.

**Impacto.** Depende de la métrica (ver el informe en Nextcloud, carpeta Informes-IA).

**Causas probables**

- Ver los hallazgos del informe.

**Diagnóstico**

- Abrir el informe en Nextcloud (Informes-IA).
- Comparar con Grafana.

**Solución**

- Según la métrica: ver la entrada del manual que corresponde.

**Verificación**

- El próximo informe sale OK.

**Escalar.** Si sale crítico dos días seguidos.

**Lo que consulta n8n en Prometheus:** CPU de la VM de Docker; Memoria de la VM de Docker; Réplicas en streaming; API del backend (/api/health).
