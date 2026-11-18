// Tests de endurecimiento de la API (SCRUM-65).
const { describe, it, before } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');

process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = process.env.JWT_SECRET || 'test_jwt_secret_key_123456789';
process.env.CORS_ORIGINS = 'https://gymhub.example.com,http://localhost:4200';
process.env.AUTH_RATE_LIMIT_MAX = '3';
process.env.BODY_LIMIT = '1kb';
process.env.TRUST_PROXY = '1';

const app = require('../app');
const sequelize = require('../config/database');
const Usuario = require('../src/models/usuario.model');
const { trustProxy, corsOrigins } = require('../config/security');

describe('SCRUM-65 · Endurecimiento de la API', () => {
    before(() => {
        sequelize.authenticate = async () => true;
        Usuario.findOne = async () => null; // ningún usuario existe: todo login da 401
    });

    describe('helmet', () => {
        it('agrega cabeceras de seguridad y oculta X-Powered-By', async () => {
            const res = await request(app).get('/api/health');
            assert.equal(res.status, 200);
            assert.equal(res.headers['x-content-type-options'], 'nosniff');
            assert.equal(res.headers['x-frame-options'], 'SAMEORIGIN');
            assert.match(res.headers['strict-transport-security'], /max-age=\d+/);
            assert.match(res.headers['content-security-policy'], /default-src 'self'/);
            assert.match(res.headers['content-security-policy'], /frame-ancestors 'none'/);
            assert.equal(res.headers['referrer-policy'], 'no-referrer');
            assert.equal(res.headers['x-powered-by'], undefined);
        });
    });

    describe('CORS por entorno', () => {
        it('permite un origen listado en CORS_ORIGINS', async () => {
            const res = await request(app).get('/api/health').set('Origin', 'https://gymhub.example.com');
            assert.equal(res.headers['access-control-allow-origin'], 'https://gymhub.example.com');
        });

        it('no devuelve Access-Control-Allow-Origin para un origen no listado', async () => {
            const res = await request(app).get('/api/health').set('Origin', 'https://sitio-malicioso.example');
            assert.equal(res.headers['access-control-allow-origin'], undefined);
        });

        it('responde el preflight solo para orígenes permitidos', async () => {
            const ok = await request(app).options('/api/auth/login')
                .set('Origin', 'http://localhost:4200')
                .set('Access-Control-Request-Method', 'POST');
            assert.equal(ok.status, 204);
            assert.equal(ok.headers['access-control-allow-origin'], 'http://localhost:4200');
        });

        it('lee la lista de orígenes desde la variable y usa defaults si no está', () => {
            assert.deepEqual(corsOrigins('https://a.com, https://b.com'), ['https://a.com', 'https://b.com']);
            assert.ok(corsOrigins('').includes('http://localhost:4200'));
        });
    });

    describe('trust proxy', () => {
        it('interpreta TRUST_PROXY', () => {
            assert.equal(trustProxy('false'), false);
            assert.equal(trustProxy('2'), 2);
            assert.equal(trustProxy('true'), 1);
            assert.equal(trustProxy(''), 'loopback, uniquelocal');
            assert.equal(app.get('trust proxy'), 1);
        });
    });

    describe('límite de tamaño del body', () => {
        it('rechaza con 413 (JSON) un body mayor a BODY_LIMIT', async () => {
            const res = await request(app)
                .post('/api/usuarios')
                .set('Content-Type', 'application/json')
                .send(JSON.stringify({ relleno: 'x'.repeat(5000) }));
            assert.equal(res.status, 413);
            assert.equal(res.body.status, '0');
        });

        it('responde 400 (JSON) ante un JSON mal formado', async () => {
            const res = await request(app)
                .post('/api/usuarios')
                .set('Content-Type', 'application/json')
                .send('{"roto":');
            assert.equal(res.status, 400);
            assert.equal(res.body.msg, 'JSON inválido.');
        });
    });

    describe('rate limiting en /api/auth', () => {
        it('bloquea con 429 al superar AUTH_RATE_LIMIT_MAX intentos por IP', async () => {
            const ip = '203.0.113.10'; // IP de documentación (RFC 5737), vía X-Forwarded-For
            const intento = () => request(app)
                .post('/api/auth/login')
                .set('X-Forwarded-For', ip)
                .send({ email: 'atacante@example.com', password: 'probando123' });

            for (let i = 0; i < 3; i++) {
                const res = await intento();
                assert.equal(res.status, 401, `intento ${i + 1} debería ser 401`);
            }
            const bloqueado = await intento();
            assert.equal(bloqueado.status, 429);
            assert.equal(bloqueado.body.status, '0');
            assert.ok(bloqueado.headers['ratelimit-policy'] || bloqueado.headers['ratelimit'], 'debe informar la política de límite');
        });

        it('cuenta por IP real: otra IP detrás del mismo proxy no queda bloqueada', async () => {
            const res = await request(app)
                .post('/api/auth/login')
                .set('X-Forwarded-For', '198.51.100.20')
                .send({ email: 'socio@example.com', password: 'probando123' });
            assert.equal(res.status, 401);
        });
    });
});
