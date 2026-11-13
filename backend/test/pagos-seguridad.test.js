// Regresión de los hallazgos de SCRUM-81 sobre POST /api/pagos.
const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const jwt = require('jsonwebtoken');
const axios = require('axios');

process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = process.env.JWT_SECRET || 'test_jwt_secret_key_123456789';
process.env.AUTH_RATE_LIMIT_MAX = '1000';
process.env.RATE_LIMIT_MAX = '100000';

const app = require('../app');
const Tarifa = require('../src/models/tarifa.model');
const Pago = require('../src/models/pago.model');
const Rol = require('../src/models/rol.model');
const UsuarioRol = require('../src/models/usuarioRol.model');

const SOCIO = 30, OTRO_SOCIO = 31, ADMIN = 1;
const token = (id) => jwt.sign({ id, email: `u${id}@demo.com`, estado: true }, process.env.JWT_SECRET, { expiresIn: '1h' });
const ROLES = { [ADMIN]: 'admin', [SOCIO]: 'socio', [OTRO_SOCIO]: 'socio' };

const originales = {};
let creados, marcadas, pagoMP;

beforeEach(() => {
    Object.assign(originales, {
        rolFindOne: Rol.findOne, urFindOne: UsuarioRol.findOne, tFind: Tarifa.findByPk,
        tUpdate: Tarifa.update, pCreate: Pago.create, pFindOne: Pago.findOne, get: axios.get,
        token: process.env.ACCESS_TOKEN,
    });
    creados = []; marcadas = [];
    process.env.ACCESS_TOKEN = 'TEST-token-ficticio';
    Rol.findOne = async ({ where }) => ({ id: { admin: 1, entrenador: 2, socio: 3 }[where.nombre], nombre: where.nombre });
    UsuarioRol.findOne = async ({ where }) => (ROLES[where.id_usuario] === { 1: 'admin', 2: 'entrenador', 3: 'socio' }[where.id_rol]) ? { ...where } : null;
    // Cuota 10 es del SOCIO, cuota 20 es de OTRO_SOCIO; ambas impagas, $25000.
    Tarifa.findByPk = async (id) => ({ 10: { id: 10, precio: '25000', activo: true, pagado: false, suscripcion: { id: 1, usuarioId: SOCIO } },
                                       20: { id: 20, precio: '25000', activo: true, pagado: false, suscripcion: { id: 2, usuarioId: OTRO_SOCIO } } }[id] || null);
    Tarifa.update = async (vals, { where }) => { marcadas.push(where.id); return [1]; };
    Pago.create = async (p) => { creados.push(p); return p; };
    Pago.findOne = async () => null;
    pagoMP = { id: 555, status: 'approved', transaction_amount: 25000, external_reference: '10' };
    axios.get = async (url) => {
        if (!url.endsWith(`/${pagoMP.id}`)) { const e = new Error('404'); e.response = { status: 404 }; throw e; }
        return { data: pagoMP };
    };
});

afterEach(() => {
    Rol.findOne = originales.rolFindOne; UsuarioRol.findOne = originales.urFindOne;
    Tarifa.findByPk = originales.tFind; Tarifa.update = originales.tUpdate;
    Pago.create = originales.pCreate; Pago.findOne = originales.pFindOne; axios.get = originales.get;
    if (originales.token === undefined) delete process.env.ACCESS_TOKEN; else process.env.ACCESS_TOKEN = originales.token;
});

const pagar = (usuario, body) => request(app).post('/api/pagos').set('Authorization', `Bearer ${token(usuario)}`).send(body);

describe('SCRUM-81 · POST /api/pagos', () => {
    it('IDOR: un socio NO puede pagar/marcar la cuota de otro socio (403)', async () => {
        const res = await pagar(SOCIO, { tarifa: { id: 20 }, monto: '1', transaccion: 'FRAUDE', mp_payment_id: '555' });
        assert.equal(res.status, 403);
        assert.equal(marcadas.length, 0);
    });

    it('un socio NO puede marcar su cuota como paga sin un pago de MercadoPago (400)', async () => {
        const res = await pagar(SOCIO, { tarifa: { id: 10 }, monto: '25000', transaccion: 'SIN-PAGAR' });
        assert.equal(res.status, 400);
        assert.equal(marcadas.length, 0);
    });

    it('rechaza un pago de MercadoPago inexistente', async () => {
        const res = await pagar(SOCIO, { tarifa: { id: 10 }, mp_payment_id: '999' });
        assert.equal(res.status, 400);
        assert.match(res.body.msg, /no existe/);
    });

    it('rechaza un pago no aprobado', async () => {
        pagoMP.status = 'pending';
        const res = await pagar(SOCIO, { tarifa: { id: 10 }, mp_payment_id: '555' });
        assert.equal(res.status, 400);
        assert.equal(marcadas.length, 0);
    });

    it('rechaza un pago aprobado de OTRA cuota (external_reference distinto)', async () => {
        pagoMP.external_reference = '99';
        const res = await pagar(SOCIO, { tarifa: { id: 10 }, mp_payment_id: '555' });
        assert.equal(res.status, 400);
    });

    it('rechaza un pago por un monto menor al de la cuota (precio manipulado en el link)', async () => {
        pagoMP.transaction_amount = 1;
        const res = await pagar(SOCIO, { tarifa: { id: 10 }, mp_payment_id: '555' });
        assert.equal(res.status, 400);
        assert.match(res.body.msg, /monto/);
    });

    it('rechaza reutilizar un pago ya registrado', async () => {
        Pago.findOne = async () => ({ id: 1, transaccion: 'MP-555' });
        const res = await pagar(SOCIO, { tarifa: { id: 10 }, mp_payment_id: '555' });
        assert.equal(res.status, 400);
    });

    it('sin ACCESS_TOKEN el servidor no puede verificar y no marca la cuota (503)', async () => {
        delete process.env.ACCESS_TOKEN;
        const res = await pagar(SOCIO, { tarifa: { id: 10 }, mp_payment_id: '555' });
        assert.equal(res.status, 503);
        assert.equal(marcadas.length, 0);
    });

    it('pago aprobado, propio y completo: se registra con los datos de MercadoPago', async () => {
        const res = await pagar(SOCIO, { tarifa: { id: 10 }, mp_payment_id: '555', monto: '1', transaccion: 'lo que mande el navegador' });
        assert.equal(res.status, 200);
        assert.deepEqual(marcadas, [10]);
        assert.equal(creados[0].transaccion, 'MP-555');
        assert.equal(creados[0].monto, '25000');
    });

    it('compatibilidad: toma el id de pago desde "Referencia: <id>" en transaccion', async () => {
        const res = await pagar(SOCIO, { tarifa: { id: 10 }, transaccion: 'Pago Mercado Pago - Referencia: 555' });
        assert.equal(res.status, 200);
    });

    it('el admin sigue pudiendo registrar pagos manuales de cualquier cuota', async () => {
        const res = await pagar(ADMIN, { tarifa: { id: 20 }, fecha: '2026-11-13', transaccion: 'EFECTIVO-001', monto: '25000' });
        assert.equal(res.status, 200);
        assert.deepEqual(marcadas, [20]);
        assert.equal(creados[0].transaccion, 'EFECTIVO-001');
    });
});
