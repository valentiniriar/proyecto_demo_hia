-- =====================================================================
--  SCRUM-35 - Dataset de prueba
--  Paso 2/4: generacion masiva con INSERT ... SELECT generate_series.
--
--  Orden: padres antes que hijos. Los ids generados arrancan despues de los
--  del seed y terminan en 6.000.000, asi cada tabla de datos queda con
--  exactamente 6.000.000 filas (seed incluido). ejercicios llega a 200.
--
--  Las subconsultas con "OFFSET 0" son a proposito: evitan que el planificador
--  las aplane, asi cada valor intermedio se calcula una sola vez por fila y
--  las funciones ds_* reciben columnas simples (condicion para el inlining).
--
--  Todo corre en una sola transaccion: si algo falla no queda carga a medias
--  (pero las restricciones siguen eliminadas por el paso 1: recrear la base).
-- =====================================================================

\set ON_ERROR_STOP on
\timing on

SET synchronous_commit = off;
SET work_mem = '64MB';
SET TimeZone = 'UTC';   -- las conversiones date -> timestamptz no dependen del servidor

BEGIN;

-- ---------------------------------------------------------------------
-- ejercicios: 197 nuevos (ids 4..200) -> total 200 (catalogo realista)
-- 40 ejercicios base x 5 variantes = 200 nombres distintos.
-- ---------------------------------------------------------------------
INSERT INTO ejercicios (id, nombre, descripcion, youtube_url, activo, "createdAt", "updatedAt")
SELECT id,
       base[1 + b] || ' ' || variante[1 + v],
       'Ejercicio de ' || grupo[1 + b] || ', ' || variante[1 + v] || '.',
       'https://www.youtube.com/watch?v=' || substr(md5('gymhub-ejercicio-' || id), 1, 11),
       ds_rand(id, 70) < 0.95,
       timestamptz '2021-01-04 10:00+00' + (id * interval '1 hour'),
       timestamptz '2021-01-04 10:00+00' + (id * interval '1 hour')
FROM (
    SELECT id, (id - 4) % 40 AS b, (id - 4) / 40 AS v,
           ARRAY['Sentadilla','Press de banca','Peso muerto','Press militar','Remo',
                 'Dominadas','Fondos','Curl de bíceps','Extensión de tríceps','Zancadas',
                 'Hip thrust','Prensa de piernas','Extensión de cuádriceps','Curl femoral','Elevación de talones',
                 'Press inclinado','Aperturas','Pullover','Jalón al pecho','Elevaciones laterales',
                 'Pájaros','Face pull','Encogimientos','Crunch','Plancha',
                 'Rueda abdominal','Russian twist','Elevación de piernas','Peso muerto rumano','Sentadilla búlgara',
                 'Step up','Puente de glúteos','Patada de glúteo','Abducción de cadera','Aducción de cadera',
                 'Remo al mentón','Press Arnold','Curl martillo','Press francés','Good morning'] AS base,
           ARRAY['piernas','pecho','espalda baja','hombros','espalda',
                 'espalda','tríceps','bíceps','tríceps','piernas',
                 'glúteos','piernas','cuádriceps','isquiotibiales','gemelos',
                 'pecho','pecho','espalda','espalda','hombros',
                 'hombros posteriores','hombros','trapecio','abdomen','core',
                 'core','oblicuos','abdomen','isquiotibiales','piernas',
                 'piernas','glúteos','glúteos','glúteo medio','aductores',
                 'hombros','hombros','bíceps','tríceps','espalda baja'] AS grupo,
           ARRAY['con mancuernas','en máquina','en polea','unilateral','con banda elástica'] AS variante
    FROM generate_series(4, 200) AS id
) s;

-- ---------------------------------------------------------------------
-- usuarios: 5.999.997 (ids 4..6.000.000)
--   dni   = 20.000.000 + id  -> unico por construccion, rango realista
--   email = nombre.apellido.id@dominio -> unico por el id
--   password_hash = bcrypt de "demo1234" (el mismo del seed)
--   createdAt: entre 5 y 35 dias antes del mes de alta (ds_mes_alta)
-- ---------------------------------------------------------------------
INSERT INTO usuarios (id, nombre, apellido, dni, email, password_hash, google_id, estado, "createdAt", "updatedAt")
SELECT id, nombre, apellido,
       (20000000 + id)::text,
       translate(lower(nombre || '.' || apellido || '.' || id || '@' || dominio), 'áéíóúüñ', 'aeiouun'),
       '$2b$10$W1jNfsMqOttG20pebf.6N.jEvIEqBIDPvwCtcTEhlnhQul1TpQLK6',
       CASE WHEN ds_rand(id, 4) < 0.08 THEN (100000000000000000000::numeric + id::bigint * 1000003)::text END,
       ds_rand(id, 5) < 0.92,
       creado, creado
