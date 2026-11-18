# SCRUM-84 · Procedimiento de respuesta a incidentes y flujo n8n de eventos de seguridad

**Épica:** E14 · Seguridad informática y amenazas actuales  
**Responsable:** Valentín Iriarte  
**Rama:** `feat/SCRUM-84-respuesta-incidentes`  
**Informe de seguridad final (documento obligatorio n.º 14):** [`14-informe-seguridad.md`](14-informe-seguridad.md)

## 1. Roles

| Rol | Quién | Responsabilidad |
|---|---|---|
| **Coordinador de incidentes** | Valentín Iriarte (manager en Mantis) | Declara el incidente, asigna, decide la contención y el cierre. Registra todo en Mantis |
| **Suplente / comunicación** | Francisco Paredes (Scrum master) | Avisa al equipo y al docente; actualiza Jira; reemplaza al coordinador si no está |
| **Backend y seguridad de la API** | Tiziano Gallo | Análisis de logs de la API, rotación de `JWT_SECRET`, parches |
| **Base de datos, backups y réplica** | Valentín Lozano | Contención en la BD, restauración desde backup, failover |
| **Infraestructura y monitoreo** | Enzo Villagrán | Docker, túnel de Cloudflare, firewall, Prometheus/Alertmanager |

> Asignación **propuesta** según el área de cada integrante en el tablero de Jira; el equipo la valida en la próxima daily.

Canal: grupo del equipo para el aviso inicial. **Todo lo demás queda escrito en la incidencia de Mantis** (decisiones, comandos, horas).

## 2. Clasificación

| Nivel | Criterio | Ejemplos | Tiempo de respuesta |
|---|---|---|---|
| **P1 crítico** | Datos expuestos o alterados, fraude, caída total, secreto filtrado | Token de MercadoPago en el repo, ransomware, cuotas marcadas sin pagar | Inmediato (mismo día) |
| **P2 alto** | Ataque en curso contenido parcialmente; función principal caída | Fuerza bruta sostenida, login de admin desde IP desconocida, DDoS | ≤ 4 h |
| **P3 medio/bajo** | Evento sospechoso sin impacto | Rate limit activado una vez, escaneo de puertos | Dentro del sprint |

## 3. Fases

| Fase | Qué se hace | Responsable | Registro |
|---|---|---|---|
| **1. Detección** | Alertas de Alertmanager (SCRUM-68), incidencias automáticas del **flujo 4 de n8n** (abajo), CI (gitleaks, `npm audit`), aviso de un usuario | Cualquiera la reporta; el coordinador la valida | Incidencia en Mantis (categoría Seguridad) + hora de detección |
| **2. Contención** | Cortar el daño sin destruir evidencia: bajar el túnel (`docker stop gymhub_cloudflared`), bloquear la IP en Cloudflare, deshabilitar la cuenta afectada (`usuarios.estado=false`), revocar tokens | Coordinador + área afectada | Nota en Mantis con cada acción y hora |
| **3. Erradicación** | Eliminar la causa: parche (rama `fix/SCRUM-XX`), rotar secretos, quitar el artefacto malicioso, actualizar dependencias | Área afectada | PR referenciado en la incidencia → estado **resuelta** |
| **4. Recuperación** | Volver a servicio y verificar: redeploy, restauración desde backup verificado, monitoreo reforzado 48 h | Infra + BD | Evidencia (healthcheck, smoke tests, métricas) → estado **cerrada** |
| **5. Lecciones aprendidas** | Post-mortem sin culpables en ≤ 3 días: línea de tiempo, causa raíz, qué funcionó, acciones preventivas como tickets de Jira | Todo el equipo | Nota final en Mantis + tickets nuevos + actualizar la matriz de amenazas (SCRUM-63) |

Preservar evidencia **antes** de limpiar: `docker logs <contenedor> > evidencia.log`, captura de Grafana, export de la incidencia.

## 4. Playbooks

### 4.1 Credenciales filtradas (JWT_SECRET, ACCESS_TOKEN, GROQ_API_KEY, DB_PASS, token del túnel)

