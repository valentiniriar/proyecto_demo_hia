// Dashboard del admin (SCRUM-42): con 6M filas cada cálculo recorre las tablas enteras (~2-3 s),
// así que el resultado se cachea y las visitas simultáneas comparten un solo cálculo.
const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const jwt = require('jsonwebtoken');

process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = process.env.JWT_SECRET || 'test_jwt_secret_key_123456789';
process.env.AUTH_RATE_LIMIT_MAX = '1000';
process.env.RATE_LIMIT_MAX = '100000';

const app = require('../app');
const dashboardCtrl = require('../src/controllers/dashboard.controller');
const Usuario = require('../src/models/usuario.model');
const Tarifa = require('../src/models/tarifa.model');
const Rol = require('../src/models/rol.model');
const UsuarioRol = require('../src/models/usuarioRol.model');

const ADMIN = 1;
const token = jwt.sign({ id: ADMIN, email: 'admin@demo.com', estado: true }, process.env.JWT_SECRET, { expiresIn: '1h' });

describe('GET /api/dashboard/stats', () => {
    let originales;
    let consultas;

    beforeEach(() => {
        dashboardCtrl._limpiarCache();
        consultas = 0;
        originales = {
            uFindAll: Usuario.findAll, tFindAll: Tarifa.findAll, rFindAll: Rol.findAll,
            rFindOne: Rol.findOne, urFindAll: UsuarioRol.findAll, urFindOne: UsuarioRol.findOne,
        };
        // Autorización: el admin tiene el rol admin.
        Rol.findOne = async ({ where }) => ({ id: { admin: 1, entrenador: 2, socio: 3 }[where.nombre], nombre: where.nombre });
        UsuarioRol.findOne = async ({ where }) => (where.id_usuario === ADMIN && where.id_rol === 1 ? { ...where } : null);
        // Datos del dashboard.
        Usuario.findAll = async () => { consultas++; return [{ activos: '1840538', inactivos: '159462' }]; };
        Tarifa.findAll = async () => { consultas++; return [{ total: '123456.50' }]; };
        Rol.findAll = async () => { consultas++; return [{ id: 1, nombre: 'admin' }, { id: 2, nombre: 'entrenador' }, { id: 3, nombre: 'socio' }]; };
        UsuarioRol.findAll = async () => { consultas++; return [{ id_rol: 1, total: '6000' }, { id_rol: 2, total: '90000' }, { id_rol: 3, total: '1904000' }]; };
    });

    afterEach(() => {
        Usuario.findAll = originales.uFindAll; Tarifa.findAll = originales.tFindAll; Rol.findAll = originales.rFindAll;
        Rol.findOne = originales.rFindOne; UsuarioRol.findAll = originales.urFindAll; UsuarioRol.findOne = originales.urFindOne;
        dashboardCtrl._limpiarCache();
    });

    const pedir = () => request(app).get('/api/dashboard/stats').set('Authorization', `Bearer ${token}`);

    it('devuelve el mismo formato que antes, con números', async () => {
        const res = await pedir();
        assert.equal(res.status, 200);
        assert.deepEqual(res.body.data, {
            usuarios: { total: 2000000, activos: 1840538, inactivos: 159462 },
            roles: { admins: 6000, entrenadores: 90000, socios: 1904000 },
            finanzas: { ingresosTotales: 123456.5 },
        });
    });

    it('la segunda visita sale de la caché (no vuelve a consultar la base)', async () => {
        await pedir();
        assert.equal(consultas, 4);
        const res = await pedir();
        assert.equal(res.status, 200);
        assert.equal(consultas, 4);
    });

    it('visitas simultáneas comparten un solo cálculo', async () => {
        const respuestas = await Promise.all([pedir(), pedir(), pedir()]);
        respuestas.forEach((r) => assert.equal(r.status, 200));
        assert.equal(consultas, 4);
    });

    it('si la base falla responde 500 y no cachea el error', async () => {
        Usuario.findAll = async () => { throw new Error('base caída'); };
        assert.equal((await pedir()).status, 500);
        Usuario.findAll = async () => { consultas++; return [{ activos: '1', inactivos: '0' }]; };
        const res = await pedir();
        assert.equal(res.status, 200);
        assert.equal(res.body.data.usuarios.total, 1);
    });
});
