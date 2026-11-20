const Usuario = require('../models/usuario.model');
const Rol = require('../models/rol.model');
const Tarifa = require('../models/tarifa.model');
const UsuarioRol = require('../models/usuarioRol.model');
const { fn, col, cast } = require('sequelize');

const dashboardCtrl = {};

dashboardCtrl.getStats = async (req, res) => {
    try {
        const usuariosActivos = await Usuario.count({ where: { estado: true } });
        const usuariosInactivos = await Usuario.count({ where: { estado: false } });

        // SUM en la base: antes se traían todas las tarifas pagadas (millones de filas) para sumarlas en JS.
        // precio es VARCHAR: se castea a NUMERIC para sumar.
        const [{ total }] = await Tarifa.findAll({
            where: { pagado: true, activo: true },
            attributes: [[fn('SUM', cast(col('precio'), 'NUMERIC')), 'total']],
            raw: true
        });
        const ingresosTotales = Number(total) || 0;

        const roles = await Rol.findAll({
            attributes: ['id', 'nombre'],
            raw: true
        });

        const cantidades = await UsuarioRol.findAll({
            attributes: ['id_rol', [fn('COUNT', col('id_usuario')), 'total']],
            group: ['id_rol'],
            raw: true
        });

        const porId = new Map(
            cantidades.map(x => [Number(x.id_rol), Number(x.total)])
        );
        const porNombre = Object.fromEntries(
            roles.map(r => [r.nombre, porId.get(r.id) || 0])
        );

        const admins = porNombre.admin || 0;
        const entrenadores = porNombre.entrenador || 0;
        const socios = porNombre.socio || 0;

        res.json({
            status: '1',
            msg: 'Estadísticas obtenidas',
            data: {
                usuarios: {
                    total: usuariosActivos + usuariosInactivos,
                    activos: usuariosActivos,
                    inactivos: usuariosInactivos
                },
                roles: {
                    admins,
                    entrenadores,
                    socios
                },
                finanzas: {
                    ingresosTotales
                }
            }
        });

    } catch (error) {
        console.error(error);
        res.status(500).json({ status: '0', msg: 'Error al obtener estadísticas del dashboard.' });
    }
};

module.exports = dashboardCtrl;
