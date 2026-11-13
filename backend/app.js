const dotenv = require("dotenv");
dotenv.config();

const express = require('express');
const sequelize = require('./config/database');
const security = require('./config/security');

const app = express();

// Seguridad (SCRUM-65): IP real detrás de Cloudflare/Nginx, cabeceras HTTP seguras,
// CORS por entorno, límites de solicitudes y de tamaño del body.
app.set('trust proxy', security.trustProxy());
app.disable('x-powered-by');
app.use(security.helmetMiddleware());
app.use(security.corsMiddleware());
app.use('/api', security.globalRateLimit());
app.use('/api/auth', security.authRateLimit());
// Eventos de seguridad hacia n8n: login fallido y login de admin (SCRUM-84).
app.use('/api/auth', require('./src/middlewares/security-events.middleware').auditarAuth);
app.use(express.json({ limit: security.bodyLimit() }));

// Salud del servicio: lo usan el HEALTHCHECK de Docker, el deploy del CI/CD y el monitoreo.
// 200 si la API responde y la base acepta conexiones; 503 si la base no está disponible.
app.get('/api/health', async (req, res) => {
    try {
        await sequelize.authenticate();
        res.json({ status: 'ok', db: 'up', uptime: Math.round(process.uptime()) });
    } catch (error) {
        res.status(503).json({ status: 'error', db: 'down' });
    }
});

// Rutas para mercado pago
app.use('/api/mp', require('./src/routes/mp.route.js'));

// Associations
require('./config/associations');

// Swagger
const swaggerUi = require('swagger-ui-express');
const swaggerFile = require('./swagger_output.json');

// Routes
app.use('/api/usuarios', require('./src/routes/usuario.route.js'));
app.use('/api/auth', require('./src/routes/auth.route.js'));
app.use('/api/roles', require('./src/routes/rol.route'));

app.use('/api/ejercicios', require('./src/routes/ejercicio.route.js'));
app.use('/api/youtube', require('./src/routes/youtube.route.js'));
app.use('/api/rutinas', require('./src/routes/rutina.route.js'));
app.use('/api/suscripciones', require('./src/routes/suscripcion.route.js'));
app.use('/api/tarifas', require('./src/routes/tarifa.route.js'));
app.use('/api/pagos', require('./src/routes/pago.route.js'));
app.use('/api/dashboard', require('./src/routes/dashboard.route.js'));
app.use('/api/ai', require('./src/routes/ai.route.js'));
app.use('/api/nutricion', require('./src/routes/nutricion.route.js'));

// Ruta hacia la documentacion de swagger
app.use('/api/docs', swaggerUi.serve, swaggerUi.setup(swaggerFile));

// Errores del parser JSON: responder en el mismo formato que el resto de la API
// en lugar de la página HTML por defecto de Express.
app.use((err, req, res, next) => {
    if (err && err.type === 'entity.too.large') {
        return res.status(413).json({ status: '0', msg: 'El cuerpo de la solicitud supera el tamaño máximo permitido.' });
    }
    if (err && err.type === 'entity.parse.failed') {
        return res.status(400).json({ status: '0', msg: 'JSON inválido.' });
    }
    return next(err);
});

module.exports = app;
