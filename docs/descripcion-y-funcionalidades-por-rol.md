# SCRUM-20 — GymHub: descripción y funcionalidades por rol

**Proyecto:** GymHub — Trabajo Integrador HIA 2026
**Alcance:** Descripción general, perfiles de usuario, vistas del frontend, endpoints asociados e integraciones externas.
**Fecha de relevamiento:** 11 de noviembre de 2026.
**Fuentes revisadas:** `README.md`, `frontend/README.md`, `frontend/src/app/app.routes.ts`, servicios Angular, `backend/index.js`, rutas y controladores de Express, `backend/.env.example`.

## 1. Descripción y objetivo

GymHub es una aplicación web para centralizar la administración de un gimnasio. Permite gestionar usuarios y permisos, ejercicios, rutinas, suscripciones, cuotas y pagos. La experiencia se organiza en tres perfiles —**administrador, entrenador y socio**— que disponen de vistas y operaciones diferentes.

El objetivo es simplificar el trabajo diario del gimnasio y ofrecer a sus socios información sobre rutinas y pagos en una misma plataforma. El sistema combina un **frontend Angular 21** con una **API REST Node.js/Express** que utiliza **Sequelize y PostgreSQL 16**. Hay autenticación basada en JWT y controles de acceso por rol. El frontend utiliza guards para restringir rutas y el backend incorpora middleware de autenticación/autorización en rutas sensibles.

Arquitectura lógica: **navegador → Angular/Nginx → API Express → PostgreSQL**; adicionalmente, el backend integra servicios externos. Las rutas API de la documentación se expresan desde `/api`, como en la solución propuesta en SCRUM-50. La incorporación final de estos cambios a `main` está sujeta a aprobación del Pull Request.

## 2. Funciones generales y públicas

| Funcionalidad | Ruta del frontend | Endpoint de API asociado | Observación |
|---|---|---|---|
| Página de inicio | `/home` | Sin endpoint obligatorio identificado | Página de entrada y navegación. |
| Inicio de sesión | `/login` | `POST /api/auth/login` | Devuelve sesión y rol para la navegación. |
| Inicio de sesión con Google | `/login` | `POST /api/auth/google` | Requiere configuración de Google. |
| Registro de usuario | `/register` | `POST /api/usuarios/` | Alta inicial mediante formulario. |
| Búsqueda de ejercicios en YouTube | `/buscar-ejercicio` | `GET /api/youtube/buscar?q=...` | La vista no tiene guard en Angular, pero el endpoint requiere token. |

## 3. Funcionalidades por rol

### Administrador

| Función | Ruta del frontend | Endpoint(s) principales |
|---|---|---|
| Panel con estadísticas | `/dashboard` | `GET /api/dashboard/stats` |
| Listar y mantener usuarios | `/usuarios` | `GET /api/usuarios/`, `PUT /api/usuarios/:dni`, `DELETE /api/usuarios/:dni` |
| Activar o desactivar usuarios | `/usuarios` | `PATCH /api/usuarios/:dni/active`, `PATCH /api/usuarios/:dni/inactive` |
| Consultar, asignar o retirar roles | `/usuarios` | `GET /api/roles/usuario/:dni`, `POST` o `DELETE /api/roles/usuario/:dni/rol/:nombreRol` |
| Gestionar suscripciones | `/suscripciones` | `GET /api/suscripciones/`, `POST /api/suscripciones/`, `PATCH /api/suscripciones/:id`, `DELETE /api/suscripciones/:id` |
| Administrar cuotas y tarifas | `/tarifas` | `GET /api/tarifas/`, `POST /api/tarifas/`, `PATCH /api/tarifas/:id/anular` |
| Registrar pagos y generar enlaces | `/tarifas` | `POST /api/pagos/`, `POST /api/mp/payment` |
| Consultar y anular pagos | `/pagos` | `GET /api/pagos/`, `PATCH /api/pagos/:id/anular` |

Las rutas indicadas se encuentran protegidas por `adminGuard` en Angular. Su funcionamiento también depende de los permisos del backend.

### Entrenador

| Función | Ruta del frontend | Endpoint(s) principales |
|---|---|---|
| Listar, crear, editar y eliminar ejercicios | `/ejercicios` | `GET /api/ejercicios/`, `POST /api/ejercicios/`, `PUT /api/ejercicios/:id`, `DELETE /api/ejercicios/:id` |
| Listar y administrar rutinas | `/rutinas` | `GET /api/rutinas/`, `POST /api/rutinas/`, `PUT /api/rutinas/:id`, `DELETE /api/rutinas/:id` |
| Asociar ejercicios a una rutina | `/rutinas` | `POST /api/rutinas/setEjercicios` |
| Consultar socios y ejercicios para asignaciones | `/rutinas` | `GET /api/usuarios/socios/list`, `GET /api/ejercicios/` |
| Solicitar asistencia de IA para rutinas | `/rutinas` | `POST /api/ai/generar-rutina` |

