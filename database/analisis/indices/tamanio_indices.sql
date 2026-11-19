-- =====================================================================
--  SCRUM-39.1 - Tamano de tablas e indices, y uso de cada indice
--  Uso:
--    docker exec -i demo_hia_db_dev psql -X -U <user> -d <db> -f - < tamanio_indices.sql
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

\echo '==> Tablas: heap, indices y total'
SELECT relname AS tabla,
       pg_size_pretty(pg_relation_size(relid))       AS heap,
       pg_size_pretty(pg_indexes_size(relid))        AS indices,
       pg_size_pretty(pg_total_relation_size(relid)) AS total
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(relid) DESC;

\echo '==> Indices: tamano y cantidad de escaneos'
SELECT relname AS tabla, indexrelname AS indice,
       pg_size_pretty(pg_relation_size(indexrelid)) AS tamanio,
       pg_relation_size(indexrelid) AS bytes,
       idx_scan
FROM pg_stat_user_indexes
WHERE schemaname = 'public'
ORDER BY relname, pg_relation_size(indexrelid) DESC;

\echo '==> Base completa'
SELECT pg_size_pretty(pg_database_size(current_database())) AS base;