1. **Detectar:** el job de gitleaks del CI falla, GitHub secret scanning avisa o alguien lo reporta. Abrir incidencia **P1**.
2. **Contener y rotar primero** (borrar el commit no alcanza: el secreto ya es público):

   | Secreto | Cómo rotarlo | Efecto |
   |---|---|---|
   | `JWT_SECRET` | Generar otro (`openssl rand -hex 32`), actualizar `.env` / `gh secret set JWT_SECRET --env produccion`, reiniciar el backend | **Todas las sesiones quedan inválidas** (todos vuelven a iniciar sesión): es lo buscado |
   | `ACCESS_TOKEN` (MercadoPago) | Panel de MercadoPago → Credenciales → renovar | Revisar pagos/preferencias creados en la ventana de exposición |
   | `GROQ_API_KEY`, `YOUTUBE_API_KEY` | Revocar y crear una nueva en la consola del proveedor | Revisar consumo |
   | `DB_PASS` | `ALTER USER demo_hia PASSWORD '...'` + `.env` + reiniciar backend | Verificar que la BD no esté expuesta (SCRUM-61) |
   | `CLOUDFLARE_TUNNEL_TOKEN` | Zero Trust → Tunnels → *Refresh token* | El túnel viejo deja de conectar |
   | Token de Mantis / n8n | Mantis → Mi cuenta → Tokens de API → revocar | Recrear la credencial en n8n |

3. **Erradicar:** quitar el secreto del código (PR), y recién después limpiar el historial (`git filter-repo`) si hace falta.
4. **Recuperar:** smoke tests (`npm test`), login de prueba, verificar que el valor viejo ya no sirve.
5. **Lecciones:** ¿por qué no lo frenó la push protection? Agregar la regla que faltó.

### 4.2 Ransomware / cifrado o borrado de datos

1. **Detectar:** la app devuelve errores de BD, archivos con extensión rara, nota de rescate, alerta de disco.
2. **Contener de inmediato:** desconectar la PC/servidor de la red y bajar el túnel. **No apagar** si se puede evitar (preserva evidencia en memoria). No pagar el rescate.
3. **Erradicar:** reinstalar el host o recrear contenedores **desde las imágenes y el repo** (todo es reproducible: compose + `database/01_schema.sql`). Rotar **todas** las credenciales (4.1).
4. **Recuperar desde un backup sano:**
   ```bash
   # Elegir el último backup ANTERIOR al incidente y verificado (flujo n8n 2, SCRUM-77)
   # Procedimiento de SCRUM-38: pg_restore desde el contenedor de backups (volumen /backups)
   docker compose exec backup pg_restore -h db -U demo_hia -d demo_hia --clean --if-exists -v /backups/<backup-sano>.dump
   ```
   Si los backups del host también se cifraron, usar la **copia offline** (disco externo desconectado o nube con versionado). Verificar con smoke tests y conteo de filas.
5. **Lecciones:** ¿cómo entró? ¿El backup offline estaba al día? Cuánta pérdida hubo (RPO real vs. objetivo).

**Prevención:** regla 3-2-1 para backups (3 copias, 2 medios, 1 fuera del host/offline), probar la restauración (SCRUM-38) y verificación diaria con n8n (SCRUM-77).

### 4.3 Caída por DDoS / flood

1. **Detectar:** alerta de disponibilidad del blackbox (SCRUM-85) o latencia alta (SCRUM-68); en el flujo 4 aparecen muchas incidencias `rate_limit` de IPs distintas.
2. **Contener:**
   - Cloudflare → *Security → Settings* → **"I'm Under Attack" mode** (desafío JS a todo el tráfico).
   - Reglas WAF / bloqueo por país o ASN de origen.
   - Bajar `RATE_LIMIT_MAX` en el `.env` y reiniciar el backend.
3. **Erradicar:** cuando el pico pasa, revisar si apuntó a un endpoint costoso (búsquedas, IA) y agregar límites específicos.
4. **Recuperar:** desactivar "Under Attack", monitorear 24 h.
5. **Plan B para la demo:** mostrar la app en local (`http://localhost:8080`) o con un túnel rápido nuevo (SCRUM-60).

## 5. Flujo 4 de n8n: eventos de seguridad → clasificación → incidencia en Mantis

```
Backend GymHub ──POST (X-GymHub-Secret)──► n8n webhook /webhook/gymhub-seguridad
  • login_fallido (401/403)                  │
  • rate_limit (429, auth/global)            ▼
  • login_admin (login OK de un admin)   Clasificar y deduplicar (Code)
                                           │ fuerza bruta: ≥10 fallidos/IP en 5 min
                                           │ admin desde IP nueva (la 1.ª IP es la referencia)
                                           │ rate limit activado
                                           │ misma clave en < 1 h → no repite
                                           ▼
                                      ¿Abrir incidencia?
                                       │sí                    │no
                                       ▼                      ▼
                          POST Mantis /api/rest/issues    Solo registrar
                          (token n8n-bot, categoría Seguridad, tags SCRUM-84)
```

