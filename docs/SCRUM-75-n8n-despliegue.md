# SCRUM-75 — n8n local seguro y persistente

## Alcance
- Se despliega una instancia **aislada** del n8n usado en otros trabajos, sin tocar GymHub PostgreSQL.
- Compose: `infra/n8n/docker-compose.yml`.
- Datos y credenciales cifradas persistidos en el volumen Docker `gymhub-scrum75_n8n_data`.
- La clave `N8N_ENCRYPTION_KEY` se genera aleatoriamente y permanece en `infra/n8n/.env` **sin versionarse**.
- El editor y los webhooks solo están publicados en `127.0.0.1`; no se exponen a Internet.
- Para usar cookies en este laboratorio HTTP local se configura `N8N_SECURE_COOKIE=false`. **No usar esta configuración para acceso remoto o producción**: allí se requiere HTTPS/TLS y cookie segura.
- Se limita el acceso a las variables de entorno y archivos de configuración desde nodos.

## Instalación
Desde `infra/n8n/`: `docker compose up -d`. El puerto local está definido en `.env` (`N8N_HOST_PORT`).

## Cuenta owner y 2FA (manual)
1. Abrir `http://localhost:<N8N_HOST_PORT>` y completar registro del **owner** con correo propio y contraseña única y fuerte. No enviar contraseña ni códigos al equipo o al chat.
2. En n8n: **Settings → Profile & preferences → Enable 2FA**. Vincular una aplicación autenticadora y guardar códigos de recuperación en un lugar seguro.
3. Documentar evidencia de que el owner inició sesión y 2FA quedó activado, **sin mostrar códigos, tokens ni contraseñas**.

## Credenciales e integraciones
- Las futuras credenciales de Mantis, Nextcloud, correo/Telegram e IA se crean en **Credentials** de n8n y se referencian desde los nodos; no se pegan tokens en textos de nodos o exportaciones JSON.
- No generar ni compartir claves reales para la evidencia. Las integraciones todavía no conectadas quedan **pendientes** hasta SCRUM-76/79 y demás servicios.
- Si en el futuro se habilitan webhooks accesibles desde Internet, exigir autenticación/validación y restringir la publicación mediante el proxy. **No se publican webhooks externos en SCRUM-75**.

## Prueba de persistencia realizada (11/11/2026)

**Resultado:** se recreó el contenedor de n8n sin borrar el
volumen persistente. Se comprobó que el usuario Owner y el
workflow «Prueba persistencia SCRUM75» continuaron disponibles.

### Procedimiento para repetir la prueba
1. Crear el owner en la UI y, opcionalmente, un workflow de prueba llamado `SCRUM75-Persistencia`.
2. Desde `infra/n8n/` ejecutar `docker compose restart n8n`, esperar que vuelva y comprobar que el usuario y el workflow siguen disponibles.
3. Registrar `docker compose ps`, `docker port gymhub-n8n-scrum75 5678/tcp`, volumen `docker volume inspect gymhub-scrum75_n8n_data` y captura del editor.
4. **Nunca usar** `docker compose down -v` ni borrar el volumen o regenerar la clave de cifrado si hay credenciales guardadas.

## Observaciones
- Esta entrega usa SQLite dentro del volumen persistente, válido según el criterio de aceptación de SCRUM-75. Para mayor escala se recomienda PostgreSQL dedicado.
- La imagen `stable` debe fijarse a un digest/versión verificada antes de despliegues reproducibles en producción.
- Los flujos de automatización y las credenciales externas no están todavía configurados por este script.
