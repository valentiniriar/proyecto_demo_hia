// Endurecimiento de la API (SCRUM-65).
// Todo se configura por variables de entorno para poder ajustar dev / prod / demo
// sin tocar código. Valores por defecto pensados para desarrollo local.
const helmet = require('helmet');
const cors = require('cors');
const { rateLimit } = require('express-rate-limit');

const DEFAULT_CORS_ORIGINS = [
    'http://localhost:4200',
    'https://localhost:4200',
    'http://localhost:8080',
];

const entero = (valor, porDefecto) => {
    const n = Number.parseInt(valor, 10);
    return Number.isFinite(n) && n > 0 ? n : porDefecto;
};

// TRUST_PROXY: cuántos proxies hay delante del backend para que req.ip sea la IP real
// del cliente (y el rate limit no cuente a todos como "la IP de Nginx").
//   - "false"                       -> backend expuesto directo, sin proxy
//   - número (ej. "2")              -> cantidad de saltos: cloudflared -> Nginx -> backend = 2
//   - lista ("loopback, uniquelocal") -> confiar en proxies de esas redes (default:
//     Nginx y cloudflared corren en redes Docker privadas)
const trustProxy = (valor = process.env.TRUST_PROXY) => {
    if (valor === undefined || valor === '') return 'loopback, uniquelocal';
    if (valor === 'false') return false;
    if (valor === 'true') return 1; // "true" confiaría en cualquiera: se interpreta como 1 salto
    if (/^\d+$/.test(valor)) return Number(valor);
    return valor;
};

// CORS_ORIGINS: lista separada por comas de orígenes permitidos.
// Cuando el frontend se sirve por Nginx en el mismo dominio (/api), CORS no se usa.
const corsOrigins = (valor = process.env.CORS_ORIGINS) => {
    if (!valor) return DEFAULT_CORS_ORIGINS;
    return valor.split(',').map((o) => o.trim()).filter(Boolean);
};

const corsMiddleware = () => {
    const permitidos = corsOrigins();
    return cors({
        origin: (origin, callback) => {
            // Sin cabecera Origin = misma página, curl, healthchecks: no aplica CORS.
            if (!origin || permitidos.includes(origin)) return callback(null, true);
            return callback(null, false);
        },
        methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
        allowedHeaders: ['Content-Type', 'Authorization'],
        maxAge: 600,
    });
};

const helmetMiddleware = () => helmet({
    // La API devuelve JSON; la única página HTML es Swagger UI, que carga sus
    // scripts desde /api/docs (mismo origen) y usa estilos inline.
    contentSecurityPolicy: {
        directives: {
            defaultSrc: ["'self'"],
            scriptSrc: ["'self'"],
            styleSrc: ["'self'", "'unsafe-inline'"],
            imgSrc: ["'self'", 'data:'],
            connectSrc: ["'self'"],
            objectSrc: ["'none'"],
            frameAncestors: ["'none'"],
            baseUri: ["'self'"],
            // HTTPS lo pone Cloudflare/Nginx; en local la API es http y Swagger debe funcionar.
            upgradeInsecureRequests: null,
        },
    },
    // Las respuestas de la API se consumen desde otro origen en desarrollo (localhost:4200).
    crossOriginResourcePolicy: { policy: 'same-site' },
});

const { emitirEventoSeguridad } = require('../src/services/security-events');

// 429 en el formato de la API + evento de seguridad para n8n (SCRUM-84).
const respuesta429 = (msg, limite) => (req, res) => {
    emitirEventoSeguridad('rate_limit', req, { status: 429, limite });
    return res.status(429).json({ status: '0', msg });
};

// Fuerza bruta: intentos a /api/auth/* (login y login con Google) por IP.
// Solo cuentan los intentos fallidos (status >= 400): así un aula entera detrás de la
// misma IP pública puede iniciar sesión, pero adivinar contraseñas queda limitado.
const authRateLimit = () => rateLimit({
    windowMs: entero(process.env.AUTH_RATE_LIMIT_WINDOW_MS, 60 * 1000),
    limit: entero(process.env.AUTH_RATE_LIMIT_MAX, 5),
    skipSuccessfulRequests: true,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    handler: respuesta429('Demasiados intentos de inicio de sesión. Esperá un minuto y volvé a intentar.', 'auth'),
});

// Límite global por IP para toda la API (abuso / scraping / DoS básico).
// /api/health queda afuera: lo consultan Docker, Prometheus y el CI cada pocos segundos.
const globalRateLimit = () => rateLimit({
    windowMs: entero(process.env.RATE_LIMIT_WINDOW_MS, 15 * 60 * 1000),
    limit: entero(process.env.RATE_LIMIT_MAX, 1000),
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    skip: (req) => req.path === '/health',
    handler: respuesta429('Demasiadas solicitudes. Intentá de nuevo en unos minutos.', 'global'),
});

// Límite de tamaño del body JSON (evita payloads gigantes). Ej: "100kb", "1mb".
const bodyLimit = () => process.env.BODY_LIMIT || '100kb';

module.exports = {
    trustProxy,
    corsOrigins,
    corsMiddleware,
    helmetMiddleware,
    authRateLimit,
    globalRateLimit,
    bodyLimit,
};
