# SCRUM-60 · Publicar la app con Cloudflare Tunnel y HTTPS

**Épica:** E09 · Publicación y acceso desde Internet (túnel seguro)  
**Responsable:** Valentín Iriarte  
**Rama:** `feat/SCRUM-60-cloudflare-tunnel`

## 1. Qué se publica y cómo

```
Navegador (Internet)
   │  HTTPS (certificado gestionado por Cloudflare)
   ▼
Cloudflare Edge ── TLS, DDoS básico, WAF
   ▲
   │  túnel saliente iniciado desde nuestra red (QUIC/HTTP2, puerto 7844)
   │  → el router NO tiene puertos abiertos
┌──┴──────────────── Docker · red gymhub_frontend_net ────────────────┐
│  cloudflared ──HTTP──► frontend (Nginx :8080) ──/api/──► backend :3000 │
└──────────────────────────────────────────────────────────┬─────────┘
                                                           │ red gymhub_db_net
                                                           ▼
                                                    PostgreSQL (db)
```

- **Un solo servicio publicado:** el Nginx del frontend. Sirve la SPA de Angular y hace de proxy de `/api/` hacia el backend por la red interna de Docker.
- BD, pgAdmin, Prometheus, Grafana, n8n y Mantis **no tienen regla de ingreso** en el túnel.
- El túnel es una **conexión saliente**: no hace falta abrir puertos ni tener IP pública fija.

## 2. Archivos

| Archivo | Para qué |
|---|---|
| [`compose.tunnel.yaml`](../compose.tunnel.yaml) | Overlay de Compose. Agrega `cloudflared` (túnel con nombre, perfil `tunel`) y `cloudflared-rapido` (TryCloudflare, perfil `tunel-rapido`). Hace que Nginx llegue al backend por la red interna (`BACKEND_UPSTREAM=http://backend:3000`). |
| [`infra/cloudflared/config.yml`](../infra/cloudflared/config.yml) | Configuración versionada del túnel (**sin credenciales**): ingreso único hacia `http://frontend:8080` y métricas en `:2000` para Prometheus (SCRUM-85). |
| `frontend/nginx.conf` + `frontend/Dockerfile` | `proxy_pass` pasa a ser `${BACKEND_UPSTREAM}` (plantilla de Nginx). El default sigue siendo `http://host.docker.internal:3000`, así que el modo de desarrollo no cambia. |
| `.env.example` | Nueva variable `CLOUDFLARE_TUNNEL_TOKEN` (vacía). El valor real va solo en `.env`, que está en `.gitignore`. |

Endurecimiento del contenedor `cloudflared`: imagen fijada por versión **y digest** (`2026.10.7@sha256:4955…`), `read_only`, `no-new-privileges`, `cap_drop: ALL`, límite de 0,5 CPU / 128 MB.

## 3. Puesta en marcha

### 3.1 Opción A — Túnel rápido (demo en clase, sin cuenta)

```bash
docker compose -f compose.yaml -f compose.dev.yaml -f compose.tunnel.yaml --profile tunel-rapido up -d --build
docker logs gymhub_cloudflared_rapido 2>&1 | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com'
```

Devuelve una URL `https://<palabras-al-azar>.trycloudflare.com` con HTTPS válido. Cambia cada vez que se reinicia el contenedor y no tiene garantía de disponibilidad: sirve para la demo, no para producción.

### 3.2 Opción B — Túnel con nombre (dominio propio)

1. En Cloudflare Zero Trust → *Networks → Tunnels → Create a tunnel* → tipo **Cloudflared**, nombre `gymhub`.
2. Copiar el **token** que muestra el asistente y guardarlo en el `.env` de la raíz (nunca en el repo):
   ```
   CLOUDFLARE_TUNNEL_TOKEN=eyJhIjoi...
   ```
   Para el pipeline: `gh secret set CLOUDFLARE_TUNNEL_TOKEN --env produccion` (SCRUM-58).
3. En *Public Hostnames* del túnel: `gymhub.<dominio>` → servicio `HTTP` → `frontend:8080` (igual que `config.yml`).
4. Levantar:
   ```bash
   docker compose -f compose.yaml -f compose.dev.yaml -f compose.tunnel.yaml --profile tunel up -d --build
   ```
5. Opcional, recomendado: en *Access → Applications* proteger `/api/docs` y cualquier panel de administración con una política por email (SCRUM-61).

