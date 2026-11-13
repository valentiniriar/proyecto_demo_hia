# SCRUM-21 · Inventario del stack tecnológico y dependencias con análisis de CVEs

**Épica:** E01 · Selección y diagnóstico de la aplicación  
**Responsable:** Valentín Iriarte  
**Rama:** `docs/SCRUM-21-inventario-stack`  
**Fecha del relevamiento:** 13/11/2026 (sobre `develop` en `194a1d2`)

## 1. Resumen

| Capa | Tecnología principal | Versión instalada | Dependencias totales (árbol npm) |
|---|---|---|---|
| Backend | Node.js + Express 5 + Sequelize 6 | Node 22 (imagen `node:22-alpine`, CI) | 283 |
| Frontend | Angular 21 + Bootstrap 5 + Chart.js 4 | Angular 21.2.26, servido por Nginx (`nginx-unprivileged:alpine`) | 577 |
| Base de datos | PostgreSQL | 16.15 (`postgres:16-alpine`) | — |

**Estado de vulnerabilidades (npm audit):**

| Proyecto | Producción (`--omit=dev`) | Total (incluye herramientas de desarrollo) | Al abrir el ticket |
|---|---|---|---|
| Backend | **2 moderadas** | 9 (2 bajas, 7 moderadas) | 12 (1 crítica, 5 altas) |
| Frontend | **0** | 16 moderadas | 47 (3 críticas, 18 altas) |

