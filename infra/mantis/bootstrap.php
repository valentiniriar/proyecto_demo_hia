<?php
/**
 * Configuración inicial de Mantis para GymHub (SCRUM-70). Idempotente.
 *
 * Se ejecuta dentro del contenedor, después de instalar el esquema:
 *   docker exec gymhub-mantis php /opt/gymhub/bootstrap.php
 *
 * Crea (si no existen): el proyecto GymHub, sus categorías, los 5 integrantes con
 * su rol, el usuario de servicio "n8n-bot" con permisos mínimos y su token de API.
 * Rota la contraseña por defecto del administrador.
 *
 * Las contraseñas y el token generados se imprimen UNA sola vez en JSON por stdout
 * (setup.sh los guarda en infra/mantis/credenciales.local.json, ignorado por Git).
 */

if( php_sapi_name() !== 'cli' ) { http_response_code( 404 ); exit; }

require_once '/var/www/html/core.php';
require_api( 'user_api.php' );
require_api( 'project_api.php' );
require_api( 'category_api.php' );
require_api( 'api_token_api.php' );
require_api( 'authentication_api.php' );

$t_admin_id = user_get_id_by_name( 'administrator' );
if( !$t_admin_id ) {
	fwrite( STDERR, "No existe el usuario 'administrator': ¿se instaló el esquema?\n" );
	exit( 1 );
}
auth_attempt_script_login( 'administrator' );

function pass_aleatoria() {
	return rtrim( strtr( base64_encode( random_bytes( 18 ) ), '+/', 'Ab' ), '=' );
}

$t_salida = array( 'usuarios_creados' => array(), 'admin' => null, 'n8n_token' => null );

# 1. Contraseña del administrador: se rota si sigue la de fábrica ("root").
if( auth_does_password_match( $t_admin_id, 'root' ) ) {
	$t_pass = pass_aleatoria();
	user_set_password( $t_admin_id, $t_pass );
	$t_salida['admin'] = array( 'usuario' => 'administrator', 'password' => $t_pass );
}

# 2. Proyecto.
$t_project_id = project_get_id_by_name( 'GymHub' );
if( !$t_project_id ) {
	$t_project_id = project_create(
		'GymHub',
		'Incidencias de GymHub (Práctica Integradora). Cada incidencia referencia su ticket de Jira (SCRUM-XX) y el PR que la resuelve.',
		10 /* status: development */,
		VS_PRIVATE /* solo miembros del proyecto */
	);
}

# 3. Categorías.
$t_categorias = array( 'Backend', 'Frontend', 'Base de datos', 'Infraestructura', 'Seguridad', 'Rendimiento', 'CI/CD', 'Automatización' );
foreach( $t_categorias as $t_cat ) {
	if( !category_get_id_by_name( $t_cat, $t_project_id, false ) ) {
		category_add( $t_project_id, $t_cat );
	}
}

# 4. Integrantes (rol global y rol en el proyecto) y usuario de servicio.
#    access: MANAGER 70 · DEVELOPER 55 · REPORTER 25
$t_usuarios = array(
	array( 'viriarte',   'Valentín Iriarte',   MANAGER ),   # responsable de E11 (incidencias)
	array( 'fparedes',   'Francisco Paredes',  MANAGER ),   # Scrum / CI-CD
	array( 'vlozano',    'Valentín Lozano',    DEVELOPER ),
	array( 'evillagran', 'Enzo Villagrán',     DEVELOPER ),
	array( 'tgallo',     'Tiziano Gallo',      DEVELOPER ),
	array( 'n8n-bot',    'n8n (automatización)', REPORTER ), # solo reporta incidencias y agrega notas
);
foreach( $t_usuarios as $t_u ) {
	list( $t_nombre, $t_real, $t_nivel ) = $t_u;
	$t_id = user_get_id_by_name( $t_nombre );
	if( !$t_id ) {
		$t_pass = pass_aleatoria();
		user_create( $t_nombre, $t_pass, $t_nombre . '@gymhub.local', $t_nivel, false, true, $t_real );
		$t_id = user_get_id_by_name( $t_nombre );
		$t_salida['usuarios_creados'][] = array( 'usuario' => $t_nombre, 'nombre' => $t_real, 'password' => $t_pass );
	}
	if( !project_includes_user( $t_project_id, $t_id ) ) {
		project_add_user( $t_project_id, $t_id, $t_nivel );
	}
}

# 5. Token de API para n8n (solo se crea si el bot no tiene ninguno).
$t_bot_id = user_get_id_by_name( 'n8n-bot' );
if( count( api_token_get_all( $t_bot_id ) ) === 0 ) {
	$t_salida['n8n_token'] = api_token_create( 'n8n', $t_bot_id );
}

# 6. Resumen (sin secretos) por stderr, secretos nuevos en JSON por stdout.
fwrite( STDERR, sprintf( "Proyecto GymHub id=%d · categorías=%d · miembros=%d\n",
	$t_project_id,
	count( category_get_all_rows( $t_project_id ) ),
	count( project_get_all_user_rows( $t_project_id, ANYBODY, false ) ) ) );
echo json_encode( $t_salida, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE ), "\n";
