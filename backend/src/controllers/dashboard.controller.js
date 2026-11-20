const Usuario = require('../models/usuario.model');
const Rol = require('../models/rol.model');
const Tarifa = require('../models/tarifa.model');
const UsuarioRol = require('../models/usuarioRol.model');
const { fn, col, cast, literal } = require('sequelize');

const dashboardCtrl = {};

// Las estadísticas son agregados sobre TODAS las filas (con el dataset, 6M de usuarios y de tarifas):
// ningún índice evita recorrerlas (SCRUM-39 midió usuarios(estado) y usuario_roles(id_rol): no
// llegaban a la mitad del tiempo). Antes, el dashboard tardaba ~10 s en CADA visita del admin.
// Ahora (SCRUM-42):
//   1. Las consultas corren en paralelo y los usuarios activos/inactivos salen de UNA sola pasada.
//   2. El resultado se guarda en memoria DASHBOARD_CACHE_MS (default 5 min): solo la primera visita
//      de cada ventana paga el cálculo. Son totales de un panel, no datos transaccionales: unos minutos
//      de desfase son aceptables.
//   3. Si llegan varias visitas mientras se calcula, comparten la misma consulta (no se lanzan N cálculos).
const CACHE_MS = Number.parseInt(process.env.DASHBOARD_CACHE_MS, 10) >= 0
    ? Number.parseInt(process.env.DASHBOARD_CACHE_MS, 10)
    : 5 * 60 * 1000;

let cache = null;      // { data, expira }
let enCurso = null;    // promesa del cálculo en marcha

const calcularStats = async () => {
    const [usuarios, finanzas, roles, cantidades] = await Promise.all([
        Usuario.findAll({
            attributes: [
                [literal('COUNT(*) FILTER (WHERE estado)'), 'activos'],
                [literal('COUNT(*) FILTER (WHERE NOT estado)'), 'inactivos'],
            ],
            raw: true,
        }),
        // precio es VARCHAR: se castea a NUMERIC para sumar en la base.
        Tarifa.findAll({
            where: { pagado: true, activo: true },
            attributes: [[fn('SUM', cast(col('precio'), 'NUMERIC')), 'total']],
            raw: true,
        }),
        Rol.findAll({ attributes: ['id', 'nombre'], raw: true }),
        UsuarioRol.findAll({
            attributes: ['id_rol', [fn('COUNT', col('id_usuario')), 'total']],
            group: ['id_rol'],
            raw: true,
        }),
    ]);

    const activos = Number(usuarios[0]?.activos) || 0;
    const inactivos = Number(usuarios[0]?.inactivos) || 0;
    const porId = new Map(cantidades.map(x => [Number(x.id_rol), Number(x.total)]));
    const porNombre = Object.fromEntries(roles.map(r => [r.nombre, porId.get(r.id) || 0]));

    return {
        usuarios: { total: activos + inactivos, activos, inactivos },
        roles: {
            admins: porNombre.admin || 0,
            entrenadores: porNombre.entrenador || 0,
            socios: porNombre.socio || 0,
        },
        finanzas: { ingresosTotales: Number(finanzas[0]?.total) || 0 },
    };
};

const obtenerStats = async () => {
    if (cache && cache.expira > Date.now()) return cache.data;
    if (!enCurso) {
        enCurso = calcularStats()
            .then((data) => {
                cache = { data, expira: Date.now() + CACHE_MS };
                return data;
            })
            .finally(() => { enCurso = null; });
    }
    return enCurso;
};

dashboardCtrl.getStats = async (req, res) => {
    try {
        const data = await obtenerStats();
        res.json({ status: '1', msg: 'Estadísticas obtenidas', data });
    } catch (error) {
        console.error(error);
        res.status(500).json({ status: '0', msg: 'Error al obtener estadísticas del dashboard.' });
    }
};

// Solo para tests.
dashboardCtrl._limpiarCache = () => { cache = null; enCurso = null; };

module.exports = dashboardCtrl;