FROM (
    SELECT id,
           ds_pick(ARRAY['Juan','María','Santiago','Sofía','Mateo','Valentina','Benjamín','Martina',
                         'Lucas','Catalina','Joaquín','Emilia','Tomás','Isabella','Thiago','Mía',
                         'Facundo','Camila','Agustín','Lucía','Nicolás','Julieta','Franco','Agustina',
                         'Ignacio','Florencia','Lautaro','Milagros','Gonzalo','Paula','Federico','Carolina',
                         'Diego','Micaela','Pablo','Rocío','Martín','Antonella','Alejandro','Daniela',
                         'Sebastián','Victoria','Ezequiel','Brenda','Matías','Abril','Gabriel','Delfina',
                         'Leandro','Malena','Ramiro','Josefina','Bruno','Pilar','Emiliano','Guadalupe',
                         'Maximiliano','Celeste','Rodrigo','Ana'], id, 1) AS nombre,
           ds_pick(ARRAY['González','Rodríguez','Gómez','Fernández','López','Díaz','Martínez','Pérez',
                         'García','Sánchez','Romero','Sosa','Álvarez','Torres','Ruiz','Ramírez',
                         'Flores','Acosta','Benítez','Medina','Suárez','Herrera','Aguirre','Pereyra',
                         'Gutiérrez','Giménez','Molina','Silva','Castro','Rojas','Ortiz','Núñez',
                         'Luna','Juárez','Cabrera','Ríos','Ferreyra','Godoy','Morales','Domínguez',
                         'Moreno','Peralta','Vega','Carrizo','Quiroga','Castillo','Ledesma','Muñoz',
                         'Ojeda','Ponce','Vera','Vázquez','Villalba','Cardozo','Navarro','Coronel',
                         'Figueroa','Correa','Cáceres','Vargas'], id, 2) AS apellido,
           CASE WHEN ds_rand(id, 3) < 0.60 THEN 'gmail.com'
                WHEN ds_rand(id, 3) < 0.80 THEN 'hotmail.com'
                WHEN ds_rand(id, 3) < 0.88 THEN 'yahoo.com.ar'
                WHEN ds_rand(id, 3) < 0.96 THEN 'outlook.com'
                ELSE 'live.com.ar' END AS dominio,
           (ds_mes_fecha(ds_mes_alta(id)) - interval '35 days'
              + ds_rand(id, 6) * interval '30 days')::timestamptz AS creado
    FROM generate_series(4, 6000000) AS id
    OFFSET 0
) s;

-- ---------------------------------------------------------------------
-- usuario_roles: 1 rol por usuario generado (5.999.997) -> total 6.000.000
--   ~0,1 % admin, ~1,5 % entrenador, resto socio (ver ds_rol)
-- ---------------------------------------------------------------------
INSERT INTO usuario_roles (id_usuario, id_rol)
SELECT id, ds_rol(id)
FROM generate_series(4, 6000000) AS id;

-- ---------------------------------------------------------------------
-- suscripciones: 5.999.999 (ids 2..6.000.000), indice i = id - 2
--   tipo: 20 % baja antes de facturar, 70 % mensual, 10 % trimestral
--   fecha_inicio: dia 1 del mes, entre el alta del socio y nov-2026
--   activo: vigente a la fecha de corte (2026-11-13) y no dada de baja
-- ---------------------------------------------------------------------
INSERT INTO suscripciones (id, fecha_inicio, fecha_fin, precio, activo, "createdAt", "updatedAt", "usuarioId")
SELECT i + 2,
       to_char(ini, 'YYYY-MM-DD'),
       to_char(fin, 'YYYY-MM-DD'),
       precio::text,
       tipo <> 'baja' AND fin >= ds_corte(),
       creado, creado,
       uid
