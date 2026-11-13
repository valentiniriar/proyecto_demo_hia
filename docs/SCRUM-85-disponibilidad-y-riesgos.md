# SCRUM-85 · Medir disponibilidad, registrar errores y análisis de riesgos de la publicación

**Épica:** E09 · Publicación y acceso desde Internet (túnel seguro)  
**Responsable:** Valentín Iriarte  
**Rama:** `feat/SCRUM-85-disponibilidad-publicacion`

## 1. Cómo se mide

```
Prometheus ──cada 30 s──► blackbox-exporter ──HTTPS──► https://<url-pública>/api/health
     │                    (sale a Internet y entra por Cloudflare, igual que un visitante)
     └──cada 15 s──► cloudflared :2000/metrics  (conexiones con el edge, requests, errores al origen)
```

- La sonda va **desde afuera hacia adentro**: resuelve el DNS público, pasa por Cloudflare y el túnel, llega a Nginx y al backend, y `/api/health` consulta la BD. Un `200` significa que **toda la cadena** funciona.
- Módulo `https_publico` del blackbox: exige HTTPS válido (`fail_if_not_ssl`, sin `insecure_skip_verify`), sigue redirecciones y tiene timeout de 10 s.
- **Disponibilidad** = `avg_over_time(probe_success{job="blackbox-publico"}[48h]) × 100`.

### 1.1 Cambios

| Archivo | Cambio |
|---|---|
| `infra/monitoring/prometheus/prometheus.yml` | Jobs `blackbox-publico` (sonda HTTPS a la URL pública) y `cloudflared` (métricas del túnel), con targets por **archivo** (`file_sd`) para no editar la config cada vez que cambia la URL del túnel rápido. Resuelve el pendiente "agregar URL pública con HTTPS" que dejó SCRUM-66 |
| `infra/monitoring/blackbox/blackbox.yml` | Módulo `https_publico` |
| `infra/monitoring/prometheus/alerts/gymhub.rules.yml` | Grupo `gymhub-publicacion` con 6 reglas (validadas con `promtool`: 14 reglas en total, sin errores) |
| `infra/monitoring/docker-compose.yml` | Monta `prometheus/targets/` |
| `compose.tunnel.yaml` | Publica las métricas de cloudflared en `127.0.0.1:2000` (solo local) |
| `infra/monitoring/publicar-target.sh` | Detecta la URL del túnel rápido (o recibe la del túnel con nombre) y genera los targets. Los archivos generados no se versionan |
| `infra/monitoring/reporte-disponibilidad.sh` | Reporte en Markdown para una ventana dada: disponibilidad, sondas fallidas, latencia, vencimiento del certificado, conexiones del túnel, errores al origen, 5xx de Nginx, cortes del túnel y alertas activas |

### 1.2 Alertas de la publicación

| Alerta | Condición | Severidad |
|---|---|---|
| `GymHubUrlPublicaCaida` | `probe_success == 0` durante 2 min | crítica |
| `GymHubUrlPublicaLenta` | sonda > 3 s durante 5 min | advertencia |
| `GymHubCertificadoPorVencer` | certificado vence en < 7 días | advertencia |
| `GymHubTunelCaido` | `up{job="cloudflared"} == 0` durante 2 min | crítica |
| `GymHubTunelSinConexiones` | `cloudflared_tunnel_ha_connections < 1` durante 2 min | crítica |
| `GymHubTunelErroresOrigen` | > 5 errores hacia Nginx en 5 min | advertencia |

## 2. Procedimiento de medición de 48 h (antes de la defensa)

```bash
# 1. App + túnel (la PC tiene que quedar encendida y sin suspender)
docker compose -f compose.yaml -f compose.dev.yaml -f compose.tunnel.yaml --profile tunel-rapido up -d --build
# 2. Monitoreo
cd infra/monitoring && docker compose up -d && cd ../..
# 3. Registrar la URL pública como target
bash infra/monitoring/publicar-target.sh            # o: bash infra/monitoring/publicar-target.sh https://gymhub.<dominio>
# 4. Dejar correr al menos 48 h y generar el reporte
bash infra/monitoring/reporte-disponibilidad.sh 48h docs/evidencias/SCRUM-85/reporte-48h.md
```

