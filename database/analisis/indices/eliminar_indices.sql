-- =====================================================================
--  SCRUM-39.1 - Borra los indices de crear_indices.sql
--  Deja la base como en SCRUM-39 (solo PK y UNIQUE) para medir "sin indice".
--  Con -v solo_condicionales=1 borra solo los condicionales y deja los de
--  prioridad 1 (estado final despues de la comparativa).
--
--  DROP INDEX CONCURRENTLY no puede correr dentro de una transaccion.
--  Uso:
--    docker exec -i demo_hia_db_dev psql -X -U <user> -d <db> -f - < eliminar_indices.sql
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

DROP INDEX CONCURRENTLY IF EXISTS idx_usuario_roles_rol;
DROP INDEX CONCURRENTLY IF EXISTS idx_usuarios_estado;
DROP INDEX CONCURRENTLY IF EXISTS idx_pagos_fecha_id;

\if :{?solo_condicionales}
    \echo '==> Condicionales borrados; se conservan los de prioridad 1'
\else
    DROP INDEX CONCURRENTLY IF EXISTS idx_rutinas_usuario;
    DROP INDEX CONCURRENTLY IF EXISTS idx_suscripciones_usuario;
    DROP INDEX CONCURRENTLY IF EXISTS idx_tarifas_suscripcion;
    DROP INDEX CONCURRENTLY IF EXISTS uq_pagos_transaccion;
    DROP INDEX CONCURRENTLY IF EXISTS idx_pagos_transaccion;
    \echo '==> Todos los indices de SCRUM-39.1 borrados'
\endif
