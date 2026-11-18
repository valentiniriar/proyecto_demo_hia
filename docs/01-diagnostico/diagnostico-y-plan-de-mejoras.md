# Diagnóstico técnico y plan de mejoras

Ticket: SCRUM-23 · Épica: E01 Selección y diagnóstico · Fecha: 10/11/2026

Relevamiento del código tal como lo recibimos (commit `3028ee7`): backend con 13 controladores (~1.950 líneas JS), frontend con 16 componentes (~2.600 líneas TS) y una base PostgreSQL de 9 tablas. La aplicación funciona en local: los tres roles inician sesión y las rutas protegidas responden según el rol.

Severidad: **Crítica** (explotable o rompe la app con el volumen exigido) · **Alta** · **Media** · **Baja**.

## 1. Hallazgos

### Seguridad

| # | Hallazgo | Dónde | Severidad | Ticket |
|---|---|---|---|---|
| S1 | **Un socio puede marcar como pagada cualquier cuota.** `POST /api/pagos` acepta `tarifaId` del body sin verificar que la tarifa pertenezca al socio ni que exista un pago aprobado en MercadoPago, y luego hace `Tarifa.update({ pagado: true })`. | `pago.controller.js` `createPago`, `pago.route.js` | Crítica | SCRUM-81 |
| S2 | **Asignación masiva:** `Pago.create(req.body)` guarda el body completo; el cliente puede fijar `monto`, `fecha` o `transaccion`. | `pago.controller.js` | Alta | SCRUM-81 |
| S3 | Dependencias vulnerables: backend 12 (1 crítica, 5 altas: nodemailer, follow-redirects, qs, proxy-addr, uuid…); frontend 47 (3 críticas, 18 altas). | `package-lock.json` | Alta | SCRUM-64 |
| S4 | Sin límite de intentos en `/api/auth/login`: permite fuerza bruta de contraseñas. | `index.js`, `auth.route.js` | Alta | SCRUM-65 |
| S5 | Sin cabeceras de seguridad (`helmet`) ni límite de tamaño del body. | `index.js` | Media | SCRUM-65 |
| S6 | JWT, email e id guardados en `localStorage`: robables ante un XSS. El token dura 8 h sin revocación. | `login.service.ts`, `auth.controller.js` | Media | SCRUM-83 |
| S7 | Prompt injection: el texto del usuario se concatena directo al prompt del LLM, sin validación de longitud ni límite de uso (costo). | `ai.controller.js` | Media | SCRUM-82 |
| S8 | Swagger (`/api/docs`) público: expone el mapa completo de la API. | `index.js` | Baja | SCRUM-65 |
| S9 | `test_mp.js` suelto en el backend, con ruta absoluta a un `.env` de otra máquina. | `backend/test_mp.js` | Baja | SCRUM-31 |
| S10 | El alta pública (`POST /api/usuarios`) asigna el rol con un id fijo (`id_rol: 3`); si cambia el orden del seed, un registro anónimo podría recibir otro rol. | `usuario.controller.js` | Baja | SCRUM-81 |

### Rendimiento (crítico con el dataset de 6.000.000 de registros)

| # | Hallazgo | Dónde | Severidad | Ticket |
|---|---|---|---|---|
| R1 | El dashboard trae **todas las tarifas pagadas** a memoria y suma los precios en JavaScript, y carga todos los usuarios de cada rol solo para contarlos. Con millones de filas agota la memoria del proceso. Debe resolverse con `SUM()` / `COUNT()` en SQL. | `dashboard.controller.js` | Crítica | SCRUM-42 |
| R2 | Ningún listado tiene paginación (`findAll` sin `limit`/`offset` en 8 controladores): `GET /api/usuarios`, `/pagos`, `/tarifas`, etc. devuelven tablas completas. | `src/controllers/*` | Crítica | SCRUM-42 |
| R3 | `verificarRol` hace 2 consultas por rol en **cada** petición protegida (busca el rol por nombre y luego la asignación). | `rol.middleware.js` | Media | SCRUM-42 |
| R4 | Sin índices en las FK más consultadas (`tarifas.suscripcionId`, `pagos.tarifaId`, `rutinas.usuarioId`) ni en filtros frecuentes (`pagado`, `activo`). | `database/01_schema.sql` | Alta | SCRUM-41 |

