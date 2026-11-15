-- =====================================================================
--  SCRUM-35 - Dataset de prueba
--  Paso 4/4: verificacion de criterios de aceptacion.
--
--  1. Conteos exactos (6.000.000 por tabla de datos; roles 3; ejercicios 200)
--  2. Huerfanos por cada FK (tienen que ser 0)
--  3. Unicidad de dni, email y transaccion
--  4. Coherencia de negocio (pagado <-> pagos, montos, fechas)
--  5. Distribuciones (informativo, para el documento)
--  6. Huella del dataset (para comprobar que es reproducible)
--
--  Los chequeos 1 a 4 se guardan en una tabla temporal y al final un bloque
--  DO aborta con error si alguno no da lo esperado.
--  Solo lectura: no modifica datos.
-- =====================================================================

\set ON_ERROR_STOP on
\timing on
\pset footer off

SET work_mem = '64MB';
SET TimeZone = 'UTC';
-- El hash join paralelo reserva la tabla hash en memoria compartida (/dev/shm)
-- segun work_mem, y Docker limita /dev/shm a 64 MB -> "No space left on device".
-- Se desactiva solo el hash paralelo; el resto del paralelismo sigue activo.
-- (Visto en la 1.a ejecucion, SCRUM-36.)
SET enable_parallel_hash = off;

CREATE TEMP TABLE ds_chequeo (
    grupo    text,
    chequeo  text,
    valor    bigint,
    esperado bigint
);

-- ---------------------------------------------------------------------
-- 1. Conteos
-- ---------------------------------------------------------------------
INSERT INTO ds_chequeo
SELECT 'conteo', t, n, e FROM (VALUES
    ('usuarios',          (SELECT count(*) FROM usuarios),          6000000),
    ('usuario_roles',     (SELECT count(*) FROM usuario_roles),     6000000),
    ('rutinas',           (SELECT count(*) FROM rutinas),           6000000),
    ('rutina_ejercicios', (SELECT count(*) FROM rutina_ejercicios), 6000000),
    ('suscripciones',     (SELECT count(*) FROM suscripciones),     6000000),
    ('tarifas',           (SELECT count(*) FROM tarifas),           6000000),
    ('pagos',             (SELECT count(*) FROM pagos),             6000000),
    ('roles (catalogo)',      (SELECT count(*) FROM roles),         3),
    ('ejercicios (catalogo)', (SELECT count(*) FROM ejercicios),    200)
) v(t, n, e);

-- ---------------------------------------------------------------------
-- 2. Huerfanos: FK que apunta a un padre inexistente, o FK nula
--    (las FK admiten NULL, pero en este dataset ninguna deberia serlo)
-- ---------------------------------------------------------------------
INSERT INTO ds_chequeo
SELECT 'huerfanos', t, n, 0 FROM (VALUES
    ('usuario_roles.id_usuario -> usuarios',
        (SELECT count(*) FROM usuario_roles h LEFT JOIN usuarios p ON p.id = h.id_usuario WHERE p.id IS NULL)),
    ('usuario_roles.id_rol -> roles',
        (SELECT count(*) FROM usuario_roles h LEFT JOIN roles p ON p.id = h.id_rol WHERE p.id IS NULL)),
    ('rutinas.usuarioId -> usuarios',
        (SELECT count(*) FROM rutinas h LEFT JOIN usuarios p ON p.id = h."usuarioId" WHERE p.id IS NULL)),
    ('rutina_ejercicios.id_rutina -> rutinas',
        (SELECT count(*) FROM rutina_ejercicios h LEFT JOIN rutinas p ON p.id = h.id_rutina WHERE p.id IS NULL)),
    ('rutina_ejercicios.id_ejercicio -> ejercicios',
        (SELECT count(*) FROM rutina_ejercicios h LEFT JOIN ejercicios p ON p.id = h.id_ejercicio WHERE p.id IS NULL)),
    ('suscripciones.usuarioId -> usuarios',
        (SELECT count(*) FROM suscripciones h LEFT JOIN usuarios p ON p.id = h."usuarioId" WHERE p.id IS NULL)),
    ('tarifas.suscripcionId -> suscripciones',
        (SELECT count(*) FROM tarifas h LEFT JOIN suscripciones p ON p.id = h."suscripcionId" WHERE p.id IS NULL)),
    ('pagos.tarifaId -> tarifas',
        (SELECT count(*) FROM pagos h LEFT JOIN tarifas p ON p.id = h."tarifaId" WHERE p.id IS NULL))
) v(t, n);

