# SCRUM-63 · Matriz de amenazas de GymHub

**Épica:** E14 · Seguridad informática y amenazas actuales  
**Responsable:** Valentín Iriarte  
**Rama:** `docs/SCRUM-63-matriz-amenazas`  
**Fecha:** 13/11/2026 · revisada sobre `develop` (`54f12a2`)

## 1. Metodología

- **Activos:** lo que hay que proteger: datos de socios (DNI, email, hash de contraseña), datos de pagos y cuotas, cuentas con rol `admin`, disponibilidad de la app, secretos (JWT, MercadoPago, Groq, Google, SMTP, túnel), base de datos y backups, código y pipeline.
- **Probabilidad (P)** e **Impacto (I)** en escala 1–3:
  - P: 1 = improbable, 2 = posible, 3 = probable.
  - I: 1 = bajo, 2 = medio (afecta a un usuario o a una función), 3 = alto (pérdida o filtración masiva, fraude, caída total).
- **Riesgo = P × I**:
  - 1–2 🟢 bajo.
  - 3–4 🟡 medio.
  - 6–9 🔴 alto.
- **Riesgo inherente:** sin controles. **Riesgo residual:** con los controles **ya implementados** en `develop`. Si un control está planificado y no implementado, el residual no baja hasta que se mergee.
- Cada control apunta al ticket de Jira que lo implementa o lo verifica.
- Fuentes: código del repo (rutas, middlewares, controllers, compose), OWASP Top 10 2021, OWASP API Security Top 10 2023 y eventos recientes (ataques a la cadena de suministro npm en 2025, compromiso de `tj-actions/changed-files`).

## 2. Matriz

