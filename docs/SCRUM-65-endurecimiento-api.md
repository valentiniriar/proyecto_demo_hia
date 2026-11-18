# SCRUM-65 · Endurecer la API: helmet, rate limiting en login y CORS por entorno

**Épica:** E14 · Seguridad informática y amenazas actuales  
**Responsable:** Valentín Iriarte  
**Rama:** `feat/SCRUM-65-endurecer-api`

## 1. Hallazgo

La API no usaba helmet ni limitaba los intentos de login (fuerza bruta sin freno), CORS admitía solo `localhost` escrito en el código, y `express.json()` no tenía límite de tamaño explícito.

## 2. Cambios

Toda la configuración vive en [`backend/config/security.js`](../backend/config/security.js) y se aplica en [`backend/app.js`](../backend/app.js), antes de las rutas:

```js
app.set('trust proxy', security.trustProxy());
app.disable('x-powered-by');
app.use(security.helmetMiddleware());
app.use(security.corsMiddleware());
app.use('/api', security.globalRateLimit());
app.use('/api/auth', security.authRateLimit());
app.use(express.json({ limit: security.bodyLimit() }));
```

| Control | Implementación | Variable de entorno (default) |
|---|---|---|
| Cabeceras seguras | `helmet` 8.3.0: CSP restrictiva (`default-src 'self'`, `frame-ancestors 'none'`, `object-src 'none'`), HSTS, `nosniff`, `X-Frame-Options`, `Referrer-Policy: no-referrer`; además se quita `X-Powered-By` | — |
| Rate limit de login | `express-rate-limit` en `/api/auth/*` (login y login con Google). **Solo cuentan los intentos fallidos** (`skipSuccessfulRequests`), así un aula entera detrás de una misma IP puede entrar pero adivinar contraseñas queda frenado. Responde `429` con `{status:'0', msg}` y cabeceras `RateLimit`/`RateLimit-Policy` | `AUTH_RATE_LIMIT_MAX` (5), `AUTH_RATE_LIMIT_WINDOW_MS` (60000) |
| Rate limit global | Toda `/api/*` por IP, salvo `/api/health` (lo consultan Docker, Prometheus y el CI) | `RATE_LIMIT_MAX` (1000), `RATE_LIMIT_WINDOW_MS` (900000 = 15 min) |
| IP real detrás de proxies | `trust proxy` configurable. El default confía en proxies de redes privadas (Nginx y cloudflared corren en redes Docker), así `req.ip` es la IP del cliente y no la de Nginx | `TRUST_PROXY` (`loopback, uniquelocal`); `false` sin proxy; `2` para cloudflared → Nginx → backend |
| CORS por entorno | Lista blanca leída de la variable. Un origen no listado no recibe `Access-Control-Allow-Origin` | `CORS_ORIGINS` (`http://localhost:4200,https://localhost:4200,http://localhost:8080`) |
| Límite de body | `express.json({ limit })`. Si se supera responde `413` en JSON; un JSON roto responde `400` en JSON (antes devolvía una página HTML de error) | `BODY_LIMIT` (`100kb`) |

Además, `npm test` y `npm run test:ci` ahora corren `security.test.js` y también `ai-security.test.js` (SCRUM-82), que antes no estaba incluido.

## 3. Pruebas automáticas

[`backend/test/security.test.js`](../backend/test/security.test.js), 10 casos:

- helmet: cabeceras presentes y sin `X-Powered-By`.
- CORS: origen permitido recibe la cabecera, origen ajeno no; preflight `204`; parseo de la variable.
- `trust proxy`: interpretación de `TRUST_PROXY`.
- Body: `413` con un body mayor al límite; `400` con JSON mal formado.
- Rate limit: 3 intentos fallidos `401`, el 4.º `429`; otra IP detrás del mismo proxy no queda bloqueada.

```
$ npm test
# tests 21
# pass 21
# fail 0
```

## 4. Verificación contra la API real (PostgreSQL en Docker)

Cabeceras de `GET /api/health`:

```
HTTP/1.1 200 OK
Content-Security-Policy: default-src 'self';base-uri 'self';font-src 'self' https: data:;form-action 'self';frame-ancestors 'none';img-src 'self' data:;object-src 'none';script-src 'self';script-src-attr 'none';style-src 'self' 'unsafe-inline';connect-src 'self'
Referrer-Policy: no-referrer
Strict-Transport-Security: max-age=31536000; includeSubDomains
X-Content-Type-Options: nosniff
X-Frame-Options: SAMEORIGIN
```

Fuerza bruta contra `admin@demo.com` (7 contraseñas incorrectas seguidas):

```
401 401 401 401 401 429 429
```

Después del bloqueo, incluso la contraseña correcta recibe `429` hasta que pasa el minuto:

```
HTTP/1.1 429 Too Many Requests
RateLimit: "5-in-1min"; r=0; t=60
```

Swagger UI (`/api/docs`) carga y funciona con la CSP nueva, sin errores en la consola del navegador.

## 5. Notas para producción

- Detrás de Cloudflare Tunnel + Nginx (SCRUM-60) se puede dejar el default o fijar `TRUST_PROXY=2`. **Nunca** `true` sin restricción: permitiría falsificar la IP con `X-Forwarded-For` y saltear el rate limit.
- El contador del rate limit vive en memoria del proceso: con una sola instancia del backend alcanza. Con varias réplicas habría que usar un store compartido (Redis).
- HSTS solo tiene efecto cuando la API se sirve por HTTPS (Cloudflare).

## 6. Criterios de aceptación

| Criterio | Estado |
|---|---|
| helmet activo con cabeceras verificadas | ✔ Secciones 3 y 4 |
| express-rate-limit en `/api/auth/*` (5 intentos/min por IP) y límite global razonable | ✔ 5 fallidos/min por IP; 1000 req/15 min global |
| trust proxy configurado para obtener la IP real detrás de Cloudflare/Nginx | ✔ `TRUST_PROXY`, test de IPs distintas |
| Orígenes CORS desde variable de entorno | ✔ `CORS_ORIGINS` |
| Límite de tamaño de body en `express.json()` | ✔ `BODY_LIMIT` (100kb), 413 en JSON |
