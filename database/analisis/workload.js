// =====================================================================
//  SCRUM-39 - Carga HTTP contra el backend con el dataset de 6M
//
//  Ejercita los endpoints candidatos que SI escalan por HTTP:
//    POST /api/auth/login                  (socio generado)       login por email
//    GET  /api/tarifas/mis-tarifas         (token del socio)      mis-tarifas
//    GET  /api/rutinas/mis-rutinas         (token del socio)      mis-rutinas
//    GET  /api/usuarios/:dni               (token admin)          usuario por DNI
//    GET  /api/tarifas/impagas/:usuarioId  (token admin)          impagas por usuario
//  Cada request autenticado ademas pasa por verificarRol (2 consultas).
//
//  Socios activos y stats del dashboard no se piden por HTTP (traen
//  millones de filas a Node): ver consultas_psql.sql.
//
//  Entrada: USUARIOS = archivo TSV "id<TAB>email<TAB>dni" (lo genera ejercitar.sh)
//  Variables: BASE_URL (http://localhost:3000), CONCURRENCIA (4),
//             ADMIN_EMAIL (admin@demo.com), PASSWORD (demo1234)
//  Sin dependencias: fetch nativo de Node >= 18.
// =====================================================================
const fs = require('fs');

const BASE_URL = process.env.BASE_URL || 'http://localhost:3000';
const CONCURRENCIA = Number(process.env.CONCURRENCIA || 4);
const PASSWORD = process.env.PASSWORD || 'demo1234';
const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'admin@demo.com';
const ARCHIVO = process.env.USUARIOS;

if (!ARCHIVO || !fs.existsSync(ARCHIVO)) {
    console.error('ERROR: definir USUARIOS=<archivo TSV id/email/dni> (lo genera ejercitar.sh)');
    process.exit(1);
}

const usuarios = fs.readFileSync(ARCHIVO, 'utf8')
    .split(/\r?\n/).filter(Boolean)
    .map((linea) => { const [id, email, dni] = linea.split('\t'); return { id, email, dni }; });

const stats = new Map();
const registrar = (nombre, ms, status) => {
    if (!stats.has(nombre)) stats.set(nombre, { tiempos: [], errores: 0, status: {} });
    const s = stats.get(nombre);
    s.tiempos.push(ms);
    s.status[status] = (s.status[status] || 0) + 1;
    if (status >= 400 || status === 0) s.errores += 1;
};

async function pedir(nombre, metodo, ruta, { token, body } = {}) {
    const inicio = performance.now();
    let status = 0;
    let json = null;
    try {
        const res = await fetch(BASE_URL + ruta, {
            method: metodo,
            headers: {
                'Content-Type': 'application/json',
                ...(token ? { Authorization: `Bearer ${token}` } : {}),
            },
            body: body ? JSON.stringify(body) : undefined,
            signal: AbortSignal.timeout(120_000),
        });
        status = res.status;
        json = await res.json().catch(() => null);
    } catch (e) {
        console.error(`  ${nombre} ${ruta}: ${e.message}`);
    }
    registrar(nombre, performance.now() - inicio, status);
    return { status, json };
}

const login = async (email) => {
    const r = await pedir('POST /api/auth/login', 'POST', '/api/auth/login', { body: { email, password: PASSWORD } });
    return r.json && r.json.token;
};

async function main() {
    console.log(`SCRUM-39 workload: ${usuarios.length} socios, concurrencia ${CONCURRENCIA}, ${BASE_URL}`);
    const salud = await fetch(`${BASE_URL}/api/health`).then((r) => r.json()).catch(() => null);
    if (!salud || salud.status !== 'ok') {
        console.error('ERROR: el backend no responde ok en /api/health');
        process.exit(1);
    }

    const tokenAdmin = await login(ADMIN_EMAIL);
    if (!tokenAdmin) {
        console.error(`ERROR: no se pudo loguear ${ADMIN_EMAIL}`);
        process.exit(1);
    }

    const inicio = performance.now();
    let siguiente = 0;
    let hechos = 0;

    async function trabajador() {
        while (siguiente < usuarios.length) {
            const u = usuarios[siguiente++];
            const token = await login(u.email);
            if (token) {
                await pedir('GET /api/tarifas/mis-tarifas', 'GET', '/api/tarifas/mis-tarifas', { token });
                await pedir('GET /api/rutinas/mis-rutinas', 'GET', '/api/rutinas/mis-rutinas', { token });
            }
            await pedir('GET /api/usuarios/:dni', 'GET', `/api/usuarios/${u.dni}`, { token: tokenAdmin });
            await pedir('GET /api/tarifas/impagas/:usuarioId', 'GET', `/api/tarifas/impagas/${u.id}`, { token: tokenAdmin });
            hechos += 1;
            if (hechos % 25 === 0) {
                console.log(`  ${hechos}/${usuarios.length} socios (${Math.round((performance.now() - inicio) / 1000)} s)`);
            }
        }
    }

    await Promise.all(Array.from({ length: CONCURRENCIA }, trabajador));

    const pct = (arr, p) => arr[Math.min(arr.length - 1, Math.floor((p / 100) * arr.length))];
    console.log(`\nDuracion total: ${Math.round((performance.now() - inicio) / 1000)} s\n`);
    console.log('endpoint'.padEnd(38) + 'llamadas'.padStart(9) + 'p50_ms'.padStart(9) + 'p95_ms'.padStart(9) + 'max_ms'.padStart(9) + 'errores'.padStart(9) + '  status');
    let errores5xx = 0;
    for (const [nombre, s] of stats) {
        const t = [...s.tiempos].sort((a, b) => a - b);
        errores5xx += Object.entries(s.status).filter(([c]) => Number(c) >= 500 || Number(c) === 0).reduce((a, [, n]) => a + n, 0);
        console.log(nombre.padEnd(38) + String(t.length).padStart(9) + pct(t, 50).toFixed(0).padStart(9)
            + pct(t, 95).toFixed(0).padStart(9) + t[t.length - 1].toFixed(0).padStart(9) + String(s.errores).padStart(9)
            + '  ' + JSON.stringify(s.status));
    }
    if (errores5xx > 0) {
        console.error(`\nERROR: ${errores5xx} respuestas 5xx o sin respuesta`);
        process.exit(1);
    }
}

main();
