-- =====================================================================
--  Datos iniciales. SOLO PARA DESARROLLO / DEMO.
--
--  Roles: el backend asigna id_rol = 3 ("socio") a todo usuario nuevo y
--  valida permisos por nombre ('admin', 'entrenador', 'socio'), asi que los
--  ids 1, 2 y 3 deben mantenerse en este orden.
--
--  Usuarios demo (contrasena de los tres: demo1234):
--      admin@demo.com | entrenador@demo.com | socio@demo.com
--  Cambiarlas / borrarlas antes de cualquier uso real.
-- =====================================================================

INSERT INTO roles (id, nombre) VALUES
    (1, 'admin'),
    (2, 'entrenador'),
    (3, 'socio');

INSERT INTO usuarios (id, nombre, apellido, dni, email, password_hash, estado) VALUES
    (1, 'Admin',      'Demo', '10000001', 'admin@demo.com',      '$2b$10$W1jNfsMqOttG20pebf.6N.jEvIEqBIDPvwCtcTEhlnhQul1TpQLK6', TRUE),
    (2, 'Entrenador', 'Demo', '10000002', 'entrenador@demo.com', '$2b$10$W1jNfsMqOttG20pebf.6N.jEvIEqBIDPvwCtcTEhlnhQul1TpQLK6', TRUE),
    (3, 'Socio',      'Demo', '10000003', 'socio@demo.com',      '$2b$10$W1jNfsMqOttG20pebf.6N.jEvIEqBIDPvwCtcTEhlnhQul1TpQLK6', TRUE);

INSERT INTO usuario_roles (id_usuario, id_rol) VALUES
    (1, 1),
    (2, 2),
    (3, 3);

INSERT INTO ejercicios (id, nombre, descripcion, youtube_url, activo) VALUES
    (1, 'Sentadilla',      'Ejercicio de piernas y gluteos con barra o peso corporal.', 'https://www.youtube.com/watch?v=aclHkVaku9U', TRUE),
    (2, 'Press de banca',  'Ejercicio de pecho, hombros y triceps.',                    'https://www.youtube.com/watch?v=rT7DgCr-3pg', TRUE),
    (3, 'Peso muerto',     'Ejercicio compuesto de espalda baja, gluteos e isquios.',   'https://www.youtube.com/watch?v=op9kVnSso6Q', TRUE);

INSERT INTO rutinas (id, dia_semana, turno, nombre, descripcion, activo, "usuarioId") VALUES
    (1, 'Lunes', 'Manana', 'Fuerza full body', 'Rutina de fuerza basica para el socio demo.', TRUE, 3);

INSERT INTO rutina_ejercicios (id_rutina, id_ejercicio) VALUES
    (1, 1),
    (1, 2),
    (1, 3);

INSERT INTO suscripciones (id, fecha_inicio, fecha_fin, precio, activo, "usuarioId") VALUES
    (1, '2026-01-01', '2026-12-31', '25000', TRUE, 3);

INSERT INTO tarifas (id, anio, mes, precio, pagado, activo, "suscripcionId") VALUES
    (1, '2026', '1', '25000', TRUE,  TRUE, 1),
    (2, '2026', '2', '25000', FALSE, TRUE, 1);

INSERT INTO pagos (id, fecha, transaccion, monto, activo, "tarifaId") VALUES
    (1, '2026-01-05', 'DEMO-0001', '25000', TRUE, 1);

-- Los ids se insertaron a mano: se reposicionan las secuencias para que los
-- proximos INSERT (sin id) no choquen con estos.
SELECT setval(pg_get_serial_sequence('roles',          'id'), (SELECT MAX(id) FROM roles));
SELECT setval(pg_get_serial_sequence('usuarios',       'id'), (SELECT MAX(id) FROM usuarios));
SELECT setval(pg_get_serial_sequence('ejercicios',     'id'), (SELECT MAX(id) FROM ejercicios));
SELECT setval(pg_get_serial_sequence('rutinas',        'id'), (SELECT MAX(id) FROM rutinas));
SELECT setval(pg_get_serial_sequence('suscripciones',  'id'), (SELECT MAX(id) FROM suscripciones));
SELECT setval(pg_get_serial_sequence('tarifas',        'id'), (SELECT MAX(id) FROM tarifas));
SELECT setval(pg_get_serial_sequence('pagos',          'id'), (SELECT MAX(id) FROM pagos));