### 5.1 Componentes

| Parte | Archivo |
|---|---|
| Emisor de eventos en el backend (opcional, desactivado si no hay URL) | `backend/src/services/security-events.js`, `backend/src/middlewares/security-events.middleware.js`, handler 429 en `backend/config/security.js` |
| Variables | `SECURITY_EVENTS_WEBHOOK_URL`, `SECURITY_EVENTS_WEBHOOK_SECRET` (backend `.env` y `compose.dev.yaml`) |
| Flujo exportado | `infra/n8n/workflows/flujo-4-eventos-seguridad.json` |
| Tests | `backend/test/security-events.test.js` (5 casos) |

Garantías:

- El envío es "fire and forget" con 3 s de timeout: si n8n está caído, la API responde igual (hay un test que lo verifica).
- El webhook exige el secreto. Las credenciales viven en **Credentials** de n8n, nunca en el JSON del flujo (el JSON solo referencia sus nombres).

### 5.2 Instalación

1. Levantar Mantis (`bash infra/mantis/setup.sh`) y n8n (`infra/n8n`, SCRUM-75).
2. En n8n → *Credentials → New → Header Auth*:
   - **"GymHub - secreto de eventos de seguridad"**: nombre `X-GymHub-Secret`, valor = un secreto aleatorio (`openssl rand -hex 24`).
   - **"Mantis - token n8n-bot"**: nombre `Authorization`, valor = el `n8n_token` de `infra/mantis/credenciales.local.json`.
3. *Workflows → Import from file* → `flujo-4-eventos-seguridad.json` → asignar las dos credenciales → **Activate**.
4. En el `.env` de la raíz (lo lee `compose.dev.yaml`):
   ```
   SECURITY_EVENTS_WEBHOOK_URL=http://host.docker.internal:5679/webhook/gymhub-seguridad
   SECURITY_EVENTS_WEBHOOK_SECRET=<el mismo secreto>
   ```
   y recrear el backend.

En Linux, `host.docker.internal` requiere `extra_hosts: ["host.docker.internal:host-gateway"]` en el servicio (n8n y backend).

### 5.3 Prueba realizada (13/11/2026)

Instancia de n8n **2.47.7** descartable (`gymhub-n8n-prueba84`, volumen propio, borrada al terminar). Credenciales y flujo importados con la CLI de n8n (`import:credentials`, `import:workflow`) y flujo activado.

| Prueba | Resultado |
|---|---|
| POST al webhook **sin** el secreto | `403` |
| `login_admin` desde la primera IP (198.51.100.10) | Solo registro (IP de referencia) |
| `login_admin` desde 203.0.113.66 y 203.0.113.77 | Mantis **#5** y **#6**: "Login de administrador (admin@demo.com) desde IP nueva …" (mayor, urgente) |
| 9 `login_fallido` desde 192.0.2.200 | Solo registro |
| 10.º `login_fallido` | Mantis **#7**: "Posible fuerza bruta: 10 logins fallidos en 5 min desde 192.0.2.200" (mayor, alta) |
| 11.º `login_fallido` | Deduplicado: sin incidencia nueva |
| **De punta a punta:** 6 logins fallidos reales contra la API (Nginx → backend) | API: `401 401 401 401 401 429` → evento `rate_limit` → Mantis **#8** "Rate limit (auth) activado para 203.0.113.200", reportada por `n8n-bot` |

Historial de la #8 en Mantis:

```
#8 [nueva] [n8n] Rate limit (auth) activado para 203.0.113.200 · Seguridad · severidad menor · prioridad normal
  2026-11-13 13:13 n8n-bot: issue-new
  2026-11-13 13:13 n8n-bot: tag-added
```

Las incidencias #5–#8 son de esta prueba controlada. Se cierran en SCRUM-72 como prueba del flujo, no como incidentes reales.

## 6. Criterios de aceptación

| Criterio | Estado |
|---|---|
| Procedimiento: detección → contención → erradicación → recuperación → lecciones aprendidas, con responsables | ✔ Secciones 1–3 |
| Playbooks: credenciales filtradas (rotación de JWT_SECRET y claves), ransomware (restauración desde backup offline), caída por DDoS | ✔ Sección 4 |
| Flujo n8n (4.º, opcional): eventos de seguridad (muchos 401/429, login admin desde IP nueva) → clasificación → incidencia en Mantis | ✔ Sección 5, probado de punta a punta |
| Informe de seguridad final (documento obligatorio n.º 14) | ✔ [`14-informe-seguridad.md`](14-informe-seguridad.md) |