FROM (
    SELECT i, tipo, ini, precio, uid,
           CASE tipo
               WHEN 'mensual'    THEN (ini + interval '1 month'  - interval '1 day')::date
               WHEN 'trimestral' THEN (ini + interval '3 months' - interval '1 day')::date
               ELSE ini + 5 + floor(ds_rand(i, 44) * 20)::int   -- baja a los 5-24 dias
           END AS fin,
           (ini - ds_rand(i, 45) * interval '5 days')::timestamptz AS creado
    FROM (
        SELECT i, ds_sub_tipo(i) AS tipo, ds_mes_fecha(ds_sub_mes(i)) AS ini,
               ds_sub_precio(i) AS precio, ds_sub_usuario(i) AS uid
        FROM generate_series(0, 5999998) AS i
        OFFSET 0
    ) a
    OFFSET 0
) b;

-- ---------------------------------------------------------------------
-- tarifas: 5.999.998 (ids 3..6.000.000), indice k = id - 3
--   una cuota por mes de la suscripcion (mensual 1, trimestral 3, baja 0)
--   pagado: 80 % (bloques de 5, ver ds_tarifa_npagos)
--   activo: las impagas de hace mas de 6 meses quedan 70 % dadas de baja
--           (deuda anulada); el resto activas
-- ---------------------------------------------------------------------
INSERT INTO tarifas (id, anio, mes, precio, pagado, activo, "createdAt", "updatedAt", "suscripcionId")
SELECT k + 3,
       (2021 + mes / 12)::text,
       (mes % 12 + 1)::text,
       precio::text,
       npagos > 0,
       CASE WHEN npagos = 0 AND mes < 64 THEN ds_rand(k, 51) >= 0.7 ELSE TRUE END,
       creado, creado,
       si + 2
FROM (
    SELECT k, si, npagos,
           ds_sub_mes(si) + cuota AS mes,
           ds_sub_precio(si) AS precio,
           (ds_mes_fecha(ds_sub_mes(si) + cuota) + interval '5 minutes')::timestamptz AS creado
    FROM (
        SELECT k, ds_tarifa_sub(k) AS si, ds_tarifa_cuota(k) AS cuota, ds_tarifa_npagos(k) AS npagos
        FROM generate_series(0, 5999997) AS k
        OFFSET 0
    ) a
    OFFSET 0
) b;

-- ---------------------------------------------------------------------
-- pagos: 5.999.999 (ids 2..6.000.000), indice k = id - 2
--   solo de tarifas pagadas; 1 de cada 4 pagadas se abono en dos partes
--   fecha: 85 % entre el dia 1 y el 10 del mes; 15 % con mora de 11 a 45 dias;
--          la segunda parte 7-20 dias despues; nunca despues de la fecha de corte
--   monto: precio completo, o floor(precio/2) + resto (la suma da exacta)
-- ---------------------------------------------------------------------
INSERT INTO pagos (id, fecha, transaccion, monto, activo, "createdAt", "updatedAt", "tarifaId")
SELECT k + 2,
       to_char(fecha, 'YYYY-MM-DD'),
       'MP-' || lpad((k + 2)::text, 10, '0'),
       monto::text,
       TRUE,
       creado, creado,
       ti + 3
FROM (
    SELECT k, ti, fecha,
           CASE WHEN partes = 1 THEN precio
                WHEN parte  = 1 THEN precio / 2
                ELSE precio - precio / 2 END AS monto,
           (fecha + interval '8 hours' + ds_rand(k, 56) * interval '14 hours')::timestamptz AS creado
    FROM (
        SELECT k, ti, parte, partes, precio,
               least(ds_corte(),
                     ds_mes_fecha(mes)
                     + CASE WHEN ds_rand(ti, 53) < 0.85 THEN floor(ds_rand(ti, 54) * 10)::int
                            ELSE 10 + floor(ds_rand(ti, 54) * 35)::int END
                     + CASE WHEN parte = 2 THEN 7 + floor(ds_rand(ti, 55) * 14)::int ELSE 0 END
               ) AS fecha
        FROM (
            SELECT k, ti, parte, partes,
                   ds_sub_mes(si) + ds_tarifa_cuota(ti) AS mes,
                   ds_sub_precio(si) AS precio
            FROM (
                SELECT k, ti, parte, ds_tarifa_npagos(ti) AS partes, ds_tarifa_sub(ti) AS si
                FROM (
                    SELECT k, ds_pago_tarifa(k) AS ti, ds_pago_parte(k) AS parte
                    FROM generate_series(0, 5999998) AS k
                    OFFSET 0
                ) a0
                OFFSET 0
            ) a
            OFFSET 0
        ) b
        OFFSET 0
    ) c
) d;

