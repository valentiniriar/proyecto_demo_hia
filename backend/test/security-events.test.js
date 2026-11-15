// Eventos de seguridad hacia n8n (SCRUM-84).
const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const bcrypt = require('bcrypt');

process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = process.env.JWT_SECRET || 'test_jwt_secret_key_123456789';
process.env.AUTH_RATE_LIMIT_MAX = '2';
process.env.TRUST_PROXY = '1';

const app = require('../app');
const Usuario = require('../src/models/usuario.model');
const UsuarioRol = require('../src/models/usuarioRol.model');
const Rol = require('../src/models/rol.model');
const { emitirEventoSeguridad } = require('../src/services/security-events');

const esperar = () => new Promise((r) => setTimeout(r, 20));
let enviados, fetchOriginal, originales;

beforeEach(async () => {
    enviados = [];
    fetchOriginal = global.fetch;
    global.fetch = async (url, opts) => { enviados.push({ url, headers: opts.headers, body: JSON.parse(opts.body) }); return { ok: true }; };
    process.env.SECURITY_EVENTS_WEBHOOK_URL = 'http://n8n.test/webhook/gymhub-seguridad';
    process.env.SECURITY_EVENTS_WEBHOOK_SECRET = 'secreto-de-prueba';
    const hash = await bcrypt.hash('Correcta123', 4);
    originales = { u: Usuario.findOne, ur: UsuarioRol.findOne, r: Rol.findByPk };
    Usuario.findOne = async ({ where }) => (where.email === 'admin@demo.com'
        ? { id: 1, nombre: 'Admin', apellido: 'Demo', email: 'admin@demo.com', password_hash: hash, estado: true } : null);
    UsuarioRol.findOne = async () => ({ id_usuario: 1, id_rol: 1 });
    Rol.findByPk = async () => ({ id: 1, nombre: 'admin' });
});

afterEach(() => {
    global.fetch = fetchOriginal;
    Usuario.findOne = originales.u; UsuarioRol.findOne = originales.ur; Rol.findByPk = originales.r;
    delete process.env.SECURITY_EVENTS_WEBHOOK_URL;
    delete process.env.SECURITY_EVENTS_WEBHOOK_SECRET;
});

const login = (ip, email, password) => request(app).post('/api/auth/login').set('X-Forwarded-For', ip).send({ email, password });

describe('SCRUM-84 · eventos de seguridad', () => {
    it('login fallido → evento login_fallido con IP real, email y secreto', async () => {
        await login('203.0.113.50', 'admin@demo.com', 'incorrecta');
        await esperar();
        assert.equal(enviados.length, 1);
        assert.equal(enviados[0].url, 'http://n8n.test/webhook/gymhub-seguridad');
        assert.equal(enviados[0].headers['X-GymHub-Secret'], 'secreto-de-prueba');
        assert.equal(enviados[0].body.tipo, 'login_fallido');
        assert.equal(enviados[0].body.ip, '203.0.113.50');
        assert.equal(enviados[0].body.email, 'admin@demo.com');
        assert.equal(enviados[0].body.status, 401);
    });

    it('login exitoso de un admin → evento login_admin', async () => {
        const res = await login('198.51.100.7', 'admin@demo.com', 'Correcta123');
        assert.equal(res.status, 200);
        await esperar();
        assert.equal(enviados.length, 1);
        assert.equal(enviados[0].body.tipo, 'login_admin');
        assert.equal(enviados[0].body.ip, '198.51.100.7');
        assert.equal(enviados[0].body.usuario_id, 1);
    });

    it('rate limit alcanzado → evento rate_limit', async () => {
        for (let i = 0; i < 3; i++) await login('192.0.2.99', 'admin@demo.com', `mala${i}`);
        await esperar();
        const tipos = enviados.map((e) => e.body.tipo);
        assert.deepEqual(tipos, ['login_fallido', 'login_fallido', 'rate_limit']);
        assert.equal(enviados[2].body.limite, 'auth');
    });

    it('sin SECURITY_EVENTS_WEBHOOK_URL no envía nada', async () => {
        delete process.env.SECURITY_EVENTS_WEBHOOK_URL;
        const enviado = await emitirEventoSeguridad('login_fallido', { ip: '1.1.1.1', method: 'POST', originalUrl: '/x', get: () => '' });
        assert.equal(enviado, false);
        assert.equal(enviados.length, 0);
    });

    it('si n8n no responde, la API responde igual', async () => {
        global.fetch = async () => { throw new Error('ECONNREFUSED'); };
        const res = await login('203.0.113.77', 'admin@demo.com', 'incorrecta');
        assert.equal(res.status, 401);
    });
});
