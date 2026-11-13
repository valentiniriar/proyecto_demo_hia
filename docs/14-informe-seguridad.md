# Documento obligatorio n.º 14 · Informe de seguridad final de GymHub

**Épica:** E14 · Seguridad informática y amenazas actuales  
**Elaborado en:** SCRUM-84 · Valentín Iriarte  
**Fecha:** 13/11/2026 · estado de `develop` a esa fecha

## 1. Resumen ejecutivo

GymHub (Angular + Express + PostgreSQL, en Docker) se publica en Internet **solo** a través de Cloudflare Tunnel. Durante el proyecto:

- Se modelaron **18 amenazas** (SCRUM-63).
- Se implementaron controles en la API, el pipeline, la red y la operación.
- Se hicieron pruebas de seguridad controladas (SCRUM-81) que encontraron y corrigieron **una falla crítica de fraude en pagos** (un socio podía marcar como pagada cualquier cuota).

| Indicador | Valor |
|---|---|
| Amenazas con riesgo **alto** antes de los controles | 13 de 18 |
| Amenazas con riesgo **alto** residual hoy | **1** (A04: robo de credenciales de admin sin 2FA → SCRUM-83) |
| Secretos en el historial del repo (gitleaks, todas las ramas) | **0** |
| Vulnerabilidades altas/críticas en dependencias de producción (`npm audit`) | **0** (backend: 2 moderadas no explotables; frontend: 0) |
| Pruebas de seguridad automatizadas del script de SCRUM-81 | **23/23 OK** (antes de las correcciones: 20/23) |
| OWASP ZAP baseline | **0 FAIL**, 9 WARN justificadas (antes 11) |
| Tests de backend en el CI | 37 (smoke, endurecimiento, IA, pagos, eventos de seguridad) |
| Puertos de GymHub visibles desde la LAN (nmap) | **0** |

## 2. Superficie expuesta

```
Internet ──HTTPS──► Cloudflare ──túnel saliente──► Nginx (frontend) ──/api──► API ──► PostgreSQL
                                                                       (redes Docker internas)
Herramientas internas (pgAdmin, Grafana, Prometheus, n8n, Mantis): solo 127.0.0.1 / Tailscale
```

Detalle y matriz de acceso: SCRUM-60 (túnel), SCRUM-61 (control de acceso, firewall, nmap).

## 3. Controles implementados

| Área | Control | Ticket | Evidencia |
|---|---|---|---|
| Código / repo | Auditoría de secretos con gitleaks en todo el historial; limpieza de `test_mp.js`; `.gitignore` de `.env`, dumps y certificados | SCRUM-31 | `docs/SCRUM-31-auditoria-secretos.md` |
| Dependencias | Inventario y CVEs; corrección de 12 + 47 vulnerabilidades | SCRUM-21, SCRUM-64 | `docs/SCRUM-21-inventario-stack-y-cves.md` |
| API | helmet (CSP, HSTS…), rate limit de login (5 fallidos/min/IP) y global, `trust proxy`, CORS por entorno, límite de body | SCRUM-65 | `docs/SCRUM-65-endurecimiento-api.md` |
| API · IA | Validación y filtro de prompt injection, rate limit por usuario en `/api/ai` | SCRUM-82 | `docs/SCRUM-82-riesgos-ia.md` |
| API · pagos | Propiedad de la cuota + verificación del pago contra MercadoPago (estado, referencia, monto, no reutilización) | SCRUM-81 | `docs/SCRUM-81-pruebas-seguridad.md` |
| Frontend | CSP con orígenes explícitos, `Permissions-Policy`, COOP/CORP, sin versión de Nginx | SCRUM-81 | ZAP antes/después |
| CI/CD | `permissions` mínimos, Actions fijadas por SHA, `persist-credentials: false`, gitleaks en cada PR, Dependabot, secret scanning + push protection, Environment `produccion` | SCRUM-58 | `docs/SCRUM-58-secretos-pipeline.md` |
| Red | Cloudflare Tunnel (sin puertos abiertos), servicios internos en `127.0.0.1`, reglas de firewall, matriz de acceso | SCRUM-60, SCRUM-61 | nmap antes/después |
| Datos | Backups automáticos, restauración probada, réplica con failover | SCRUM-37, 38, 45, 48 | docs de E04/E06 |
| Detección | Prometheus + Alertmanager; flujo n8n 4 de eventos de seguridad → Mantis | SCRUM-66/68, SCRUM-84 | `docs/SCRUM-84-respuesta-incidentes.md` |
| Respuesta | Procedimiento en 5 fases, roles, playbooks (credenciales, ransomware, DDoS) | SCRUM-84 | ídem |
| Gestión | Mantis con proyecto, categorías, roles y token de mínimo privilegio para n8n | SCRUM-70 | `docs/SCRUM-70-mantis.md` |

