-- =====================================================================
--  SCRUM-39.1 - Comparativa sin indice / con indice: LECTURAS
--  Mismo SQL que genera Sequelize (ver explain_candidatas.sql), mas las
--  variantes reescritas o paginadas que proponen SCRUM-39 y SCRUM-39.1.
--  Un EXPLAIN por encabezado: comparar.sh extrae "Execution Time" por id.
--
--  Variables: uid (socio de la muestra), corrida (1, 2, 3).
--  Uso:
--    docker exec -i demo_hia_db_dev psql -X -U <user> -d <db> -v uid=21037 -v corrida=1 -f - < explain_lecturas.sql
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

-- ---------- Indices de prioridad 1 ----------

\echo '######## L1 | C1 mis-rutinas |' corrida :corrida
EXPLAIN (ANALYZE, BUFFERS) SELECT "Rutina"."id", "Rutina"."dia_semana", "Rutina"."turno", "Rutina"."nombre", "Rutina"."descripcion", "Rutina"."activo", "Rutina"."createdAt", "Rutina"."updatedAt", "Rutina"."usuarioId", "ejercicios"."id" AS "ejercicios.id", "ejercicios"."nombre" AS "ejercicios.nombre", "ejercicios"."descripcion" AS "ejercicios.descripcion", "ejercicios"."youtube_url" AS "ejercicios.youtube_url", "ejercicios"."activo" AS "ejercicios.activo" FROM "rutinas" AS "Rutina" LEFT OUTER JOIN ( "rutina_ejercicios" AS "ejercicios->RutinaEjercicio" INNER JOIN "ejercicios" AS "ejercicios" ON "ejercicios"."id" = "ejercicios->RutinaEjercicio"."id_ejercicio") ON "Rutina"."id" = "ejercicios->RutinaEjercicio"."id_rutina" WHERE "Rutina"."usuarioId" = :uid;

\echo '######## L2 | C2 mis-tarifas |' corrida :corrida
EXPLAIN (ANALYZE, BUFFERS) SELECT "Tarifa"."id", "Tarifa"."anio", "Tarifa"."mes", "Tarifa"."precio", "Tarifa"."pagado", "Tarifa"."activo", "Tarifa"."createdAt", "Tarifa"."updatedAt", "Tarifa"."suscripcionId", "suscripcion"."id" AS "suscripcion.id", "suscripcion"."fecha_inicio" AS "suscripcion.fecha_inicio", "suscripcion"."fecha_fin" AS "suscripcion.fecha_fin", "suscripcion"."precio" AS "suscripcion.precio", "suscripcion"."activo" AS "suscripcion.activo" FROM "tarifas" AS "Tarifa" INNER JOIN "suscripciones" AS "suscripcion" ON "Tarifa"."suscripcionId" = "suscripcion"."id" AND "suscripcion"."usuarioId" = :uid ORDER BY "Tarifa"."anio" DESC, "Tarifa"."mes" DESC;

\echo '######## L3 | C3 impagas por usuario |' corrida :corrida
EXPLAIN (ANALYZE, BUFFERS) SELECT "Tarifa"."id", "Tarifa"."anio", "Tarifa"."mes", "Tarifa"."precio", "Tarifa"."pagado", "Tarifa"."activo", "Tarifa"."createdAt", "Tarifa"."updatedAt", "Tarifa"."suscripcionId", "suscripcion"."id" AS "suscripcion.id", "suscripcion"."fecha_inicio" AS "suscripcion.fecha_inicio", "suscripcion"."fecha_fin" AS "suscripcion.fecha_fin", "suscripcion"."precio" AS "suscripcion.precio", "suscripcion"."activo" AS "suscripcion.activo", "suscripcion->usuario"."id" AS "suscripcion.usuario.id", "suscripcion->usuario"."apellido" AS "suscripcion.usuario.apellido", "suscripcion->usuario"."nombre" AS "suscripcion.usuario.nombre", "suscripcion->usuario"."email" AS "suscripcion.usuario.email" FROM "tarifas" AS "Tarifa" INNER JOIN "suscripciones" AS "suscripcion" ON "Tarifa"."suscripcionId" = "suscripcion"."id" AND "suscripcion"."usuarioId" = :uid LEFT OUTER JOIN "usuarios" AS "suscripcion->usuario" ON "suscripcion"."usuarioId" = "suscripcion->usuario"."id" WHERE "Tarifa"."pagado" = false AND "Tarifa"."activo" = true ORDER BY "Tarifa"."anio" ASC, "Tarifa"."mes" ASC;

-- pago.controller.js:78 (Pago.findOne agrega LIMIT 1). Transaccion inexistente:
-- es el caso normal (un pago nuevo) y el peor para un seq scan, que recorre toda la tabla.
\echo '######## L4 | pago duplicado MercadoPago |' corrida :corrida
EXPLAIN (ANALYZE, BUFFERS) SELECT "id", "fecha", "transaccion", "monto", "activo", "createdAt", "updatedAt", "tarifaId" FROM "pagos" AS "Pago" WHERE "Pago"."transaccion" = 'MP-9999999999' LIMIT 1;

