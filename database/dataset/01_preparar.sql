-- =====================================================================
--  SCRUM-35 - Dataset de prueba (6.000.000 filas por tabla de datos)
--  Paso 1/4: validaciones previas, funciones auxiliares y baja de
--            restricciones (PK, UNIQUE y FK) para acelerar la carga.
--
--  Requiere una base recien creada: 01_schema.sql + 02_seed.sql y nada mas.
--  Se ejecuta con database/dataset/cargar.sh (ver docs/SCRUM-35-dataset-6m.md).
--
--  Todo lo "aleatorio" sale de ds_rand(id, sal), una funcion hash
--  determinista: el dataset es identico en cada ejecucion.
--
--  Nota de rendimiento: todas las funciones ds_* son una UNICA expresion
--  (SELECT sin FROM) e IMMUTABLE, para que PostgreSQL las expanda en linea
--  (inlining) dentro de los INSERT y no pague una llamada por fila.
-- =====================================================================

\set ON_ERROR_STOP on
\timing on

BEGIN;

-- ---------------------------------------------------------------------
-- 1. Validaciones previas: la base tiene que tener SOLO las filas del seed
-- ---------------------------------------------------------------------
DO $$
DECLARE
    v_esperado CONSTANT jsonb := '{"usuarios":3,"usuario_roles":3,"roles":3,"ejercicios":3,
                                   "rutinas":1,"rutina_ejercicios":3,"suscripciones":1,
                                   "tarifas":2,"pagos":1}';
    v_tabla text;
    v_cant  bigint;
BEGIN
    FOR v_tabla IN SELECT jsonb_object_keys(v_esperado) LOOP
        EXECUTE format('SELECT count(*) FROM %I', v_tabla) INTO v_cant;
        IF v_cant <> (v_esperado ->> v_tabla)::bigint THEN
            RAISE EXCEPTION 'La tabla % tiene % filas y se esperaban % (solo el seed). '
                            'Base ya cargada o modificada: recrearla con '
                            '"docker compose --profile dev down -v && docker compose --profile dev up -d".',
                            v_tabla, v_cant, v_esperado ->> v_tabla;
        END IF;
    END LOOP;

    -- Los ids del seed tienen que ser los de 02_seed.sql (los generados arrancan despues).
    IF (SELECT max(id) FROM usuarios) <> 3 OR (SELECT max(id) FROM ejercicios) <> 3
       OR (SELECT max(id) FROM rutinas) <> 1 OR (SELECT max(id) FROM suscripciones) <> 1
       OR (SELECT max(id) FROM tarifas) <> 2 OR (SELECT max(id) FROM pagos) <> 1
       OR (SELECT max(id) FROM roles) <> 3 THEN
        RAISE EXCEPTION 'Los ids del seed no coinciden con database/02_seed.sql.';
    END IF;
END $$;

-- ---------------------------------------------------------------------
-- 2. Funciones auxiliares deterministas (se borran en 03_restaurar_indices.sql)
-- ---------------------------------------------------------------------

-- Numero pseudoaleatorio en [0, 1) a partir de (id, sal). Usa 52 bits del hash:
-- nunca devuelve 1.0. Mismo (id, sal) -> mismo valor, siempre.
CREATE OR REPLACE FUNCTION ds_rand(p_id bigint, p_sal int) RETURNS double precision
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT ((hashint8extended(p_id, p_sal::bigint) & 9223372036854775807) >> 11)::double precision
           / 4503599627370496.0
$$;

-- Elemento de un arreglo elegido por hash.
CREATE OR REPLACE FUNCTION ds_pick(p_arr text[], p_id bigint, p_sal int) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT p_arr[1 + floor(ds_rand(p_id, p_sal) * array_length(p_arr, 1))::int]
$$;

-- Fecha de corte del dataset (fija, para que sea reproducible: no usa now()).
CREATE OR REPLACE FUNCTION ds_corte() RETURNS date
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT date '2026-11-13' $$;

