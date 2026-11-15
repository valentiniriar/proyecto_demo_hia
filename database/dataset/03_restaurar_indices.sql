-- =====================================================================
--  SCRUM-35 - Dataset de prueba
--  Paso 3/4: recrear PK, UNIQUE y FK con los nombres de 01_schema.sql,
--            reposicionar secuencias, borrar las funciones ds_* y VACUUM ANALYZE.
--
--  Las FK se crean CON validacion (sin NOT VALID): PostgreSQL revisa cada
--  fila y, si existiera un solo huerfano, este paso falla. Lo mismo con
--  UNIQUE (dni, email): un duplicado hace fallar el paso.
-- =====================================================================

\set ON_ERROR_STOP on
\timing on

SET maintenance_work_mem = '512MB';          -- contenedor de 2-4 GB (SCRUM-43)
SET max_parallel_maintenance_workers = 2;     -- CREATE INDEX en paralelo

BEGIN;

-- ---------- Claves primarias y unicas ----------
ALTER TABLE usuarios
    ADD CONSTRAINT usuarios_pkey       PRIMARY KEY (id),
    ADD CONSTRAINT usuarios_dni_key    UNIQUE (dni),
    ADD CONSTRAINT usuarios_email_key  UNIQUE (email);

ALTER TABLE usuario_roles     ADD CONSTRAINT usuario_roles_pkey     PRIMARY KEY (id_usuario, id_rol);
ALTER TABLE rutinas           ADD CONSTRAINT rutinas_pkey           PRIMARY KEY (id);
ALTER TABLE rutina_ejercicios ADD CONSTRAINT rutina_ejercicios_pkey PRIMARY KEY (id_rutina, id_ejercicio);
ALTER TABLE suscripciones     ADD CONSTRAINT suscripciones_pkey     PRIMARY KEY (id);
ALTER TABLE tarifas           ADD CONSTRAINT tarifas_pkey           PRIMARY KEY (id);
ALTER TABLE pagos             ADD CONSTRAINT pagos_pkey             PRIMARY KEY (id);

-- ---------- Claves foraneas (mismas reglas que 01_schema.sql) ----------
ALTER TABLE usuario_roles
    ADD CONSTRAINT usuario_roles_id_usuario_fkey
        FOREIGN KEY (id_usuario) REFERENCES usuarios (id) ON UPDATE CASCADE ON DELETE CASCADE,
    ADD CONSTRAINT usuario_roles_id_rol_fkey
        FOREIGN KEY (id_rol) REFERENCES roles (id) ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE rutinas
    ADD CONSTRAINT "rutinas_usuarioId_fkey"
        FOREIGN KEY ("usuarioId") REFERENCES usuarios (id) ON UPDATE CASCADE ON DELETE SET NULL;

ALTER TABLE rutina_ejercicios
    ADD CONSTRAINT rutina_ejercicios_id_rutina_fkey
        FOREIGN KEY (id_rutina) REFERENCES rutinas (id) ON UPDATE CASCADE ON DELETE CASCADE,
    ADD CONSTRAINT rutina_ejercicios_id_ejercicio_fkey
        FOREIGN KEY (id_ejercicio) REFERENCES ejercicios (id) ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE suscripciones
    ADD CONSTRAINT "suscripciones_usuarioId_fkey"
        FOREIGN KEY ("usuarioId") REFERENCES usuarios (id) ON UPDATE CASCADE ON DELETE SET NULL;

ALTER TABLE tarifas
    ADD CONSTRAINT "tarifas_suscripcionId_fkey"
        FOREIGN KEY ("suscripcionId") REFERENCES suscripciones (id) ON UPDATE CASCADE ON DELETE SET NULL;

ALTER TABLE pagos
    ADD CONSTRAINT "pagos_tarifaId_fkey"
        FOREIGN KEY ("tarifaId") REFERENCES tarifas (id) ON UPDATE CASCADE ON DELETE SET NULL;

-- ---------- Secuencias (mismo patron que 02_seed.sql) ----------
SELECT setval(pg_get_serial_sequence('usuarios',      'id'), (SELECT max(id) FROM usuarios));
SELECT setval(pg_get_serial_sequence('ejercicios',    'id'), (SELECT max(id) FROM ejercicios));
SELECT setval(pg_get_serial_sequence('rutinas',       'id'), (SELECT max(id) FROM rutinas));
SELECT setval(pg_get_serial_sequence('suscripciones', 'id'), (SELECT max(id) FROM suscripciones));
SELECT setval(pg_get_serial_sequence('tarifas',       'id'), (SELECT max(id) FROM tarifas));
SELECT setval(pg_get_serial_sequence('pagos',         'id'), (SELECT max(id) FROM pagos));

-- ---------- Funciones auxiliares: el esquema queda igual que el original ----------
DROP FUNCTION ds_re_orden(bigint), ds_re_rutina(bigint), ds_rutina_nej(bigint),
              ds_pago_parte(bigint), ds_pago_tarifa(bigint),
              ds_tarifa_npagos(bigint), ds_tarifa_cuota(bigint), ds_tarifa_sub(bigint),
              ds_sub_precio(bigint), ds_sub_mes(bigint), ds_sub_mes_max(bigint),
              ds_sub_usuario(bigint), ds_sub_tipo(bigint),
              ds_mes_alta(bigint), ds_socio(bigint, int), ds_rol(bigint),
              ds_idx(bigint, int, int, int), ds_pos(bigint, int, int),
              ds_mes_fecha(int), ds_corte(), ds_pick(text[], bigint, int), ds_rand(bigint, int);

COMMIT;

-- VACUUM no puede ir dentro de una transaccion. Actualiza estadisticas del
-- planificador y el visibility map (habilita index-only scans).
-- PARALLEL 0: el vacuum paralelo guarda los ids de tuplas en memoria
-- compartida (/dev/shm) segun maintenance_work_mem (~234 MB pedidos), y Docker
-- le da a /dev/shm solo 64 MB por defecto -> "No space left on device".
-- Sin paralelismo usa memoria local del proceso. (Visto en la 1.a ejecucion, SCRUM-36.)
VACUUM (ANALYZE, PARALLEL 0) usuarios, usuario_roles, roles, ejercicios, rutinas,
                 rutina_ejercicios, suscripciones, tarifas, pagos;
