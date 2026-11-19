-- =====================================================================
--  SCRUM-39.1 - Indices propuestos (docs/SCRUM-39.1-explicacion-indices.md)
--
--  Prioridad 1 (se crean siempre):
--    idx_rutinas_usuario, idx_suscripciones_usuario, idx_tarifas_suscripcion
--    uq_pagos_transaccion (o idx_pagos_transaccion si hay duplicados)
--  Condicionales (solo con -v condicionales=1, para medirlos en la comparativa):
--    idx_usuario_roles_rol, idx_usuarios_estado, idx_pagos_fecha_id
--
--  CREATE INDEX CONCURRENTLY no bloquea escrituras, pero NO puede correr
--  dentro de una transaccion: no usar psql -1 ni envolver en BEGIN/COMMIT.
--
--  Uso:
--    docker exec -i demo_hia_db_dev psql -X -U <user> -d <db> -f - < crear_indices.sql
--    docker exec -i demo_hia_db_dev psql -X -U <user> -d <db> -v condicionales=1 -f - < crear_indices.sql
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off
\timing on

-- Un CREATE INDEX CONCURRENTLY que fallo deja el indice INVALID, y
-- IF NOT EXISTS lo daria por creado. Se aborta antes de seguir.
DO $$
DECLARE
    v_invalidos text;
BEGIN
    SELECT string_agg(c.relname, ', ') INTO v_invalidos
    FROM pg_index i
    JOIN pg_class c ON c.oid = i.indexrelid
    WHERE NOT i.indisvalid
      AND c.relname IN ('idx_rutinas_usuario', 'idx_suscripciones_usuario', 'idx_tarifas_suscripcion',
                        'uq_pagos_transaccion', 'idx_pagos_transaccion',
                        'idx_usuario_roles_rol', 'idx_usuarios_estado', 'idx_pagos_fecha_id');
    IF v_invalidos IS NOT NULL THEN
        RAISE EXCEPTION 'Indices INVALID de una corrida anterior: %. Borrarlos con eliminar_indices.sql y reintentar.', v_invalidos;
    END IF;
END $$;

-- ===== Prioridad 1: FK de las consultas por usuario (C1, C2, C3) =====
\echo '==> idx_rutinas_usuario'
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_rutinas_usuario       ON rutinas       ("usuarioId");
\echo '==> idx_suscripciones_usuario'
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_suscripciones_usuario ON suscripciones ("usuarioId");
\echo '==> idx_tarifas_suscripcion'
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tarifas_suscripcion   ON tarifas       ("suscripcionId");

-- ===== Prioridad 1: control de pago duplicado (pago.controller.js:78) =====
-- UNIQUE solo si hoy no hay duplicados (los pagos manuales cargan transaccion a mano).
SELECT EXISTS (SELECT 1 FROM pagos GROUP BY transaccion HAVING count(*) > 1) AS hay_duplicados \gset
\if :hay_duplicados
    \echo 'AVISO: pagos.transaccion tiene duplicados. Se crea un indice NO unico (idx_pagos_transaccion).'
    \echo '       Listarlos: SELECT transaccion, count(*) FROM pagos GROUP BY transaccion HAVING count(*) > 1;'
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_pagos_transaccion ON pagos (transaccion);
\else
    \echo '==> uq_pagos_transaccion'
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS uq_pagos_transaccion ON pagos (transaccion);
\endif

-- ===== Condicionales: solo para medir (ver criterio de decision en la comparativa) =====
\if :{?condicionales}
    \echo '==> [condicional] idx_usuario_roles_rol (C7 dashboard por rol)'
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_usuario_roles_rol ON usuario_roles (id_rol);
    \echo '==> [condicional] idx_usuarios_estado (C6 dashboard por estado)'
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_usuarios_estado   ON usuarios (estado);
    \echo '==> [condicional] idx_pagos_fecha_id (C8 pagos por rango, paginado)'
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_pagos_fecha_id    ON pagos (fecha, id);
\else
    \echo '(condicionales omitidos: pasar -v condicionales=1 para crearlos)'
\endif

\timing off
\echo '==> Indices creados'
SELECT c.relname AS tabla, i.relname AS indice, pg_size_pretty(pg_relation_size(i.oid)) AS tamanio
FROM pg_index x
JOIN pg_class i ON i.oid = x.indexrelid
JOIN pg_class c ON c.oid = x.indrelid
WHERE i.relname IN ('idx_rutinas_usuario', 'idx_suscripciones_usuario', 'idx_tarifas_suscripcion',
                    'uq_pagos_transaccion', 'idx_pagos_transaccion',
                    'idx_usuario_roles_rol', 'idx_usuarios_estado', 'idx_pagos_fecha_id')
ORDER BY c.relname, i.relname;
