// =====================================================================
//  SCRUM-39 - Captura del SQL que genera Sequelize para las consultas
//  que no se ejercitan por HTTP (socios activos, stats del dashboard,
//  ejercicios por nombre ILIKE y pagos por rango de fechas).
//
//  No se conecta a la base: reemplaza la conexion y Query.run por stubs
//  que solo imprimen el SQL. Asi el texto de consultas_psql.sql es el
//  mismo que enviaria el backend, sin traer millones de filas a Node.
//
//  Uso (desde la raiz del repo):  node database/analisis/capturar-sql.js
// =====================================================================
process.env.NODE_ENV = 'test';
process.env.DB_NAME = process.env.DB_NAME || 'demo_hia';
process.env.DB_USER = process.env.DB_USER || 'demo_hia';

const path = require('path');
const backend = (p) => require(path.join(__dirname, '..', '..', 'backend', p));

const sequelize = backend('config/database');
const capturadas = [];
sequelize.connectionManager.getConnection = async () => ({});
sequelize.connectionManager.releaseConnection = async () => {};
sequelize.dialect.Query.prototype.run = async function run(sql) {
    capturadas.push(sql);
    return [];
};

const { fn, col, Op } = require(require.resolve('sequelize', { paths: [path.join(__dirname, '..', '..', 'backend')] }));
backend('config/associations');
const Usuario = backend('src/models/usuario.model');
const Rol = backend('src/models/rol.model');
const Tarifa = backend('src/models/tarifa.model');
const UsuarioRol = backend('src/models/usuarioRol.model');
const Ejercicio = backend('src/models/ejercicio.model');
const Pago = backend('src/models/pago.model');

(async () => {
    const consultas = {
        // usuario.controller.js getSocios
        socios_activos: () => Usuario.findAll({
            where: { estado: true },
            attributes: { exclude: ['password_hash', 'createdAt', 'updatedAt'] },
            include: [{ model: Rol, attributes: [], where: { nombre: 'socio' }, through: { attributes: [] }, required: true }],
        }),
        // dashboard.controller.js getStats (5 consultas)
        dashboard_activos: () => Usuario.count({ where: { estado: true } }),
        dashboard_inactivos: () => Usuario.count({ where: { estado: false } }),
        dashboard_tarifas_pagadas: () => Tarifa.findAll({ where: { pagado: true, activo: true }, attributes: ['precio'] }),
        dashboard_roles: () => Rol.findAll({ attributes: ['id', 'nombre'], raw: true }),
        dashboard_por_rol: () => UsuarioRol.findAll({
            attributes: ['id_rol', [fn('COUNT', col('id_usuario')), 'total']], group: ['id_rol'], raw: true,
        }),
        // SIN ENDPOINT en el backend: SQL propuesto, escrito como lo haria un controlador
        // con Op.iLike y Op.between (ver docs/SCRUM-39-analisis-consultas-pgbadger.md)
        ejercicios_ilike: () => Ejercicio.findAll({ where: { nombre: { [Op.iLike]: '%press%' } } }),
        pagos_rango_fechas: () => Pago.findAll({
            where: { fecha: { [Op.between]: ['2026-10-01', '2026-10-31'] } },
            include: [{ model: Tarifa, as: 'tarifa', attributes: ['anio', 'mes', 'precio', 'activo'] }],
            order: [['fecha', 'ASC']],
        }),
    };
    for (const [nombre, ejecutar] of Object.entries(consultas)) {
        capturadas.length = 0;
        try { await ejecutar(); } catch { /* el stub devuelve [] y count() puede quejarse */ }
        for (const sql of capturadas) console.log(`-- ${nombre}\n${sql.replace(/^Executing \(default\): /, '')}\n`);
    }
})();
