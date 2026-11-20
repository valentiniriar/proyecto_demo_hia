#!/usr/bin/env node
// Genera los flujos de PRODUCCIÓN de n8n (infra/n8n/workflows/0*.json) a partir de los flujos del
// equipo (carpeta originales/), conservando su lógica (validación, deduplicación, clasificación) y
// adaptando lo necesario para el servidor:
//   - credenciales por ID fijo (las crea infra/n8n/configurar.sh, cifradas; ningún secreto en los JSON)
//   - URLs internas de Docker (mantis, nextcloud, prometheus, analizador, mailpit) en lugar de localhost
//   - Error Workflow (00) asignado a todos los flujos
//   - flujo 2 sin "Execute Command" (n8n 2.x lo desactiva): lee /backups/latest_status.json en solo lectura
//   - flujo 3 nuevo: informe de rendimiento con el analizador Python, Nextcloud y aprobación humana
//
//   node infra/n8n/workflows/generar.js     (volver a correr si se cambian los originales)
const fs = require('fs');
const path = require('path');

const DIR = __dirname;
const ORIG = path.join(DIR, 'originales');
const leer = (f) => JSON.parse(fs.readFileSync(path.join(ORIG, f), 'utf8'));
const escribir = (f, wf) => fs.writeFileSync(path.join(DIR, f), JSON.stringify(wf, null, 2) + '\n');

// Links que se ven desde la tailnet (en los mails). IP de Tailscale del servidor (ver SCRUM-61).
const WEB = 'http://100.65.22.99';
const CRED = {
  alertas: { httpHeaderAuth: { id: 'gymhubAlertasWh1', name: 'Webhook Alertmanager (Bearer)' } },
  eventos: { httpHeaderAuth: { id: 'gymhubEventosSeg', name: 'GymHub - secreto de eventos de seguridad' } },
  mantis: { httpHeaderAuth: { id: 'gymhubMantisBot', name: 'Mantis - token n8n-bot' } },
  smtp: { smtp: { id: 'gymhubMailpit01', name: 'SMTP Mailpit (interno)' } },
  nextcloud: { httpBasicAuth: { id: 'gymhubNextcloud1', name: 'Nextcloud - n8n-bot (app password)' } },
};
const ID = {
  errores: 'GymHubErrores001', alertas: 'GymHubAlertas001', backups: 'GymHubBackups001',
  informe: 'GymHubInforme001', seguridad: 'GymHubSeguridad1',
};
const SETTINGS = { executionOrder: 'v1', saveDataSuccessExecution: 'all', saveDataErrorExecution: 'all',
  saveManualExecutions: true, errorWorkflow: ID.errores };
const DE = 'n8n@gymhub.local';
const PARA = 'equipo@gymhub.local';

let n = 0;
const nodo = (name, type, typeVersion, parameters, extra = {}) =>
  ({ id: `nodo-${++n}`, name, type: `n8n-nodes-base.${type}`, typeVersion, position: [n * 220, 300], parameters, ...extra });
const conectar = (pares) => {
  const c = {};
  for (const [desde, hacia, salida = 0] of pares) {
    c[desde] ??= { main: [] };
    while (c[desde].main.length <= salida) c[desde].main.push([]);
    c[desde].main[salida].push({ node: hacia, type: 'main', index: 0 });
  }
  return c;
};
const flujo = (id, name, nodes, connections, settings = SETTINGS) =>
  ({ id, name, active: false, nodes, connections, settings, pinData: {}, tags: [] });
const mail = (name, subject, html, extra = {}) =>
  nodo(name, 'emailSend', 2.1, { fromEmail: DE, toEmail: PARA, subject, emailFormat: 'html', html, options: {} },
    { credentials: CRED.smtp, ...extra });
const mantisPost = (name, jsonBody) => nodo(name, 'httpRequest', 4.2, {
  method: 'POST', url: 'http://mantis/api/rest/issues', authentication: 'genericCredentialType',
  genericAuthType: 'httpHeaderAuth', sendBody: true, specifyBody: 'json', jsonBody, options: { timeout: 15000 },
}, { credentials: CRED.mantis });

