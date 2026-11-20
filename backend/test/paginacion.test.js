// Paginación de listados: las tablas tienen ~6M filas y traerlas todas colgaba el backend y el navegador.
const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const jwt = require('jsonwebtoken');

process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = process.env.JWT_SECRET || 'test_jwt_secret_key_123456789';
process.env.AUTH_RATE_LIMIT_MAX = '1000';
process.env.RATE_LIMIT_MAX = '100000';

const app = require('../app');
const Pago = require('../src/models/pago.model');
const Suscripcion = require('../src/models/suscripcion.model');
const Usuario = require('../src/models/usuario.model');
const Rol = require('../src/models/rol.model');
const UsuarioRol = require('../src/models/usuarioRol.model');
const { leerPaginacion, opcionesConsulta, armarPagina, leerBusqueda } = require('../src/utils/paginacion');

const ADMIN = 1;
const token = jwt.sign({ id: ADMIN, email: 'admin@demo.com', estado: true }, process.env.JWT_SECRET, { expiresIn: '1h' });
const filas = (n) => Array.from({ length: n }, (_, i) => ({ id: 1000 - i }));

describe('utils/paginacion', () => {
    it('defaults: página 1 de 20', () => {
        assert.deepEqual(leerPaginacion({ query: {} }), { page: 1, limit: 20, offset: 0 });
    });

    it('calcula el offset y respeta el tope de 100', () => {
        assert.deepEqual(leerPaginacion({ query: { page: '3', limit: '50' } }), { page: 3, limit: 50, offset: 100 });
        assert.equal(leerPaginacion({ query: { limit: '100000' } }).limit, 100);
    });

    it('valores inválidos vuelven a los defaults', () => {
        for (const query of [{ page: 'abc', limit: 'x' }, { page: '-2', limit: '0' }, { page: ['1', '2'] }]) {
            assert.deepEqual(leerPaginacion({ query }), { page: 1, limit: 20, offset: 0 });
        }
    });

    it('pide una fila extra y ordena por id descendente', () => {
        assert.deepEqual(opcionesConsulta({ limit: 20, offset: 40 }), { limit: 21, offset: 40, order: [['id', 'DESC']] });
    });

    it('hasMore solo si vino la fila extra, que no se devuelve', () => {
        const conMas = armarPagina(filas(21), { page: 1, limit: 20 });
        assert.equal(conMas.items.length, 20);
        assert.equal(conMas.hasMore, true);
        const ultima = armarPagina(filas(7), { page: 4, limit: 20 });
        assert.deepEqual({ n: ultima.items.length, hasMore: ultima.hasMore, page: ultima.page }, { n: 7, hasMore: false, page: 4 });
    });

    it('leerBusqueda recorta y descarta vacíos o no-texto', () => {
        assert.equal(leerBusqueda({ query: { q: '  123 ' } }), '123');
        assert.equal(leerBusqueda({ query: { q: '   ' } }), null);
        assert.equal(leerBusqueda({ query: { q: ['a'] } }), null);
    });
});

describe('Endpoints paginados', () => {
    const originales = {};
    let consultas;

    beforeEach(() => {
        Object.assign(originales, {
            rolFindOne: Rol.findOne, urFindOne: UsuarioRol.findOne,
            pFindAll: Pago.findAll, sFindAll: Suscripcion.findAll, uFindOne: Usuario.findOne,
        });
        consultas = [];
        Rol.findOne = async ({ where }) => ({ id: { admin: 1, entrenador: 2, socio: 3 }[where.nombre], nombre: where.nombre });
        UsuarioRol.findOne = async ({ where }) => (where.id_usuario === ADMIN && where.id_rol === 1 ? { ...where } : null);
        Pago.findAll = async (opts) => { consultas.push(opts); return filas(opts.limit); };
        Suscripcion.findAll = async (opts) => { consultas.push(opts); return filas(3); };
        Usuario.findOne = async ({ where }) => (where.dni === '10000003' ? { id: 3 } : null);
    });

    afterEach(() => {
        Rol.findOne = originales.rolFindOne; UsuarioRol.findOne = originales.urFindOne;
        Pago.findAll = originales.pFindAll; Suscripcion.findAll = originales.sFindAll; Usuario.findOne = originales.uFindOne;
    });

    const get = (url) => request(app).get(url).set('Authorization', `Bearer ${token}`);

    it('GET /api/pagos devuelve 20 por página con hasMore, sin traer toda la tabla', async () => {
        const res = await get('/api/pagos?page=2');
        assert.equal(res.status, 200);
        assert.equal(consultas[0].limit, 21);
        assert.equal(consultas[0].offset, 20);
        assert.deepEqual({ n: res.body.items.length, page: res.body.page, hasMore: res.body.hasMore }, { n: 20, page: 2, hasMore: true });
    });

    it('GET /api/pagos con limit enorme queda en 100', async () => {
        await get('/api/pagos?limit=1000000');
        assert.equal(consultas[0].limit, 101);
    });

    it('GET /api/suscripciones?q=<dni> filtra por id o por el socio de ese DNI', async () => {
        const res = await get('/api/suscripciones?q=10000003');
        assert.equal(res.status, 200);
        assert.equal(res.body.hasMore, false);
        const [condiciones] = Object.getOwnPropertySymbols(consultas[0].where).map((s) => consultas[0].where[s]);
        assert.deepEqual(condiciones, [{ id: 10000003 }, { usuarioId: 3 }]);
    });

    it('GET /api/suscripciones?q=<texto> no consulta la base (sin índice por apellido)', async () => {
        const res = await get('/api/suscripciones?q=Perez');
        assert.equal(res.status, 200);
        assert.deepEqual(res.body.items, []);
        assert.equal(consultas.length, 0);
    });
});
