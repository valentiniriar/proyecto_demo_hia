# SCRUM-73/74 · Desplegar Nextcloud con estructura de carpetas y matriz de permisos

**Épica:** Gestión documental · Nextcloud  
**Responsable:** Enzo Villagrán  
**Rama:** `feature/SCRUM-73-74-nextcloud`  
**Siguiente paso:** flujo n8n IA → Nextcloud (SCRUM-78), ver [sección 8](#8-pendiente-y-recomendaciones)

Nextcloud es el repositorio central de los informes del trabajo (sobre todo PDF y Markdown) y el destino donde n8n
deja los informes generados con IA. No se publica a Internet: se usa desde la PC servidor o por Tailscale.

## 1. Resumen de lo realizado

- **Despliegue en Docker** de `nextcloud:34-apache` con su **propia base PostgreSQL 16**. La base está en una red interna sin salida a Internet.
  Los datos viven en dos **volúmenes con nombre** (`gymhub_nextcloud_data` y `gymhub_nextcloud_db`), que sobreviven a reinicios y a `docker compose down`.
- **Instalación y configuración automáticas e idempotentes** con `infra/nextcloud/setup.sh`: genera las claves, instala Nextcloud y crea
  grupos, usuarios, carpetas y permisos. Se puede correr las veces que haga falta sin duplicar nada.
- **16 carpetas compartidas** (Team folders), de `01-Diagnóstico` a `15-Final` más `Informes-IA`. No pertenecen a ningún usuario, así que no se pierden si alguien deja el equipo.
- **3 grupos con una matriz de permisos**: `equipo` (control total), `docentes-lectura` (solo lectura) y `n8n-servicio` (solo escribe en `Informes-IA`).
- **Cuenta de servicio `n8n-bot`** con una **app password** que solo sirve para WebDAV. No permite entrar a la web, borrar ni compartir.
- **Compartición endurecida**: sin enlaces públicos, y docentes y n8n no pueden compartir nada.
- **Pruebas automáticas** de la matriz (18/18 OK), incluida la de **acceso denegado** a un usuario sin grupo, con evidencia en `docs/evidencias/SCRUM-73-74/`.
- **Backup** de la base y de los archivos con `infra/nextcloud/db/backup.sh`.
- **Integración** con las herramientas existentes: `scripts/infra.sh` (levantar, bajar, estado, credenciales), `scripts/tailscale-serve.sh`
  (puerto 8082 en la tailnet) y la documentación de SCRUM-61.

## 2. Arquitectura y archivos

```
PC del equipo (127.0.0.1:8082) ─┐
Tailscale (…ts.net:8082) ───────┴─► gymhub-nextcloud (nextcloud:34-apache) ── volumen gymhub_nextcloud_data
                                        │  red gymhub_nextcloud_internal (internal: sin salida a Internet)
                                        ▼
                                   gymhub-nextcloud-db (PostgreSQL 16) ── volumen gymhub_nextcloud_db
n8n ──── red gymhub_tools_net ──► http://nextcloud/remote.php/webdav/Informes-IA/  (n8n-bot + app password)
```

| Archivo | Contenido |
|---|---|
| [`infra/nextcloud/docker-compose.yml`](../infra/nextcloud/docker-compose.yml) | Proyecto `gymhub-herramientas` (junto con Mantis y n8n). Base con healthcheck en la red interna; Nextcloud **solo en `127.0.0.1:8082`**, con alias `nextcloud` en `gymhub_tools_net`; límites de CPU/RAM. |
| [`infra/nextcloud/setup.sh`](../infra/nextcloud/setup.sh) | Despliegue idempotente. `--regenerar` rota todas las contraseñas y la app password de n8n. |
| [`infra/nextcloud/cloud/bootstrap.sh`](../infra/nextcloud/cloud/bootstrap.sh) | Configuración con `occ`: carpetas, grupos, usuarios, matriz, compartición y app password. **Es la fuente de verdad**: en cada corrida vuelve a aplicar la matriz y corrige los cambios hechos a mano en la UI. |
| [`infra/nextcloud/cloud/gymhub.config.php`](../infra/nextcloud/cloud/gymhub.config.php) | Configuración sin secretos: español/Argentina, sin archivos de ejemplo para usuarios nuevos, papelera y versiones de 30 días. |
| [`infra/nextcloud/cloud/prueba-permisos.sh`](../infra/nextcloud/cloud/prueba-permisos.sh) | 18 pruebas WebDAV con las cuentas reales. No deja archivos de prueba. |
| [`infra/nextcloud/db/backup.sh`](../infra/nextcloud/db/backup.sh) | Dump de la base y tar de los archivos, en modo mantenimiento, hacia `backups/nextcloud/<fecha>/`. |
| `infra/nextcloud/.env.example` · `.gitignore` | Plantilla de variables. `.env` y `credenciales.local*.json` no se versionan. |

> `cloud/` y `db/` guardan **configuración y scripts**, no datos. Los documentos no se comparten por Git: se suben a Nextcloud.

## 3. Cómo usarlo localmente

Requisitos: Docker (Docker Desktop en Windows con Git Bash, o Docker Engine en Linux) y `openssl`. Todos los comandos se corren desde la raíz del repo.

### 3.1 Levantar y bajar

```bash
bash infra/nextcloud/setup.sh        # primera vez (1-3 min) o después de cambiar carpetas/usuarios/permisos
bash scripts/infra.sh levantar       # uso diario: Nextcloud junto con monitoreo, Mantis y n8n
bash scripts/infra.sh estado         # ¿responde? (fila "Nextcloud")
bash scripts/infra.sh bajar          # detiene todo; los datos quedan en los volúmenes
```

Solo Nextcloud, sin el resto:

```bash
docker compose -f infra/nextcloud/docker-compose.yml --env-file infra/nextcloud/.env up -d
docker compose -f infra/nextcloud/docker-compose.yml --env-file infra/nextcloud/.env down     # ⚠ nunca "down -v"
```

Los contenedores tienen `restart: unless-stopped` y vuelven a arrancar solos cuando se reinicia Docker.

### 3.2 Entrar

| Desde | URL |
|---|---|
| La PC servidor | <http://localhost:8082> |
| Otro dispositivo de la tailnet (después de `bash scripts/tailscale-serve.sh`) | <http://gymhub-servidor.tailec3350.ts.net:8082> |

| Cuenta | Para qué | Dónde está la contraseña |
|---|---|---|
| `admin` | Solo administración de Nextcloud | `NEXTCLOUD_ADMIN_PASS` en `infra/nextcloud/.env` |
| `viriarte`, `fparedes`, `vlozano`, `evillagran`, `tgallo` | Trabajo diario del equipo | `infra/nextcloud/credenciales.local.json` |
| `docente` | Corrección, solo lectura | ídem |
| `sin-acceso` | Solo para la prueba de acceso denegado | ídem |
| `n8n-bot` | Solo n8n, con app password | ídem (`"tipo": "n8n"`) |

`bash scripts/infra.sh credenciales` junta todas las credenciales en `produccion/CREDENCIALES.txt` (ignorado por Git).
Cada contraseña se reparte por un canal privado y el integrante la cambia al entrar (Configuración personal → Seguridad).

> `credenciales.local.json` contiene solo las credenciales generadas en **la última corrida que creó alguna**, y cada corrida
> deja también una copia `credenciales.local.<fecha>.json`. Si se pierde una contraseña: `bash infra/nextcloud/setup.sh --regenerar`
> (regenera **todas** y la app password de n8n; después hay que actualizar la credencial en n8n).

### 3.3 Subir documentos

- **Web:** entrar con un usuario de `equipo`, abrir la carpeta y arrastrar los archivos. Los `.md` se pueden ver y editar desde el navegador.
- **Cliente de escritorio de Nextcloud:** servidor `http://localhost:8082` (o la URL de Tailscale) para sincronizar carpetas.

**Persistencia:**

| Acción | ¿Se conserva el archivo? |
|---|---|
| Reiniciar la PC o Docker, `down` / `up -d`, `scripts/infra.sh bajar` | ✔ |
| Actualizar la imagen de Nextcloud | ✔ |
| `docker compose … down -v` o `docker volume rm gymhub_nextcloud_*` | ✖ **se borra todo** |

- Subir siempre por la web, WebDAV o el cliente, **nunca copiando archivos directo dentro del volumen**: Nextcloud no los registra
  (si pasara, corregir con `docker exec -u www-data gymhub-nextcloud php occ files:scan --all`).
- La copia de Nextcloud y la de `docs/` del repo son **independientes**: si se corrige un `.md` en el repo, hay que volver a subirlo.
  Nextcloud guarda la versión anterior durante 30 días.

### 3.4 Tareas de administración

| Tarea | Cómo |
|---|---|
| Agregar un usuario (por ej. un docente real) | Agregar una línea en `USUARIOS` de `cloud/bootstrap.sh` → `bash infra/nextcloud/setup.sh` → su contraseña queda en `credenciales.local.json`. Si está fuera de la PC, también hay que sumarlo a la tailnet. |
| Agregar una carpeta o cambiar permisos | Editar `CARPETAS` o las llamadas a `permisos` en `cloud/bootstrap.sh`, correr `setup.sh` y actualizar la [sección 5](#5-matriz-de-permisos). No cambiar permisos desde la UI: la próxima corrida los pisa. |
| Rotar contraseñas y la app password de n8n | `bash infra/nextcloud/setup.sh --regenerar` |
| Verificar la matriz | `bash infra/nextcloud/cloud/prueba-permisos.sh` (necesita que `credenciales.local.json` tenga evillagran, docente, sin-acceso y n8n; si no, correr `--regenerar`) |
| Backup | `bash infra/nextcloud/db/backup.sh` → `backups/nextcloud/<fecha>/` (ignorado por Git: contiene datos y la config con secretos) |
| Restaurar | Ver el encabezado de `db/backup.sh`: `psql` del dump y `tar xzf` en el volumen, con Nextcloud en modo mantenimiento. |
| Ejecutar `occ` | `docker exec -u www-data gymhub-nextcloud php occ <comando>` |

### 3.5 Problemas comunes

| Síntoma | Causa y solución |
|---|---|
| «Acceso mediante un dominio no confiable» | Se entró por una dirección que no está en `NEXTCLOUD_TRUSTED_DOMAINS` (por ej. la IP de la LAN). Usar `localhost` o la URL de Tailscale. Para agregar otra: ver los índices con `occ config:system:get trusted_domains` y usar el siguiente libre: `occ config:system:set trusted_domains <n> --value=<host>`. |
| `setup.sh` dice «Nextcloud no terminó de instalarse» | `docker logs gymhub-nextcloud`. Si la instalación falló a medias en un entorno **nuevo y sin datos**, `down -v` y repetir. |
| Queda «en mantenimiento» después de un backup cortado | `docker exec -u www-data gymhub-nextcloud php occ maintenance:mode --off` |
| Las respuestas tardan varios segundos después de errores de login | Protección contra fuerza bruta de Nextcloud. Se pasa sola. Se limpia con `occ security:bruteforce:reset <ip>`. |
| El puerto 8082 está ocupado | Cambiar `NEXTCLOUD_HOST_PORT` en `infra/nextcloud/.env` y `overwrite.cli.url` en `cloud/gymhub.config.php`. |

## 4. Estructura de carpetas y grupos

`01-Diagnóstico` · `02-Scrum` · `03-Git` · `04-BD-Docker` · `05-Optimización` · `06-Replicación` · `07-Contenedores` · `08-CICD` ·
`09-Publicación` · `10-Monitoreo` · `11-Incidencias` · `12-Documental` · `13-n8n` · `14-Seguridad` · `15-Final` · `Informes-IA`

| Grupo | Integrantes | Propósito |
|---|---|---|
| `equipo` | viriarte, fparedes, vlozano, evillagran, tgallo | Los 5 integrantes: suben, editan, organizan y comparten internamente. |
| `docentes-lectura` | docente | Corrección: ven todo y no pueden modificar nada. |
| `n8n-servicio` | n8n-bot | Cuenta de servicio de la automatización: solo escribe en `Informes-IA`. |
| _(ninguno)_ | sin-acceso | Usuario válido sin grupo; se usa únicamente en la prueba de acceso denegado. |

Los usuarios nuevos empiezan con la raíz vacía: solo ven las carpetas a las que su grupo tiene acceso.

## 5. Matriz de permisos

L = leer/descargar · E = crear y modificar · B = borrar · C = compartir con otros usuarios.

| Carpeta | `equipo` | `docentes-lectura` | `n8n-servicio` | Sin grupo |
|---|---|---|---|---|
| `01-Diagnóstico` … `15-Final` | L E B C | L | — (no la ve) | — (no la ve) |
| `Informes-IA` | L E B C | L | **L E** (sin B ni C) | — (no la ve) |

Reglas globales: **enlaces públicos desactivados** (`shareapi_allow_links = no`), y `docentes-lectura` y `n8n-servicio`
**excluidos de compartir** (`shareapi_exclude_groups_list`).

## 6. Cuenta de servicio de n8n

| Campo | Valor |
|---|---|
| Usuario | `n8n-bot` (grupo `n8n-servicio`) |
| Autenticación | **App password** `n8n-informes-ia`, creada con `occ user:auth-tokens:add` **sin** la contraseña de login: alcanza para WebDAV, pero no permite entrar a la web ni cambiar la cuenta. La contraseña de login es aleatoria y no se usa. |
| URL desde n8n | `http://nextcloud/remote.php/webdav` (nodo Nextcloud de n8n) o `http://nextcloud/remote.php/dav/files/n8n-bot` (HTTP Request). Ambas probadas desde la red `gymhub_tools_net`. |
| Alcance | Solo `Informes-IA`: crear archivos y subcarpetas y sobrescribir. No ve las otras 15 carpetas, no borra y no comparte. |
| Rotación | `bash infra/nextcloud/setup.sh --regenerar` y actualizar la credencial en n8n. Revocación de emergencia: `occ user:auth-tokens:list n8n-bot` y `occ user:auth-tokens:delete n8n-bot <id>`. |

## 7. Verificación

Comprobado el 19/11/2026 en la PC servidor:

| Prueba | Resultado |
|---|---|
| `setup.sh` en una instalación vacía y después otra vez | La primera crea todo. La segunda informa «ya existe» en cada paso y no genera credenciales. |
| Matriz real (`occ groupfolders:list`) | Las 15 carpetas: `equipo` 31 (L E B C), `docentes-lectura` 1 (L), sin `n8n-servicio`. `Informes-IA`: además `n8n-servicio` 7 (L E). |
| [`prueba-permisos.sh`](evidencias/SCRUM-73-74/) | **18/18 OK** (detalle abajo). |
| n8n → Nextcloud por la red `tools` | Desde un contenedor en `gymhub_tools_net` con la app password: `status.php` 200; PUT por `/remote.php/webdav` y por `/remote.php/dav` 201; MKCOL de subcarpeta 201; contraseña errónea 401. |
| Persistencia | Archivo subido → `down` → `up -d` → GET 200 y usuarios intactos. |
| Exposición | `ss -ltn`: solo `127.0.0.1:8082`; no escucha en la LAN. |
| Backup | `db/backup.sh`: dump de la base (137 tablas) y tar de archivos. Nextcloud sale solo del modo mantenimiento. |

| Usuario | Acción | Esperado | Obtenido |
|---|---|---|---|
| n8n-bot | PROPFIND en su raíz | solo `Informes-IA` | solo `Informes-IA` |
| n8n-bot | PUT nuevo / PUT sobrescribir en `Informes-IA` | 201 / 204 | 201 / 204 |
| n8n-bot | DELETE en `Informes-IA` | 403 | 403 |
| n8n-bot | PROPFIND / PUT en `01-Diagnóstico` | 404 / denegado | 404 / 404 |
| n8n-bot | Crear enlace público (OCS) | 403 | 403 |
| docente | GET en `Informes-IA` · PROPFIND en `05-Optimización` | 200 · 207 | 200 · 207 |
| docente | PUT en `05-Optimización` · DELETE en `Informes-IA` | 403 · 403 | 403 · 403 |
| **sin-acceso** | PROPFIND en `Informes-IA` · GET del informe · espacio de n8n-bot | **404 · 404 · 404** | **404 · 404 · 404** |
| evillagran (equipo) | PUT + DELETE en `05-Optimización`, DELETE en `Informes-IA` | 201 · 204 · 204 | 201 · 204 · 204 |

Nextcloud responde **404** en lugar de 403 cuando el usuario no tiene la carpeta: así no revela que existe.

## 8. Pendiente y recomendaciones

### 8.1 Criterios de aceptación de este ticket

| Criterio | Estado |
|---|---|
| Nextcloud en Docker con BD propia y volumen persistente | ✔ Secciones 1, 2 y 7. |
| Grupos (equipo, docentes-lectura, n8n-servicio) y matriz de permisos documentada | ✔ Secciones 4 y 5. |
| Cuenta de servicio de n8n con app password y acceso solo a Informes-IA | ✔ Sección 6. |
| Prueba de acceso denegado a usuario no autorizado | ✔ Sección 7 y `docs/evidencias/SCRUM-73-74/`. |

### 8.2 Recomendación para el flujo n8n IA → Nextcloud (SCRUM-78)

Nextcloud ya está listo para recibir los informes; falta todo el lado de n8n. Pasos recomendados, en orden:

**a. Conectar n8n a la red de Nextcloud.** n8n entra a `gymhub_tools_net` solo con el override
`infra/n8n/SCRUM-76.n8n.override.example.yml`. `scripts/infra.sh levantar` ya lo aplica; si se levanta n8n a mano, hay que incluirlo:
```bash
docker compose -f infra/n8n/docker-compose.yml -f infra/n8n/SCRUM-76.n8n.override.example.yml --env-file infra/n8n/.env up -d
```
Comprobación (n8n corre sobre Node, que trae `fetch`):
```bash
docker exec gymhub-n8n-scrum75 node -e "fetch('http://nextcloud/status.php').then(r=>r.text()).then(console.log)"
```
debe devolver un JSON con `"installed":true`.

**b. Crear la credencial en n8n** (Credentials → *Nextcloud API*):

| Campo | Valor |
|---|---|
| Web DAV URL | `http://nextcloud/remote.php/webdav` |
| User | `n8n-bot` |
| Password | la `app_password` de `infra/nextcloud/credenciales.local.json` |

Nunca escribir la app password en un nodo, en una expresión ni en un workflow exportado (SCRUM-75/76). No usar `admin` ni la cuenta de un integrante.

**c. Estructura sugerida del flujo:**

```
Schedule Trigger (ej. diario 08:00) ─► Recolectar datos (Prometheus / Mantis por HTTP Request)
  ─► Nodo IA (resumen en Markdown) ─► Code: armar nombre y contenido
  ─► Nextcloud · Folder · Create  /Informes-IA/AAAA-MM          (con "Continue On Fail": si ya existe, da error y se sigue)
  ─► Nextcloud · File · Upload    /Informes-IA/AAAA-MM/informe-AAAA-MM-DD-HHmm.md
  ─► (opcional) aviso por Telegram/correo con la ruta del archivo
Error Workflow: el de manejo de errores de SCRUM-76 (registra la falla / abre incidencia en Mantis)
```

- **Nombres únicos con fecha y hora**: n8n **no puede borrar** en `Informes-IA`, así que no debe depender de borrar y recrear archivos. Si repite un nombre, el archivo se sobrescribe (204) y la versión anterior queda en el historial de versiones.
- **Subcarpetas por mes**: n8n puede crearlas (probado, MKCOL 201), así la carpeta no crece sin orden.
- **Encabezado del informe**: fecha, período analizado, fuentes de datos, modelo de IA usado y la leyenda «generado automáticamente, revisar antes de usar» (riesgos IA, SCRUM-82).
- **No enviar datos sensibles al modelo** (credenciales, datos personales de socios); solo métricas e incidencias resumidas.
- Si se usa *HTTP Request* en lugar del nodo Nextcloud: `PUT http://nextcloud/remote.php/dav/files/n8n-bot/Informes-IA/<archivo>` con autenticación *Basic* desde la misma credencial.

**d. Pruebas y evidencia que conviene dejar** (en `docs/evidencias/SCRUM-78/`):
1. Ejecución exitosa: captura de la ejecución en n8n y del archivo en `Informes-IA` (visto como `evillagran` y como `docente`).
2. **Falla intencional**: revocar la app password (`occ user:auth-tokens:delete`) o cambiarla en la credencial → el nodo recibe **401** → se dispara el Error Workflow. Después, `setup.sh --regenerar` y actualizar la credencial.
3. Mínimo privilegio en el flujo: un nodo que intente subir a `/01-Diagnóstico/` debe fallar (409 por `/remote.php/webdav`, 404 por `/remote.php/dav`: n8n no ve la carpeta).
4. Exportar el workflow a `infra/n8n/workflows/` y revisar que el JSON **no** contenga la app password.

### 8.3 Otras recomendaciones

| Prioridad | Recomendación |
|---|---|
| Alta | **Subir los `.md` existentes de `docs/`** a su carpeta (por ej. SCRUM-45…49 → `06-Replicación`, SCRUM-66…68 → `10-Monitoreo`). Conviene un script WebDAV que se pueda repetir cuando cambien los documentos. |
| Alta | **Repartir las contraseñas** por canal privado y pedir que cada integrante la cambie. Después borrar las copias `credenciales.local.<fecha>.json` que ya no hagan falta. |
| Media | **Backup periódico**: correr `db/backup.sh` antes de la entrega o agregarlo al flujo de backups de n8n (SCRUM-77). Hoy no hay copia fuera de la PC. |
| Media | **Tareas en segundo plano**: Nextcloud está en modo AJAX y sus tareas (limpieza de papelera y versiones) corren solo cuando alguien usa la web. Para uso sostenido: cron del host cada 5 min con `docker exec -u www-data gymhub-nextcloud php -f cron.php` y `occ background:cron`. |
| Baja | Habilitar HTTPS en la tailnet (`tailscale serve --https`) si los docentes entran desde fuera de la PC. Hoy es HTTP dentro de la VPN cifrada de Tailscale. |
| Baja | Conservar `sin-acceso` mientras se necesiten las pruebas. Deshabilitarlo después de la entrega (`occ user:disable sin-acceso`). |