// ─────────────────────────────── 00 · Manejo de errores ───────────────────────────────
{
  n = 0;
  const o = leer('SCRUM-76-manejo-errores.json');
  const trig = o.nodes.find((x) => x.type.endsWith('errorTrigger'));
  const m = nodo('Avisar error al equipo', 'emailSend', 2.1, {
    fromEmail: DE, toEmail: PARA, subject: '=ERROR en n8n · {{ $json.workflow?.name || "flujo desconocido" }}',
    emailFormat: 'text',
    text: '=Falló un flujo de n8n de GymHub.\n\nFlujo: {{ $json.workflow?.name || "Desconocido" }}\n' +
      'Nodo: {{ $json.execution?.lastNodeExecuted || "No disponible" }}\n' +
      'Error: {{ $json.execution?.error?.message || $json.trigger?.error?.message || "Sin detalle" }}\n' +
      'Ejecución: {{ $json.execution?.url || "-" }}\n\nRevisar la ejecución en n8n (' + WEB + ':5679).',
    options: {},
  }, { credentials: CRED.smtp });
  escribir('00-manejo-errores.json', flujo(ID.errores, '00 · Manejo de errores (avisa por mail)',
    [{ ...trig, name: 'Error Trigger', position: [0, 300] }, m], conectar([['Error Trigger', m.name]]),
    { executionOrder: 'v1', saveDataSuccessExecution: 'all', saveDataErrorExecution: 'all' }));
}

// ─────────────────────── 01 · Alertas de Prometheus → Mantis (SCRUM-76) ───────────────────────
{
  n = 0;
  const o = leer('SCRUM-76-alertmanager-mantis.json');
  const by = (nm) => JSON.parse(JSON.stringify(o.nodes.find((x) => x.name === nm)));
  const wh = by('Webhook Alertmanager');
  wh.parameters.path = 'gymhub-alertas';
  wh.credentials = CRED.alertas;
  wh.webhookId = 'gymhub-alertas';
  const val = by('Validar y deduplicar');
  // Corrección: los saltos de línea iban escapados dos veces y Mantis mostraba "\n" literal.
  val.parameters.jsCode = val.parameters.jsCode.replace(/\\\\n/g, '\\n');
  const iff = by('Estado firing?');
  const crear = by('Crear incidencia Mantis');
  crear.credentials = CRED.mantis;
  crear.parameters.options = { timeout: 15000 };
  const guardar = by('Guardar ID de incidencia');
  guardar.parameters.jsCode = guardar.parameters.jsCode.replace('http://localhost:8990', `${WEB}:8990`);
  const nota = by('Agregar nota de resolucion');
  nota.credentials = CRED.mantis;
  nota.parameters.options = { timeout: 15000 };
  const resuelta = by('Marcar alerta resuelta');
  const m = mail('Avisar al responsable', '=[GymHub] Nueva incidencia #{{$json.issueId}} por alerta de monitoreo',
    by('Send an Email').parameters.html);
  const nodes = [wh, val, iff, crear, guardar, nota, resuelta, m].map((x, i) => ({ ...x, position: [i * 220, 300] }));
  escribir('01-alertas-a-mantis.json', flujo(ID.alertas, '01 · Alertas de Prometheus → incidencia en Mantis', nodes, conectar([
    [wh.name, val.name], [val.name, iff.name], [iff.name, crear.name, 0], [iff.name, nota.name, 1],
    [crear.name, guardar.name], [nota.name, resuelta.name], [guardar.name, m.name],
  ])));
}

