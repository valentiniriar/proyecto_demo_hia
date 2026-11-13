const Pago = require('./../../src/models/pago.model'); // Asegúrate de usar la ruta
const Tarifa = require('./../../src/models/tarifa.model'); // Asegúrate de usar la ruta
const Suscripcion = require('./../../src/models/suscripcion.model');
const Rol = require('./../../src/models/rol.model');
const UsuarioRol = require('./../../src/models/usuarioRol.model');
const { obtenerPago, PagoNoVerificableError } = require('../services/mercadopago.service');

const pagoCtrl = {};

const esAdmin = async (usuarioId) => {
    const rolAdmin = await Rol.findOne({ where: { nombre: 'admin' } });
    if (!rolAdmin) return false;
    const asignacion = await UsuarioRol.findOne({ where: { id_usuario: usuarioId, id_rol: rolAdmin.id } });
    return Boolean(asignacion);
};

// ID del pago de MercadoPago: campo explícito o, por compatibilidad, el número
// que el front incluye en "transaccion" ("Pago Mercado Pago - Referencia: 123").
const paymentIdDe = (data) => {
    if (data.mp_payment_id) return String(data.mp_payment_id);
    const m = /Referencia:\s*(\d+)/.exec(String(data.transaccion || ''));
    return m ? m[1] : null;
};

pagoCtrl.createPago = async (req, res) => {

  try {
    const data = req.body;
    const tarifaId = Number.parseInt(data.tarifa?.id || data.tarifaId, 10);

    if (!Number.isInteger(tarifaId) || tarifaId <= 0) {
        return res.status(400).json({ status: '0', msg: 'Falta tarifa asociada.' });
    }

    const tarifa = await Tarifa.findByPk(tarifaId, {
        include: [{ model: Suscripcion, as: 'suscripcion', attributes: ['id', 'usuarioId'] }]
    });

    if (!tarifa) {
        return res.status(404).json({ status: '0', msg: 'Tarifa asociada no encontrada.' });
    }

    if (tarifa.activo === false) {
        return res.status(400).json({ status: '0', msg: 'No se puede crear un pago para una tarifa anulada.' });
    }

    if (tarifa.pagado === true) {
        return res.status(400).json({ status: '0', msg: 'No se puede crear un pago para una tarifa ya pagada.' });
    }

    // SCRUM-81: el administrador puede registrar pagos manuales (efectivo, transferencia).
    // Un socio solo puede registrar el pago de SU cuota y con un pago de MercadoPago
    // verificado del lado servidor (aprobado, de esta cuota y por el monto completo).
    let nuevoPago;
    if (await esAdmin(req.usuario.id)) {
        nuevoPago = {
            fecha: data.fecha,
            transaccion: data.transaccion,
            monto: data.monto,
            activo: data.activo !== false,
        };
    } else {
        if (!tarifa.suscripcion || Number(tarifa.suscripcion.usuarioId) !== Number(req.usuario.id)) {
            return res.status(403).json({ status: '0', msg: 'La cuota no pertenece al usuario autenticado.' });
        }

        const pagoMP = await obtenerPago(paymentIdDe(data));

        if (pagoMP.status !== 'approved') {
            return res.status(400).json({ status: '0', msg: 'El pago de MercadoPago no está aprobado.' });
        }
        if (pagoMP.external_reference !== String(tarifaId)) {
            return res.status(400).json({ status: '0', msg: 'El pago de MercadoPago corresponde a otra cuota.' });
        }
        if (!(pagoMP.transaction_amount >= Number(tarifa.precio))) {
            return res.status(400).json({ status: '0', msg: 'El monto pagado no cubre el precio de la cuota.' });
        }
        const yaUsado = await Pago.findOne({ where: { transaccion: `MP-${pagoMP.id}` } });
        if (yaUsado) {
            return res.status(400).json({ status: '0', msg: 'Ese pago de MercadoPago ya fue registrado.' });
        }

        // Los datos del pago salen de MercadoPago, no del body enviado por el navegador.
        nuevoPago = {
            fecha: new Date().toISOString().split('T')[0],
            transaccion: `MP-${pagoMP.id}`,
            monto: String(pagoMP.transaction_amount),
            activo: true,
        };
    }

    await Pago.create({ ...nuevoPago, tarifaId });
    await Tarifa.update({ pagado: true }, { where: { id: tarifaId } });
    res.json({ status: '1', msg: 'Pago guardado.' });

  } catch (error) {
    if (error instanceof PagoNoVerificableError) {
        return res.status(error.statusCode).json({ status: '0', msg: error.message });
    }
    console.error(error);
    res.status(400).json({ status: '0', msg: 'Error procesando operacion.' }); 
  } 
}; 

pagoCtrl.getPagos = async (req, res) => { 
  try { 
    const pagos = await Pago.findAll(
            {include: [
           {model: Tarifa, as: 'tarifa', attributes: ['anio','mes' , 'precio', 'activo']}
        ]}

    ); 
    res.json(pagos); 
  } catch (error) { 
    res.status(500).json({ status: '0', msg: 'Error al obtener los pagos.' }); 
  } 
}; 
 
pagoCtrl.anularPago = async (pagoId) => { 
  if (!pagoId) {
    const error = new Error('Falta el id del pago.');
    error.statusCode = 400;
    throw error;
  }

  const pago = await Pago.findByPk(pagoId);

  if (!pago) {
    const error = new Error('Pago no encontrado.');
    error.statusCode = 404;
    throw error;
  }

  const tarifaId = pago.tarifaId || pago.dataValues.tarifaId || pago.getDataValue('tarifaId');

  if (!tarifaId) {
    const error = new Error('El pago no tiene una tarifa asociada.');
    error.statusCode = 400;
    throw error;
  }

  const tarifa = await Tarifa.findByPk(tarifaId);

  if (!tarifa) {
    const error = new Error('Tarifa asociada no encontrada.');
    error.statusCode = 404;
    throw error;
  }

  if (tarifa.activo === false) {
    const error = new Error('No se puede anular un pago de una tarifa anulada.');
    error.statusCode = 400;
    throw error;
  }

  if (tarifa.pagado === false) {
    const error = new Error('La tarifa asociada ya no se encuentra pagada.');
    error.statusCode = 400;
    throw error;
  }

  await Pago.update(
    { activo: false },
    { where: { id: pagoId } }
  );

  await Tarifa.update(
    { pagado: false },
    { where: { id: tarifaId } }
  );

  return { status: '1', msg: 'Pago anulado correctamente.' };
}; 

module.exports = pagoCtrl; 