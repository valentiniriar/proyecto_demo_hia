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
  diagnostico: { httpBasicAuth: { id: 'gymhubDiagnost01', name: 'Diagnóstico - usuario y clave de la página' } },
};
const ID = {
  errores: 'GymHubErrores001', alertas: 'GymHubAlertas001', backups: 'GymHubBackups001',
  informe: 'GymHubInforme001', seguridad: 'GymHubSeguridad1', diagnostico: 'GymHubDiagnost1',
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
  // Diagnóstico automático con el manual de Nextcloud (flujo 05 como subflujo). Si falla, el aviso sale igual.
  const diag = nodo('Diagnosticar con el manual (flujo 05)', 'executeWorkflow', 1.2, {
    source: 'database', workflowId: { __rl: true, value: ID.diagnostico, mode: 'id' },
    options: { waitForSubWorkflow: true },
  }, { onError: 'continueRegularOutput', alwaysOutputData: true });
  const G = '$("Guardar ID de incidencia").item.json';
  const m = mail('Avisar al responsable', `=[GymHub] Nueva incidencia #{{${G}.issueId}} por alerta de monitoreo{{ $json.codigo ? " · " + $json.codigo : "" }}`,
    '=<h2>Alerta de monitoreo - GymHub</h2><p>Se creó una nueva incidencia en Mantis.</p>' +
    `<p><strong>ID:</strong> #{{${G}.issueId}} · <a href="{{${G}.link}}">Ver incidencia en Mantis</a></p>` +
    '{{ $json.codigo ? "<h3>Diagnóstico (" + $json.codigo + " · " + $json.titulo + ")</h3><p>" + $json.conclusion_html + "</p>" +' +
    ` "<p>Diagnóstico completo en Nextcloud: <a href=\\"${WEB}:8082/apps/files/?dir=/Diagnosticos\\">Diagnosticos/" + $json.archivo + "</a></p>"` +
    ' : "<p>No se pudo generar el diagnóstico automático: pedirlo con el número de incidencia en el flujo 05.</p>" }}' +
    '<p>Notificación automática generada por n8n.</p>');
  const nodes = [wh, val, iff, crear, guardar, diag, nota, resuelta, m].map((x, i) => ({ ...x, position: [i * 220, 300] }));
  escribir('01-alertas-a-mantis.json', flujo(ID.alertas, '01 · Alertas de Prometheus → incidencia en Mantis', nodes, conectar([
    [wh.name, val.name], [val.name, iff.name], [iff.name, crear.name, 0], [iff.name, nota.name, 1],
    [crear.name, guardar.name], [nota.name, resuelta.name], [guardar.name, diag.name], [diag.name, m.name],
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
    // resumeUrl ya trae "?signature=…": la decisión va con "&". Con "?" quedaba pegada a la firma y n8n
    // respondía 401 "Invalid token" (encontrado en la prueba de producción del 20/11/2026).
    '<p><a href="{{ $execution.resumeUrl + ($execution.resumeUrl.includes("?") ? "&" : "?") }}decision=aprobar">✅ Aprobar</a> &nbsp; · &nbsp; ' +
    '<a href="{{ $execution.resumeUrl + ($execution.resumeUrl.includes("?") ? "&" : "?") }}decision=rechazar">❌ Rechazar</a></p><p>El pedido vence en 24 horas.</p>');
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
  // Deduplicación contra Mantis (fuente de verdad). La de staticData no alcanza con eventos simultáneos:
  // n8n carga la memoria del flujo al RECIBIR el webhook, así que 6 avisos en paralelo abrían 6 incidencias
  // (20/11/2026). Con N8N_CONCURRENCY_PRODUCTION_LIMIT=1 las ejecuciones van en fila y cada una ve en Mantis
  // lo que creó la anterior.
  const buscar = nodo('Buscar incidencias recientes en Mantis', 'httpRequest', 4.2, {
    url: 'http://mantis/api/rest/issues?page_size=50', authentication: 'genericCredentialType',
    genericAuthType: 'httpHeaderAuth', options: { timeout: 15000 },
  }, { credentials: CRED.mantis, position: [880, 160] });
  const marcar = nodo('¿Ya hay una abierta?', 'code', 2, { jsCode: [
    "const inc = $('Clasificar y deduplicar').item.json;",
    "const resumen = '[n8n] ' + inc.incidencia.resumen;",
    "const hace1h = Date.now() - 3600 * 1000;",
    "const previa = ($json.issues || []).find((i) => i.summary === resumen && i.status?.name !== 'closed'",
    "  && Date.parse(i.created_at) > hace1h);",
    "return [{ json: { ...inc, duplicada: Boolean(previa), previa: previa ? previa.id : null } }];",
  ].join('\n') }, { position: [1100, 160] });
  const iffDup = nodo('¿Duplicada?', 'if', 1, { conditions: { boolean: [{ value1: '={{ $json.duplicada }}', value2: true }] } },
    { position: [1320, 160] });
  const dup = nodo('Duplicada (ya está en Mantis)', 'noOp', 1, {}, { position: [1540, 60] });
  inc.position = [1540, 260];
  nodes.push(buscar, marcar, iffDup, dup);
  const conn = JSON.parse(JSON.stringify(o.connections));
  const si = conn['¿Abrir incidencia?'].main[0];
  si.splice(0, si.length, { node: buscar.name, type: 'main', index: 0 });
  Object.assign(conn, conectar([[buscar.name, marcar.name], [marcar.name, iffDup.name],
    [iffDup.name, dup.name, 0], [iffDup.name, inc.name, 1]]));
  // El body de "Crear incidencia" usa $json.incidencia y $json.evento: "¿Ya hay una abierta?" los conserva.
  escribir('04-eventos-seguridad.json', flujo(ID.seguridad, '04 · Eventos de seguridad del backend → Mantis', nodes, conn));
}

// ───────────── 05 · Diagnóstico con el manual de errores (Nextcloud) a partir del ID del error ─────────────
// Se le pasa el código del manual (GH-DB-001) o el número de incidencia de Mantis. Lee el manual desde
// Nextcloud (Manual-Operaciones/manual-errores.json, n8n solo tiene lectura), consulta el estado ACTUAL en
// Prometheus, arma el diagnóstico, lo guarda en Nextcloud (Diagnosticos/) y lo agrega como nota en Mantis.
//   - Desde el navegador (tailnet): http://100.65.22.99:5679/webhook/gymhub-diagnostico?id=41  (usuario y clave)
//   - Automático: el flujo 01 lo llama como subflujo con cada incidencia nueva.
// Los nodos Code se escriben como funciones normales (se valida su sintaxis acá) y se guarda solo el cuerpo.
const cuerpo = (f) => { const s = f.toString(); return s.slice(s.indexOf('{') + 1, s.lastIndexOf('}')).trim() + '\n'; };
/* eslint-disable no-undef */
const PAGINA_CSS = 'body{font-family:system-ui,Segoe UI,sans-serif;max-width:860px;margin:24px auto;padding:0 16px;' +
  'color:#1d2330;background:#f6f7f9;line-height:1.5}h1{font-size:1.5rem}h2{font-size:1.15rem;margin-top:1.6em}' +
  '.caja{background:#fff;border:1px solid #dde1e7;border-radius:10px;padding:16px 20px;margin:12px 0}' +
  '.estado{font-weight:700;padding:10px 14px;border-radius:8px}.ok{background:#e3f6e8;color:#13612e}' +
  '.deg{background:#fff4dc;color:#7a4b00}.mal{background:#fde4e4;color:#8a1414}.gris{background:#eceff3}' +
  'code{background:#eef1f5;padding:1px 5px;border-radius:4px;font-size:.92em;word-break:break-word}' +
  'table{border-collapse:collapse;width:100%}td{border-bottom:1px solid #eceff3;padding:6px 4px;vertical-align:top}' +
  'input{font-size:1rem;padding:8px 10px;border:1px solid #c5cbd3;border-radius:6px;width:220px}' +
  'button{font-size:1rem;padding:8px 16px;border:0;border-radius:6px;background:#2357d9;color:#fff;cursor:pointer}' +
  'small{color:#5b6472}';
{
  n = 0;
  const wh = nodo('Página de diagnóstico (GET ?id=)', 'webhook', 2, {
    httpMethod: 'GET', path: 'gymhub-diagnostico', authentication: 'basicAuth', responseMode: 'responseNode', options: {},
  }, { webhookId: 'gymhub-diagnostico', credentials: CRED.diagnostico });
  const sub = nodo('Llamado desde el flujo 01', 'executeWorkflowTrigger', 1.1, { inputSource: 'passthrough' });
  const norm = nodo('Normalizar ID', 'code', 2, { jsCode: cuerpo(function () {
    // Validación de la entrada: número de incidencia de Mantis o código del manual. Nada más.
    const j = $input.first().json;
    const desdeWeb = Boolean(j.query || j.headers);
    const crudo = String((j.query && j.query.id) ?? j.issueId ?? j.id ?? '').trim().replace(/^#/, '').slice(0, 40);
    let tipo;
    if (!crudo) tipo = 'formulario';
    else if (/^\d{1,7}$/.test(crudo)) tipo = 'mantis';
    else if (/^GH-[A-Z]{2,4}-\d{3}$/i.test(crudo)) tipo = 'codigo';
    else tipo = 'invalido';
    if (!desdeWeb && tipo !== 'mantis' && tipo !== 'codigo') throw new Error('Diagnóstico: el flujo 01 no pasó un ID de incidencia válido');
    return [{ json: { id: tipo === 'codigo' ? crudo.toUpperCase() : crudo, tipo, origen: desdeWeb ? 'web' : 'flujo01' } }];
  }) });
  const iffForm = nodo('¿Mostrar el formulario?', 'if', 1, { conditions: { boolean: [
    { value1: '={{ ["formulario", "invalido"].includes($json.tipo) }}', value2: true }] } });
  const form = nodo('Armar formulario', 'code', 2, { jsCode: `const CSS = ${JSON.stringify(PAGINA_CSS)};\n` + cuerpo(function () {
    const j = $input.first().json;
    const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    const error = j.tipo === 'invalido'
      ? `<p class="estado mal">"${esc(j.id)}" no es un ID válido. Usá el número de incidencia de Mantis (por ejemplo 41) o un código del manual (por ejemplo GH-DB-001).</p>` : '';
    const html = `<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">` +
      `<title>Diagnóstico GymHub</title><style>${CSS}</style></head><body><h1>Diagnóstico de errores · GymHub</h1>${error}` +
      '<div class="caja"><form method="get"><p>ID del error: número de incidencia de Mantis o código del manual.</p>' +
      '<input name="id" placeholder="41 o GH-DB-001" autofocus required> <button>Diagnosticar</button></form></div>' +
      '<p><small>n8n lee el manual de errores desde Nextcloud (Manual-Operaciones), consulta el estado actual en Prometheus ' +
      'y guarda el diagnóstico en Nextcloud (Diagnosticos).</small></p></body></html>';
    return [{ json: { html } }];
  }) });
  const respForm = nodo('Responder formulario', 'respondToWebhook', 1.1, {
    respondWith: 'text', responseBody: '={{ $json.html }}',
    options: { responseCode: 200, responseHeaders: { entries: [{ name: 'Content-Type', value: 'text/html; charset=utf-8' }] } },
  });
  const leerManual = nodo('Leer manual (Nextcloud)', 'httpRequest', 4.2, {
    url: 'http://nextcloud/remote.php/dav/files/n8n-bot/Manual-Operaciones/manual-errores.json',
    authentication: 'genericCredentialType', genericAuthType: 'httpBasicAuth',
    options: { timeout: 15000, response: { response: { responseFormat: 'json' } } },
  }, { credentials: CRED.nextcloud });
  const iffMantis = nodo('¿Es una incidencia de Mantis?', 'if', 1, { conditions: { boolean: [
    { value1: '={{ $("Normalizar ID").first().json.tipo === "mantis" }}', value2: true }] } });
  const leerInc = nodo('Leer incidencia en Mantis', 'httpRequest', 4.2, {
    url: '=http://mantis/api/rest/issues/{{ $("Normalizar ID").first().json.id }}',
    authentication: 'genericCredentialType', genericAuthType: 'httpHeaderAuth', options: { timeout: 15000 },
  }, { credentials: CRED.mantis, onError: 'continueRegularOutput', alwaysOutputData: true });
  const buscar = nodo('Buscar el error en el manual', 'code', 2, { jsCode: cuerpo(function () {
    const pedido = $('Normalizar ID').first().json;
    let manual = $('Leer manual (Nextcloud)').first().json;
    if (typeof manual.data === 'string') manual = JSON.parse(manual.data);
    if (!manual || !Array.isArray(manual.errores) || !manual.consultas) throw new Error('El manual de Nextcloud no tiene el formato esperado (errores / consultas)');
    let incidencia = null, alerta = null, instancia = null, aviso = null;
    if (pedido.tipo === 'mantis') {
      const r = $input.first().json;
      incidencia = r && Array.isArray(r.issues) && r.issues[0] ? r.issues[0] : null;
      if (!incidencia) aviso = `La incidencia #${pedido.id} no existe en Mantis o no se pudo leer.`;
      else {
        const m = /^\[Prometheus\]\s+(\S+)\s+-\s+(.*)$/.exec(incidencia.summary || '');
        if (m) { alerta = m[1]; instancia = m[2]; }
      }
    }
    let entrada = null;
    if (pedido.tipo === 'codigo') entrada = manual.errores.find((e) => e.codigo === pedido.id) || null;
    else if (alerta) entrada = manual.errores.find((e) => e.alerta === alerta) || null;
    else if (incidencia) entrada = manual.errores.find((e) => e.patron && new RegExp(e.patron, 'i').test(incidencia.summary || '')) || null;
    if (!entrada && !aviso) aviso = pedido.tipo === 'codigo' ? `El código ${pedido.id} no está en el manual.`
      : `La incidencia #${pedido.id} no corresponde a ningún error del manual${alerta ? ` (alerta ${alerta})` : ''}.`;
    const claves = entrada ? entrada.consultas : ['lider', 'api'];
    const consultas = claves.filter((k) => manual.consultas[k]).map((k) => ({ clave: k, ...manual.consultas[k] }));
    if (entrada && entrada.alerta) consultas.push({ clave: 'alerta_activa', nombre: `¿Sigue activa la alerta ${entrada.alerta}?`,
      promql: `ALERTS{alertstate="firing",alertname="${entrada.alerta}"}`, tipo: 'lista' });
    const contexto = { pedido, entrada, aviso, manual_version: manual.version, alerta, instancia,
      incidencia: incidencia ? { id: incidencia.id, resumen: incidencia.summary, estado: incidencia.status && incidencia.status.name, creada: incidencia.created_at } : null,
      codigos: manual.errores.map((e) => `${e.codigo} · ${e.titulo}`) };
    return consultas.map((c, i) => ({ json: { ...c, contexto: i === 0 ? contexto : undefined } }));
  }) });
  const prom = nodo('Estado actual (Prometheus)', 'httpRequest', 4.2, {
    url: 'http://prometheus:9090/api/v1/query', sendQuery: true,
    queryParameters: { parameters: [{ name: 'query', value: '={{ $json.promql }}' }] }, options: { timeout: 15000 },
  }, { onError: 'continueRegularOutput', alwaysOutputData: true });
  const armar = nodo('Armar diagnóstico', 'code', 2, { jsCode: `const CSS = ${JSON.stringify(PAGINA_CSS)};\nconst WEB = ${JSON.stringify(WEB)};\n` + cuerpo(function () {
    const items = $('Buscar el error en el manual').all().map((i) => i.json);
    const resp = $input.all().map((i) => i.json);
    const ctx = items[0].contexto;
    const e = ctx.entrada;
    const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    const fmt = (v, u) => {
      if (v == null || Number.isNaN(v)) return '-';
      if (u === 'ok') return v >= 1 ? 'OK' : 'FALLA';
      if (u === 'bytes') return v < 1024 ? `${Math.round(v)} B` : v < 1048576 ? `${(v / 1024).toFixed(1)} KB` : `${(v / 1048576).toFixed(1)} MB`;
      if (u === '%') return `${v.toFixed(1)} %`;
      if (u === 's') return `${v.toFixed(2)} s`;
      return Number.isInteger(v) ? String(v) : v.toFixed(2);
    };
    const quien = (m) => String(m.name || m.alertname || m.instance || m.job || 'total').replace(/:8008$/, '');
    // 1. Estado actual, consulta por consulta.
    const vivo = {};
    const filas = items.map((c, i) => {
      const r = resp[i] || {};
      if (r.status !== 'success') { vivo[c.clave] = undefined; return [c.nombre, 'sin datos (Prometheus no respondió)']; }
      const res = (r.data && r.data.result) || [];
      if (c.tipo === 'valor') {
        const v = res.length ? Number(res[0].value[1]) : null;
        vivo[c.clave] = v;
        return [c.nombre, v == null ? 'sin datos' : fmt(v, c.unidad)];
      }
      const lista = res.map((x) => ({ quien: quien(x.metric), valor: Number(x.value[1]) }));
      vivo[c.clave] = lista;
      return [c.nombre, lista.length ? lista.map((x) => (c.unidad ? `${x.quien}: ${fmt(x.valor, c.unidad)}` : x.quien)).join(', ') : 'ninguno'];
    });
    // 2. Conclusiones a partir del estado actual.
    const conc = [];
    const L = (k) => (Array.isArray(vivo[k]) ? vivo[k] : null);
    const N = (k) => (typeof vivo[k] === 'number' ? vivo[k] : null);
    if (L('lider')) {
      if (L('lider').length === 1) conc.push(`El cluster tiene líder: ${L('lider')[0].quien} (acepta escrituras; HAProxy le manda el puerto 5432).`);
      else if (L('lider').length === 0) conc.push('El cluster NO tiene líder en este momento: las escrituras fallan.');
      else conc.push(`Hay ${L('lider').length} líderes (${L('lider').map((x) => x.quien).join(', ')}): posible split-brain.`);
    }
    if (L('nodos_caidos')) {
      conc.push(L('nodos_caidos').length
        ? `Nodos caídos: ${L('nodos_caidos').map((x) => x.quien).join(', ')}. Levantarlos con: ${L('nodos_caidos').map((x) => `docker start gymhub_${x.quien.replace('-', '_')}_prod`).join(' ; ')} (vuelven como réplica).`
        : 'Todos los nodos de Patroni responden.');
    }
    if (N('replicas') != null) conc.push(N('replicas') >= 2 ? `Réplicas en streaming: ${N('replicas')} de 2 (redundancia completa).` : `Réplicas en streaming: ${N('replicas')} de 2 (redundancia reducida).`);
    if (N('timeline') != null) conc.push(`Timeline actual: ${N('timeline')} (sube 1 con cada failover).`);
    if (N('api') != null) conc.push(N('api') >= 1 ? 'La app responde (/api/health OK): los usuarios no están afectados.' : 'La app NO responde en /api/health: hay impacto para los usuarios.');
    if (L('alerta_activa')) conc.push(L('alerta_activa').length ? `La alerta ${e.alerta} sigue activa.` : `La alerta ${e.alerta} ya no está activa (se resolvió).`);
    let estado = 'SIN ENTRADA EN EL MANUAL', clase = 'gris';
    if (e) {
      const caido = N('api') === 0 || (L('lider') && L('lider').length !== 1) || N('pg_up') === 0 || N('front') === 0;
      const pendiente = (L('nodos_caidos') && L('nodos_caidos').length) || (N('replicas') != null && N('replicas') < 2)
        || (L('alerta_activa') && L('alerta_activa').length) || (L('exporters') && L('exporters').length);
      if (caido) { estado = 'CRÍTICO: el servicio está afectado'; clase = 'mal'; }
      else if (pendiente) { estado = 'DEGRADADO: el servicio funciona, falta volver a la normalidad'; clase = 'deg'; }
      else { estado = 'RECUPERADO: todo normal'; clase = 'ok'; }
    }
    // 3. Documento.
    const ahora = new Date(new Date().toLocaleString('en-US', { timeZone: 'America/Argentina/Jujuy' }));
    const p = (x) => String(x).padStart(2, '0');
    const fecha = `${ahora.getFullYear()}-${p(ahora.getMonth() + 1)}-${p(ahora.getDate())} ${p(ahora.getHours())}:${p(ahora.getMinutes())}`;
    const sello = fecha.replace(/[-: ]/g, '').replace(/^(\d{8})/, '$1-');
    const inc = ctx.incidencia;
    const archivo = `diagnostico-${e ? e.codigo : 'sin-codigo'}${inc ? `-inc${inc.id}` : ''}-${sello}.md`;
    const lista = (xs) => (xs || []).map((x) => `- ${x}`).join('\n');
    const md = [
      `# Diagnóstico ${e ? `${e.codigo} · ${e.titulo}` : 'sin entrada en el manual'}`, '',
      `- **Generado:** ${fecha} (hora de Argentina) por el flujo 05 de n8n.`,
      `- **ID recibido:** ${ctx.pedido.id} (${ctx.pedido.tipo === 'mantis' ? 'incidencia de Mantis' : 'código del manual'}; pedido desde ${ctx.pedido.origen === 'web' ? 'la página de diagnóstico' : 'el flujo 01, automático'}).`,
      inc ? `- **Incidencia:** [#${inc.id}](${WEB}:8990/view.php?id=${inc.id}) · ${inc.resumen} · estado ${inc.estado}.` : null,
      `- **Manual usado:** Nextcloud › Manual-Operaciones/manual-errores.json (versión ${ctx.manual_version}).`,
      `- **Estado general:** **${estado}**`,
      ctx.aviso ? `\n> ${ctx.aviso}` : null, '',
      '## Conclusión con el estado actual', '', lista(conc) || '- Sin datos.', '',
      '## Estado actual (Prometheus)', '', '| Qué se consultó | Resultado |', '|---|---|',
      ...filas.map(([a, b]) => `| ${a} | ${String(b).replace(/\|/g, '/')} |`),
    ].filter((x) => x !== null);
    if (e) {
      md.push('', `## Qué significa (${e.componente}, severidad ${e.severidad})`, '', e.que_significa, '', `**Impacto:** ${e.impacto}`,
        '', '## Causas probables', '', lista(e.causas), '', '## Pasos de diagnóstico', '', lista(e.diagnostico),
        '', '## Solución', '', lista(e.solucion), '', '## Cómo verificar que quedó resuelto', '', lista(e.verificacion),
        '', `**Escalar:** ${e.escalar}`);
    } else {
      md.push('', '## Códigos disponibles en el manual', '', lista(ctx.codigos));
    }
    const markdown = md.join('\n') + '\n';
    const li = (xs) => `<ul>${(xs || []).map((x) => `<li>${esc(x)}</li>`).join('')}</ul>`;
    const html = `<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">` +
      `<title>Diagnóstico ${esc(e ? e.codigo : '')}</title><style>${CSS}</style></head><body>` +
      `<p><a href="?">← otro ID</a></p><h1>${esc(e ? `${e.codigo} · ${e.titulo}` : 'Sin entrada en el manual')}</h1>` +
      `<p class="estado ${clase}">${esc(estado)}</p>${ctx.aviso ? `<p class="estado gris">${esc(ctx.aviso)}</p>` : ''}` +
      (inc ? `<p>Incidencia <a href="${WEB}:8990/view.php?id=${inc.id}" target="_blank">#${inc.id}</a> · ${esc(inc.resumen)}</p>` : '') +
      `<div class="caja"><h2>Conclusión con el estado actual</h2>${li(conc)}</div>` +
      `<div class="caja"><h2>Estado actual (Prometheus)</h2><table>${filas.map(([a, b]) => `<tr><td>${esc(a)}</td><td><b>${esc(b)}</b></td></tr>`).join('')}</table></div>` +
      (e ? `<div class="caja"><h2>Qué significa</h2><p>${esc(e.que_significa)}</p><p><b>Impacto:</b> ${esc(e.impacto)}</p>` +
        `<h2>Causas probables</h2>${li(e.causas)}<h2>Pasos de diagnóstico</h2>${li(e.diagnostico)}` +
        `<h2>Solución</h2>${li(e.solucion)}<h2>Verificación</h2>${li(e.verificacion)}<p><b>Escalar:</b> ${esc(e.escalar)}</p></div>`
        : `<div class="caja"><h2>Códigos del manual</h2>${li(ctx.codigos)}</div>`) +
      `<p><small>Guardado en Nextcloud: Diagnosticos/${esc(archivo)} · Manual: Manual-Operaciones/manual-errores.json (v${esc(ctx.manual_version)})</small></p></body></html>`;
    const nota = `Diagnóstico automático (n8n, flujo 05) con el manual de errores de Nextcloud.\n` +
      `Código: ${e ? `${e.codigo} · ${e.titulo}` : 'sin entrada en el manual'}\nEstado: ${estado}\n\n` +
      `${conc.map((x) => `- ${x}`).join('\n')}\n\n` +
      (e ? `Solución según el manual:\n${e.solucion.map((x) => `- ${x}`).join('\n')}\n\n` : '') +
      `Diagnóstico completo en Nextcloud: Diagnosticos/${archivo}`;
    return [{ json: { codigo: e ? e.codigo : null, titulo: e ? e.titulo : null, estado, conclusiones: conc,
      conclusion_html: `<b>${esc(estado)}</b><br>${conc.map(esc).join('<br>')}`, archivo, markdown, html, nota,
      issueId: inc ? inc.id : null, origen: ctx.pedido.origen } }];
  }) });
  const guardar = nodo('Guardar en Nextcloud (Diagnosticos)', 'httpRequest', 4.2, {
    method: 'PUT', url: '=http://nextcloud/remote.php/dav/files/n8n-bot/Diagnosticos/{{ $json.archivo }}',
    authentication: 'genericCredentialType', genericAuthType: 'httpBasicAuth', sendBody: true, contentType: 'raw',
    rawContentType: 'text/markdown; charset=utf-8', body: '={{ $json.markdown }}', options: { timeout: 20000 },
  }, { credentials: CRED.nextcloud });
  const iffNota = nodo('¿Hay incidencia en Mantis?', 'if', 1, { conditions: { boolean: [
    { value1: '={{ Boolean($("Armar diagnóstico").first().json.issueId) }}', value2: true }] } });
  const nota = nodo('Agregar diagnóstico a la incidencia', 'httpRequest', 4.2, {
    method: 'POST', url: '=http://mantis/api/rest/issues/{{ $("Armar diagnóstico").first().json.issueId }}/notes',
    authentication: 'genericCredentialType', genericAuthType: 'httpHeaderAuth', sendBody: true, specifyBody: 'json',
    jsonBody: '={{ JSON.stringify({ text: $("Armar diagnóstico").first().json.nota, view_state: { name: "public" } }) }}',
    options: { timeout: 15000 },
  }, { credentials: CRED.mantis });
  const resultado = nodo('Resultado', 'code', 2, { jsCode: cuerpo(function () {
    const d = $('Armar diagnóstico').first().json;
    return [{ json: { codigo: d.codigo, titulo: d.titulo, estado: d.estado, conclusion_html: d.conclusion_html,
      archivo: d.archivo, issueId: d.issueId, origen: d.origen } }];
  }) });
  const iffWeb = nodo('¿Lo pidió la página?', 'if', 1, { conditions: { string: [{ value1: '={{ $json.origen }}', value2: 'web' }] } });
  const resp = nodo('Responder diagnóstico', 'respondToWebhook', 1.1, {
    respondWith: 'text', responseBody: '={{ $("Armar diagnóstico").first().json.html }}',
    options: { responseCode: 200, responseHeaders: { entries: [{ name: 'Content-Type', value: 'text/html; charset=utf-8' }] } },
  });
  const devolver = nodo('Devolver al flujo 01', 'noOp', 1, {});
  const nodes = [wh, sub, norm, iffForm, form, respForm, leerManual, iffMantis, leerInc, buscar, prom, armar, guardar,
    iffNota, nota, resultado, iffWeb, resp, devolver];
  escribir('05-diagnostico-manual.json', flujo(ID.diagnostico, '05 · Diagnóstico con el manual de errores (Nextcloud)', nodes, conectar([
    [wh.name, norm.name], [sub.name, norm.name], [norm.name, iffForm.name], [iffForm.name, form.name, 0], [form.name, respForm.name],
    [iffForm.name, leerManual.name, 1], [leerManual.name, iffMantis.name], [iffMantis.name, leerInc.name, 0],
    [iffMantis.name, buscar.name, 1], [leerInc.name, buscar.name], [buscar.name, prom.name], [prom.name, armar.name],
    [armar.name, guardar.name], [guardar.name, iffNota.name], [iffNota.name, nota.name, 0], [iffNota.name, resultado.name, 1],
    [nota.name, resultado.name], [resultado.name, iffWeb.name], [iffWeb.name, resp.name, 0], [iffWeb.name, devolver.name, 1],
  ])));
}

// ───────────── Manual de errores en Markdown (para leerlo en Nextcloud), generado del JSON ─────────────
{
  const M = JSON.parse(fs.readFileSync(path.join(DIR, '..', 'manual', 'manual-errores.json'), 'utf8'));
  const lista = (xs) => xs.map((x) => `- ${x}`).join('\n');
  const md = [`# ${M.titulo}`, '', `Versión ${M.version} · actualizado ${M.actualizado}.`, '', M.uso, '',
    '> Generado desde `infra/n8n/manual/manual-errores.json` (la versión que lee n8n). No editar este archivo a mano.', '',
    '## Índice', '', '| Código | Alerta / origen | Severidad | Error |', '|---|---|---|---|',
    ...M.errores.map((e) => `| ${e.codigo} | ${e.alerta || `(${e.patron.split('|')[0]})`} | ${e.severidad} | ${e.titulo} |`)];
  for (const e of M.errores) {
    md.push('', `## ${e.codigo} · ${e.titulo}`, '', `**Componente:** ${e.componente} · **Severidad:** ${e.severidad}` +
      (e.alerta ? ` · **Alerta:** \`${e.alerta}\`` : ''), '', `**Qué significa.** ${e.que_significa}`, '',
      `**Impacto.** ${e.impacto}`, '', '**Causas probables**', '', lista(e.causas), '', '**Diagnóstico**', '', lista(e.diagnostico),
      '', '**Solución**', '', lista(e.solucion), '', '**Verificación**', '', lista(e.verificacion), '', `**Escalar.** ${e.escalar}`, '',
      `**Lo que consulta n8n en Prometheus:** ${e.consultas.map((k) => M.consultas[k].nombre).join('; ')}.`);
  }
  fs.writeFileSync(path.join(DIR, '..', 'manual', 'manual-errores.md'), md.join('\n') + '\n');
}

console.log('Flujos generados en', DIR);