// ─────────────────────────── 02 · Verificación de backups ───────────────────────────
{
  n = 0;
  const cron = nodo('Todos los días 04:00', 'scheduleTrigger', 1.2,
    { rule: { interval: [{ field: 'cronExpression', expression: '0 4 * * *' }] } });
  const manual = nodo('Ejecutar ahora (prueba)', 'manualTrigger', 1, {});
  // n8n 2.x desactiva "Execute Command": se lee el archivo con los nodos de archivos, que solo pueden
  // acceder a /backups (N8N_RESTRICT_FILE_ACCESS_TO), montado en solo lectura.
  const leerArch = nodo('Leer latest_status.json', 'readWriteFile', 1,
    { operation: 'read', fileSelector: '/backups/latest_status.json', options: {} },
    { onError: 'continueRegularOutput', alwaysOutputData: true });
  const extraer = nodo('Extraer JSON', 'extractFromFile', 1,
    { operation: 'fromJson', binaryPropertyName: 'data', options: {} },
    { onError: 'continueRegularOutput', alwaysOutputData: true });
  const validar = nodo('Validar antigüedad y estado', 'code', 2, { jsCode: [
    "// Valida el estado que escribe database/backup/backup.sh. Sin archivo o JSON ilegible = fallo.",
    "const s = $json.data && typeof $json.data === 'object' ? $json.data : {};",
    "const status = s.status || ($json.error ? 'not_found' : 'unknown');",
    "const ts = s.timestamp ? new Date(s.timestamp) : null;",
    "const horas = ts && !isNaN(ts) ? (Date.now() - ts.getTime()) / 3600000 : 999;",
    "const problemas = [];",
    "if (status !== 'success') problemas.push(`estado \"${status}\"`);",
    "if (horas >= 26) problemas.push(`último backup hace ${Math.round(horas)} h (máximo 26 h)`);",
    "if (status === 'success' && (!s.size || /^0(\\.0)?[A-Z]?$/.test(String(s.size)))) problemas.push('archivo vacío');",
    "return [{ json: { valido: problemas.length === 0, problemas: problemas.join('; '), status,",
    "  archivo: s.filename || 'ninguno', tamanio: s.size || '0', duracion_s: s.duration_seconds ?? null,",
    "  horas: Math.round(horas), timestamp: s.timestamp || 'N/A' } }];",
  ].join('\n') });
  const iff = nodo('¿Backup válido?', 'if', 1, { conditions: { boolean: [{ value1: '={{ $json.valido }}', value2: true }] } });
  const ok = nodo('Registrar OK', 'code', 2, { jsCode:
    "return [{ json: { resultado: 'BACKUP OK', ...$input.first().json } }];" });
  // Corrección: el original mandaba category/severity como texto y sin proyecto: Mantis lo rechazaba.
  const inc = mantisPost('Crear incidencia en Mantis', '={{ JSON.stringify({\n' +
    "  project: { name: 'GymHub' }, category: { name: 'Base de datos' },\n" +
    "  severity: { name: 'major' }, priority: { name: 'high' }, reproducibility: { name: 'have not tried' },\n" +
    "  summary: '[n8n] Falló la verificación del backup diario de producción',\n" +
    "  description: 'El flujo 2 de n8n detectó un problema con el backup de las 03:00.\\n\\nProblemas: ' + $json.problemas +\n" +
    "    '\\nEstado: ' + $json.status + '\\nArchivo: ' + $json.archivo + '\\nTamaño: ' + $json.tamanio +\n" +
    "    '\\nFecha del último backup: ' + $json.timestamp,\n" +
    "  additional_information: 'Revisar: docker logs gymhub_backup_prod y /backups/backup.log. Restaurar: database/backup/restore.sh',\n" +
    "  tags: [{ name: 'backup' }, { name: 'n8n' }]\n}) }}");
  const m = mail('Avisar al responsable', '=[GymHub] Backup diario con problemas · incidencia #{{$json.issue.id}}',
    '=<h2>Backup diario: verificación fallida</h2><p><b>Problemas:</b> {{ $("Validar antigüedad y estado").item.json.problemas }}</p>' +
    `<p>Se abrió la incidencia <a href="${WEB}:8990/view.php?id={{$json.issue.id}}">#{{$json.issue.id}}</a> en Mantis.</p>` +
    '<p>Notificación automática del flujo 2 de n8n.</p>');
  const nodes = [cron, manual, leerArch, extraer, validar, iff, ok, inc, m];
  escribir('02-verificacion-backups.json', flujo(ID.backups, '02 · Verificación del backup diario', nodes, conectar([
    [cron.name, leerArch.name], [manual.name, leerArch.name], [leerArch.name, extraer.name], [extraer.name, validar.name],
    [validar.name, iff.name], [iff.name, ok.name, 0], [iff.name, inc.name, 1], [inc.name, m.name],
  ])));
}

