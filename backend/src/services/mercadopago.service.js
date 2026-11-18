// Consulta de pagos en MercadoPago del lado servidor (SCRUM-81).
// El navegador no es una fuente confiable: el estado, el monto y la referencia de un
// pago se verifican directamente contra la API de MercadoPago con nuestro ACCESS_TOKEN.
const axios = require('axios');

const MP_PAYMENTS_URL = 'https://api.mercadopago.com/v1/payments';

class PagoNoVerificableError extends Error {
    constructor(msg, statusCode = 400) {
        super(msg);
        this.statusCode = statusCode;
    }
}

// Devuelve { id, status, transaction_amount, external_reference } o lanza PagoNoVerificableError.
async function obtenerPago(paymentId) {
    if (!/^\d{1,20}$/.test(String(paymentId || ''))) {
        throw new PagoNoVerificableError('Falta el identificador del pago de MercadoPago o no es válido.');
    }
    if (!process.env.ACCESS_TOKEN) {
        throw new PagoNoVerificableError('No se puede verificar el pago: MercadoPago no está configurado en el servidor.', 503);
    }
    try {
        const { data } = await axios.get(`${MP_PAYMENTS_URL}/${paymentId}`, {
            headers: { Authorization: `Bearer ${process.env.ACCESS_TOKEN}` },
            timeout: 8000,
        });
        return {
            id: String(data.id),
            status: data.status,
            transaction_amount: Number(data.transaction_amount),
            external_reference: data.external_reference == null ? '' : String(data.external_reference),
        };
    } catch (error) {
        if (error.response && error.response.status === 404) {
            throw new PagoNoVerificableError('El pago informado no existe en MercadoPago.');
        }
        throw new PagoNoVerificableError('No se pudo consultar el pago en MercadoPago. Intentá más tarde.', 502);
    }
}

module.exports = { obtenerPago, PagoNoVerificableError };
