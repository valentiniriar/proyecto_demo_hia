# SCRUM-79 — Corrección de autenticación del workflow de backups

Se eliminó el header `Authorization` escrito con `$env.MANTIS_API_TOKEN` en el nodo Mantis del JSON versionado de SCRUM-77. El nodo ya está configurado como `genericCredentialType/httpHeaderAuth`, y deberá asociarse a una credencial válida desde **Credentials de n8n** al importar; no se importa ni activa automáticamente. Esta corrección **no verifica integridad `pg_restore --list` ni ejecuta el flujo**. No se incluyen tokens.