// ─────────────────── 03 · Informe de rendimiento (analizador Python + Nextcloud) ───────────────────
{
  n = 0;
  const cron = nodo('Todos los días 08:00', 'scheduleTrigger', 1.2,
    { rule: { interval: [{ field: 'cronExpression', expression: '0 8 * * *' }] } });
  const manual = nodo('Ejecutar ahora (prueba)', 'manualTrigger', 1, {});
  const metricas = nodo('Definir métricas (24 h)', 'code', 2, { jsCode: [
    "// Qué se mide. Umbrales alineados con las alertas de infra/monitoring/prometheus/alerts.",
    "const fin = Math.floor(Date.now() / 1000), inicio = fin - 24 * 3600;",
    "const m = [",
    "  { nombre: 'Disponibilidad del backend', unidad: '', umbral_bajo: 1, promql: 'min(probe_success{job=\"blackbox-local-health\",instance=~\".*backend.*\"})' },",
    "  { nombre: 'Disponibilidad del frontend', unidad: '', umbral_bajo: 1, promql: 'min(probe_success{job=\"blackbox-local-health\",instance=~\".*frontend.*\"})' },",
    "  { nombre: 'Latencia de /api/health', unidad: 's', umbral_alto: 0.5, promql: 'max(probe_duration_seconds{job=\"blackbox-local-health\"})' },",
    "  { nombre: 'CPU de los contenedores GymHub', unidad: 'núcleos', umbral_alto: 6, promql: 'sum(rate(container_cpu_usage_seconds_total{name=~\"gymhub.*\"}[5m]))' },",
    "  { nombre: 'Memoria de los contenedores GymHub', unidad: 'bytes', umbral_alto: 10 * 1024 ** 3, promql: 'sum(container_memory_working_set_bytes{name=~\"gymhub.*\"})' },",
    "  { nombre: 'Conexiones a PostgreSQL (líder)', unidad: '', umbral_alto: 80, promql: 'sum(pg_stat_activity_count)' },",
    "  { nombre: 'Réplicas de Patroni en streaming', unidad: '', umbral_bajo: 2, promql: 'sum(patroni_postgres_streaming)' },",
    "];",
    "return m.map((x) => ({ json: { ...x, inicio, fin, paso: 300 } }));",
  ].join('\n') });
  const prom = nodo('Consultar Prometheus', 'httpRequest', 4.2, {
    url: 'http://prometheus:9090/api/v1/query_range', sendQuery: true,
    queryParameters: { parameters: [
      { name: 'query', value: '={{ $json.promql }}' }, { name: 'start', value: '={{ $json.inicio }}' },
      { name: 'end', value: '={{ $json.fin }}' }, { name: 'step', value: '={{ $json.paso }}' },
    ] }, options: { timeout: 20000 },
  });
  const series = nodo('Armar series', 'code', 2, { jsCode: [
    "// Valida las respuestas de Prometheus y arma el pedido para el analizador.",
    "const defs = $('Definir métricas (24 h)').all().map((i) => i.json);",
    "const resp = $input.all().map((i) => i.json);",
    "if (resp.length !== defs.length) throw new Error(`Prometheus devolvió ${resp.length} respuestas para ${defs.length} métricas`);",
    "const series = defs.map((d, i) => {",
    "  const r = resp[i];",
    "  if (r.status !== 'success') throw new Error(`Prometheus: consulta fallida para \"${d.nombre}\"`);",
    "  const valores = (r.data?.result?.[0]?.values || []).filter((v) => Array.isArray(v) && v.length === 2);",
    "  return { nombre: d.nombre, unidad: d.unidad, umbral_alto: d.umbral_alto ?? null, umbral_bajo: d.umbral_bajo ?? null, valores };",
    "});",
    "const iso = (t) => new Date(t * 1000).toISOString().slice(0, 16).replace('T', ' ') + ' UTC';",
    "return [{ json: { desde: iso(defs[0].inicio), hasta: iso(defs[0].fin), series } }];",
  ].join('\n') });
  const analizar = nodo('Analizar anomalías (Python)', 'httpRequest', 4.2, {
    method: 'POST', url: 'http://analizador:8000/analizar', sendBody: true, specifyBody: 'json',
    jsonBody: '={{ JSON.stringify($json) }}', options: { timeout: 20000 },
  });
  const preparar = nodo('Preparar informe', 'code', 2, { jsCode: [
    "const r = $json;",
    "if (typeof r.markdown !== 'string' || !r.estado_general) throw new Error('El analizador devolvió una respuesta inválida');",
    "const ahora = new Date(new Date().toLocaleString('en-US', { timeZone: 'America/Argentina/Jujuy' }));",
    "const p = (x) => String(x).padStart(2, '0');",
    "const archivo = `informe-rendimiento-${ahora.getFullYear()}-${p(ahora.getMonth() + 1)}-${p(ahora.getDate())}-${p(ahora.getHours())}${p(ahora.getMinutes())}.md`;",
    "const resumen = r.series.map((s) => `<li>${s.nombre}: <b>${s.severidad}</b>${s.hallazgos.length ? ' — ' + s.hallazgos[0] : ''}</li>`).join('');",
    "return [{ json: { archivo, markdown: r.markdown, estado: r.estado_general, hallazgos: r.hallazgos, resumen } }];",
  ].join('\n') });
  const subir = nodo('Guardar en Nextcloud (Informes-IA)', 'httpRequest', 4.2, {
    method: 'PUT', url: '=http://nextcloud/remote.php/dav/files/n8n-bot/Informes-IA/{{ $json.archivo }}',
    authentication: 'genericCredentialType', genericAuthType: 'httpBasicAuth', sendBody: true, contentType: 'raw',
    rawContentType: 'text/markdown; charset=utf-8', body: '={{ $json.markdown }}', options: { timeout: 20000 },
  }, { credentials: CRED.nextcloud });
  const avisar = mail('Avisar al equipo', '=[GymHub] Informe de rendimiento · {{ $("Preparar informe").item.json.estado.toUpperCase() }}',
    '=<h2>Informe de rendimiento de GymHub</h2><p>Estado general: <b>{{ $("Preparar informe").item.json.estado }}</b> · ' +
    'hallazgos: {{ $("Preparar informe").item.json.hallazgos }}</p><ul>{{ $("Preparar informe").item.json.resumen }}</ul>' +
    `<p>Informe completo en Nextcloud: <a href="${WEB}:8082/apps/files/?dir=/Informes-IA">Informes-IA/{{ $("Preparar informe").item.json.archivo }}</a></p>` +
    '<p>Generado por el flujo 3 de n8n con el analizador Python.</p>');
  const critico = nodo('¿Estado crítico?', 'if', 1, { conditions: { string: [
    { value1: '={{ $("Preparar informe").item.json.estado }}', value2: 'critico' }] } });
  const fin = nodo('Sin acción (estado no crítico)', 'noOp', 1, {});
  // Aprobación humana: la acción "crítica" (escalar como incidencia) solo se ejecuta si una persona la
  // aprueba desde el link del mail. Si nadie responde en 24 h, no se hace nada.
  const pedir = mail('Pedir aprobación', '=[GymHub] ¿Escalar el informe crítico como incidencia?',
    '=<h2>El informe de rendimiento salió CRÍTICO</h2><ul>{{ $("Preparar informe").item.json.resumen }}</ul>' +
    '<p>¿Abrir una incidencia de rendimiento en Mantis y asignarla?</p>' +
    '<p><a href="{{ $execution.resumeUrl }}?decision=aprobar">✅ Aprobar</a> &nbsp; · &nbsp; ' +
    '<a href="{{ $execution.resumeUrl }}?decision=rechazar">❌ Rechazar</a></p><p>El pedido vence en 24 horas.</p>');
  const esperar = nodo('Esperar decisión (24 h)', 'wait', 1.1, {
    resume: 'webhook', httpMethod: 'GET', limitWaitTime: true, limitType: 'afterTimeInterval',
    resumeAmount: 24, resumeUnit: 'hours', options: {},
  }, { webhookId: 'gymhub-aprobacion-informe' });
  const aprobado = nodo('¿Aprobado?', 'if', 1, { conditions: { string: [
    { value1: '={{ $json.query?.decision || "vencido" }}', value2: 'aprobar' }] } });
  const inc = mantisPost('Abrir incidencia de rendimiento', '={{ JSON.stringify({\n' +
    "  project: { name: 'GymHub' }, category: { name: 'Rendimiento' }, severity: { name: 'major' },\n" +
    "  priority: { name: 'high' }, reproducibility: { name: 'have not tried' },\n" +
    "  summary: '[n8n] Informe de rendimiento CRÍTICO: ' + $('Preparar informe').item.json.archivo,\n" +
    "  description: $('Preparar informe').item.json.markdown.slice(0, 8000),\n" +
    "  additional_information: 'Escalada con aprobación humana desde el flujo 3 de n8n. Informe en Nextcloud: Informes-IA/' + $('Preparar informe').item.json.archivo,\n" +
    "  tags: [{ name: 'rendimiento' }, { name: 'n8n' }]\n}) }}");
  const rech = nodo('Registrar rechazo o vencimiento', 'code', 2, { jsCode:
    "return [{ json: { resultado: 'NO ESCALADO', decision: $json.query?.decision || 'vencido (24 h sin respuesta)' } }];" });
  const nodes = [cron, manual, metricas, prom, series, analizar, preparar, subir, avisar, critico, fin, pedir, esperar, aprobado, inc, rech];
  escribir('03-informe-rendimiento.json', flujo(ID.informe, '03 · Informe de rendimiento (analizador Python → Nextcloud)', nodes, conectar([
    [cron.name, metricas.name], [manual.name, metricas.name], [metricas.name, prom.name], [prom.name, series.name],
    [series.name, analizar.name], [analizar.name, preparar.name], [preparar.name, subir.name], [subir.name, avisar.name],
    [avisar.name, critico.name], [critico.name, pedir.name, 0], [critico.name, fin.name, 1], [pedir.name, esperar.name],
    [esperar.name, aprobado.name], [aprobado.name, inc.name, 0], [aprobado.name, rech.name, 1],
  ])));
}

