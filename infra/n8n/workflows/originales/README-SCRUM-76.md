# SCRUM-76 — Alertmanager → n8n → MantisBT + Mailpit

> Entregable para revisión y Pull Request a `develop`. Archivos de ejemplo, sin credenciales ni tokens; el entorno local del integrante sigue siendo el validado. **No se debe activar un segundo workflow con el mismo webhook en la misma instancia.**

## Contenido

- `infra/n8n/workflows/SCRUM-76-alertmanager-mantis.json`: recepción HTTP POST con Header Auth, validación de severidad y fingerprint, deduplicación, creación de incidencia Mantis, anotación de recuperación y correo de alta.
- `infra/n8n/workflows/SCRUM-76-manejo-errores.json`: Error Trigger → correo SMTP de fallo a Mailpit.
- `infra/n8n/SCRUM-76.n8n.override.example.yml`: ejemplo de unión persistente de n8n a `gymhub_tools_net`.
- `infra/monitoring/alertmanager/alertmanager.scrum76.example.yml`: receptor de n8n y `send_resolved` con Bearer token leído desde Docker Secret.
- `infra/monitoring/SCRUM-76.alertmanager.override.example.yml`: ejemplo de Compose para conectar Alertmanager a `gymhub_tools_net` y montar el secreto.

## Verificado en Mac de desarrollo — 14/11/2026

1. Autenticación del webhook: HTTP 200 (antes HTTP 403).
2. Creación automática de incidencia mediante n8n → REST Mantis; GET/POST de Mantis previamente probados con `n8n-bot`.
3. Secuencia controlada `firing` + `firing` con mismo fingerprint + `resolved`: una sola incidencia, nota de resolución añadida (Mantis #3 y #5).
4. Alerta sintética enviada **directamente a Alertmanager** por `POST /api/v2/alerts`: n8n ejecución #8 `Succeeded`, 329 ms, ruta de creación completada.
5. SMTP local Mailpit: correo de alta `Nueva incidencia GymHub #5`, con fingerprint y enlace a Mantis.
6. Error Workflow: payload `{"alerts":"prueba-error"}` produjo error de validación y Mailpit recibió `ERROR - SCRUM-76 GymHub`, con nombre del workflow, mensaje y nodo.

**Pendiente:** verificar el circuito íntegro con una *regla de Prometheus que entre en `firing`*, sin inyectarla en Alertmanager. Esta prueba debe constar en Jira antes de marcar todos los criterios como cerrados.

## Seguridad y despliegue

- **No se incluyen** credenciales, IDs de credenciales, tokens, claves, `meta.instanceId`, IDs de workflow locales ni datos de ejecución.
- **No se alteran** los Compose originales ni `alertmanager/alertmanager.yml`; los archivos `.example.yml` son ejemplos explícitos y requieren activación consciente.
- Las exportaciones están con `active: false` y **sin asociación local de credenciales**, por lo que NO deben sustituir/importarse sobre un workflow productivo sin reconfigurarlo y verificar primero en un entorno de prueba.
- Al importar en otra instancia, configurar manualmente las credenciales HTTP Header Auth del webhook (`Authorization: Bearer <token>`) y Mantis (`Authorization: <token-del-bot>`, **sin** `Bearer` para el REST de Mantis), y SMTP hacia `gymhub-mailpit-scrum76:1025` (sin SSL/TLS en la red local de Docker).
- Configurar desde Settings del workflow principal su `Error Workflow` para que apunte a `SCRUM-76 - Manejo de errores` **después** de importar ambos; el ID de esta vinculación depende de la instancia y se quitó del JSON.
- El correo `responsable@gymhub.local` es **solo una dirección de laboratorio atrapada en Mailpit**: no demuestra notificación real externa. La UI Mailpit local se expone exclusivamente en `127.0.0.1:8026`.
- El enlace `http://localhost:8990/view.php?id=...` sirve únicamente en la Mac del entorno de prueba; en una instalación externa hay que usar una URL alcanzable por el responsable.
- El almacenamiento de deduplicación actual es `$getWorkflowStaticData('global')`: **probado funcionalmente en secuencia**, pero no garantiza atomicidad ante concurrencia ni persistencia transaccional. Para producción, usar PostgreSQL con llave única por fingerprint y transacciones.
- El receptor Alertmanager en el Compose de ejemplo espera un secreto en archivo local. No guardar ese token en el repositorio, logs, comandos pegados en tickets, capturas ni mensajes.

## Cómo integrar en el repo sin modificar el entorno local actual

1. Crear rama local desde `develop`: `git checkout develop && git pull --ff-only && git switch -c feat/SCRUM-76-alertas-n8n-mantis`.
2. Copiar los archivos del paquete en el repositorio, respetando las rutas relativas, verificar `git status`, y **no incluir** ningún `.env`, token, JSON de credenciales, datos de ejecución, archivos de respaldo o bases de datos.
3. Revisar `git diff --check` y `git diff --stat`; commit: `git add infra/n8n/workflows/SCRUM-76-* infra/n8n/workflows/README-SCRUM-76.md infra/n8n/SCRUM-76.n8n.override.example.yml infra/monitoring/alertmanager/alertmanager.scrum76.example.yml infra/monitoring/SCRUM-76.alertmanager.override.example.yml && git commit -m "feat(SCRUM-76): documentar flujo n8n Alertmanager-Mantis y alertas"`.
4. Publicar rama `git push -u origin feat/SCRUM-76-alertas-n8n-mantis` y abrir PR **a `develop`**, no a `main`. No fusionar hasta completar revisión y evidencia de Prometheus.
5. Para desplegar los ejemplos en otra instancia: definir `SCRUM76_WEBHOOK_TOKEN_FILE` con ruta absoluta de un secreto creado *fuera del repo*, validar `docker compose ... config --quiet` y luego aplicar con sus overrides. No modificar el montaje actual ya funcionando del integrante.

## Tarea Jira

[SCRUM-76](https://gymhubb.atlassian.net/browse/SCRUM-76) — mantener `En curso` hasta evidencia final de Prometheus y revisión del PR.
