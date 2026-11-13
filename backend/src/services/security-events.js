// Eventos de seguridad hacia n8n (SCRUM-84).
// El backend avisa: login fallido, rate limit alcanzado y login exitoso de un admin.
// n8n los clasifica (fuerza bruta, IP nueva de admin) y abre la incidencia en Mantis.
//
// Desactivado por defecto: solo envía si existe SECURITY_EVENTS_WEBHOOK_URL.
// El envío es "fire and forget" con timeout corto: si n8n no responde, la API sigue igual.

const recortar = (v, n) => (v == null ? undefined : String(v).slice(0, n));

function emitirEventoSeguridad(tipo, req, extra = {}) {
    const url = process.env.SECURITY_EVENTS_WEBHOOK_URL;
    if (!url || typeof fetch !== 'function') return Promise.resolve(false);

    const evento = {
        tipo,                                   // login_fallido | rate_limit | login_admin
        fecha: new Date().toISOString(),
        ip: req.ip,
        metodo: req.method,
        ruta: recortar(req.originalUrl, 200),
        user_agent: recortar(req.get && req.get('user-agent'), 200),
        ...extra,
    };

    return fetch(url, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            // Secreto compartido: n8n descarta lo que no lo traiga (credencial Header Auth).
            'X-GymHub-Secret': process.env.SECURITY_EVENTS_WEBHOOK_SECRET || '',
        },
        body: JSON.stringify(evento),
        signal: AbortSignal.timeout(3000),
    }).then(() => true).catch(() => false);
}

module.exports = { emitirEventoSeguridad };