// ─────────────────────── 04 · Eventos de seguridad del backend (SCRUM-84) ───────────────────────
{
  n = 0;
  const o = leer('flujo-4-eventos-seguridad.json');
  const nodes = JSON.parse(JSON.stringify(o.nodes));
  const wh = nodes.find((x) => x.type.endsWith('webhook'));
  wh.credentials = CRED.eventos;
  wh.webhookId = 'gymhub-seguridad';
  const cls = nodes.find((x) => x.name === 'Clasificar y deduplicar');
  // Validación de datos recibidos (requisito de seguridad del TP): tipo conocido e IP con formato válido.
  cls.parameters.jsCode = [
    "// Validación del evento recibido antes de clasificarlo.",
    "{",
    "  const b = $input.first().json.body;",
    "  if (!b || typeof b !== 'object') throw new Error('Evento sin cuerpo JSON');",
    "  if (!['login_fallido', 'rate_limit', 'login_admin'].includes(b.tipo)) throw new Error(`Tipo de evento desconocido: ${String(b.tipo).slice(0, 40)}`);",
    "  if (b.ip && !/^[0-9a-fA-F:.]{2,45}$/.test(String(b.ip))) throw new Error('IP con formato inválido');",
    "}",
    cls.parameters.jsCode,
  ].join('\n');
  const inc = nodes.find((x) => x.name === 'Crear incidencia en Mantis');
  inc.parameters.url = 'http://mantis/api/rest/issues';
  inc.credentials = CRED.mantis;
  escribir('04-eventos-seguridad.json', flujo(ID.seguridad, '04 · Eventos de seguridad del backend → Mantis', nodes, o.connections));
}

console.log('Flujos generados en', DIR);
