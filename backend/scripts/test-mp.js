// Prueba manual de la integración con MercadoPago (SCRUM-31).
// Crea una preferencia de pago de prueba y muestra el link (init_point).
//
// Uso (desde backend/):   npm run test:mp
// Requiere ACCESS_TOKEN (token de PRUEBA de MercadoPago) en backend/.env.
// No forma parte de los tests automáticos ni de la imagen Docker.
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env') });
const axios = require('axios');

async function testMP() {
  if (!process.env.ACCESS_TOKEN) {
    console.error('Falta ACCESS_TOKEN en backend/.env (usar un token de prueba de MercadoPago).');
    process.exitCode = 1;
    return;
  }

  const frontendUrl = process.env.FRONTEND_URL || 'http://localhost:4200';

  try {
    const url = 'https://api.mercadopago.com/checkout/preferences';
    const body = {
      payer_email: 'test_user@example.com',
      items: [
        {
          title: 'Cuota gimnasio',
          description: 'Pago de cuota mensual',
          category_id: 'services',
          quantity: 1,
          unit_price: 1500,
        },
      ],
      back_urls: {
        failure: `${frontendUrl}/tarifas`,
        pending: `${frontendUrl}/tarifas`,
        success: `${frontendUrl}/tarifas`,
      },
      auto_return: 'approved',
    };

    const payment = await axios.post(url, body, {
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${process.env.ACCESS_TOKEN}`,
      },
    });

    console.log('Preferencia creada:', payment.data.init_point);
  } catch (error) {
    console.error('Error de MercadoPago:', JSON.stringify(error.response?.data, null, 2) || error.message);
    process.exitCode = 1;
  }
}

testMP();
