const bcrypt = require('bcrypt');
const { validationResult } = require('express-validator');
const Usuario = require('./../../src/models/usuario.model');
const UsuarioRol = require('./../../src/models/usuarioRol.model');
const Rol = require('./../../src/models/rol.model');
const { leerPaginacion, opcionesConsulta, armarPagina, leerBusqueda } = require('../utils/paginacion');
const usuarioCtrl = {};

// Alta de nuevo usuario
usuarioCtrl.createUsuario = async (req, res) => {
    try {
        const errors = validationResult(req);
        if (!errors.isEmpty()) {
            return res.status(422).json({ status: '0', errors: errors.array() });
        }

        const usuarioExistente = await Usuario.findOne({ where: { dni: req.body.dni } });
        if (usuarioExistente) {
            return res.json({status: '0', msg: `El usuario con el DNI ${req.body.dni} ya se encuentra registrado.`});
        } 
        
        const password_hash = await bcrypt.hash(req.body.password, 10)
        
        const nuevoUsuario = await Usuario.create({
            nombre: req.body.nombre,
            apellido: req.body.apellido,
            dni: req.body.dni,
            email: req.body.email,
            password_hash: password_hash,
            google_id: req.body.google_id || null
        });

        await UsuarioRol.create({ id_usuario: nuevoUsuario.id, id_rol: 3 });

        res.json({status: '1', msg: 'Usuario creado correctamente.'});
    } catch (error) {
        console.error(error);
        res.status(500).json({status: '0', msg: 'Error al procesar la peticion de alta'});
    }
};

// Obtener todos los usuarios
usuarioCtrl.getUsuarios = async (req, res) => {
    try {
        const paginacion = leerPaginacion(req);
        const filas = await Usuario.findAll({
            attributes: { exclude: ['password_hash', 'createdAt', 'updatedAt'] },
            ...opcionesConsulta(paginacion)
        });
        const { items, ...pagina } = armarPagina(filas, paginacion);
        res.json({status: '1', msg: 'Usuarios obtenidos correctamente.', usuarios: items, ...pagina});
    } catch (error) {
        console.error(error);
        res.status(500).json({status: '0', msg: 'Error al obtener los usuarios'});
    }
};

// Obtener usuario por DNI
usuarioCtrl.getUsuarioByDni = async (req, res) => {
    try {
        const usuario = await Usuario.findOne({
            where: { dni: req.params.dni },
            attributes: { exclude: ['password_hash', 'createdAt', 'updatedAt'] }
        });
        if (usuario) {
            res.json({status: '1', msg: 'Usuario obtenido correctamente.', usuario});
        } else {
            res.status(404).json({status: '0', msg: 'Usuario no encontrado'});
        }
    } catch (error) {
        console.error(error);
        res.status(500).json({status: '0', msg: 'Error al obtener el usuario'});
    }
};

// Modificar un usuario
usuarioCtrl.updateUsuario = async (req, res) => {
    try {
        const errors = validationResult(req);
        if (!errors.isEmpty()) {
            return res.status(422).json({status: '0', errors: errors.array()});
        }

        const usuario = await Usuario.findOne({ where: { dni: req.params.dni } });
        if (!usuario) {
            return res.status(404).json({status: '0', msg: 'Usuario no encontrado'});
        } 

        const datosActualizados = { ...req.body };
        if (req.body.password) {
            datosActualizados.password_hash = await bcrypt.hash(req.body.password, 10);
            delete datosActualizados.password;
        }

        await usuario.update(datosActualizados);
        res.json({status: '1', msg: 'Usuario modificado correctamente.'});
    } catch (error) {
        console.error(error);
        res.status(500).json({status: '0', msg: 'Error al modificar el usuario'});
    }
};

// Eliminar un usuario
usuarioCtrl.deleteUsuario = async (req, res) => {
    try {
        const usuario = await Usuario.findOne({ where: { dni: req.params.dni } });
        if (!usuario) {
            return res.status(404).json({status: '0', msg: 'Usuario no encontrado'});
        }
        await usuario.destroy();
        res.json({status: '1', msg: 'Usuario eliminado correctamente.'});
    } catch (error) {
        console.error(error);
        res.status(500).json({status: '0', msg: 'Error al eliminar el usuario'});
    }
};

// Inactivar usuario (baja logica)
usuarioCtrl.inactiveUsuario = async (req, res) => {
    try {
        const usuario = await Usuario.findOne({ where: { dni: req.params.dni } });
        if (!usuario) {
            return res.status(404).json({status: '0', msg: 'Usuario no encontrado'});
        }
        await usuario.update({ estado: false });
        res.json({status: '1', msg: 'Usuario inactivado correctamente.'});
    } catch (error) {
        console.error(error);
        res.status(500).json({status: '0', msg: 'Error al inactivar el usuario'});
    }
};

// Activar usuario
usuarioCtrl.activeUsuario = async (req, res) => {
    try {
        const usuario = await Usuario.findOne({ where: { dni: req.params.dni } });
        if (!usuario) {
            return res.status(404).json({status: '0', msg: 'Usuario no encontrado'});
        }
        await usuario.update({ estado: true });
        res.json({status: '1', msg: 'Usuario activado correctamente.'});
    } catch (error) {
        console.error(error);
        res.status(500).json({status: '0', msg: 'Error al activar el usuario'});
    }
};


// Obtener solo los usuarios que son Socios
usuarioCtrl.getSocios = async (req, res) => {
    try {
        const paginacion = leerPaginacion(req);
        // ?q= (combos de suscripciones y rutinas): DNI exacto, que tiene índice único. No se busca por
        // apellido: sin índice, una búsqueda sin resultados recorría los ~6M usuarios.
        const q = leerBusqueda(req);
        const where = { estado: true };
        if (q) where.dni = q;

        const filas = q && !/^\d+$/.test(q) ? [] : await Usuario.findAll({
            where,
            ...opcionesConsulta(paginacion),
            attributes: { exclude: ['password_hash', 'createdAt', 'updatedAt'] },
            include: [{
                model: Rol,
                attributes: [],
                where: { nombre: 'socio' },
                through: { attributes: [] },
                required: true
            }]
        });

        const { items, ...pagina } = armarPagina(filas, paginacion);
        res.json({status: '1', msg: 'Socios obtenidos correctamente.', usuarios: items, ...pagina});
    } catch (error) {
        console.error(error);
        res.status(500).json({status: '0', msg: 'Error al obtener los socios'});
    }
};

module.exports = usuarioCtrl;