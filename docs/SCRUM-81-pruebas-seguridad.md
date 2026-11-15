# SCRUM-81 · Pruebas de seguridad controladas (SQLi, fuerza bruta, IDOR, OWASP ZAP)

**Épica:** E14 · Seguridad informática y amenazas actuales  
**Responsable:** Valentín Iriarte  
**Rama:** `fix/SCRUM-81-pruebas-seguridad`  
**Fecha:** 13/11/2026

> **Alcance:** solo contra **nuestro entorno local de prueba** (`http://localhost:8080`, stack `compose.yaml + compose.dev.yaml`, datos demo). No se probó contra la URL pública ni contra servicios de terceros.

## 1. Herramientas y método

| Prueba | Herramienta | Detalle |
|---|---|---|
| Escaneo pasivo | **OWASP ZAP 2.16.1** `zap-baseline.py` (imagen `ghcr.io/zaproxy/zaproxy:2.16.1`) | Spider + reglas pasivas contra `http://frontend:8080` desde la red Docker |
| SQLi, fuerza bruta, escalamiento de rol, IDOR | Script reproducible [`evidencias/SCRUM-81/pruebas-seguridad.sh`](evidencias/SCRUM-81/pruebas-seguridad.sh) (curl) | 23 verificaciones automáticas con resultado esperado. Crea dos socios "víctima" con su suscripción y cuota para probar el acceso cruzado |
| Regresión | `backend/test/pagos-seguridad.test.js` (node:test + supertest) | 11 casos que fijan la corrección en el CI |

Cada prueba se corrió **antes** y **después** de la corrección: [`resultado-antes.txt`](evidencias/SCRUM-81/resultado-antes.txt), [`resultado-despues.txt`](evidencias/SCRUM-81/resultado-despues.txt), [`zap-antes.html`](evidencias/SCRUM-81/zap-antes.html), [`zap-despues.html`](evidencias/SCRUM-81/zap-despues.html).

## 2. Resultados por prueba

### 2.1 Inyección SQL — sin vulnerabilidad

| Intento | Resultado | Lectura |
|---|---|---|
| Login con email `' OR '1'='1` | 422 | `express-validator` rechaza el email antes de tocar la BD |
| Login con email `admin@demo.com'--` | 422 | Ídem |
| Login con password `' OR 1=1--` | 401 | Sequelize parametriza; bcrypt compara contra el hash |
| `GET /api/usuarios/1' OR '1'='1` (admin) | 404 | Se busca literalmente ese DNI; no devuelve datos |
| `GET /api/tarifas/impagas/1 OR 1=1` (admin) | **500 → 400** | Sin fuga, pero el parámetro no se validaba → **hallazgo H3** |
| `GET /api/nutricion/buscar?q=' UNION SELECT password_hash FROM usuarios--` | 200 | El término solo se reenvía a Open Food Facts; nunca llega a nuestra BD |

Los endpoints `/api/ejercicios/buscar` y `/api/usuarios/buscar` del ticket **no existen** en la API actual. Las búsquedas reales son las de nutrición y YouTube; las dos reenvían el término a servicios externos, sin SQL.

### 2.2 Fuerza bruta — mitigada (SCRUM-65)

```
7 intentos fallidos desde la misma IP: 401 401 401 401 401 429 429
✔ el 6.º intento fallido se bloquea
✔ otra IP no queda bloqueada
```

### 2.3 Escalamiento de rol — sin vulnerabilidad

Socio contra `GET/DELETE /usuarios`, `GET /pagos`, `GET/POST /tarifas`, `POST /suscripciones`, `GET /dashboard/stats`, y entrenador contra `DELETE /usuarios`: todo **403**. JWT con payload alterado (id=1, firma vieja) y JWT `alg=none`: **401**.

### 2.4 IDOR — **vulnerabilidad crítica encontrada y corregida**

| Prueba | Antes | Después |
|---|---|---|
| `/mis-tarifas` del socio demo incluye la cuota de otro socio | No | No |
| Socio llama `/tarifas/impagas/<id de otro socio>` | 403 | 403 |
| **Socio registra un pago de $1 sobre la cuota de otro socio** | **200 "Pago guardado."** → la cuota ajena quedaba pagada | **403** "La cuota no pertenece al usuario autenticado." |
| **Socio marca su propia cuota como pagada sin pagar** | **200** | **400** "Falta el identificador del pago de MercadoPago…" |

### 2.5 OWASP ZAP baseline

| | Antes | Después |
|---|---|---|
| FAIL | 0 | 0 |
| WARN | 11 | 9 |
| PASS | 56 | 58 |