Recomendaciones para la ventana de medición:

- En Windows, *Configuración → Energía* en "nunca suspender".
- Docker Desktop configurado para iniciar con la sesión.
- Usar el **túnel con nombre** si está disponible: su URL no cambia si se reinicia el contenedor.
- En paralelo, opcional: un monitor externo gratuito (UptimeRobot, cada 5 min) a la misma URL, como segunda fuente independiente de la PC.

> **Estado:** la infraestructura de medición está lista y probada (sección 3). La corrida de 48 h depende de dejar la PC publicando antes de la fecha de defensa. Cuando termine, se adjunta `reporte-48h.md` a esta carpeta y al ticket.

## 3. Prueba realizada (13/11/2026)

Stack: app (`compose.dev`) + túnel rápido + monitoreo (Prometheus 3.5.0, blackbox 0.29.1, Alertmanager 0.28.1).

**Sonda sana** (antes de la falla):

```
blackbox-publico  https://<url-efimera>.trycloudflare.com/api/health   up
cloudflared       host.docker.internal:2000                              up
probe_success = 1 · probe_http_status_code = 200 · probe_http_ssl = 1
días hasta el vencimiento del certificado = 51 · probe_duration_seconds = 0,97
cloudflared_tunnel_ha_connections = 1
reglas gymhub-publicacion: 6 cargadas, estado ok/inactive
```

**Falla simulada:** se detuvo el Nginx de origen (`docker stop gymhub_frontend_dev`) de 13:33:07 a 13:36:34.

```
Visitante → https://<url>/api/health : 502 502 502 502 502 502   (Cloudflare no llega al origen)
Prometheus  → GymHubUrlPublicaCaida     firing
              GymHubTunelErroresOrigen  firing
Alertmanager→ GymHubUrlPublicaCaida active · GymHubTunelErroresOrigen active
Recuperación: probe_success vuelve a 1 a las 13:36:49 (15 s después de levantar Nginx)
```

Reporte generado por el script para esa ventana: [`evidencias/SCRUM-85/reporte-prueba-falla.md`](evidencias/SCRUM-85/reporte-prueba-falla.md).

- Disponibilidad 46,2 % en 25 min, dominada por la caída provocada.
- 7 sondas fallidas.
- 13 requests que el túnel no pudo entregar al origen, con hora y causa (`Unable to reach the origin service`).
- 0 cortes del túnel: el túnel siguió conectado; lo que falló fue el origen.

Durante la prueba aparecieron dos alertas **previas a este ticket**, que no son de la publicación:

- `GymHubFrontendUnavailable`: la regla de SCRUM-68 sondea `host.docker.internal:8081`, pero el frontend de `compose.dev` está en el 8080.
- `GymHubExporterUnavailable`: cAdvisor no arranca en Docker Desktop para Windows porque no puede montar `/var/run/docker.sock`.

Quedan informadas para SCRUM-66/68.

## 4. Registro de errores

Los errores relevantes de la publicación quedan registrados en tres lugares:

| Error | Dónde queda | Cómo se consulta |
|---|---|---|
| Caídas y lentitud vistas desde afuera | Serie `probe_success` / `probe_duration_seconds` en Prometheus (retención 7 días) + alertas | `reporte-disponibilidad.sh`, Grafana, `http://localhost:9090/alerts` |
| 5xx devueltos por la app | Log de acceso de Nginx (`docker logs gymhub_frontend_dev`) | Sección "5xx" del reporte |
| Requests que no llegan al origen (502 de Cloudflare) | Log de cloudflared (`ERR Request failed`) + métrica `cloudflared_tunnel_request_errors` | Sección "Errores hacia el origen" del reporte |
| Cortes y reconexiones del túnel | Log de cloudflared (`Connection terminated`, `Registered tunnel connection`) + `cloudflared_tunnel_ha_connections` | Sección "Eventos del túnel" del reporte |
| Incidentes | Mantis (categoría Infraestructura/Seguridad), a mano o con el flujo n8n 4 | `node infra/mantis/incidencias.js listar` |