-- Restricciones realmente presentes y validadas (8 FK, 7 PK de datos, 2 UNIQUE de usuarios)
INSERT INTO ds_chequeo
SELECT 'restricciones', 'FK validadas en el esquema', count(*), 8
FROM pg_constraint WHERE contype = 'f' AND convalidated AND connamespace = 'public'::regnamespace;

INSERT INTO ds_chequeo
SELECT 'restricciones', 'UNIQUE usuarios (dni, email)', count(*), 2
FROM pg_constraint WHERE contype = 'u' AND conrelid = 'usuarios'::regclass;

-- ---------------------------------------------------------------------
-- 3. Unicidad
-- ---------------------------------------------------------------------
INSERT INTO ds_chequeo
SELECT 'unicidad', t, n, 0 FROM (VALUES
    ('usuarios.dni duplicados',       (SELECT count(*) - count(DISTINCT dni)   FROM usuarios)),
    ('usuarios.email duplicados',     (SELECT count(*) - count(DISTINCT email) FROM usuarios)),
    ('pagos.transaccion duplicadas',  (SELECT count(*) - count(DISTINCT transaccion) FROM pagos))
) v(t, n);

-- ---------------------------------------------------------------------
-- 4. Coherencia de negocio
-- ---------------------------------------------------------------------
CREATE TEMP TABLE ds_pagos_por_tarifa AS
SELECT "tarifaId" AS tarifa_id, count(*) AS n, sum(monto::int) AS total,
       min(fecha::date) AS primera, max(fecha::date) AS ultima
FROM pagos
GROUP BY "tarifaId";
ANALYZE ds_pagos_por_tarifa;

INSERT INTO ds_chequeo
SELECT 'coherencia', t, n, 0 FROM (VALUES
    ('tarifas impagas con pagos',
        (SELECT count(*) FROM tarifas t JOIN ds_pagos_por_tarifa p ON p.tarifa_id = t.id WHERE NOT t.pagado)),
    ('tarifas pagadas sin pagos',
        (SELECT count(*) FROM tarifas t LEFT JOIN ds_pagos_por_tarifa p ON p.tarifa_id = t.id
         WHERE t.pagado AND p.tarifa_id IS NULL)),
    ('tarifas donde suma(pagos) <> precio',
        (SELECT count(*) FROM tarifas t JOIN ds_pagos_por_tarifa p ON p.tarifa_id = t.id
         WHERE p.total <> t.precio::int)),
    ('pagos anteriores al mes de su cuota',
        (SELECT count(*) FROM tarifas t JOIN ds_pagos_por_tarifa p ON p.tarifa_id = t.id
         WHERE p.primera < make_date(t.anio::int, t.mes::int, 1))),
    ('pagos posteriores a la fecha de corte (2026-11-13)',
        (SELECT count(*) FROM ds_pagos_por_tarifa WHERE ultima > date '2026-11-13')),
    ('suscripciones con fecha_fin < fecha_inicio',
        (SELECT count(*) FROM suscripciones WHERE fecha_fin::date < fecha_inicio::date)),
    ('rutinas con ejercicio repetido (PK compuesta)',
        (SELECT count(*) - count(DISTINCT (id_rutina, id_ejercicio)) FROM rutina_ejercicios)),
    ('montos o precios <= 0',
        (SELECT (SELECT count(*) FROM pagos WHERE monto::int <= 0)
              + (SELECT count(*) FROM tarifas WHERE precio::int <= 0)))
) v(t, n);