-- Mes "n" del dataset: 0 = enero 2021 ... 70 = noviembre 2026.
CREATE OR REPLACE FUNCTION ds_mes_fecha(p_mes int) RETURNS date
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT (date '2021-01-01' + make_interval(months => p_mes))::date
$$;

-- Reparto padre -> hijos por bloques. Dentro de cada bloque de "tam" padres
-- la posicion se rota por hash, para que el patron no quede pegado a los ids.
--   ds_pos: indice de padre -> posicion dentro de su bloque
--   ds_idx: (bloque, posicion) -> indice de padre (inversa de ds_pos)
CREATE OR REPLACE FUNCTION ds_pos(p_i bigint, p_tam int, p_sal int) RETURNS int
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT (((p_i % p_tam) + floor(ds_rand(p_i / p_tam, p_sal) * p_tam)::bigint) % p_tam)::int
$$;

CREATE OR REPLACE FUNCTION ds_idx(p_bloque bigint, p_pos int, p_tam int, p_sal int) RETURNS bigint
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT p_bloque * p_tam
           + ((p_pos - floor(ds_rand(p_bloque, p_sal) * p_tam)::int + p_tam) % p_tam)
$$;

-- ---------- Usuarios (ids 4..6.000.000) ----------
-- Rol por id: id % 1000 = 0 -> admin (0,1 %); 1..15 -> entrenador (1,5 %); resto socio.
CREATE OR REPLACE FUNCTION ds_rol(p_uid bigint) RETURNS int
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE WHEN p_uid % 1000 = 0  THEN 1
                WHEN p_uid % 1000 <= 15 THEN 2
                ELSE 3 END
$$;

-- Elige por hash un SOCIO generado (ids 4..5.999.999). Si el candidato es
-- admin/entrenador se corre 16 lugares, que siempre cae en socio.
CREATE OR REPLACE FUNCTION ds_socio(p_x bigint, p_sal int) RETURNS bigint
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT 4 + floor(ds_rand(p_x, p_sal) * 5999980)::bigint
           + CASE WHEN (4 + floor(ds_rand(p_x, p_sal) * 5999980)::bigint) % 1000 <= 15 THEN 16 ELSE 0 END
$$;

-- Mes de alta del usuario (0..70), sesgado a lo reciente con sqrt: simula el
-- crecimiento del gimnasio (mas altas en 2025-2026 que en 2021).
CREATE OR REPLACE FUNCTION ds_mes_alta(p_uid bigint) RETURNS int
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT least(70, floor(sqrt(ds_rand(p_uid, 11)) * 71)::int)
$$;

-- ---------- Suscripciones (indice i = id - 2; 5.999.999 generadas) ----------
-- Bloques de 10: posiciones 0-1 'baja' (0 cuotas), 2-8 'mensual' (1 cuota),
-- 9 'trimestral' (3 cuotas) -> 10 tarifas cada 10 suscripciones.
-- Cola (i >= 5.999.990, bloque incompleto de 9): 8 'mensual' + 1 'baja', asi
-- las tarifas generadas son exactamente 5.999.998.
CREATE OR REPLACE FUNCTION ds_sub_tipo(p_i bigint) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN p_i >= 5999998 THEN 'baja'
        WHEN p_i >= 5999990 THEN 'mensual'
        ELSE (ARRAY['baja','baja','mensual','mensual','mensual','mensual',
                    'mensual','mensual','mensual','trimestral'])[ds_pos(p_i, 10, 30) + 1]
    END
$$;

CREATE OR REPLACE FUNCTION ds_sub_usuario(p_i bigint) RETURNS bigint
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT ds_socio(p_i, 41) $$;

-- Ultimo mes en que puede empezar: las trimestrales tienen que terminar a mas
-- tardar en noviembre 2026 (mes 70).
CREATE OR REPLACE FUNCTION ds_sub_mes_max(p_i bigint) RETURNS int
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE WHEN ds_sub_tipo(p_i) = 'trimestral' THEN 68 ELSE 70 END
$$;

