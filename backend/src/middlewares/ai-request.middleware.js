const { body, validationResult } = require('express-validator');
const { rateLimit } = require('express-rate-limit');

// Límite por identidad verificada, no por IP compartida entre usuarios.
const aiRateLimit = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: 10,
  standardHeaders: 'draft-8',
  legacyHeaders: false,
  keyGenerator: (req) => `user:${String(req.usuario.id)}`,
  message: { status: '0', msg: 'Límite de solicitudes de IA alcanzado; reintentá más tarde.' }
});

const nombreValido = /^[\p{L}\p{N} ,.:()\/-]+$/u;
// Defensa adicional frente a ataques conocidos; no garantiza bloquear todos los ataques.
const instruccionSospechosa = /(?:ignora|ignore|desobedece|omite|override|revela|muestra|envia|envía).{0,60}(?:instrucciones|reglas|prompt|sistema|system|clave|contraseña|token|api.?key)/i;
const nombreSeguro = (v) => nombreValido.test(v) && !instruccionSospechosa.test(v);

const aiRequestValidators = [
  body('nombre')
    .isString().withMessage('El nombre debe ser texto.')
    .bail()
    .trim()
    .isLength({ min: 2, max: 80 }).withMessage('El nombre debe tener entre 2 y 80 caracteres.')
    .bail()
    .custom(nombreSeguro).withMessage('El nombre contiene caracteres o instrucciones no permitidos.'),
  body('ejercicios')
    .optional()
    .isArray({ min: 0, max: 20 }).withMessage('ejercicios debe ser una lista de hasta 20 nombres.')
    .bail()
    .custom((items) => items.every((v) => typeof v === 'string' &&
      v.trim().length >= 2 && v.trim().length <= 80 && nombreSeguro(v)))
    .withMessage('Cada ejercicio debe tener entre 2 y 80 caracteres y no contener instrucciones.')
];

const handleAiValidation = (req, res, next) => {
  const errores = validationResult(req);
  if (!errores.isEmpty()) {
    return res.status(400).json({ status: '0', msg: 'Solicitud de IA inválida.', errors: errores.array().map(e => ({ campo: e.path, mensaje: e.msg })) });
  }
  next();
};

module.exports = { aiRateLimit, aiRequestValidators, handleAiValidation };