\echo
\echo '==================== RESULTADO DE LOS CHEQUEOS ===================='
SELECT grupo, chequeo,
       to_char(valor, 'FM999G999G999')    AS valor,
       to_char(esperado, 'FM999G999G999') AS esperado,
       CASE WHEN valor = esperado THEN 'OK' ELSE 'FALLA' END AS estado
FROM ds_chequeo
ORDER BY CASE grupo WHEN 'conteo' THEN 1 WHEN 'huerfanos' THEN 2 WHEN 'restricciones' THEN 3
                    WHEN 'unicidad' THEN 4 ELSE 5 END, chequeo;

-- ---------------------------------------------------------------------
-- 5. Distribuciones (informativo)
-- ---------------------------------------------------------------------
\echo
\echo '==================== DISTRIBUCIONES ===================='

\echo '--- Tarifas: pagadas / impagas (activas y anuladas) ---'
SELECT CASE WHEN pagado THEN 'pagada' ELSE 'impaga' END AS estado,
       activo,
       to_char(count(*), 'FM999G999G999') AS tarifas,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS porcentaje
FROM tarifas GROUP BY pagado, activo ORDER BY pagado DESC, activo DESC;

\echo '--- Tarifas por anio: volumen, % impago y percentiles de precio ---'
SELECT anio,
       to_char(count(*), 'FM999G999G999') AS tarifas,
       round(100.0 * count(*) FILTER (WHERE NOT pagado) / count(*), 2) AS pct_impago,
       percentile_disc(0.10) WITHIN GROUP (ORDER BY precio::int) AS precio_p10,
       percentile_disc(0.50) WITHIN GROUP (ORDER BY precio::int) AS precio_p50,
       percentile_disc(0.90) WITHIN GROUP (ORDER BY precio::int) AS precio_p90
FROM tarifas GROUP BY anio ORDER BY anio;

\echo '--- Pagos: en termino (dia 1-10) vs con mora, y en una o dos partes ---'
SELECT CASE WHEN extract(day FROM fecha::date) <= 10
                 AND date_trunc('month', fecha::date) = make_date(t.anio::int, t.mes::int, 1)
            THEN 'en termino' ELSE 'con mora / 2da parte' END AS momento,
       to_char(count(*), 'FM999G999G999') AS pagos,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS porcentaje
FROM pagos p JOIN tarifas t ON t.id = p."tarifaId"
GROUP BY 1 ORDER BY 1;

SELECT n AS pagos_por_tarifa_pagada, to_char(count(*), 'FM999G999G999') AS tarifas
FROM ds_pagos_por_tarifa GROUP BY n ORDER BY n;

\echo '--- Suscripciones: altas por anio, activas y duracion ---'
SELECT left(fecha_inicio, 4) AS anio,
       to_char(count(*), 'FM999G999G999') AS suscripciones,
       count(*) FILTER (WHERE activo) AS activas,
       round(avg(fecha_fin::date - fecha_inicio::date), 1) AS dias_promedio
FROM suscripciones GROUP BY 1 ORDER BY 1;

SELECT n AS tarifas_por_suscripcion, to_char(count(*), 'FM999G999G999') AS suscripciones
FROM (SELECT s.id, count(t.id) AS n
      FROM suscripciones s LEFT JOIN tarifas t ON t."suscripcionId" = s.id GROUP BY s.id) x
GROUP BY n ORDER BY n;

\echo '--- Usuarios: altas por anio, estado y roles ---'
SELECT extract(year FROM "createdAt")::int AS anio,
       to_char(count(*), 'FM999G999G999') AS usuarios,
       round(100.0 * count(*) FILTER (WHERE estado) / count(*), 2) AS pct_activos,
       round(100.0 * count(*) FILTER (WHERE google_id IS NOT NULL) / count(*), 2) AS pct_google
FROM usuarios GROUP BY 1 ORDER BY 1;

SELECT r.nombre AS rol, to_char(count(*), 'FM999G999G999') AS usuarios,
       round(100.0 * count(*) / sum(count(*)) OVER (), 3) AS porcentaje
