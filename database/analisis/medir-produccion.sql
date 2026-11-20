-- Mediciones de las consultas lentas detectadas con el dataset de 6M en producción (SCRUM-42).
-- Solo lectura: se corre contra una RÉPLICA, que es de donde lee el backend. Con Patroni, el puerto 5433
-- de HAProxy lleva a una réplica (o al líder si no hay ninguna):
--   docker exec -i -e PGPASSWORD=<DB_PASS> gymhub_pg_1_prod psql -X -h db -p 5433 -U <DB_USER> -d <DB_NAME> -f - < database/analisis/medir-produccion.sql
-- (antes de Patroni, el 20/11/2026: docker exec -i gymhub_db_replica_prod psql ...)
\pset pager off
\timing on
-- Socio de ejemplo: el usuario demo (id 3) y uno generado.
\echo '==> M1 Mis rutinas (rutinas por usuarioId)'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) SELECT * FROM rutinas WHERE "usuarioId" = 3;
\echo '==> M2 Mis tarifas (tarifas de las suscripciones de un usuario)'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT t.* FROM tarifas t JOIN suscripciones s ON s.id = t."suscripcionId" WHERE s."usuarioId" = 3;
\echo '==> M3 Suscripciones de un usuario'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) SELECT * FROM suscripciones WHERE "usuarioId" = 1234567;
\echo '==> M4 Pagos de una tarifa'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) SELECT * FROM pagos WHERE "tarifaId" = 1234567;
\echo '==> M5 Dashboard: usuarios activos (como hoy: dos COUNT separados)'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) SELECT count(*) FROM usuarios WHERE estado = true;
\echo '==> M6 Dashboard: ingresos (SUM de tarifas pagadas y activas)'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) SELECT sum(precio::numeric) FROM tarifas WHERE pagado AND activo;
\echo '==> M7 Dashboard: usuarios por rol'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) SELECT id_rol, count(id_usuario) FROM usuario_roles GROUP BY id_rol;
\echo '==> M8 Dashboard: activos e inactivos en UNA pasada (FILTER)'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) SELECT count(*) FILTER (WHERE estado), count(*) FILTER (WHERE NOT estado) FROM usuarios;
