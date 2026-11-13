# SCRUM-70 · Desplegar Mantis Bug Tracker y configurar categorías, prioridades y usuarios

**Épica:** E11 · Gestión de incidencias con Mantis  
**Responsable:** Valentín Iriarte  
**Rama:** `feat/SCRUM-70-mantis`

## 1. Arquitectura

```
PC del equipo (127.0.0.1:8990) ──► gymhub-mantis (PHP 8.3 + Apache, Mantis 2.28.4)
                                        │  red gymhub_mantis_internal (internal: sin salida a Internet)
                                        ▼
                                   gymhub-mantis-db (MariaDB 11.4) ── volumen gymhub_mantis_db
n8n ──── red gymhub_tools_net ──► http://mantis/api/rest/...  (token del usuario n8n-bot)
```

| Archivo | Contenido |
|---|---|
| [`infra/mantis/Dockerfile`](../infra/mantis/Dockerfile) | Imagen propia: `php:8.3-apache` + extensiones `mysqli`/`gd` + **release oficial de Mantis 2.28.4 verificado por SHA-256** (`a400bd29…`, igual al `.digests` publicado). Apache sin versión en cabeceras, sin listado de directorios, `/admin` solo desde el contenedor y `config_inc.php` bloqueado. |
| [`infra/mantis/entrypoint.sh`](../infra/mantis/entrypoint.sh) | Genera `config_inc.php` en cada arranque a partir de variables de entorno. La contraseña de la BD y la sal criptográfica nunca están en el repo ni en la imagen. Idioma español, zona horaria de Argentina, registro público y recuperación por email desactivados, API REST activa. |
| [`infra/mantis/docker-compose.yml`](../infra/mantis/docker-compose.yml) | Proyecto Compose `gymhub-mantis`: MariaDB con volumen persistente y healthcheck, en una red **interna**; Mantis publicado **solo en `127.0.0.1:8990`**; límites de CPU/RAM. |
| [`infra/mantis/setup.sh`](../infra/mantis/setup.sh) | Despliegue idempotente: genera `.env` con claves aleatorias, levanta todo, instala el esquema la primera vez y ejecuta `bootstrap.php`. |
| [`infra/mantis/bootstrap.php`](../infra/mantis/bootstrap.php) | Configuración con la API interna de Mantis: proyecto, categorías, usuarios, token de n8n y rotación de la contraseña de fábrica del administrador. |
| `infra/mantis/.gitignore` | Excluye `.env` y `credenciales.local*.json`. |

## 2. Puesta en marcha

```bash
bash infra/mantis/setup.sh            # primera vez (Git Bash en Windows o bash en Linux/macOS)
docker compose -f infra/mantis/docker-compose.yml --env-file infra/mantis/.env up -d   # uso diario
```

- URL: <http://localhost:8990> (solo desde la PC que corre Docker; ver SCRUM-61 para acceso remoto por Tailscale).
- Las contraseñas iniciales de cada usuario y el token de n8n quedan en `infra/mantis/credenciales.local.json`, que **no se sube**. Se reparten por un canal privado y cada integrante cambia la suya al entrar.
- Persistencia: la BD vive en el volumen `gymhub_mantis_db`. `docker compose down` no la borra; `down -v` sí.

## 3. Configuración aplicada

### 3.1 Proyecto

| Campo | Valor |
|---|---|
| Nombre | GymHub |
| Estado | Desarrollo |
| Visibilidad | **Privado**: solo miembros del proyecto |
| Convención | Cada incidencia referencia su ticket de Jira (`SCRUM-XX`) y el PR que la resuelve |

### 3.2 Categorías

Backend · Frontend · Base de datos · Infraestructura · Seguridad · Rendimiento · CI/CD · Automatización.

"General" es la categoría global que trae Mantis; se mantiene para lo que no encaja en ninguna de las anteriores.

### 3.3 Severidades (qué tan grave es)

| Severidad Mantis | Uso en GymHub | Ejemplo |
|---|---|---|
| _(etiquetas tal como las muestra Mantis en español)_ | | |
| **bloqueo** (block) | Impide usar la app o desplegar | API caída, la BD no levanta |
| **fallo** (crash) | Pérdida de datos, fallo de seguridad explotable, fraude | Pagos que se marcan sin verificar |
| **mayor** (major) | Función principal rota o degradada; vulnerabilidad alta | Backup que no restaura, consulta de 48 s |
| **menor** (minor) | Falla con alternativa; default | Mensaje de error confuso |
| **trivial / texto / ajuste** | Cosmético, textos, mejoras chicas | Typo en un label |
| **funcionalidad** (feature) | Pedido de mejora, no es defecto | — |