## 5. Análisis de riesgos y limitaciones de Cloudflare Tunnel

| # | Riesgo / limitación | Prob. | Impacto | Mitigación |
|---|---|---|---|---|
| R1 | **La PC tiene que estar encendida**: si se apaga, se suspende o se reinicia Windows (updates), la app desaparece de Internet | Alta | Alto | Desactivar suspensión y reinicio automático durante la ventana; Docker Desktop al inicio; `restart: unless-stopped` en todos los contenedores; alerta `GymHubUrlPublicaCaida` |
| R2 | **Ancho de banda y estabilidad de la conexión doméstica** (subida limitada, cortes del proveedor, Wi-Fi) | Media | Medio | Conexión por cable; la SPA es estática y liviana; Cloudflare cachea nada sensible (solo estáticos); `GymHubTunelSinConexiones` avisa |
| R3 | **Dependencia de un tercero (Cloudflare)**: una caída o cambio de condiciones del servicio afecta la publicación. El túnel rápido **no tiene SLA**, cambia de URL en cada arranque y tiene límites de uso | Baja (túnel con nombre) / Media (túnel rápido) | Alto | Túnel con nombre y dominio propio para la defensa; plan B (sección 6); la configuración está versionada y se reconstruye en minutos |
| R4 | Cloudflare termina el TLS: **ve el tráfico en claro** (incluidas credenciales de login) | Cierta (por diseño) | Medio | Aceptado para el TP; mitigable con *Full (strict)* y certificado de origen en Nginx |
| R5 | Recursos de la PC compartidos con el uso personal (CPU/RAM al 100 %) | Media | Medio | Límites de CPU/RAM por contenedor (SCRUM-53); alertas de CPU, memoria y disco (SCRUM-68) |
| R6 | Robo del token del túnel → alguien conecta **su** origen a nuestro hostname | Baja | Alto | Token solo en `.env` / Environment; *Refresh token* en el panel (playbook SCRUM-84) |
| R7 | Exposición de la app a ataques de Internet | Media | Alto | Ver SCRUM-61, SCRUM-63, SCRUM-65 y SCRUM-81: solo el frontend publicado, rate limit, cabeceras, pruebas de seguridad |
| R8 | Monitoreo en la **misma PC**: si la PC cae, cae también el que avisa | Alta (si ocurre R1) | Medio | Monitor externo independiente (UptimeRobot) como segunda fuente |

## 6. Plan B para la demo

| Situación en la defensa | Acción | Tiempo |
|---|---|---|
| La URL del túnel con nombre no responde | Levantar el túnel rápido: `docker compose ... --profile tunel-rapido up -d` y compartir la nueva URL `*.trycloudflare.com` | ~1 min |
| No hay Internet en el aula / Cloudflare caído | Demo **local** en la notebook: `http://localhost:8080` (mismo stack, misma BD) | Inmediato |
| La PC que publica falla | Otra notebook del equipo con el repo: `docker compose -f compose.yaml -f compose.dev.yaml up -d --build` (BD con datos demo desde `database/02_seed.sql`) | ~5 min |
| Falla la base de datos | Restaurar el último backup (SCRUM-38) o recrear el volumen con el seed | ~2 min |
| Todo falla | Video y capturas de la demo grabados con anticipación (SCRUM-88) | Inmediato |

## 7. Criterios de aceptación

| Criterio | Estado |
|---|---|
| Disponibilidad medida (blackbox de Prometheus y/o UptimeRobot) durante al menos 48 h previas a la defensa | ⏳ **Infraestructura lista y probada** (sondas, alertas y reporte, con una falla simulada). **Pendiente:** la corrida de 48 h con la PC publicando antes de la defensa (procedimiento en la sección 2) |
| Errores relevantes registrados (5xx, caídas del túnel) | ✔ Sección 4; probado con la falla simulada |
| Análisis de riesgos y limitaciones de Cloudflare Tunnel (dependencia de terceros, la PC debe estar encendida, ancho de banda doméstico) y plan B para la demo | ✔ Secciones 5 y 6 |