FROM usuario_roles ur JOIN roles r ON r.id = ur.id_rol GROUP BY r.nombre ORDER BY count(*) DESC;

SELECT split_part(email, '@', 2) AS dominio, to_char(count(*), 'FM999G999G999') AS usuarios
FROM usuarios GROUP BY 1 ORDER BY count(*) DESC;

\echo '--- Rutinas: turno, dia y ejercicios por rutina ---'
SELECT turno, to_char(count(*), 'FM999G999G999') AS rutinas,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS porcentaje
FROM rutinas GROUP BY turno ORDER BY count(*) DESC;

SELECT dia_semana, to_char(count(*), 'FM999G999G999') AS rutinas,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS porcentaje
FROM rutinas GROUP BY dia_semana ORDER BY count(*) DESC;

SELECT n AS ejercicios_por_rutina, to_char(count(*), 'FM999G999G999') AS rutinas
FROM (SELECT r.id, count(re.id_rutina) AS n
      FROM rutinas r LEFT JOIN rutina_ejercicios re ON re.id_rutina = r.id GROUP BY r.id) x
GROUP BY n ORDER BY n;

-- ---------------------------------------------------------------------
-- 6. Tamanios y huella del dataset
-- ---------------------------------------------------------------------
\echo
\echo '==================== TAMANIOS ===================='
SELECT c.relname AS tabla,
       pg_size_pretty(pg_table_size(c.oid))          AS datos,
       pg_size_pretty(pg_indexes_size(c.oid))        AS indices,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total
FROM pg_class c
WHERE c.relkind = 'r' AND c.relnamespace = 'public'::regnamespace
ORDER BY pg_total_relation_size(c.oid) DESC;

SELECT pg_size_pretty(pg_database_size(current_database())) AS tamanio_base;

\echo
\echo '==================== HUELLA (reproducibilidad) ===================='
\echo 'Tiene que dar lo mismo en dos cargas desde cero. Excluye las filas del'
\echo 'seed porque su createdAt es NOW() al crear el contenedor.'
SELECT 'usuarios' AS tabla, md5(sum(hashtextextended(t::text, 0)::numeric)::text) AS huella FROM usuarios t WHERE id > 3
UNION ALL SELECT 'usuario_roles',     md5(sum(hashtextextended(t::text, 0)::numeric)::text) FROM usuario_roles t
UNION ALL SELECT 'ejercicios',        md5(sum(hashtextextended(t::text, 0)::numeric)::text) FROM ejercicios t WHERE id > 3
UNION ALL SELECT 'rutinas',           md5(sum(hashtextextended(t::text, 0)::numeric)::text) FROM rutinas t WHERE id > 1
UNION ALL SELECT 'rutina_ejercicios', md5(sum(hashtextextended(t::text, 0)::numeric)::text) FROM rutina_ejercicios t
UNION ALL SELECT 'suscripciones',     md5(sum(hashtextextended(t::text, 0)::numeric)::text) FROM suscripciones t WHERE id > 1
UNION ALL SELECT 'tarifas',           md5(sum(hashtextextended(t::text, 0)::numeric)::text) FROM tarifas t WHERE id > 2
UNION ALL SELECT 'pagos',             md5(sum(hashtextextended(t::text, 0)::numeric)::text) FROM pagos t WHERE id > 1;

-- ---------------------------------------------------------------------
-- Veredicto: aborta si algun chequeo de los puntos 1 a 4 no da lo esperado
-- ---------------------------------------------------------------------
DO $$
DECLARE
    v_fallas text;
BEGIN
    SELECT string_agg(format('%s / %s: %s (esperado %s)', grupo, chequeo, valor, esperado), E'\n')
      INTO v_fallas
      FROM ds_chequeo WHERE valor IS DISTINCT FROM esperado;

    IF v_fallas IS NOT NULL THEN
        RAISE EXCEPTION E'SCRUM-35: el dataset NO cumple los criterios:\n%', v_fallas;
    END IF;

    RAISE NOTICE 'SCRUM-35: todos los chequeos OK (conteos exactos, 0 huerfanos, unicidad y coherencia).';
END $$;
