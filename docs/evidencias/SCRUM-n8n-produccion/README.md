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

## Pendiente

- **Alerta real de Prometheus** (no inyectada) recorriendo Alertmanager → n8n → Mantis → *resolved*. Requiere provocar una condición real en producción, por ejemplo detener una réplica de Patroni unos minutos.
- **Aprobación humana del flujo 03** con un informe crítico, que sale con la misma prueba: menos de 2 réplicas en streaming.
- **Eventos reales del backend**, que llegan después de desplegar `SECURITY_EVENTS_WEBHOOK_URL/SECRET` (release de este cambio).