| Alerta ZAP | Antes | Después | Tratamiento |
|---|---|---|---|
| 10036 Versión del servidor en `Server` | WARN | ✔ resuelta | `server_tokens off` |
| 10063 Sin `Permissions-Policy` | WARN | ✔ resuelta | Cámara, micrófono, geolocalización, pagos y USB deshabilitados |
| 10055 CSP con comodines (`https:` en script/connect/frame/font) | WARN | Solo queda `img-src https:` | Orígenes explícitos (Google Sign-In, YouTube, Google Maps). `img-src https:` se acepta: miniaturas de YouTube y fotos de Open Food Facts vienen de dominios variables |
| 90004 Aislamiento (Spectre) | WARN ×14 | WARN ×8 | Se agregaron `Cross-Origin-Opener-Policy: same-origin-allow-popups` y `Cross-Origin-Resource-Policy: same-origin`. **Riesgo aceptado** para `COEP: require-corp`, que rompería los embeds de YouTube, Maps y Google Sign-In |
| 10017 / 90003 JS de otro dominio sin SRI | WARN | WARN | **Riesgo aceptado:** es el script oficial de Google Sign-In, que Google cambia sin aviso (no admite SRI). Mitigado por la CSP, que solo permite `accounts.google.com` |
| 10027 Comentarios sospechosos / 10110 funciones JS peligrosas | WARN | WARN | Falsos positivos en los bundles minificados de Angular y librerías |
| 10049 Contenido cacheable / 10109 aplicación moderna / 10116 versión de ZAP | WARN | WARN | Informativos |

## 3. Hallazgos, corrección y re-test

| # | Mantis | Hallazgo | Severidad | Corrección | Re-test |
|---|---|---|---|---|---|
| H1 | #1 | IDOR en `POST /api/pagos`: un socio marcaba como pagada la cuota de otro socio | fallo / inmediata | El backend verifica que la cuota pertenezca al usuario del JWT (`tarifa.suscripcion.usuarioId`); si no, **403** | ✔ 403 (script y test) |
| H2 | #2 | El pago no se verificaba del lado servidor: un socio marcaba su cuota con una transacción inventada, o pagaba menos manipulando `unit_price` del link | fallo / inmediata | Nuevo `services/mercadopago.service.js`: el backend consulta `GET /v1/payments/{id}` con su `ACCESS_TOKEN` y exige `status=approved`, `external_reference` = la cuota y `transaction_amount ≥ precio`. Además rechaza reutilizar un pago y guarda **los datos de MercadoPago** (no los del navegador). Sin `ACCESS_TOKEN` responde 503 y no marca nada. El admin sigue pudiendo registrar pagos manuales (efectivo). El front envía `mp_payment_id` | ✔ 400/403 (script) + 11 tests de regresión |
| H3 | #3 | `GET /tarifas/impagas/:usuarioId` respondía 500 ante un id no numérico | menor / normal | Validación `^\d+$` → **400** | ✔ 400 |
| H4 | #4 | Cabeceras de seguridad incompletas en Nginx (ZAP) | menor / alta | `server_tokens off`, CSP con orígenes explícitos, `form-action`, `Permissions-Policy`, COOP, CORP y `Referrer-Policy` en `frontend/nginx.conf` | ✔ ZAP 11 → 9 WARN; la app se probó en el navegador (login con Google, rutinas con YouTube) sin errores de CSP |

Las cuatro incidencias quedaron cargadas en Mantis (proyecto GymHub, asignadas a `viriarte`), con los JSON en [`evidencias/SCRUM-81/mantis/`](evidencias/SCRUM-81/mantis/). Al mergear este PR pasan a **resuelta** con la referencia al PR, y en SCRUM-72 se **cierran** con la evidencia.

Resultado final del script: **antes 20 OK / 3 hallazgos → después 23 OK / 0 hallazgos**.

## 4. Observaciones (fuera del alcance de este ticket)

- `ReferenceError: google is not defined` en la consola al entrar directo a `/login` o `/register`: el componente usa `google.accounts.id` antes de que termine de cargar el script `async`. No es de seguridad; candidato a un ticket de frontend.
- Con `TRUST_PROXY` por defecto se confía en proxies de redes privadas: desde una red privada se puede falsear `X-Forwarded-For` (el script lo usa para simular IPs). Desde Internet no: el túnel agrega la IP pública real (SCRUM-60/65).

## 5. Criterios de aceptación

| Criterio | Estado |
|---|---|
| Escaneo OWASP ZAP baseline contra la URL de prueba, con reporte | ✔ 2.5 + reportes HTML/MD antes y después |
| Intento de SQLi en login y buscadores | ✔ 2.1 (los buscadores del ticket no existen; se probaron los reales) |
| Fuerza bruta al login para validar el rate limiting | ✔ 2.2 |
| Escalamiento de rol: socio llamando endpoints de admin; socio accediendo a tarifas/rutinas de otro socio (IDOR) | ✔ 2.3 y 2.4 |
| Resultado, corrección aplicada y re-test para cada hallazgo; incidencias cargadas en Mantis | ✔ Sección 3 (Mantis #1–#4) |