-- Mes de inicio: entre el alta del socio y el ultimo mes posible.
CREATE OR REPLACE FUNCTION ds_sub_mes(p_i bigint) RETURNS int
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT least(ds_mes_alta(ds_sub_usuario(p_i)), ds_sub_mes_max(p_i))
           + floor(ds_rand(p_i, 42)
                   * (ds_sub_mes_max(p_i) - least(ds_mes_alta(ds_sub_usuario(p_i)), ds_sub_mes_max(p_i)) + 1))::int
$$;

-- Precio mensual del plan: Basico 40 %, Estandar 30 %, Full 20 %, Premium 10 %,
-- ajustado por inflacion segun el anio de inicio (indice 2021 = 1,0 ... 2026 = 13,5);
-- trimestral con 10 % de descuento; redondeado a $500.
CREATE OR REPLACE FUNCTION ds_sub_precio(p_i bigint) RETURNS int
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT (round(
              (CASE WHEN ds_rand(p_i, 43) < 0.4 THEN 2000
                    WHEN ds_rand(p_i, 43) < 0.7 THEN 2600
                    WHEN ds_rand(p_i, 43) < 0.9 THEN 3200
                    ELSE 4000 END)
            * (ARRAY[1.0, 1.9, 4.5, 9.0, 11.5, 13.5])[1 + ds_sub_mes(p_i) / 12]
            * (CASE WHEN ds_sub_tipo(p_i) = 'trimestral' THEN 0.9 ELSE 1.0 END)
            / 500) * 500)::int
$$;

-- ---------- Tarifas (indice k = id - 3; 5.999.998 generadas) ----------
-- Tarifa k -> suscripcion (indice) y numero de cuota (0..2) dentro de ella.
CREATE OR REPLACE FUNCTION ds_tarifa_sub(p_k bigint) RETURNS bigint
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE WHEN p_k >= 5999990 THEN p_k
                ELSE ds_idx(p_k / 10,
                            CASE WHEN p_k % 10 < 7 THEN (p_k % 10)::int + 2 ELSE 9 END,
                            10, 30)
           END
$$;

CREATE OR REPLACE FUNCTION ds_tarifa_cuota(p_k bigint) RETURNS int
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE WHEN p_k >= 5999990 OR p_k % 10 < 7 THEN 0 ELSE (p_k % 10)::int - 7 END
$$;

-- Cantidad de pagos de la tarifa. Bloques de 5: posicion 0 impaga (0 pagos),
-- 1-3 con un pago, 4 pagada en dos partes -> 5 pagos cada 5 tarifas.
-- Cola (k >= 5.999.995, bloque incompleto de 3): la primera en dos partes y
-- las otras dos con un pago, asi los pagos generados son exactamente 5.999.999.
CREATE OR REPLACE FUNCTION ds_tarifa_npagos(p_k bigint) RETURNS int
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN p_k = 5999995 THEN 2
        WHEN p_k > 5999995 THEN 1
        ELSE (ARRAY[0, 1, 1, 1, 2])[ds_pos(p_k, 5, 50) + 1]
    END
$$;

-- ---------- Pagos (indice k = id - 2; 5.999.999 generados) ----------
-- Pago k -> tarifa (indice) y parte (1 o 2). Total de partes = ds_tarifa_npagos(tarifa).
CREATE OR REPLACE FUNCTION ds_pago_tarifa(p_k bigint) RETURNS bigint
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN p_k >= 5999997 THEN p_k - 1
        WHEN p_k >= 5999995 THEN 5999995
        ELSE ds_idx(p_k / 5, CASE WHEN p_k % 5 < 3 THEN (p_k % 5)::int + 1 ELSE 4 END, 5, 50)
    END
$$;

CREATE OR REPLACE FUNCTION ds_pago_parte(p_k bigint) RETURNS int
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN p_k >= 5999997 THEN 1
        WHEN p_k >= 5999995 THEN (p_k - 5999995)::int + 1
        WHEN p_k % 5 < 3    THEN 1
        ELSE (p_k % 5)::int - 2
    END