Las críticas y altas detectadas al abrir el ticket ya fueron corregidas por **SCRUM-64** (PR #4, actualización de dependencias). Lo que queda no tiene corrección sin un cambio de versión mayor y no es explotable en nuestro uso; el análisis está en la sección 4.

Salidas completas: [`evidencias/SCRUM-21/npm-audit-backend.txt`](evidencias/SCRUM-21/npm-audit-backend.txt) y [`evidencias/SCRUM-21/npm-audit-frontend.txt`](evidencias/SCRUM-21/npm-audit-frontend.txt).

## 2. Inventario de componentes

### 2.1 Backend (`backend/package.json`)

| Tipo | Componente | Versión | Licencia | Función en GymHub |
|---|---|---|---|---|
| prod | express | 5.2.1 | MIT | Servidor HTTP y ruteo de la API REST |
| prod | sequelize | 6.37.8 | MIT | ORM: modelos, consultas parametrizadas, `sync()` y replicación lectura/escritura |
| prod | pg | 8.22.0 | MIT | Driver de PostgreSQL usado por Sequelize |
| prod | pg-hstore | 2.3.4 | MIT | Serialización hstore requerida por Sequelize para Postgres |
| prod | jsonwebtoken | 9.0.3 | MIT | Emisión y verificación de JWT de sesión |
| prod | bcrypt | 6.0.0 | MIT | Hash de contraseñas (10 rondas) |
| prod | google-auth-library | 10.9.0 | Apache-2.0 | Verificación del ID token de Google (login con Google) |
| prod | express-validator | 7.3.2 | MIT | Validación de body en registro / actualización de usuarios |
| prod | express-rate-limit | 8.7.4 | MIT | Límite de solicitudes (hoy en `/api/ai`, SCRUM-82) |
| prod | cors | 2.8.6 | MIT | Política CORS para el frontend |
| prod | dotenv | 17.4.2 | BSD-2-Clause | Carga de variables de entorno desde `.env` |
| prod | axios | 1.21.1 | MIT | Cliente HTTP hacia MercadoPago, Groq, YouTube y Open Food Facts |
| prod | nodemailer | 10.5.0 | MIT-0 | Envío de emails (bienvenida) vía Gmail SMTP |
| prod | resend | 6.17.1 | MIT | Cliente de Resend. **Declarado pero sin uso en el código** (se usa nodemailer): candidato a eliminar para reducir superficie |
| prod | swagger-ui-express | 5.0.1 | MIT | Documentación interactiva en `/api/docs` |
| dev | eslint / @eslint/js / globals | 10.14.0 / 10.0.1 / 17.14.0 | MIT | Lint (SCRUM-32) |
| dev | supertest | 7.3.2 | MIT | Tests HTTP de humo |
| dev | nodemon | 3.1.14 | MIT | Recarga en desarrollo |
| dev | swagger-autogen | 2.23.7 | MIT | Genera `swagger_output.json` |

### 2.2 Frontend (`frontend/package.json`)

| Tipo | Componente | Versión | Licencia | Función en GymHub |
|---|---|---|---|---|
| prod | @angular/core, common, compiler, forms, router, platform-browser | 21.2.26 | MIT | Framework SPA, formularios reactivos, ruteo con guards por rol |
| prod | rxjs | 7.8.2 | Apache-2.0 | Programación reactiva (HttpClient, observables) |
| prod | tslib | 2.8.1 | 0BSD | Helpers de TypeScript en runtime |
| prod | bootstrap | 5.3.8 | MIT | Estilos y componentes de UI |
| prod | chart.js | 4.5.1 | MIT | Gráficos del dashboard de administración |
| dev | @angular/cli, @angular/build | 21.2.29 | MIT | Compilación y servidor de desarrollo |
| dev | @angular/compiler-cli | 21.2.26 | MIT | Compilador AOT |
| dev | typescript | 5.9.3 | Apache-2.0 | Lenguaje |
| dev | vitest / jsdom | 4.1.12 / 28.1.0 | MIT | Tests unitarios |
| dev | prettier | 3.9.4 | MIT | Formato de código |

### 2.3 Base de datos e infraestructura

| Componente | Versión / imagen | Licencia | Función |
|---|---|---|---|
| PostgreSQL | 16.15 (`postgres:16-alpine`) | PostgreSQL License | BD relacional; primario + réplica por streaming (E06) |
| Nginx | `nginxinc/nginx-unprivileged:alpine` | BSD-2-Clause | Sirve la SPA y hace proxy de `/api/` |
| Node.js | 22 (`node:22-alpine`) | MIT | Runtime del backend (imagen Docker y CI) |
| pgAdmin 4 | `dpage/pgadmin4` | PostgreSQL License | Administración de la BD, solo en desarrollo |
| Prometheus, Grafana, Alertmanager, exporters | `infra/monitoring/` | Apache-2.0 / AGPL-3.0 (Grafana) | Monitoreo y alertas (E10) |
| n8n | `infra/n8n/` | Sustainable Use License | Automatización de flujos (E12) |
| Docker / Docker Compose | Docker 29 | Apache-2.0 | Contenerización y orquestación |
| GitHub Actions | `actions/checkout@v4`, `actions/setup-node@v4` | MIT | CI (SCRUM-55) |

## 3. Servicios externos y APIs

| Servicio | Dónde se usa | Para qué | Datos que salen | Riesgo asociado | Mitigación |
|---|---|---|---|---|---|
| **MercadoPago** (`api.mercadopago.com`) | `mp.controller.js` | Links de pago de cuotas y suscripciones (preapproval) | Monto, concepto, email del pagador | Robo del `ACCESS_TOKEN` = cobros/consultas en nombre del gimnasio; webhooks falsificados | Token solo en `.env` / GitHub Environments; usar credenciales de **prueba** en la demo; no confiar en el retorno del navegador sin verificar el pago |
| **Google Identity** (`accounts.google.com/gsi`) | `index.html`, `auth.controller.js` | Login con Google | ID token del usuario | Aceptar tokens emitidos para otra app | El backend valida el token con `google-auth-library` contra `GOOGLE_CLIENT_ID` |
| **Groq** (`api.groq.com`, modelo `llama-3.1-8b-instant`) | `ai.controller.js` | Generación de rutinas con IA | Nombre de rutina y ejercicios | Prompt injection, costo por abuso, fuga de la API key | Rate limit en `/api/ai` y validación de entrada (SCRUM-82); key en `.env` |
| **YouTube Data API v3** (`googleapis.com`) | `youtube.controller.js` | Búsqueda de videos de ejercicios | Término de búsqueda | Agotar la cuota diaria; fuga de la API key | Key restringida por API en Google Cloud; rate limit global (SCRUM-65) |
| **YouTube embeds** | frontend | Reproducir videos en rutinas | IP del navegador del usuario | Seguimiento de terceros | `frame-src` limitado por la CSP de Nginx |
| **Open Food Facts** (`world.openfoodfacts.org`) | `nutricion.controller.js` | Macronutrientes de alimentos | Término de búsqueda | Disponibilidad del tercero (sin SLA) | Manejo de errores; dato no crítico |
| **Gmail SMTP** (nodemailer) | `email.service.js` | Email de bienvenida | Email y nombre del usuario | Fuga de `EMAIL_PASS` = envío de spam desde la cuenta | Usar contraseña de aplicación, nunca la real; `.env` |
| **Google Maps embed** | `home.component.html` | Mapa de la sede | — | Bajo | — |
| **npm registry** | build | Instalación de dependencias | — | **Cadena de suministro** (ver 4.3) | `npm ci` con lockfile, `npm audit` en CI |
| **Docker Hub / GHCR** | build y despliegue | Imágenes base y de la app | — | Imagen base comprometida | Imágenes oficiales; fijar por digest (propuesto en SCRUM-58) |

## 4. Análisis de vulnerabilidades (CVEs / GHSA)

### 4.1 Backend — dependencias de producción (2 moderadas)

| Paquete | Severidad | Advisory | Vía | ¿Explotable en GymHub? | Acción |
|---|---|---|---|---|---|
| uuid < 11.1.1 | Moderada | [GHSA-w5hq-g745-h8pq](https://github.com/advisories/GHSA-w5hq-g745-h8pq): falta de chequeo de límites en v3/v5/v6 cuando se pasa `buf` | Transitiva de **sequelize** 6.37.8 | **No.** Sequelize usa `uuid.v4()` sin buffer externo; la falla solo aplica a v3/v5/v6 con `buf` provisto por el llamador. | Aceptado. `npm audit fix` propone volver a sequelize 3.x (major, regresión). Revisar cuando Sequelize 6 publique un parche o al migrar a Sequelize 7. |
| sequelize | Moderada | Hereda la de uuid | Directa | Igual que arriba | Igual que arriba |

### 4.2 Herramientas de desarrollo (no van a la imagen de producción)

| Proyecto | Paquetes | Advisory principal | Por qué el riesgo es bajo |
|---|---|---|---|
| Backend | eslint, @eslint/js, @eslint/config-array, nodemon, minimatch | [GHSA-g3hv-75wg-m249](https://github.com/advisories/GHSA-g3hv-75wg-m249) (DoS por patrones glob) | Solo se ejecutan en la PC del desarrollador o en el CI, con patrones propios; nunca reciben entrada de usuarios. La imagen Docker usa `npm ci --omit=dev`. |
| Backend | swagger-autogen, deepmerge | [GHSA-gcqx-w48m-w2h4](https://github.com/advisories/GHSA-gcqx-w48m-w2h4) (prototype poisoning) | Solo se usa para regenerar `swagger_output.json` a mano. |
| Frontend | @angular/cli y su cadena (pacote, sigstore, tuf-js, cacache, glob, minimatch, npm-registry-fetch…) — 16 | GHSA-g3hv-75wg-m249, [GHSA-3g3m-2fjr-6pw4](https://github.com/advisories/GHSA-3g3m-2fjr-6pw4) (glob) | Son dependencias del CLI de compilación. El bundle que se publica (Nginx) no las contiene: `npm audit --omit=dev` = **0**. El "fix" de npm (volver a CLI 17) sería una regresión. |

### 4.3 Cadena de suministro npm (eventos recientes)

En 2025 hubo ataques reales a la cadena de suministro de npm: secuestro de cuentas de mantenedores por phishing que publicaron versiones maliciosas de paquetes muy usados (`chalk`, `debug` y otros, septiembre 2025) y el gusano **Shai-Hulud**, que se autopropagaba robando tokens de npm y GitHub desde los `postinstall`. Para GymHub esto implica:

| Riesgo | Situación actual | Recomendación |
|---|---|---|
| Instalar una versión maliciosa nueva | `npm ci` respeta el `package-lock.json` (versiones e integridad SHA-512 fijas) | Mantener `npm ci` en CI y Docker; revisar los diffs del lockfile en cada PR |
| Scripts `postinstall` maliciosos | bcrypt usa binarios precompilados | Evaluar `npm ci --ignore-scripts` en CI donde no haga falta compilar |
| Robo de tokens en el pipeline | El CI tiene `permissions: contents: read` | Fijar Actions por SHA y secretos en Environments (SCRUM-58) |
| Dependencias sin uso que agrandan la superficie | `resend` declarado y no usado | Eliminarlo en un ticket aparte |

## 5. Cómo reproducir

```bash
cd backend  && npm ci && npm audit --omit=dev && npm audit
cd frontend && npm ci && npm audit --omit=dev && npm audit
docker run --rm postgres:16-alpine postgres --version
```

## 6. Criterios de aceptación

| Criterio | Estado |
|---|---|
| Tabla con componente, versión, función y licencia | ✔ Sección 2 |
| Salida de `npm audit` de back y front adjunta y resumida | ✔ Secciones 1 y 4 + `docs/evidencias/SCRUM-21/` |
| Servicios externos y APIs con su uso y riesgo asociado | ✔ Sección 3 |
