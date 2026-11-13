#!/usr/bin/env node
// Cliente mínimo de la API REST de Mantis para el equipo (SCRUM-72).
// El token NO se pasa por argumento: se lee de MANTIS_TOKEN (token personal de Mantis →
// "Mi cuenta → Tokens de API"). URL por defecto: http://localhost:8990
//
//   node infra/mantis/incidencias.js crear  archivo.json           # crea una incidencia, imprime su id
//   node infra/mantis/incidencias.js asignar <id> <usuario> ["nota"]
//   node infra/mantis/incidencias.js resolver <id> "nota con PR y verificación"
//   node infra/mantis/incidencias.js cerrar <id> "nota con evidencia"
//   node infra/mantis/incidencias.js nota <id> "texto"
//   node infra/mantis/incidencias.js ver <id>                       # estado + historial
//   node infra/mantis/incidencias.js listar                         # incidencias del proyecto GymHub
//
// Formato de archivo.json para "crear":
//   { "summary": "...", "description": "...", "category": "Seguridad",
//     "severity": "crash", "priority": "immediate", "steps_to_reproduce": "...",
//     "additional_information": "Jira: SCRUM-81", "tags": ["SCRUM-81"] }
const fs = require('fs');

const BASE = (process.env.MANTIS_URL || 'http://localhost:8990').replace(/\/$/, '') + '/api/rest';
const TOKEN = process.env.MANTIS_TOKEN;
if (!TOKEN) { console.error('Definir MANTIS_TOKEN con un token de API de Mantis.'); process.exit(1); }

async function api(method, path, body) {
    const res = await fetch(BASE + path, {
        method,
        headers: { Authorization: TOKEN, 'Content-Type': 'application/json' },
        body: body ? JSON.stringify(body) : undefined,
    });
    const text = await res.text();
    if (!res.ok) throw new Error(`${method} ${path} → ${res.status} ${text.slice(0, 300)}`);
    return text ? JSON.parse(text) : {};
}

const nota = (id, text) => text ? api('POST', `/issues/${id}/notes`, { text, view_state: { name: 'public' } }) : null;

async function main() {
    const [cmd, a, b, c] = process.argv.slice(2);
    switch (cmd) {
        case 'crear': {
            const spec = JSON.parse(fs.readFileSync(a, 'utf8'));
            const body = {
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
            };
            const r = await api('POST', '/issues', body);
            console.log(r.issue.id);
            break;
        }
        case 'asignar': {
            await api('PATCH', `/issues/${a}`, { handler: { name: b }, status: { name: 'assigned' } });
            await nota(a, c);
            console.log(`#${a} asignada a ${b}`);
            break;
        }
        case 'resolver': {
            await api('PATCH', `/issues/${a}`, { status: { name: 'resolved' }, resolution: { name: 'fixed' } });
            await nota(a, b);
            console.log(`#${a} resuelta`);
            break;
        }
        case 'cerrar': {
            await nota(a, b);
            await api('PATCH', `/issues/${a}`, { status: { name: 'closed' } });
            console.log(`#${a} cerrada`);
            break;
        }
        case 'nota': { await nota(a, b); console.log(`nota agregada a #${a}`); break; }
        case 'ver': {
            const { issues: [i] } = await api('GET', `/issues/${a}`);
            console.log(`#${i.id} [${i.status.label}] ${i.summary} · ${i.category.name} · severidad ${i.severity.label} · prioridad ${i.priority.label} · responsable ${i.handler ? i.handler.name : '-'}`);
            for (const h of i.history || []) {
                const f = h.field ? h.field.label : h.type.name;
                console.log(`  ${h.created_at.slice(0, 16).replace('T', ' ')} ${h.user.name}: ${f}${h.old_value ? ' ' + (h.old_value.label || h.old_value.name || h.old_value) : ''}${h.new_value ? ' → ' + (h.new_value.label || h.new_value.name || h.new_value) : ''}`);
            }
            break;
        }
        case 'listar': {
            const { issues } = await api('GET', '/issues?page_size=100');
            for (const i of issues.sort((x, y) => x.id - y.id)) {
                console.log(`#${i.id}\t${i.status.label}\t${i.severity.label}\t${i.category.name}\t${i.summary}`);
            }
            break;
        }
        default:
            console.error('Comandos: crear | asignar | resolver | cerrar | nota | ver | listar');
            process.exit(1);
    }
}

main().catch((e) => { console.error(e.message); process.exit(1); });