Estas vistas están protegidas por `entrenadorGuard`. La asistencia de IA requiere configuración de Groq y validación de seguridad específica.

### Socio

| Función | Ruta del frontend | Endpoint(s) principales |
|---|---|---|
| Ver rutinas asignadas | `/mis-rutinas` | `GET /api/rutinas/mis-rutinas` |
| Ver cuotas propias y solicitar enlace de pago | `/mis-pagos` | `GET /api/tarifas/mis-tarifas`, `POST /api/mp/payment` |
| Confirmación de pago | `/pago-exitoso` | `POST /api/pagos/` (según el flujo del componente) |
| Buscar información de alimentos | `/nutricion` | `GET /api/nutricion/buscar?q=...` |

Estas vistas están protegidas por `socioGuard`. La pantalla de rutinas puede mostrar videos embebidos de YouTube, según los enlaces cargados en los ejercicios.

## 4. Integraciones externas y configuración

**Criterio utilizado para indicar el estado:** se revisó `backend/.env.example`, que contiene las variables documentadas **sin valores de claves**. El estado real en otros equipos o servidores no puede concluirse a partir de ese archivo; requiere comprobación separada. No se incluyen credenciales en este documento.

| Servicio | Función | Configuración referenciada | Estado comprobable |
|---|---|---|---|
| Mercado Pago | Generar links/preferencias de pago y suscripción | `ACCESS_TOKEN` | **Sin clave en `.env.example`**; integración implementada, credencial de despliegue por verificar. |
| YouTube Data API | Buscar videos de ejercicios | `YOUTUBE_API_KEY` | **Sin clave en `.env.example`**; requiere credencial para búsqueda. |
| Google OAuth | Acceso con cuenta Google | `GOOGLE_CLIENT_ID` | **Sin clave en `.env.example`**; configuración de despliegue por verificar. |
| Servicio de correo | Comunicaciones del sistema | `EMAIL_USER`, `EMAIL_PASS` | **Sin claves en `.env.example`**; proveedor y funcionamiento requieren validación. |
| Groq IA | Generación asistida de rutinas | `GROQ_API_KEY` | **Sin clave en `.env.example`**; el controlador indica error si falta. |
| Open Food Facts | Búsqueda nutricional | Consulta HTTPS desde backend | **Integración identificada en código**; no exige una variable de clave en el controlador revisado; disponibilidad externa no comprobada. |
| Videos embebidos de YouTube | Mostrar contenido de ejercicios | URL de video almacenada | **Integración identificada en la interfaz**; depende del video y de la conectividad. |

## 5. Alcance, pruebas y limitaciones del relevamiento

- Las **rutas y endpoints** de las tablas se contrastaron con `app.routes.ts`, servicios Angular y rutas Express. La existencia de un endpoint no demuestra, por sí sola, que cada operación haya pasado una prueba funcional completa.
- Se comprobó previamente en el entorno local el acceso a Angular/Nginx, al backend y a `/api/docs/` mediante HTTP 200; las pruebas de cada flujo por rol y la persistencia de registros corresponden a **SCRUM-54** y siguen pendientes de evidencia final.
- La URL relativa `/api` fue preparada en **SCRUM-50** (PR #1). La contenerización de frontend se propuso en **SCRUM-52** (PR #7). Estos PR no se consideran incorporados a `main` hasta su aprobación y fusión.
- Las claves externas no deben publicarse en Git ni en documentación. Solo se documenta el nombre de las variables y el estado verificable de la plantilla.
- La subida a **Nextcloud** sigue pendiente hasta que el equipo ponga a disposición el servicio y la carpeta compartida. El archivo se entrega primero en `docs/` del repositorio, para revisión del equipo.

## 6. Referencias del propio proyecto

- [`README.md`](../README.md): arquitectura general, instalación y base de datos.
- [`frontend/src/app/app.routes.ts`](../frontend/src/app/app.routes.ts): rutas y guards.
- [`frontend/src/app/services/`](../frontend/src/app/services/): endpoints usados en la interfaz.
- [`backend/index.js`](../backend/index.js): rutas base de la API.
- [`backend/src/routes/`](../backend/src/routes/): autorización y endpoints del servidor.
- [`backend/.env.example`](../backend/.env.example): variables requeridas, sin claves.

**Relación con Jira:** [SCRUM-20](https://gymhubb.atlassian.net/browse/SCRUM-20).
