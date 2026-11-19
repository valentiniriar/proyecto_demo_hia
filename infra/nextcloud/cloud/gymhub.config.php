<?php
// Configuración de Nextcloud versionada para GymHub (SCRUM-73/74). cloud/bootstrap.sh la copia a
// /var/www/html/config/ y Nextcloud la combina con el config.php que genera la instalación.
// Sin secretos: las contraseñas viven en infra/nextcloud/.env y en la base de Nextcloud.
$CONFIG = array (
  'default_language' => 'es',
  'default_locale' => 'es_AR',
  'default_phone_region' => 'AR',
  'default_timezone' => 'America/Argentina/Jujuy',
  // Los usuarios nuevos empiezan sin los archivos de ejemplo: solo ven las carpetas del equipo.
  'skeletondirectory' => '',
  'templatedirectory' => '',
  'overwrite.cli.url' => 'http://localhost:8082',
  // Sin conexión a la tienda de apps fuera de la instalación inicial ni avisos de actualización.
  'updatechecker' => false,
  'has_internet_connection' => true,
  // Repositorio de informes: sin papelera infinita ni versiones eternas.
  'trashbin_retention_obligation' => 'auto, 30',
  'versions_retention_obligation' => 'auto, 30',
  'loglevel' => 2,
);