-- ---------------------------------------------------------------------
-- rutinas: 5.999.999 (ids 2..6.000.000), indice r = id - 2
--   asignadas a socios; 25 % borradores (sin ejercicios, inactivas);
--   del resto 88 % activas
--   dia/turno con los valores del frontend (rutinas-list.component.html)
-- ---------------------------------------------------------------------
INSERT INTO rutinas (id, dia_semana, turno, nombre, descripcion, activo, "createdAt", "updatedAt", "usuarioId")
SELECT r + 2,
       CASE WHEN ds_rand(r, 63) < 0.19 THEN 'Lunes'
            WHEN ds_rand(r, 63) < 0.36 THEN 'Martes'
            WHEN ds_rand(r, 63) < 0.55 THEN 'Miércoles'
            WHEN ds_rand(r, 63) < 0.72 THEN 'Jueves'
            WHEN ds_rand(r, 63) < 0.88 THEN 'Viernes'
            WHEN ds_rand(r, 63) < 0.97 THEN 'Sábado'
            ELSE 'Domingo' END,
       CASE WHEN ds_rand(r, 64) < 0.35 THEN 'Mañana'
            WHEN ds_rand(r, 64) < 0.75 THEN 'Tarde'
            ELSE 'Noche' END,
       ds_pick(ARRAY['Fuerza full body','Hipertrofia tren superior','Hipertrofia tren inferior',
                     'Push (empuje)','Pull (tracción)','Piernas y glúteos','Core y estabilidad',
                     'Funcional','Resistencia muscular','Principiante adaptación','Torso',
                     'Espalda y bíceps','Pecho y tríceps','Hombros y abdomen','Movilidad'], r, 66),
       ds_pick(ARRAY['Rutina de fuerza con cargas progresivas.',
                     'Rutina de hipertrofia, 4 series de 8 a 12 repeticiones.',
                     'Rutina de adaptación para socios nuevos.',
                     'Rutina con foco en técnica y control del movimiento.',
                     'Rutina en circuito con descansos cortos.',
                     'Rutina de mantenimiento, intensidad moderada.',
                     'Rutina de resistencia, 3 series de 15 repeticiones.',
                     'Rutina indicada por el entrenador tras la evaluación inicial.'], r, 67),
       nej > 0 AND ds_rand(r, 65) < 0.88,
       creado, creado,
       uid
FROM (
    SELECT r, uid, nej,
           least(timestamptz '2026-11-13 00:00+00',
                 (ds_mes_fecha(alta + floor(ds_rand(r, 68) * (71 - alta))::int)
                  + interval '9 hours' + ds_rand(r, 69) * interval '27 days')::timestamptz) AS creado
    FROM (
        SELECT r, uid, nej, ds_mes_alta(uid) AS alta
        FROM (
            SELECT r, ds_socio(r, 61) AS uid, ds_rutina_nej(r) AS nej
            FROM generate_series(0, 5999998) AS r
            OFFSET 0
        ) a0
        OFFSET 0
    ) a
) b;

-- ---------------------------------------------------------------------
-- rutina_ejercicios: 5.999.997 -> total 6.000.000
--   ejercicio = 1 + (h + j*67) % 200: como 67 y 200 son coprimos, los hasta
--   3 ejercicios de una rutina son distintos (la PK compuesta no choca).
-- ---------------------------------------------------------------------
INSERT INTO rutina_ejercicios (id_rutina, id_ejercicio)
SELECT ri + 2,
       1 + (floor(ds_rand(ri, 62) * 200)::int + j * 67) % 200
FROM (
    SELECT ds_re_rutina(k) AS ri, ds_re_orden(k) AS j
    FROM generate_series(0, 5999996) AS k
    OFFSET 0
) a;

COMMIT;
