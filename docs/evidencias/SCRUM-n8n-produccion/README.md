# n8n en producción — pruebas de integración (20/11/2026)

Servidor de producción, después de `bash infra/n8n/configurar.sh`: 5 flujos activos, 5 credenciales cifradas, n8n 2.48.5, Mailpit y analizador Python.

## Seguridad de los webhooks

| Prueba | Resultado |
|---|---|
| `POST /webhook/gymhub-alertas` sin token | **403** |
| `POST /webhook/gymhub-alertas` con `Bearer token-falso` | **403** |
| `POST /webhook/gymhub-seguridad` sin secreto | **403** |
| `POST /webhook/gymhub-seguridad` con secreto falso | **403** |
| Credenciales en la base de n8n | Guardadas cifradas (`U2FsdGVkX1…`); los JSON de los flujos solo tienen IDs y nombres |

## Flujo 01 · Alertas → Mantis

| Paso | Resultado |
|---|---|
| Alerta `GymHubPruebaFlujo01` (warning) inyectada en Alertmanager (`POST /api/v2/alerts`) | Alertmanager la mandó a n8n con el token (`alertmanager_notifications_total{integration="webhook"} 1`, 0 fallidas) |
| Incidencia | **Mantis #18** creada por `n8n-bot`, prioridad *high*, descripción con saltos de línea correctos |
| Mail | "[GymHub] Nueva incidencia #18 por alerta de monitoreo" en Mailpit |
| Resolución (`status: resolved`, mismo *fingerprint*) | Nota en #18: "Alerta recuperada automáticamente por Alertmanager…". La deduplicación sobrevivió a un reinicio de n8n |

Con la alerta inyectada por API, Alertmanager no envió el aviso de *resolved*, así que se mandó el mismo payload directo al webhook, con token, para probar la lógica de cierre.

## Flujo 02 · Verificación de backups

| Caso | Resultado |
|---|---|
| Backup real (`gymhub_gymhub_20261120_172757.dump`, 708 MB, 1 h de antigüedad) | `valido: true` → "BACKUP OK" |
| **Falla controlada:** `latest_status.json` reemplazado por `status: error` y restaurado al terminar | `valido: false` (`estado "error"`) → **Mantis #19** + mail "Backup diario con problemas · incidencia #19" |

## Flujo 03 · Informe de rendimiento

| Paso | Resultado |
|---|---|
| Prometheus | 7 consultas `query_range` de 24 h, todas `success` (~104 muestras cada una) |
| Analizador Python | Estado general **advertencia**, 3 hallazgos: muestras atípicas en latencia (27 ms contra 3 ms de mediana), CPU (0,69 contra 0,17 núcleos) y memoria (5,1 GB contra 2,6 GB), que coinciden con la carga de 6M, la migración a Patroni y los despliegues del día. Disponibilidad 100 %, réplicas 2/2 |
| Nextcloud | `Informes-IA/informe-rendimiento-2026-11-20-1533.md`, leído de vuelta por WebDAV |
| Mail | "[GymHub] Informe de rendimiento · ADVERTENCIA" |
| Aprobación humana | No se pidió, porque el estado no fue crítico (rama "Sin acción") |

## Flujo 04 · Eventos de seguridad

| Caso | Resultado |
|---|---|
| 11 eventos `login_fallido` desde `203.0.113.77` (IP de documentación, RFC 5737) | **Mantis #20** "Posible fuerza bruta: 10 logins fallidos en 5 min", categoría Seguridad, prioridad *high*. **Una sola incidencia** (deduplicación) |
| Evento con `tipo: "borrar_todo"` | Rechazado por la validación → **flujo 00** |

### Eventos reales del backend (después del release #117)

11 logins con contraseña incorrecta contra `/api/auth/login` de producción: 5 respondieron **401** y los siguientes **429**, porque el *rate limit* del backend frenó el ataque. El backend avisó a n8n y n8n lo clasificó como "Rate limit (auth) activado", que es lo correcto: el ataque ya estaba frenado antes de llegar a 10 fallidos.

