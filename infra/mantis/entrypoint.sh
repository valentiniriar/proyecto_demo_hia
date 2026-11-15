#!/bin/sh
# Genera config/config_inc.php a partir de variables de entorno en cada arranque.
# Así el archivo con la contraseña de la BD y la sal criptográfica nunca está en
# el repositorio ni en la imagen (SCRUM-70).
set -eu

: "${MANTIS_DB_HOST:=mantis-db}"
: "${MANTIS_DB_NAME:=bugtracker}"
: "${MANTIS_DB_USER:=mantis}"
: "${MANTIS_DB_PASS:?Falta MANTIS_DB_PASS}"
: "${MANTIS_CRYPTO_SALT:?Falta MANTIS_CRYPTO_SALT (openssl rand -base64 32)}"
: "${MANTIS_PATH:=http://localhost:8990/}"

php_str() { printf "%s" "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g"; }

cat > /var/www/html/config/config_inc.php <<EOF
<?php
# Generado por gymhub-mantis-entrypoint. No editar: se regenera al iniciar.
\$g_hostname               = '$(php_str "$MANTIS_DB_HOST")';
\$g_db_type                = 'mysqli';
\$g_database_name          = '$(php_str "$MANTIS_DB_NAME")';
\$g_db_username            = '$(php_str "$MANTIS_DB_USER")';
\$g_db_password            = '$(php_str "$MANTIS_DB_PASS")';
\$g_crypto_master_salt     = '$(php_str "$MANTIS_CRYPTO_SALT")';
\$g_path                   = '$(php_str "$MANTIS_PATH")';

\$g_default_timezone       = 'America/Argentina/Buenos_Aires';
\$g_default_language       = 'spanish';
\$g_window_title           = 'GymHub · Incidencias';

# Sin servidor de correo en el entorno del TP: las notificaciones van al historial.
\$g_enable_email_notification = OFF;
\$g_allow_signup           = OFF;
\$g_lost_password_feature  = OFF;
\$g_anonymous_access_enabled = OFF;

# Severidades y prioridades del equipo (ver docs/SCRUM-70-mantis.md).
\$g_default_bug_severity   = MINOR;
\$g_default_bug_priority   = NORMAL;

# Flujo de estados: nueva -> asignada -> resuelta -> cerrada.
\$g_bug_resolved_status_threshold = RESOLVED;
\$g_bug_assigned_status   = ASSIGNED;

# /admin está bloqueado por Apache salvo desde localhost del contenedor.
\$g_admin_checks           = OFF;

# API REST habilitada (n8n) solo con token de usuario.
\$g_webservice_rest_enabled = ON;
EOF

chown www-data:www-data /var/www/html/config/config_inc.php
chmod 640 /var/www/html/config/config_inc.php

exec docker-php-entrypoint "$@"