-- ---------- Indices condicionales ----------

\echo '######## L5 | C6 usuarios activos (count original) |' corrida :corrida
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) AS "count" FROM "usuarios" AS "Usuario" WHERE "Usuario"."estado" = true;

\echo '######## L6 | C6 usuarios por estado (GROUP BY reescrita) |' corrida :corrida
EXPLAIN (ANALYZE, BUFFERS) SELECT "estado", count(*) AS "count" FROM "usuarios" AS "Usuario" GROUP BY "estado";

\echo '######## L7 | C7 usuarios por rol |' corrida :corrida
EXPLAIN (ANALYZE, BUFFERS) SELECT "id_rol", COUNT("id_usuario") AS "total" FROM "usuario_roles" AS "UsuarioRol" GROUP BY "id_rol";

\echo '######## L8 | C8 pagos de un mes (sin paginar) |' corrida :corrida
EXPLAIN (ANALYZE, BUFFERS) SELECT "Pago"."id", "Pago"."fecha", "Pago"."transaccion", "Pago"."monto", "Pago"."activo", "Pago"."createdAt", "Pago"."updatedAt", "Pago"."tarifaId", "tarifa"."id" AS "tarifa.id", "tarifa"."anio" AS "tarifa.anio", "tarifa"."mes" AS "tarifa.mes", "tarifa"."precio" AS "tarifa.precio", "tarifa"."activo" AS "tarifa.activo" FROM "pagos" AS "Pago" LEFT OUTER JOIN "tarifas" AS "tarifa" ON "Pago"."tarifaId" = "tarifa"."id" WHERE "Pago"."fecha" BETWEEN '2026-10-01' AND '2026-10-31' ORDER BY "Pago"."fecha" ASC;

\echo '######## L9 | C8 pagos de un mes, primera pagina (LIMIT 50) |' corrida :corrida
EXPLAIN (ANALYZE, BUFFERS) SELECT "Pago"."id", "Pago"."fecha", "Pago"."transaccion", "Pago"."monto", "Pago"."activo", "Pago"."createdAt", "Pago"."updatedAt", "Pago"."tarifaId", "tarifa"."id" AS "tarifa.id", "tarifa"."anio" AS "tarifa.anio", "tarifa"."mes" AS "tarifa.mes", "tarifa"."precio" AS "tarifa.precio", "tarifa"."activo" AS "tarifa.activo" FROM "pagos" AS "Pago" LEFT OUTER JOIN "tarifas" AS "tarifa" ON "Pago"."tarifaId" = "tarifa"."id" WHERE "Pago"."fecha" BETWEEN '2026-10-01' AND '2026-10-31' ORDER BY "Pago"."fecha" ASC, "Pago"."id" ASC LIMIT 50;

-- Pagina intermedia con keyset: (fecha, id) > ultimo visto. id = 0 equivale a "desde el 15/10".
\echo '######## L10 | C8 pagos de un mes, pagina keyset (15/10) |' corrida :corrida
EXPLAIN (ANALYZE, BUFFERS) SELECT "Pago"."id", "Pago"."fecha", "Pago"."transaccion", "Pago"."monto", "Pago"."activo", "Pago"."createdAt", "Pago"."updatedAt", "Pago"."tarifaId", "tarifa"."id" AS "tarifa.id", "tarifa"."anio" AS "tarifa.anio", "tarifa"."mes" AS "tarifa.mes", "tarifa"."precio" AS "tarifa.precio", "tarifa"."activo" AS "tarifa.activo" FROM "pagos" AS "Pago" LEFT OUTER JOIN "tarifas" AS "tarifa" ON "Pago"."tarifaId" = "tarifa"."id" WHERE ("Pago"."fecha", "Pago"."id") > ('2026-10-15', 0) AND "Pago"."fecha" <= '2026-10-31' ORDER BY "Pago"."fecha" ASC, "Pago"."id" ASC LIMIT 50;

-- ---------- Control: no deberia cambiar (usa indices que ya existian) ----------

\echo '######## L11 | control: C4 socios paginado (keyset por id) |' corrida :corrida
EXPLAIN (ANALYZE, BUFFERS) SELECT "Usuario"."id", "Usuario"."nombre", "Usuario"."apellido", "Usuario"."dni", "Usuario"."email", "Usuario"."google_id", "Usuario"."estado" FROM "usuarios" AS "Usuario" INNER JOIN ( "usuario_roles" AS "roles->UsuarioRol" INNER JOIN "roles" AS "roles" ON "roles"."id" = "roles->UsuarioRol"."id_rol") ON "Usuario"."id" = "roles->UsuarioRol"."id_usuario" AND "roles"."nombre" = 'socio' WHERE "Usuario"."estado" = true AND "Usuario"."id" > 3000000 ORDER BY "Usuario"."id" ASC LIMIT 50;
