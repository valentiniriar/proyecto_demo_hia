-- =====================================================================
--  Migración 001 — Índices de optimización confirmados en SCRUM-39 / SCRUM-42
--
--  Se aplica sobre una base EXISTENTE (por ejemplo producción, con el dataset de 6M):
--     docker exec -i gymhub_db_prod psql -X -v ON_ERROR_STOP=1 -U <DB_USER> -d <DB_NAME> \
--         -f - < database/migraciones/001_indices_optimizacion.sql
--  Va DESPUÉS de cargar el dataset (database/dataset/cargar.sh). No se agrega a 01_schema.sql a
--  propósito: dataset/01_preparar.sql aborta si encuentra índices que no son del esquema, para no
--  cargar 6M filas manteniendo índices vivos (sería mucho más lento).
--
--  Idempotente (IF NOT EXISTS). CONCURRENTLY: no bloquea las escrituras de la app mientras se
--  construyen, pero no puede correr dentro de una transacción (este archivo no usa BEGIN).
--  Se crean en la primaria y llegan a la réplica por la replicación (WAL).
--
--  Por qué estos y no otros (detalle y mediciones en
--  docs/evidencias/SCRUM-39/comparativa-indices-consultas.md y docs/SCRUM-39.1-explicacion-indices.md):
--    - Las FK de PostgreSQL NO crean índice en la columna hija: sin ellos, "mis rutinas", "mis tarifas"
--      y las suscripciones de un socio recorren las 6M filas (Parallel Seq Scan, 1 a 2,5 s).
--    - pagos.transaccion: el backend busca por transacción para no registrar dos veces el mismo pago
--      de Mercado Pago; UNIQUE además lo garantiza en la base.
--    - Descartados por las mediciones: usuarios(estado) y usuario_roles(id_rol) (no llegan a la mitad
--      del tiempo o el planificador no los usa) y pagos(fecha, id) (la paginación ordena por id).
--      pagos("tarifaId") tampoco: la app nunca filtra pagos por tarifa.
-- =====================================================================
\set ON_ERROR_STOP on
\timing on

-- Un CREATE INDEX CONCURRENTLY que falla deja el índice INVALID: se detecta y se pide borrarlo.
DO $$
DECLARE v_invalidos text;
BEGIN
    SELECT string_agg(c.relname, ', ') INTO v_invalidos
    FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
    WHERE NOT i.indisvalid
      AND c.relname IN ('idx_rutinas_usuario', 'idx_suscripciones_usuario',
                        'idx_tarifas_suscripcion', 'uq_pagos_transaccion');
    IF v_invalidos IS NOT NULL THEN
        RAISE EXCEPTION 'Índices INVALID de una corrida anterior: %. Borrarlos (DROP INDEX CONCURRENTLY) y reintentar.', v_invalidos;
    END IF;
END $$;

\echo '==> idx_rutinas_usuario (mis rutinas, rutinas por socio)'
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_rutinas_usuario       ON rutinas       ("usuarioId");
\echo '==> idx_suscripciones_usuario (suscripciones de un socio)'
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_suscripciones_usuario ON suscripciones ("usuarioId");
\echo '==> idx_tarifas_suscripcion (mis tarifas: JOIN tarifas -> suscripciones)'
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tarifas_suscripcion   ON tarifas       ("suscripcionId");
\echo '==> uq_pagos_transaccion (pago ya registrado)'
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS uq_pagos_transaccion ON pagos (transaccion);

\echo '==> ANALYZE'
ANALYZE rutinas;
ANALYZE suscripciones;
ANALYZE tarifas;
ANALYZE pagos;

\echo '==> Índices creados'
SELECT c.relname AS indice, t.relname AS tabla, i.indisvalid AS valido,
       pg_size_pretty(pg_relation_size(c.oid)) AS tamanio
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_class t ON t.oid = i.indrelid
WHERE c.relname IN ('idx_rutinas_usuario', 'idx_suscripciones_usuario',
                    'idx_tarifas_suscripcion', 'uq_pagos_transaccion')
ORDER BY 1;
