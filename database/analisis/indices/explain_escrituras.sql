-- =====================================================================
--  SCRUM-39.1 - Comparativa sin indice / con indice: ESCRITURAS
--  Mide el costo de mantener los indices (INSERT / UPDATE) y el beneficio
--  en los borrados con FK (ON DELETE SET NULL / CASCADE).
--
--  EXPLAIN ANALYZE de un INSERT/UPDATE/DELETE SI lo ejecuta: cada prueba
--  va en BEGIN ... ROLLBACK, asi que no queda ningun cambio. Deja tuplas
--  muertas: comparar.sh corre VACUUM al final.
--  WAL: muestra los bytes de WAL generados (cada indice extra suma WAL).
--
--  Variables: uid (usuario a borrar), sid (una suscripcion de ese usuario), corrida.
--  Uso:
--    docker exec -i demo_hia_db_dev psql -X -U <user> -d <db> -v uid=21037 -v sid=123 -v corrida=1 -f - < explain_escrituras.sql
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

-- 100.000 cuotas nuevas: tarifas tiene 1 indice (PK) sin, 2 con (+ idx_tarifas_suscripcion).
\echo '######## E1 | INSERT 100k tarifas |' corrida :corrida
BEGIN;
EXPLAIN (ANALYZE, BUFFERS, WAL) INSERT INTO tarifas (anio, mes, precio, pagado, activo, "suscripcionId")
SELECT '2027', '01', '15000', false, true, g FROM generate_series(2, 100001) AS g;
ROLLBACK;

-- 100.000 pagos nuevos: pagos tiene 1 indice sin, 2 o 3 con (+ transaccion, + fecha/id).
\echo '######## E2 | INSERT 100k pagos |' corrida :corrida
BEGIN;
EXPLAIN (ANALYZE, BUFFERS, WAL) INSERT INTO pagos (fecha, transaccion, monto, activo, "tarifaId")
SELECT '2027-01-' || lpad((1 + g % 28)::text, 2, '0'), 'TEST-' || g, '15000', true, g FROM generate_series(3, 100002) AS g;
ROLLBACK;

-- 100.000 UPDATE de pagado (lo que hacen crear y anular pago). pagado no esta
-- indexado, pero con fillfactor 100 las paginas no tienen lugar para HOT:
-- la fila nueva va a otra pagina y se actualizan TODOS los indices de tarifas.
\echo '######## E3 | UPDATE pagado 100k tarifas |' corrida :corrida
BEGIN;
EXPLAIN (ANALYZE, BUFFERS, WAL) UPDATE tarifas SET pagado = NOT pagado WHERE id BETWEEN 1000000 AND 1099999;
ROLLBACK;

-- Borrar un usuario: ON DELETE SET NULL en rutinas y suscripciones, CASCADE en usuario_roles.
-- Ver las lineas "Trigger for constraint ...": sin indice cada una es un seq scan de 6M filas.
\echo '######## E4 | DELETE usuario (FK SET NULL) |' corrida :corrida
BEGIN;
EXPLAIN (ANALYZE, BUFFERS, WAL) DELETE FROM usuarios WHERE id = :uid;
ROLLBACK;

-- Borrar una suscripcion: ON DELETE SET NULL en tarifas."suscripcionId".
\echo '######## E5 | DELETE suscripcion (FK SET NULL) |' corrida :corrida
BEGIN;
EXPLAIN (ANALYZE, BUFFERS, WAL) DELETE FROM suscripciones WHERE id = :sid;
ROLLBACK;
