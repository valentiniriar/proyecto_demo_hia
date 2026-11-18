// Audita las respuestas de /api/auth/* y emite eventos de seguridad (SCRUM-84).
const { emitirEventoSeguridad } = require('../services/security-events');

const auditarAuth = (req, res, next) => {
    const jsonOriginal = res.json.bind(res);
    res.json = (body) => {
        try {
            if (res.statusCode === 401 || res.statusCode === 403) {
                emitirEventoSeguridad('login_fallido', req, {
                    status: res.statusCode,
                    email: typeof req.body?.email === 'string' ? req.body.email.slice(0, 120) : undefined,
                });
            } else if (res.statusCode === 200 && body?.usuario?.rol === 'admin') {
                emitirEventoSeguridad('login_admin', req, {
                    status: 200,
                    usuario_id: body.usuario.id,
                    email: body.usuario.email,
                });
            }
        } catch {
            // La auditoría nunca debe romper la respuesta.
        }
        return jsonOriginal(body);
    };
    next();
};

module.exports = { auditarAuth };
