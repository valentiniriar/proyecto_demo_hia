# SCRUM-61 · Control de acceso y firewall: solo servicios necesarios expuestos

**Épica:** E09 · Publicación y acceso desde Internet (túnel seguro)  
**Responsable:** Valentín Iriarte  
**Rama:** `feat/SCRUM-61-control-acceso-firewall`

## 1. Principio

Desde Internet se ve **un solo servicio**: el Nginx del frontend, a través de Cloudflare Tunnel (SCRUM-60). Todo lo demás (API directa, PostgreSQL, pgAdmin, Prometheus, Grafana, Alertmanager, n8n, Mantis, Nextcloud) se usa **desde la PC que corre Docker** (`127.0.0.1`) o, para administración remota, por **Tailscale** o **Cloudflare Access**. Nunca se publica en el router ni en la LAN.

## 2. Matriz de acceso (quién puede acceder a qué)

| Servicio | Puerto interno | Publicado en | Socio / público | Entrenador | Admin GymHub | Equipo técnico (5 integrantes) | Cómo se accede |
|---|---|---|---|---|---|---|---|
| Frontend (Nginx + SPA) | 8080 | Túnel Cloudflare (HTTPS) · `127.0.0.1:8080` | ✔ | ✔ | ✔ | ✔ | URL pública |
| API (`/api/*`) | 3000 | Solo detrás de Nginx · `127.0.0.1:3000` en dev | ✔ según rol (JWT) | ✔ según rol | ✔ | ✔ | Vía Nginx (`/api`) |
| Swagger (`/api/docs`) | 3000 | Vía Nginx | ✖ (recomendado: Cloudflare Access) | ✖ | ✔ | ✔ | Cloudflare Access por email |
| PostgreSQL primario / réplica | 5432 | `127.0.0.1:5433` / `:5434` (dev); sin puerto en prod | ✖ | ✖ | ✖ | ✔ solo lectura/DBA | Local o Tailscale |
| pgAdmin | 80 | `127.0.0.1:5050` (solo dev) | ✖ | ✖ | ✖ | ✔ | Local o Tailscale |
| Prometheus / Alertmanager | 9090 / 9093 | `127.0.0.1` | ✖ | ✖ | ✖ | ✔ | Local o Tailscale |
| Grafana | 3000 | `127.0.0.1:3001` | ✖ | ✖ | ✔ lectura (dashboard) | ✔ | Tailscale o Cloudflare Access |
| n8n | 5678 | `127.0.0.1:5679` | ✖ | ✖ | ✖ | ✔ | Local o Tailscale |
| Mantis | 80 | `127.0.0.1:8990` (SCRUM-70) | ✖ | ✖ | ✖ | ✔ (usuarios con rol) | Local o Tailscale |
| Nextcloud | 80 | Sin publicar | ✖ | ✖ | ✖ | ✔ | Tailscale |
| Métricas de cloudflared | 2000 | Solo red Docker | ✖ | ✖ | ✖ | Prometheus | Interno |

Reglas: mínimo privilegio, cuentas nominales (no compartidas) y ningún panel de administración en la URL pública sin una capa de identidad adelante.

## 3. Cambios en el repositorio

| Archivo | Antes | Después |
|---|---|---|
| `compose.dev.yaml` · frontend | `8080:8080` (todas las interfaces → visible en la LAN) | `${GYMHUB_BIND:-127.0.0.1}:8080:8080`. Para mostrarlo en la LAN a propósito: `GYMHUB_BIND=0.0.0.0` (mejor usar el túnel). |
| `compose.dev.yaml` · frontend | Nginx llegaba a la API por `host.docker.internal:3000` (obligaba a publicar el backend en el host) | `BACKEND_UPSTREAM=http://backend:3000` por la red interna `gymhub_frontend_net` |
| `compose.dev.yaml` · backend | `3000:3000` (todas las interfaces) | `127.0.0.1:3000:3000` (Swagger y debugging solo desde la PC) |
| `docker-compose.yml` (legado) · `db-dev` | `${DB_PORT:-5433}:5432` (todas las interfaces) | `127.0.0.1:${DB_PORT:-5433}:5432` |
| `infra/firewall/windows-firewall-gymhub.ps1` | — | Script idempotente que crea reglas de **bloqueo de entrada** para los 13 puertos de la app y las herramientas (grupo `GymHub (SCRUM-61)`), con `-Listar` y `-Quitar` |

Ya estaban bien y no se tocaron: pgAdmin, Prometheus, Alertmanager, Grafana y n8n (todos ligados a `127.0.0.1`), y `compose.prod.yaml` (BD sin puertos).

## 4. Firewall del host

### 4.1 Windows (PC de desarrollo / demo)

Estado verificado de los perfiles: `Domain`, `Private` y `Public` habilitados.

Aplicar las reglas (PowerShell **como administrador**, desde la raíz del repo):

```powershell
.\infra\firewall\windows-firewall-gymhub.ps1          # crea las 13 reglas de bloqueo
.\infra\firewall\windows-firewall-gymhub.ps1 -Listar  # evidencia para el informe
```

