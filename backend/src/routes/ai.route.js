const express = require('express');
const router = express.Router();
const aiCtrl = require('../controllers/ai.controller');
const verificarToken = require('../middlewares/auth.middleware');
const verificarRol = require('../middlewares/rol.middleware');
const { aiRateLimit, aiRequestValidators, handleAiValidation } = require('../middlewares/ai-request.middleware');

router.post('/generar-rutina', verificarToken, verificarRol('entrenador'), aiRateLimit, aiRequestValidators, handleAiValidation, aiCtrl.generarRutinaIA);

module.exports = router;