$$;

-- ---------- Rutinas (indice r = id - 2; 5.999.999 generadas) ----------
-- Bloques de 20: posiciones 0-4 borrador (0 ejercicios), 5-15 con 1,
-- 16-18 con 2, 19 con 3 -> 20 filas de rutina_ejercicios cada 20 rutinas.
-- Cola (r >= 5.999.980, bloque incompleto de 19): 17 con 1 ejercicio y
-- 2 borradores, asi rutina_ejercicios generadas son exactamente 5.999.997.
CREATE OR REPLACE FUNCTION ds_rutina_nej(p_r bigint) RETURNS int
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN p_r >= 5999997 THEN 0
        WHEN p_r >= 5999980 THEN 1
        ELSE (ARRAY[0,0,0,0,0, 1,1,1,1,1,1,1,1,1,1,1, 2,2,2, 3])[ds_pos(p_r, 20, 60) + 1]
    END
$$;

-- Fila k de rutina_ejercicios -> rutina (indice) y orden j (0..2) del ejercicio.
CREATE OR REPLACE FUNCTION ds_re_rutina(p_k bigint) RETURNS bigint
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN p_k >= 5999980 THEN p_k
        ELSE ds_idx(p_k / 20,
                    (ARRAY[5,6,7,8,9,10,11,12,13,14,15, 16,16,17,17,18,18, 19,19,19])[(p_k % 20)::int + 1],
                    20, 60)
    END
$$;

CREATE OR REPLACE FUNCTION ds_re_orden(p_k bigint) RETURNS int
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN p_k >= 5999980 THEN 0
        ELSE (ARRAY[0,0,0,0,0,0,0,0,0,0,0, 0,1,0,1,0,1, 0,1,2])[(p_k % 20)::int + 1]
    END
$$;

-- ---------------------------------------------------------------------
-- 3. Baja de restricciones de las 7 tablas que se cargan.
--    Primero todas las FK (dependen de las PK) y despues UNIQUE y PK.
--    Se buscan en el catalogo, asi funciona aunque la base la haya creado
--    Sequelize con otros nombres. 03_restaurar_indices.sql las recrea con
--    los nombres de 01_schema.sql. roles y ejercicios conservan su PK.
-- ---------------------------------------------------------------------
DO $$
DECLARE
    v_tablas CONSTANT text[] := ARRAY['usuarios','usuario_roles','rutinas','rutina_ejercicios',
                                      'suscripciones','tarifas','pagos'];
    r record;
BEGIN
    FOR r IN SELECT c.conrelid::regclass AS tabla, c.conname
             FROM pg_constraint c
             WHERE c.contype = 'f' AND c.connamespace = 'public'::regnamespace
    LOOP
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.tabla, r.conname);
        RAISE NOTICE 'FK eliminada: %.%', r.tabla, r.conname;
    END LOOP;

    FOR r IN SELECT c.conrelid::regclass AS tabla, c.conname
             FROM pg_constraint c
             JOIN pg_class t ON t.oid = c.conrelid
             WHERE c.contype IN ('u', 'p') AND c.connamespace = 'public'::regnamespace
               AND t.relname = ANY (v_tablas)
    LOOP
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.tabla, r.conname);
        RAISE NOTICE 'PK/UNIQUE eliminada: %.%', r.tabla, r.conname;
    END LOOP;

    -- Si queda algun indice suelto es porque alguien cambio el esquema: se
    -- aborta (y se deshace todo lo anterior) en vez de cargar con indices vivos.
    FOR r IN SELECT i.indexrelid::regclass AS indice
             FROM pg_index i
             JOIN pg_class t ON t.oid = i.indrelid
             JOIN pg_namespace n ON n.oid = t.relnamespace
             WHERE n.nspname = 'public' AND t.relname = ANY (v_tablas)
    LOOP
        RAISE EXCEPTION 'Indice no esperado %: el script solo contempla el esquema de 01_schema.sql.', r.indice;
    END LOOP;
END $$;

COMMIT;