**Hallazgo: incidencias duplicadas con eventos simultáneos.** Se abrieron 5 incidencias iguales (#21–#25). Al reproducirlo con 6 avisos en paralelo salieron **6 incidencias**. La causa: la deduplicación vivía en `staticData`, que n8n carga **al recibir** el webhook. Limitar las ejecuciones a una por vez (`N8N_CONCURRENCY_PRODUCTION_LIMIT=1`) no alcanzó por eso mismo, y siguieron saliendo 6. **Corrección:** antes de crear la incidencia, el flujo consulta en **Mantis** si ya hay una abierta igual en la última hora, y las ejecuciones van en fila. Resultado: **6 avisos en paralelo → 1 incidencia**. Las duplicadas se cerraron en Mantis como "duplicada".

## Flujo 00 · Manejo de errores

Mail recibido: *"ERROR en n8n · 04 · Eventos de seguridad del backend → Mantis — Nodo: Clasificar y deduplicar — Error: Tipo de evento desconocido: borrar_todo — Ejecución: http://100.65.22.99:5679/workflow/GymHubSeguridad1/executions/17"*.

Hallazgo durante la prueba: en n8n 2.x el *Error Workflow* también tiene que estar **publicado**. Si no, los demás flujos no pueden invocarlo ("is not active and cannot be executed"). `configurar.sh` lo publica.

## Limpieza

Las incidencias que generaron las pruebas (#18–#38) se cerraron en Mantis con una nota que las identifica como prueba controlada, y las duplicadas quedaron con resolución "duplicada". Queda abierta solo la #8 (BUG-008), que es real.

## Prueba de punta a punta con una condición real (réplica caída)

Se detuvo la réplica `gymhub_pg_3_prod` (`docker stop`) unos minutos. La app siguió respondiendo 200 con pg-2 de líder y pg-1 de réplica.

| t | Qué pasó |
|---|---|
| 0 s | pg-3 detenida |
| +11 s | Prometheus: `GymHubNodoPatroniCaido` y `GymHubReplicasInsuficientes` en *pending* |
| +32 s | `GymHubNodoPatroniCaido` en **firing** (regla `up{job="patroni"} == 0`, `for: 30s`) |
| +64 s | Alertmanager → n8n (flujo 01) → **Mantis #39** "[Prometheus] GymHubNodoPatroniCaido - pg-3:8008" + mail |
| — | Flujo 03 ejecutado: informe **CRÍTICO** (réplicas en streaming 1 < 2) en Nextcloud + mail "¿Escalar el informe crítico como incidencia?" con links Aprobar / Rechazar; la ejecución quedó **esperando** (nodo *Wait*, vence en 24 h) |
| — | Clic en **Aprobar** → n8n retomó la ejecución → **Mantis #40** "[n8n] Informe de rendimiento CRÍTICO…", categoría Rendimiento, "Escalada con aprobación humana" |
| +~1 min | `docker start`: pg-3 volvió **sola como réplica en streaming**, lag 0 |
| +~4 min | Prometheus resolvió la alerta → Alertmanager mandó el *resolved* → n8n agregó la **nota de cierre en #39** |

Así quedó probado el recorrido completo de una alerta **real**, de *firing* a *resolved*, que estaba pendiente desde SCRUM-76, y la aprobación humana del flujo 03.

**Hallazgo:** el link de aprobación armaba `resumeUrl?decision=…`, pero `resumeUrl` ya trae `?signature=…`. La decisión quedaba pegada a la firma y n8n respondía **401 "Invalid token"**, una protección correcta de n8n. Corregido: la decisión va con `&`. La aprobación de la prueba se hizo con el link bien armado.

#39 y #40 se cerraron en Mantis como prueba controlada.

## Flujo 05 · Diagnóstico con el manual de errores (Nextcloud)

Consigna: "hacer caer el nodo maestro, que n8n capture el error y devuelva un diagnóstico usando Nextcloud (con el manual, pasándole el ID del error)".

1. Se detuvo el líder `gymhub_pg_2_prod`. Patroni promovió a **pg-3** (timeline 5 → 6) y la app siguió respondiendo 200.
2. Alertmanager avisó al flujo 01, que abrió **#41** (`GymHubNodoPatroniCaido` pg-2), **#42** (`GymHubFailoverOcurrido`) y **#43** (`GymHubReplicasInsuficientes`).
3. Con el ID `41`, el flujo 05 leyó el manual desde Nextcloud (`Manual-Operaciones/manual-errores.json`), encontró **GH-DB-001** y consultó Prometheus. Resultado: *DEGRADADO*, líder pg-3, nodo caído pg-2 (`docker start gymhub_pg_2_prod`), 1 réplica de 2, timeline 6, app OK.
4. El diagnóstico quedó en Nextcloud (`Diagnosticos/diagnostico-GH-DB-001-inc41-20261120-1823.md`) y como nota en Mantis #41.

| Prueba de seguridad | Resultado |
|---|---|
| Página sin usuario y clave | 401 |
| ID inválido (`<script>`) | Rechazado y mostrado escapado |
| `n8n-bot` intenta escribir en `Manual-Operaciones` | 403 (solo lectura) |