### Arquitectura y operación

| # | Hallazgo | Dónde | Severidad | Ticket |
|---|---|---|---|---|
| A1 | URL de la API (`http://localhost:3000`) fija en 12 servicios del frontend: no se puede desplegar en otro host ni detrás del túnel. | `frontend/src/app/services/*.ts` | Alta | SCRUM-50 |
| A2 | CORS con orígenes fijos (`localhost:4200`). | `index.js` | Media | SCRUM-65 |
| A3 | Frontend y backend no contenerizados; no hay endpoint de salud para healthchecks. | — | Alta | SCRUM-51, SCRUM-52 |
| A4 | `sequelize.sync()` al arrancar en lugar de migraciones versionadas: el esquema real puede divergir de `01_schema.sql`. | `index.js` | Media | SCRUM-90 (limitación) |
| A5 | Una sola instancia de base, sin backups ni réplica. | `docker-compose.yml` | Alta | SCRUM-37, SCRUM-45 |
| A6 | Sin monitoreo, sin logs estructurados y sin CI/CD. | — | Alta | SCRUM-55, SCRUM-66 |

### Calidad del código

| # | Hallazgo | Dónde | Severidad | Ticket |
|---|---|---|---|---|
| C1 | Sin tests automatizados: `npm test` del backend sale con error a propósito; el frontend solo tiene el spec por defecto. | `backend/package.json` | Alta | SCRUM-32 |
| C2 | Sin linter en el backend. | — | Media | SCRUM-32 |
| C3 | Respuestas de error inconsistentes: algunos errores de negocio responden HTTP 200 con `status: '0'` (p. ej. DNI duplicado en el alta). | controladores | Baja | — |

## 2. Fortalezas

- Contraseñas con bcrypt (costo 10) y JWT firmado con secreto por variable de entorno.
- Autorización por rol aplicada en el backend en todas las rutas sensibles, no solo en el frontend.
- Validación de entrada con `express-validator` en usuarios, login y roles.
- Consultas mediante el ORM (parametrizadas): no se encontraron SQL crudo ni `sequelize.literal`.
- `.gitignore` correcto para `.env` y claves; el repo solo versiona `.env.example`.
- Esquema y datos demo reproducibles con Docker (`01_schema.sql`, `02_seed.sql`).

## 3. Plan de mejoras priorizado

| Prioridad | Mejora | Hallazgos | Sprint |
|---|---|---|---|
| 1 | Validar dueño de la tarifa y pago aprobado antes de registrar pagos; listar campos permitidos en `Pago.create` | S1, S2 | 2 |
| 2 | Agregados en SQL para el dashboard y paginación en todos los listados | R1, R2 | 2 |
| 3 | Índices justificados con EXPLAIN ANALYZE sobre el dataset de 6M | R4 | 2 |
| 4 | Actualizar dependencias vulnerables | S3 | 2 |
| 5 | `helmet`, rate limiting en login, CORS por variable de entorno, límite de body | S4, S5, A2 | 2 |
| 6 | URL de la API por `environment` y proxy `/api` en Nginx | A1 | 2 |
| 7 | Contenerizar backend y frontend con `/api/health` | A3 | 2 |
| 8 | Backups automáticos y réplica | A5 | 1–2 |
| 9 | CI con build, tests y auditoría; luego CD | A6, C1, C2 | 2 |
| 10 | Cachear roles en el JWT o en memoria en `verificarRol` | R3 | 3 |
| 11 | Mitigar prompt injection y limitar uso de la IA | S7 | 3 |
| 12 | Evaluar cookie HttpOnly para la sesión | S6 | 3 |

Cada hallazgo se registrará también como incidencia en Mantis (SCRUM-71) con sus pasos de reproducción.
