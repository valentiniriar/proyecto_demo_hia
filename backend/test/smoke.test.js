const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const jwt = require('jsonwebtoken');
const bcrypt = require('bcrypt');

process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = process.env.JWT_SECRET || 'test_jwt_secret_key_123456789';

const app = require('../app');
const sequelize = require('../config/database');
const Usuario = require('../src/models/usuario.model');
const Rol = require('../src/models/rol.model');
const UsuarioRol = require('../src/models/usuarioRol.model');

describe('Smoke Tests - Backend GymHub API', () => {

    describe('GET /api/health', () => {
        it('debe responder al healthcheck con 200 cuando la BD responde', async () => {
            const originalAuth = sequelize.authenticate;
            sequelize.authenticate = async () => true;

            try {
                const res = await request(app).get('/api/health');
                assert.equal(res.status, 200);
                assert.equal(res.body.status, 'ok');
                assert.equal(res.body.db, 'up');
            } finally {
                sequelize.authenticate = originalAuth;
            }
        });

        it('debe responder al healthcheck con 503 si la BD falla', async () => {
            const originalAuth = sequelize.authenticate;
            sequelize.authenticate = async () => { throw new Error('DB Down'); };

            try {
                const res = await request(app).get('/api/health');
                assert.equal(res.status, 503);
                assert.equal(res.body.status, 'error');
                assert.equal(res.body.db, 'down');
            } finally {
                sequelize.authenticate = originalAuth;
            }
        });
    });

    describe('POST /api/auth/login', () => {
        it('login inválido: debe rechazar credenciales inexistentes con 401', async () => {
            const originalFindOne = Usuario.findOne;
            Usuario.findOne = async () => null;

            try {
                const res = await request(app)
                    .post('/api/auth/login')
                    .send({ email: 'noexiste@gymhub.com', password: 'Password123!' });

                assert.equal(res.status, 401);
                assert.equal(res.body.status, '0');
                assert.match(res.body.msg, /credenciales/i);
            } finally {
                Usuario.findOne = originalFindOne;
            }
        });

        it('login OK: debe autenticar usuario válido y devolver token', async () => {
            const passwordPlana = 'Secreta123!';
            const hash = await bcrypt.hash(passwordPlana, 10);

            const originalUsuarioFindOne = Usuario.findOne;
            const originalRolFindByPk = Rol.findByPk;
            const originalUsuarioRolFindOne = UsuarioRol.findOne;

            Usuario.findOne = async ({ where }) => {
                if (where && where.email === 'socio@gymhub.com') {
                    return {
                        id: 999,
                        nombre: 'Juan',
                        apellido: 'Perez',
                        email: 'socio@gymhub.com',
                        password_hash: hash,
                        estado: true
                    };
                }
                return null;
            };

            UsuarioRol.findOne = async () => ({ id_usuario: 999, id_rol: 3 });
            Rol.findByPk = async () => ({ id: 3, nombre: 'socio' });

            try {
                const res = await request(app)
                    .post('/api/auth/login')
                    .send({ email: 'socio@gymhub.com', password: passwordPlana });

                assert.equal(res.status, 200);
                assert.equal(res.body.status, '1');
                assert.ok(res.body.token, 'Debe retornar un token JWT');
                assert.equal(res.body.usuario.rol, 'socio');
            } finally {
                Usuario.findOne = originalUsuarioFindOne;
                UsuarioRol.findOne = originalUsuarioRolFindOne;
                Rol.findByPk = originalRolFindByPk;
            }
        });
    });

    describe('Control de acceso (Auth y Rol Middlewares)', () => {
        it('ruta protegida sin token: debe responder 401', async () => {
            const res = await request(app).get('/api/usuarios');
            assert.equal(res.status, 401);
            assert.match(res.body.msg, /token/i);
        });

        it('ruta protegida con token de rol no autorizado: debe responder 403', async () => {
            const tokenSocio = jwt.sign(
                { id: 888, email: 'socio@gymhub.com', estado: true },
                process.env.JWT_SECRET,
                { expiresIn: '1h' }
            );

            const originalRolFindOne = Rol.findOne;
            const originalUsuarioRolFindOne = UsuarioRol.findOne;

            Rol.findOne = async ({ where }) => ({ id: where.nombre === 'admin' ? 1 : 2, nombre: where.nombre });
            UsuarioRol.findOne = async () => null;

            try {
                const res = await request(app)
                    .get('/api/usuarios')
                    .set('Authorization', `Bearer ${tokenSocio}`);

                assert.equal(res.status, 403);
                assert.match(res.body.msg, /acceso denegado/i);
            } finally {
                Rol.findOne = originalRolFindOne;
                UsuarioRol.findOne = originalUsuarioRolFindOne;
            }
        });
    });

});
