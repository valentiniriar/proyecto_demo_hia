#!/usr/bin/env node
// Carga el registro de incidencias del proyecto (infra/mantis/registro-incidencias.json) en una
// instancia de Mantis: crea cada incidencia, la asigna a su responsable, la resuelve con el PR y la
// verificación, y la cierra (o la deja asignada si sigue abierta). Idempotente: si ya existe una
// incidencia con el mismo resumen, la saltea.
//
//   MANTIS_URL=http://localhost:8990 MANTIS_TOKEN=<token de un administrador> \
//     node infra/mantis/cargar-registro.js [--simular]
//
// El token NO va por argumento. Las acciones quedan registradas a nombre del dueño del token; cada nota
// aclara el responsable original y que el historial completo está en docs/evidencias/SCRUM-72/.
const fs = require('fs');
const path = require('path');

const RAIZ = path.resolve(__dirname, '..', '..');
const BASE = (process.env.MANTIS_URL || 'http://localhost:8990').replace(/\/$/, '') + '/api/rest';
const TOKEN = process.env.MANTIS_TOKEN;
const SIMULAR = process.argv.includes('--simular');
if (!TOKEN && !SIMULAR) { console.error('Definir MANTIS_TOKEN con un token de API de un administrador de Mantis.'); process.exit(1); }

async function api(method, ruta, body) {
    const res = await fetch(BASE + ruta, {
        method,
        headers: { Authorization: TOKEN, 'Content-Type': 'application/json' },
        body: body ? JSON.stringify(body) : undefined,
    });
    const text = await res.text();
    if (!res.ok) throw new Error(`${method} ${ruta} → ${res.status} ${text.slice(0, 300)}`);
    return text ? JSON.parse(text) : {};
}
const nota = (id, text) => api('POST', `/issues/${id}/notes`, { text, view_state: { name: 'public' } });

async function main() {
    const registro = JSON.parse(fs.readFileSync(path.join(__dirname, 'registro-incidencias.json'), 'utf8'));
    const existentes = SIMULAR ? [] : (await api('GET', '/issues?page_size=200')).issues || [];
    const porResumen = new Map(existentes.map((i) => [i.summary, i.id]));
    let creadas = 0;

    for (const inc of registro.incidencias) {
        const spec = JSON.parse(fs.readFileSync(path.join(RAIZ, inc.archivo), 'utf8'));
        if (porResumen.has(spec.summary)) {
            console.log(`= #${porResumen.get(spec.summary)} ya existe: ${spec.summary.slice(0, 70)}`);
            continue;
        }
        const prs = inc.pr.map((n) => `#${n} (${registro.repo}/pull/${n})`).join(', ');
        if (SIMULAR) { console.log(`+ [${inc.estado}] ${inc.responsable} · ${spec.category} · ${spec.summary.slice(0, 70)}`); continue; }

        const { issue } = await api('POST', '/issues', {
            summary: spec.summary,
            description: spec.description,
            steps_to_reproduce: spec.steps_to_reproduce,
            additional_information: spec.additional_information,
            project: { name: spec.project || 'GymHub' },
            category: { name: spec.category },
            severity: { name: spec.severity || 'minor' },
            priority: { name: spec.priority || 'normal' },
            reproducibility: { name: spec.reproducibility || 'always' },
            tags: (spec.tags || []).map((name) => ({ name })),
        });
        const id = issue.id;
        await api('PATCH', `/issues/${id}`, { handler: { name: inc.responsable }, status: { name: 'assigned' } });
        await nota(id, `Asignada a ${inc.responsable}. Registro original del equipo: ${inc.archivo} (historial en docs/evidencias/SCRUM-72/historial-mantis.txt).`);
        if (inc.estado === 'cerrada') {
            await api('PATCH', `/issues/${id}`, { status: { name: 'resolved' }, resolution: { name: 'fixed' } });
            await nota(id, `Resuelta en ${prs}.`);
            await nota(id, `Verificación: ${inc.verificacion}`);
            await api('PATCH', `/issues/${id}`, { status: { name: 'closed' } });
        } else {
            await nota(id, inc.verificacion);
        }
        creadas++;
        console.log(`+ #${id} [${inc.estado}] ${inc.responsable} · ${spec.summary.slice(0, 70)}`);
    }
    console.log(`Listo: ${creadas} creadas, ${registro.incidencias.length - creadas} ya existían o simuladas.`);
}

main().catch((e) => { console.error(e.message); process.exit(1); });