## 4. Resultados de las pruebas (SCRUM-81)

| Prueba | Resultado |
|---|---|
| Inyección SQL (login, parámetros, búsquedas) | Sin vulnerabilidad: Sequelize parametriza y `express-validator` filtra. Un 500 por falta de validación se corrigió a 400 |
| Fuerza bruta | Bloqueo al 6.º intento fallido (429), por IP real |
| Escalamiento de rol y JWT manipulado (`alg=none`, payload alterado) | 403 / 401 en todos los casos |
| IDOR | `/mis-*` aislados correctamente. **Crítico encontrado y corregido:** pago sobre la cuota de otro socio y cuota propia marcada sin pagar |
| OWASP ZAP baseline | 0 FAIL; se corrigieron 2 alertas y se acotaron otras 2; el resto se acepta con justificación |

## 5. Incidencias de seguridad registradas (Mantis)

| Mantis | Origen | Estado |
|---|---|---|
| #1 IDOR en pagos | SCRUM-81 | Resuelta (PR #40) → cierre con evidencia en SCRUM-72 |
| #2 Pago no verificado del lado servidor | SCRUM-81 | Resuelta (PR #40) → SCRUM-72 |
| #3 500 ante id no numérico | SCRUM-81 | Resuelta (PR #40) → SCRUM-72 |
| #4 Cabeceras de seguridad en Nginx | SCRUM-81 | Resuelta (PR #40) → SCRUM-72 |
| #5–#8 Eventos detectados por el flujo n8n 4 | Prueba controlada (SCRUM-84) | Se cierran en SCRUM-72 como prueba del flujo |

## 6. Riesgos residuales y riesgos aceptados

| Riesgo | Nivel | Tratamiento |
|---|---|---|
| Robo de credenciales del admin (sin 2FA) | 🔴 Alto | **Pendiente:** SCRUM-83 (sesión/2FA) y Cloudflare Access para funciones de admin (SCRUM-61) |
| JWT en `localStorage` (8 h, sin revocación) | 🟡 Medio | Mitigado por la CSP; migrar a cookie `HttpOnly` (SCRUM-83) |
| Escaneo de imágenes Docker | 🟡 Medio | Pendiente: Trivy en el CI (SCRUM-80) |
| `img-src https:`, sin COEP, script de Google sin SRI | 🟢 Aceptado | Necesarios para YouTube, Open Food Facts y Google Sign-In; la CSP limita el resto |
| `uuid` moderada vía Sequelize | 🟢 Aceptado | No explotable en nuestro uso; revisar con Sequelize 7 |
| Disponibilidad atada a la PC que publica | 🟡 Medio | Monitoreo y plan B (SCRUM-85, SCRUM-88) |
| Contador del rate limit en memoria | 🟢 Bajo | Suficiente con una instancia; Redis si se escala |

## 7. Acciones manuales pendientes

1. Ejecutar `infra/firewall/windows-firewall-gymhub.ps1` como administrador en la PC de la demo (SCRUM-61).
2. Crear la política de Cloudflare Access para `/api/docs` y paneles (SCRUM-61), si se usa el túnel con nombre.
3. Cambiar o borrar los usuarios demo (`*@demo.com`) antes de dejar la app publicada por un período largo.
4. Cargar los secretos reales en el Environment `produccion` cuando exista el workflow de despliegue (SCRUM-58).
5. Activar el flujo 4 en el n8n del equipo y definir `SECURITY_EVENTS_WEBHOOK_*` (SCRUM-84, sección 5.2).

## 8. Conclusión

La postura de seguridad pasó de una API sin límites ni cabeceras, con un fraude de pagos explotable y servicios visibles en la LAN, a una publicación con una sola puerta de entrada (túnel con HTTPS), controles verificados por pruebas automatizadas en el CI, detección automática de eventos y un procedimiento de respuesta con responsables. El riesgo alto que queda (2FA de admin) está identificado y tiene ticket.