### 3.4 Prioridades (qué tan rápido se atiende)

| Prioridad | Tiempo objetivo | Cuándo |
|---|---|---|
| **inmediata** | Mismo día | Seguridad explotable o caída en la demo |
| **urgente** | ≤ 24 h | Severidad bloqueo/caída sin workaround |
| **alta** | Dentro del sprint | Severidad mayor |
| **normal** (default) | Planificar en el backlog | Severidad menor |
| **baja / ninguna** | Cuando haya tiempo | Cosmético |

### 3.5 Flujo de estados

`nueva → asignada → resuelta → cerrada` (Mantis también ofrece "se necesitan más datos", "aceptada" y "confirmada" como pasos intermedios opcionales). "Resuelta" = fix mergeado con PR referenciado. "Cerrada" = verificación hecha con evidencia (SCRUM-72).

### 3.6 Usuarios y roles

| Usuario | Integrante | Rol (global y en el proyecto) | Por qué |
|---|---|---|---|
| `viriarte` | Valentín Iriarte | **manager** | Responsable de la épica de incidencias: asigna, resuelve y cierra |
| `fparedes` | Francisco Paredes | **manager** | Scrum master / CI-CD |
| `vlozano` | Valentín Lozano | developer | Resuelve incidencias asignadas |
| `evillagran` | Enzo Villagrán | developer | Resuelve incidencias asignadas |
| `tgallo` | Tiziano Gallo | developer | Resuelve incidencias asignadas |
| `n8n-bot` | Servicio n8n | **reporter** (mínimo) | Solo crea incidencias y agrega notas; no puede asignar, resolver ni administrar |
| `administrator` | Cuenta de Mantis | administrator | Solo para mantenimiento. Contraseña de fábrica (`root`) **rotada** automáticamente |

Los emails son `<usuario>@gymhub.local`: las notificaciones por correo están desactivadas y el seguimiento se hace en el historial de cada incidencia.

### 3.7 Usuario de API para n8n

- Token `n8n` del usuario `n8n-bot`. Se genera una sola vez y se guarda en `credenciales.local.json`.
- En n8n se carga como **credencial** (Header Auth `Authorization: <token>`) o como `MANTIS_API_TOKEN` en `infra/n8n/.env`. Nunca dentro del JSON del flujo (SCRUM-75).
- n8n llega a Mantis por la red `gymhub_tools_net` con `http://mantis/api/rest/...`, la URL que ya usa el flujo 2 de SCRUM-77.

## 4. Verificación

```
$ bash infra/mantis/setup.sh
→ Instalando el esquema de Mantis
→ Configurando proyecto, categorías, usuarios y token de n8n
Proyecto GymHub id=1 · categorías=9 · miembros=6
→ Credenciales NUEVAS guardadas en infra/mantis/credenciales.local.json (no se suben al repo).
✔ Mantis listo en http://localhost:8990

$ bash infra/mantis/setup.sh          # segunda ejecución: idempotente
→ Esquema ya instalado
→ No se generaron credenciales nuevas (todo ya existía).
```

API REST con el token de `n8n-bot`:

```
GET /api/rest/users/me  → usuario: n8n-bot | nivel: reporter | proyectos: GymHub
GET /api/rest/projects  → proyecto: GymHub | visibilidad: privado
                          categorías: Automatización, Backend, Base de datos, CI/CD, Frontend, General, Infraestructura, Rendimiento, Seguridad
GET /api/rest/projects (sin token) → 401
```

Accesos restringidos (desde el host):

```
/login_page.php → 200      /admin/ → 403      /config/ → 403
/core/ → 403               /vendor/ → 403     /config/config_inc.php → 403
docker ps → gymhub-mantis  127.0.0.1:8990->80/tcp  (healthy)
            gymhub-mantis-db  3306/tcp (sin publicar, red interna)  (healthy)
```

## 5. Criterios de aceptación

| Criterio | Estado |
|---|---|
| Mantis en Docker con su BD (MariaDB) y volúmenes persistentes | ✔ MariaDB 11.4 + volumen `gymhub_mantis_db` |
| Proyecto GymHub con categorías: Backend, Frontend, Base de datos, Infraestructura, Seguridad, Rendimiento, CI/CD, Automatización | ✔ 3.1 y 3.2 |
| Prioridades y severidades definidas; los 5 integrantes como usuarios con rol | ✔ 3.3, 3.4 y 3.6 |
| Usuario de API con token de permisos mínimos para n8n | ✔ `n8n-bot` con rol reporter + token (3.7) |
| Acceso restringido (no publicado a Internet) | ✔ Solo `127.0.0.1:8990`, proyecto privado, sin registro público, `/admin` bloqueado |