| Regla (grupo `GymHub (SCRUM-61)`) | Dirección | Acción | Puertos TCP |
|---|---|---|---|
| GymHub - bloquear entrada TCP … | Entrada | Bloquear | 3000, 8080, 5432, 5433, 5434, 5050, 9090, 9093, 3001, 5678, 5679, 8990, 2000 |

No hace falta **ninguna** regla de permiso: `cloudflared` solo abre conexiones **salientes** (TCP/UDP 7844) hacia Cloudflare. Tampoco hay que configurar reenvío de puertos (port forwarding) en el router: verificar que no exista ninguno y que UPnP esté desactivado.

> Las reglas las aplica el dueño de la PC. Este ticket no modifica la configuración de seguridad del sistema operativo de forma automática.

### 4.2 Linux (servidor con self-hosted runner, SCRUM-57)

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 100.64.0.0/10 to any port 22 proto tcp   # SSH solo por Tailscale
sudo ufw enable && sudo ufw status verbose
```

Docker escribe sus propias reglas de iptables y puede saltear `ufw` para puertos publicados en `0.0.0.0`. Por eso la regla principal es **no publicar puertos** (o ligarlos a `127.0.0.1`), como hacen los compose de este repo.

## 5. Administración remota sin exponer paneles

**Opción A: Tailscale (recomendada para el equipo técnico).** Cada integrante instala Tailscale y entra a la tailnet del proyecto. En la PC/servidor:

```bash
tailscale serve --bg --https=8443 http://127.0.0.1:3001   # Grafana
tailscale serve --bg --https=8444 http://127.0.0.1:5050   # pgAdmin
```

Solo los dispositivos de la tailnet ven esos puertos; nada queda publicado en Internet.

**Opción B: Cloudflare Access (para lo que sí pasa por el túnel).** En Zero Trust → *Access → Applications → Self-hosted*:

- Aplicación `gymhub.<dominio>/api/docs` (y, si se publica, `grafana.<dominio>`).
- Política **Allow** → *Emails*: los 5 integrantes. Todo lo demás se rechaza.
- Método de login: código de un solo uso por email.

## 6. Evidencia: escaneo nmap

Escaneo TCP de los puertos 1–10000 contra la IP de la PC en la LAN (`192.168.100.11`), con nmap 7.95 desde un contenedor (otra pila de red). Salidas completas en [`evidencias/SCRUM-61/`](evidencias/SCRUM-61/).

| Puerto | Antes | Después | Qué es |
|---|---|---|---|
| **8080** | **open** | cerrado/filtrado | Frontend GymHub (ahora solo `127.0.0.1` y por el túnel) |
| 3000, 5433, 5050 | filtrado | filtrado | API, BD y pgAdmin de GymHub (ya `127.0.0.1` o ligados ahora) |
| 135, 139, 445, 5040 | open | open | Servicios propios de Windows (RPC/SMB). No son de GymHub; con el perfil de red **Público** el firewall de Windows los bloquea en redes ajenas. |
| 5432 | open | open | Servicio **PostgreSQL 17 de Windows** instalado en la PC (no es el de GymHub, que usa 5433 en Docker). Escucha en todas las interfaces: lo cubre la regla de bloqueo de 5432 del script. |
| 3307, 8989 | open | open | Contenedores de **otro trabajo práctico** (MySQL y Mantis en `Downloads/mantis-tp`), ajenos a GymHub. Se recomienda ligarlos a `127.0.0.1` o detenerlos durante la demo. |

**Conclusión:** después del cambio, la LAN no ve **ningún** puerto de GymHub. Lo que queda abierto en la PC no pertenece al proyecto y está identificado.

Desde Internet: la PC no tiene puertos reenviados en el router; lo único alcanzable es la URL de Cloudflare (443), que solo enruta al Nginx del frontend. Al detener el túnel la URL responde `530` (ver SCRUM-60). La prueba desde una red externa real (datos móviles) es parte de **SCRUM-62**.

## 7. Criterios de aceptación

| Criterio | Estado |
|---|---|
| BD, pgAdmin, Prometheus, n8n, Mantis y Nextcloud NO publicados directamente; admin solo por Tailscale o Cloudflare Access con email autorizado | ✔ Ninguno en el túnel ni en la LAN (sección 3 y nmap). Procedimiento de Tailscale y Cloudflare Access en la sección 5. **Pendiente de quien administre la cuenta de Cloudflare:** crear la política de Access. |
| Firewall de Windows / host con reglas documentadas | ✔ Script versionado + tabla de reglas + `ufw` para Linux. **Pendiente:** que el dueño de la PC lo ejecute como administrador y adjunte la salida de `-Listar`. |
| Escaneo nmap desde fuera mostrando solo lo necesario | ✔ Antes/después desde otra pila de red: ningún puerto de GymHub expuesto. El escaneo desde una red externa real se suma en SCRUM-62. |
| Definición de quién puede acceder a qué (matriz) | ✔ Sección 2 |