| # | Activo | Amenaza / escenario concreto en GymHub | P | I | Inherente | Controles (ticket) | Estado del control | Residual |
|---|---|---|---|---|---|---|---|---|
| A01 | BD y backups | **Ransomware** en la PC/servidor cifra el volumen de PostgreSQL y los backups locales | 2 | 3 | 🔴 6 | Backups automáticos con retención (SCRUM-37); prueba de restauración (SCRUM-38); verificación programada de backups con n8n (SCRUM-77); **copia offline/fuera del host** (SCRUM-84, playbook) | Restauración y verificación ✔; servicio de backups en PR #16 (sin mergear); copia offline pendiente | 🟡 4 |
| A02 | Disponibilidad de la app | **DDoS / flood** de requests contra la URL pública | 2 | 2 | 🟡 4 | Cloudflare delante (absorbe volumétricos, oculta IP de origen) (SCRUM-60); rate limit global 1000 req/15 min por IP (SCRUM-65); límites de CPU/RAM por contenedor (SCRUM-53); alertas (SCRUM-68) | ✔ | 🟢 2 |
| A03 | Cuentas de usuario | **Fuerza bruta / credential stuffing** sobre `POST /api/auth/login` | 3 | 3 | 🔴 9 | Rate limit de 5 intentos fallidos/min por IP con IP real detrás del proxy (SCRUM-65); bcrypt con 10 rondas; mensaje de error genérico ("credenciales inválidas"); prueba controlada (SCRUM-81) | ✔ | 🟡 3 |
| A04 | Cuentas `admin` | **Robo de credenciales del administrador** (phishing, reutilización de contraseña) → control total | 2 | 3 | 🔴 6 | Rate limit (SCRUM-65); **2FA para admin** y/o Cloudflare Access con email autorizado para el panel (SCRUM-61, SCRUM-83) | 2FA pendiente | 🔴 6 |
| A05 | Sesión (JWT) | **XSS que roba el JWT** guardado en `localStorage` (válido 8 h, sin revocación) | 2 | 3 | 🔴 6 | CSP estricta en Nginx (`script-src 'self' https:`) y en la API (SCRUM-52, SCRUM-65); Angular escapa por defecto; evaluar cookie `HttpOnly` + `SameSite` y expiración corta (SCRUM-83) | CSP ✔; cookie HttpOnly pendiente | 🟡 4 |
| A06 | Secretos | **Secretos filtrados** en el repo público o en logs del CI (JWT_SECRET, ACCESS_TOKEN, GROQ_API_KEY) | 2 | 3 | 🔴 6 | Auditoría con gitleaks sin hallazgos (SCRUM-31); gitleaks en cada PR + secret scanning con push protection + Environments (SCRUM-58); `.gitignore` de `.env`/dumps; playbook de rotación (SCRUM-84) | ✔ | 🟢 2 |
| A07 | Backend / frontend | **Dependencias vulnerables** (CVE conocidas en npm) | 3 | 2 | 🔴 6 | Corrección de 12 + 47 vulnerabilidades (SCRUM-64); `npm audit --audit-level=high` en el CI (SCRUM-55); Dependabot alerts + updates (SCRUM-58); inventario (SCRUM-21) | ✔ (quedan 2 moderadas no explotables) | 🟢 2 |
| A08 | Pipeline / imágenes | **Cadena de suministro:** paquete npm secuestrado, Action de GitHub comprometida, imagen base adulterada | 2 | 3 | 🔴 6 | `npm ci` con lockfile e integridad; Actions fijadas por SHA, `permissions: {}`, `persist-credentials: false` (SCRUM-58); imágenes oficiales fijadas por digest (cloudflared, gitleaks); escaneo de imágenes con Trivy (SCRUM-80) | SHA/permisos ✔; Trivy pendiente | 🟡 4 |
| A09 | BD | **Inyección SQL** en login, búsquedas o filtros | 1 | 3 | 🟡 3 | Sequelize con consultas parametrizadas (sin `sequelize.query` con strings concatenados); `express-validator` en usuarios; prueba de SQLi (SCRUM-81) | ✔ | 🟢 1 |
| A10 | Datos de socios | **IDOR / BOLA:** un socio lee cuotas o rutinas de otro (`/api/tarifas/mis-tarifas`, `/api/rutinas/mis-rutinas`) o datos de usuarios (`/api/usuarios/:dni`) | 2 | 2 | 🟡 4 | `mis-*` filtran por `req.usuario.id` del JWT, no por parámetro; `/usuarios/:dni` solo `admin` (`verificarRol`); tests de 403 por rol (SCRUM-32); prueba de escalamiento (SCRUM-81) | ✔ | 🟢 2 |
| A11 | Pagos y cuotas | **Fraude en pagos (lógica de negocio):** `POST /api/pagos` admite rol `socio` y marca como pagada **cualquier** `tarifaId` recibida, sin verificar que la cuota sea suya ni que MercadoPago haya aprobado el pago | 3 | 3 | 🔴 9 | Verificar propiedad de la cuota y el estado `approved` del pago contra la API de MercadoPago antes de marcarla pagada (**SCRUM-81**, hallazgo de esta matriz) | ✔ Corregido en SCRUM-81 (PR #40): 403 si la cuota es ajena; pago verificado contra MercadoPago (estado, referencia y monto); 11 tests de regresión | 🟢 2 |
| A12 | Pagos | **Abuso de la integración MercadoPago:** robo del `ACCESS_TOKEN` o retorno (`back_urls`) falsificado por el usuario | 2 | 3 | 🔴 6 | Token solo en `.env`/Environment (SCRUM-58); tokens de prueba en la demo; validar el pago del lado servidor (SCRUM-81 ✔) | Parcial (falta webhook de notificaciones de MP) | 🟡 3 |
| A13 | Automatizaciones | **Abuso de webhooks de n8n** (disparar flujos o crear incidencias falsas en Mantis) | 2 | 2 | 🟡 4 | n8n con autenticación y sin publicar a Internet (SCRUM-75, SCRUM-61); token de API de Mantis con permisos mínimos (SCRUM-70); pruebas de fallo de los flujos (SCRUM-79) | Parcial | 🟡 3 |
| A14 | IA (Groq) | **Prompt injection / abuso de cuota** en `POST /api/ai/generar-rutina` | 3 | 2 | 🔴 6 | Validación y filtro de instrucciones sospechosas, rate limit de 10 req/15 min por usuario (SCRUM-82) | ✔ | 🟡 3 |
| A15 | Servicios internos | **Exposición de paneles internos** (PostgreSQL, pgAdmin, Grafana, Prometheus, n8n, Mantis) a Internet o a la LAN | 2 | 3 | 🔴 6 | Solo el Nginx del frontend está en el túnel (SCRUM-60); puertos de dev ligados a `127.0.0.1`; matriz de acceso + firewall + nmap externo (SCRUM-61) | Túnel ✔; firewall/nmap en SCRUM-61 | 🟡 3 |
| A16 | Integridad de datos | **Pérdida o divergencia de datos** por caída del primario | 2 | 3 | 🔴 6 | Réplica por streaming con replication slot (SCRUM-45); failover documentado (SCRUM-48); monitoreo de lag (SCRUM-46, SCRUM-68) | Réplica en PR #19 (sin mergear) | 🟡 4 |
| A17 | Disponibilidad pública | **Caída del túnel o de la PC** que publica la app durante la demo | 2 | 2 | 🟡 4 | Monitoreo blackbox de la URL pública y registro de errores (SCRUM-85); plan B local (SCRUM-85, SCRUM-88) | Planificado | 🟡 4 |
| A18 | Operación | **Falta de detección y respuesta** ante un incidente (no se nota, no se sabe qué hacer) | 2 | 3 | 🔴 6 | Prometheus + Alertmanager (SCRUM-66/68); Mantis (SCRUM-70); procedimiento y playbooks de respuesta + flujo n8n de eventos de seguridad (SCRUM-84) | Parcial | 🟡 4 |

**Totales:** 18 amenazas.

| | Alto 🔴 | Medio 🟡 | Bajo 🟢 |
|---|---|---|---|
| Riesgo inherente | 13 | 5 | 0 |
| Riesgo residual | 1 | 11 | 6 |

## 3. Riesgos residuales altos: tratamiento

| # | Por qué sigue alto | Acción y ticket | Responsable |
|---|---|---|---|
| ~~A11~~ | ✔ **Corregido** en SCRUM-81 (PR #40, Mantis #1 y #2). Residual 🟢 2. | — | Valentín Iriarte |
| A04 | Sin segundo factor, una contraseña de admin filtrada alcanza para todo. | **SCRUM-83** (sesión) y **SCRUM-61** (Cloudflare Access por email para funciones de admin). Mientras tanto: contraseña larga y única para admin y cambiar la del usuario demo antes de publicar. | Francisco Paredes / Valentín Iriarte |

## 4. Relación amenaza → control → ticket

```
Fuerza bruta (A03) ────────► rate limit login ─────────► SCRUM-65 ✔ ─► prueba SCRUM-81
Secretos (A06) ────────────► gitleaks + push protection ► SCRUM-31 ✔, SCRUM-58 ✔
Cadena de suministro (A08) ► SHA + digest + Dependabot ─► SCRUM-58 ✔, SCRUM-80
Exposición (A15) ──────────► túnel solo frontend ───────► SCRUM-60 ✔, SCRUM-61
Fraude de pagos (A11) ─────► validar propiedad + MP ────► SCRUM-81
Ransomware (A01) ──────────► backups + restore + offline ► SCRUM-37/38 ✔, SCRUM-84
Respuesta (A18) ───────────► procedimiento + n8n ───────► SCRUM-84
```

## 5. Revisión

La matriz se actualiza:

- al cerrar cada ticket de la columna "Controles";
- después de las pruebas de SCRUM-81;
- ante cualquier incidente registrado en Mantis.

**Actualización 13/11/2026:** A11 corregido y mergeado (SCRUM-81, PR #40) → residual 🟢 2. A12 baja a 🟡 3 por la validación del pago del lado servidor.

## 6. Criterios de aceptación

| Criterio | Estado |
|---|---|
| Matriz activo × amenaza × probabilidad × impacto × control | ✔ Sección 2 |
| Amenazas pedidas: ransomware, DDoS, robo de credenciales (bcrypt, JWT, 2FA admin), dependencias vulnerables, cadena de suministro, SQLi, IDOR (`/mis-tarifas`, `/usuarios/:dni`), abuso de API y webhooks (MercadoPago, n8n), prompt injection (Groq) | ✔ A01, A02, A03/A04/A05, A07, A08, A09, A10, A12/A13, A14 |
| ≥ 12 amenazas y riesgo residual | ✔ 18 amenazas con riesgo inherente y residual |
| Cada control vinculado a un ticket | ✔ Columna "Controles" |