Si el token se filtra: en el panel, *Tunnels → gymhub → Refresh token* (lo invalida) y actualizar `.env` y el secreto del Environment.

## 4. Verificación

Prueba real del 13/11/2026 con el túnel rápido, desde la PC de desarrollo (Windows + Docker Desktop), stack `compose.yaml + compose.dev.yaml + compose.tunnel.yaml`.

## 5. Evidencia

**URL pública obtenida:** `https://federal-stephen-west-royalty.trycloudflare.com` (efímera, ya cerrada).

Certificado presentado (verificado con `tls.connect` de Node):

```
authorized: true | protocol: TLSv1.3
subject CN: trycloudflare.com | SAN: DNS:trycloudflare.com, DNS:*.trycloudflare.com
issuer: Google Trust Services / WE1
valid: Oct  5 20:58:33 2026 GMT -> Jan  3 21:58:20 2027 GMT
```

Peticiones a través del túnel:

```
GET  /                 -> HTTP 200, TLS verify=0 (OK), IP remota 104.16.231.132 (Cloudflare)
GET  /api/health       -> {"status":"ok","db":"up","uptime":30}
POST /api/auth/login   (socio@demo.com) -> {"status":"1","msg":"Login exitoso.","token":"eyJ..."}
```

La IP real del cliente llega al backend. Log de Nginx: la conexión viene del contenedor `cloudflared` (172.21.0.3) y `X-Forwarded-For` trae la IP pública del cliente (enmascarada acá). El rate limit de SCRUM-65 bloquea por esa IP:

```
401 401 401 401 401 429
172.21.0.3 - - [13/Nov/2026:15:17:33 +0000] "POST /api/auth/login HTTP/1.1" 429 103 "-" "curl/8.7.1" "<IP_PUBLICA_CLIENTE>"
```

Nginx renderizó la plantilla y llega al backend por la red interna:

```
20-envsubst-on-templates.sh: Running envsubst on /etc/nginx/templates/default.conf.template to /etc/nginx/conf.d/default.conf
proxy_pass http://backend:3000;
```

Home de GymHub abierta por la URL pública en Chrome: [`evidencias/SCRUM-60/home-por-tunel-https.jpg`](evidencias/SCRUM-60/home-por-tunel-https.jpg). El login completo de un socio en la SPA (servida por el mismo Nginx) llevó a la pantalla "¡Hola, Socio!".

Al detener `cloudflared`, la URL pasa a responder `530` (Cloudflare sin origen): no queda nada expuesto.

**Puertos:** no se tocó el router ni el firewall de Windows. `cloudflared` solo abre conexiones salientes a Cloudflare (puerto 7844). La prueba de acceso desde una red externa (datos móviles) y el escaneo desde afuera quedan en SCRUM-62 y SCRUM-61.

## 6. Limitaciones conocidas

- **Login con Google:** el `client_id` de Google OAuth solo acepta los orígenes autorizados en Google Cloud. Con una URL `trycloudflare.com` cambiante el botón de Google falla; el login con email y contraseña funciona. Con el túnel con nombre, agregar `https://gymhub.<dominio>` a *Authorized JavaScript origins*.
- **MercadoPago:** las `back_urls` apuntan a `localhost:4200`; para probar pagos desde Internet hay que configurar la URL pública.
- La PC que corre Docker tiene que estar encendida; el ancho de banda es el de la conexión doméstica (análisis completo en SCRUM-85).
- Usuarios demo (`*@demo.com` / `demo1234`): mientras el túnel esté abierto **cualquiera** puede usarlos. Cambiar las contraseñas (o borrar esos usuarios) antes de dejar la app publicada mucho tiempo.

## 7. Criterios de aceptación

| Criterio | Estado |
|---|---|
| URL pública con HTTPS válido (certificado gestionado por Cloudflare) | ✔ Sección 5 (TLS 1.3, certificado válido emitido para Cloudflare) |
| Token del túnel en `.env`, no en el repo | ✔ `CLOUDFLARE_TUNNEL_TOKEN` solo en `.env` (ignorado); `.gitignore` también cubre `cloudflared/*.json` |
| Ningún puerto abierto en el router/firewall local (conexión saliente) | ✔ cloudflared solo inicia conexiones salientes; ver sección 5 |
| Configuración del túnel versionada (sin credenciales) | ✔ `infra/cloudflared/config.yml` + `compose.tunnel.yaml` |
