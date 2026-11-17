# SCRUM-39 — Análisis de consultas con pg_stat_statements y pgBadger (dataset 6M)

## Objetivo

Habilitar `pg_stat_statements` y `log_min_duration_statement`, ejercitar la app sobre el dataset de 6M filas (SCRUM-35/36) y analizar los logs con pgBadger, para elegir con datos qué consultas optimizar. Este ticket **solo diagnostica**: no cambia índices, consultas ni código de la app. Las mejoras propuestas se aplican en otro ticket.

## Criterios de aceptación

| Criterio | Dónde |
|---|---|
| Top de consultas por tiempo total y por frecuencia | [Resultados](#resultados) y `evidencias/SCRUM-39/top_consultas.txt` |
| Reporte HTML de pgBadger adjunto | [`evidencias/SCRUM-39/pgbadger.html`](evidencias/SCRUM-39/pgbadger.html) |
| Selección justificada de ≥ 8 consultas a optimizar | [Selección](#selección-de-consultas-a-optimizar): 10 elegidas y 2 descartadas con su motivo |

## Configuración

### `database/config/postgresql.conf` (sección "OBSERVABILIDAD DE CONSULTAS")

| Parámetro | Valor | Por qué |
|---|---|---|
| `shared_preload_libraries` | `'pg_stat_statements'` | La extensión necesita memoria compartida desde el arranque. **Requiere reiniciar** el servidor |
| `pg_stat_statements.max` | `10000` | Consultas normalizadas distintas que se retienen. La app genera menos de 50 |
| `pg_stat_statements.track` | `top` | Solo cuenta las sentencias que envía el cliente, no las internas de funciones |
| `track_io_timing` | `on` | Separa en `pg_stat_statements` y en `EXPLAIN (BUFFERS)` el tiempo de lectura de disco |
| `log_min_duration_statement` | `500ms` | Valor permanente: deja en el log solo las consultas lentas. Durante la captura se baja a `0` con `ALTER SYSTEM` (sin reiniciar) y al final se restaura |
| `log_line_prefix` | `'%m [%p] %q%u@%d app=%a '` | Se agrega `app=%a` para que pgBadger separe el tráfico del backend (`gymhub-backend`) del de psql (`scrum39-psql`) |
| `log_checkpoints`, `log_lock_waits`, `log_temp_files = 0`, `log_autovacuum_min_duration = 1s` | — | Eventos que pgBadger también reporta: checkpoints, esperas de locks, archivos temporales y autovacuum |

`database/01_schema.sql` crea la extensión (`CREATE EXTENSION IF NOT EXISTS pg_stat_statements`) en los volúmenes nuevos. En un volumen existente la crea `database/analisis/00_habilitar.sql`.

### Cambios de infraestructura detectados al ejecutar

1. **El contenedor `demo_hia_db_dev` no usaba `postgresql.conf`.** Se había creado antes de SCRUM-43, así que corría con `shared_buffers = 128MB` y sin el archivo montado. Se recreó **solo el contenedor**, con el volumen de 6M intacto:
   ```bash
   docker compose -f docker-compose.yml --profile dev up -d --no-deps db-dev
   ```
   Hay que pasar `-f docker-compose.yml` porque en la raíz también existe `compose.yaml`, y `docker compose` sin `-f` elige ese.
2. **`/dev/shm` de 64 MB.** La primera corrida falló en "pagos por rango" con `could not resize shared memory segment ... No space left on device`. Docker limita `/dev/shm` a 64 MB y el *hash join* paralelo sobre 6M filas necesita más. SCRUM-35 ya lo había esquivado apagando el paralelismo en su sesión, pero **el backend habría tenido el mismo error**. Se agregó `shm_size: 256mb` a la base en `docker-compose.yml` (para `db` y `db-dev`) y en `compose.yaml` (`db`).

## Metodología

### Archivos (`database/analisis/`)

```
database/analisis/
├── ejercitar.sh              # runner: todos los pasos, salida en docs/evidencias/SCRUM-39/
├── 00_habilitar.sql          # extensión, reset de estadísticas, log_min_duration_statement = 0
├── workload.js               # carga HTTP contra el backend (Node, fetch nativo, sin dependencias)
├── consultas_psql.sql        # candidatas que no se pueden pedir por HTTP (ver abajo)
├── capturar-sql.js           # imprime el SQL que genera Sequelize, sin conectarse a la base
├── top_consultas.sql         # top por tiempo total, frecuencia y tiempo medio + escaneos por tabla
├── explain_candidatas.sql    # EXPLAIN (ANALYZE, BUFFERS) de cada candidata
├── 99_restaurar.sql          # vuelve log_min_duration_statement a 500ms
└── pgbadger/Dockerfile       # pgBadger 13.1 en contenedor (perl:5.40-slim)
```

### Cómo se ejercitó cada candidata

| Candidata | Origen en el backend | Cómo se ejecutó |
|---|---|---|
| Login por email (+ rol) | `auth.controller.js` `login` | HTTP `POST /api/auth/login` |
| Usuario por DNI | `usuario.controller.js` `getUsuarioByDni` | HTTP `GET /api/usuarios/:dni` |
| Tarifas impagas por usuario | `tarifa.controller.js` `getCuotasImpagasPorUsuario` | HTTP `GET /api/tarifas/impagas/:usuarioId` |
| Mis tarifas | `tarifa.controller.js` `getMisTarifas` | HTTP `GET /api/tarifas/mis-tarifas` |
| Mis rutinas | `rutina.controller.js` `getMisRutinas` | HTTP `GET /api/rutinas/mis-rutinas` |
| Socios activos | `usuario.controller.js` `getSocios` | **psql** |
| Stats del dashboard | `dashboard.controller.js` `getStats` | **psql** |
| Ejercicios por nombre (ILIKE) | **no existe endpoint** | **psql** |
| Pagos por rango de fechas | **no existe endpoint** | **psql** |

> [!IMPORTANT]
> **Por qué cuatro candidatas se ejecutaron con psql y no por HTTP**
>
> - **Búsqueda de ejercicios por nombre (ILIKE)** y **pagos por rango de fechas**: **el backend no tiene esos endpoints.** `GET /api/ejercicios` y `GET /api/pagos` devuelven la tabla completa y el frontend filtra en el navegador. Para analizarlas se escribió el SQL que generaría un controlador Sequelize con `Op.iLike` y `Op.between` (`capturar-sql.js` lo imprime a partir de los modelos reales).
> - **Socios activos** y **stats del dashboard**: los endpoints **existen**, pero no tienen paginación. Traen a Node ~5,4M usuarios y ~4,8M tarifas, y con el dataset de 6M el proceso se queda sin memoria antes de responder. Se ejecutó el SQL exacto que envía Sequelize (capturado con `capturar-sql.js`).
>
> Esto **no afecta el análisis**: `pg_stat_statements` y pgBadger registran todas las sentencias que llegan al servidor, sin importar qué cliente las manda. Lo único que cambia es la etiqueta `application_name` (`scrum39-psql` en lugar de `gymhub-backend`), y eso sirve justamente para distinguirlas en el reporte. Las consultas que devuelven millones de filas se enviaron como `COPY (SELECT …) TO STDOUT` hacia `/dev/null`. El servidor ejecuta el mismo plan y transmite todas las filas, pero psql no las guarda en memoria. Efecto secundario: `pg_stat_statements` no normaliza las constantes dentro de un `COPY`, así que cada mes de "pagos por rango" aparece como una entrada separada (se suman en las tablas de abajo).

### Carga generada (`ejercitar.sh`, defaults)

- **Muestra**: 276 socios activos (un id cada 20.000 a partir de 1037, porque `ds_rol` asigna admin a los ids múltiplos de 1000).
- **HTTP**: 4 trabajadores concurrentes, contra un backend propio en el puerto 3039 (`PGAPPNAME=gymhub-backend`, rate limit desactivado solo para esa instancia). Por cada socio: login, mis-tarifas y mis-rutinas con su token; usuario por DNI e impagas con token de admin. En total, 1.381 requests: **todas con 200**, ninguna con error.
- **psql**: socios activos ×3, stats del dashboard ×5 (las 5 sentencias por llamada), ILIKE ×10 términos y pagos por rango ×6 meses (mayo a octubre de 2026).
- **Ventana de captura**: 2026-11-17 17:31:33 a 17:39:42 UTC, con `log_min_duration_statement = 0`.

Entorno: Docker Desktop (Windows 11), PostgreSQL 16.15, `shared_buffers = 512MB` y base de 5,2 GB. La mayor parte del dataset no entra en caché, así que muchas lecturas van a disco (`shared_blks_read` alto).

### Cómo reproducir

```bash
docker compose -f docker-compose.yml --profile dev up -d --no-deps db-dev   # toma postgresql.conf y shm_size
(cd backend && npm ci)
./database/analisis/ejercitar.sh            # ~10 min; PASO_MUESTRA y CONCURRENCIA son configurables

# Planes de ejecución (después del runner: ensucian pg_stat_statements)
docker exec -i demo_hia_db_dev psql -X -U demo_hia -d demo_hia \
  -v uid=21037 -v email="'sofia.godoy.21037@hotmail.com'" -v dni="'20021037'" \
  -f - < database/analisis/explain_candidatas.sql
```

## Resultados

Resumen de `pg_stat_statements`: **28 consultas normalizadas, 4.221 llamadas y 1.584,7 s de tiempo de ejecución acumulado**. Como corrieron 4 trabajadores en paralelo, el acumulado supera la duración real de la ventana. Resumen de pgBadger: 4.220 consultas, 26 min 34 s de duración total, pico de 30 consultas/s y 18 archivos temporales (máx. 13,9 MiB, todos de "pagos por rango").

### Top por tiempo total

| # | Consulta (origen) | Llamadas | Total (s) | Media (ms) | Máx (ms) | % del total | Filas/llamada |
|--:|---|--:|--:|--:|--:|--:|--:|
| 1 | Mis rutinas (`getMisRutinas`) | 276 | 514,5 | 1.864 | 24.367 | **32,5** | 1,3 |
| 2 | Mis tarifas (`getMisTarifas`) | 276 | 498,9 | 1.808 | 9.927 | **31,5** | 1,0 |
| 3 | Impagas por usuario (`getCuotasImpagasPorUsuario`) | 276 | 468,7 | 1.698 | 19.217 | **29,6** | 0,1 |
| 4 | Socios activos (`getSocios`) — psql | 3 | 48,2 | 16.060 | 26.593 | 3,0 | 5.433.201 |
| 5 | Pagos por rango de fechas — psql, 6 meses sumados | 6 | 20,0 | 3.326 | 6.682 | 1,3 | ~360.000 |
| 6 | Dashboard: tarifas pagadas (`getStats`) — psql | 5 | 10,9 | 2.184 | 5.113 | 0,7 | 4.800.000 |
| 7 | Login: usuario por email | 277 | 7,6 | 27,4 | 776 | 0,5 | 1 |
| 8 | Dashboard: usuarios por rol (`GROUP BY id_rol`) | 5 | 4,8 | 952 | 3.402 | 0,3 | 3 |
| 9 | Dashboard: `count(*)` por estado (2 por llamada) | 10 | 3,9 | 392 | 730 | 0,2 | 1 |
| 10 | Usuario por DNI | 276 | 3,7 | 13,5 | 462 | 0,2 | 1 |
| 11 | Login: rol del usuario (`usuario_roles` por `id_usuario`) | 277 | 3,2 | 11,5 | 333 | 0,2 | 1 |

**Las tres consultas por usuario suman el 93,6 % del tiempo de la base**, a pesar de devolver una fila o ninguna.

### Top por frecuencia

| # | Consulta (origen) | Llamadas | Media (ms) | Total (ms) |
|--:|---|--:|--:|--:|
| 1 | `verificarRol`: asignación `usuario_roles (id_usuario, id_rol)` | **1.104** | 0,17 | 191 |
| 2 | `verificarRol`: rol por nombre (`roles WHERE nombre = $1`) | **1.104** | 0,03 | 34 |
| 3 | Login: usuario por email | 277 | 27,4 | 7.586 |
| 4 | Login: rol del usuario (`ORDER BY id_rol`) | 277 | 11,5 | 3.187 |
| 5 | Login: rol por id (`roles WHERE id = $1`) | 277 | 0,04 | 10 |
| 6 | Mis rutinas | 276 | 1.864 | 514.543 |
| 7 | Mis tarifas | 276 | 1.808 | 498.950 |
| 8 | Impagas por usuario | 276 | 1.698 | 468.748 |
| 9 | Usuario por DNI | 276 | 13,5 | 3.733 |
| 10 | Dashboard: `count(*)` por estado | 10 | 392 | 3.923 |

Las dos consultas de `verificarRol` son el 52 % de las llamadas: cada request autenticado hace 2 consultas solo para chequear permisos. Las 9 llamadas a `pg_class`/`information_schema` que también aparecen en el reporte salen de `sequelize.sync()` al arrancar el backend, no de la carga.

### Escaneos por tabla (`pg_stat_user_tables`)

| Tabla | Seq scans | Filas leídas por seq scan | Lectura |
|---|--:|--:|---|
| `suscripciones` | 1.544 | 3.312 M | Recorrida completa en cada mis-tarifas e impagas, para filtrar por `"usuarioId"` |
| `tarifas` | 1.558 | 2.088 M | Recorrida completa en el mismo *hash join* |
| `rutinas` | 775 | 1.656 M | Recorrida completa en cada mis-rutinas, para filtrar por `"usuarioId"` |
| `pagos` | 18 | 36 M | Recorrida completa en cada rango de fechas |

Las cuentas son de *workers* paralelos (3 por consulta): cada lectura de 2M filas es un tercio de la tabla.

## Selección de consultas a optimizar

Criterios aplicados, en orden de peso: **(a)** porcentaje del tiempo total de la base, **(b)** frecuencia, **(c)** filas leídas contra filas devueltas (seq scan para devolver 1 fila), **(d)** volumen enviado a Node que la base podría resolver, **(e)** derrames a disco (`temp_blks_written`). Los planes completos están en `evidencias/SCRUM-39/explain_candidatas.txt`. Los tiempos de `EXPLAIN` son de una ejecución con caché fría y pueden diferir de las medias de la carga.

| # | Consulta | Evidencia | Diagnóstico (plan) | Mejora propuesta (no aplicada) |
|--:|---|---|---|---|
| **1** | **Mis rutinas** | 32,5 % del tiempo · 1.864 ms de media para 1,3 filas | `Parallel Seq Scan on rutinas`: descarta 2M filas por *worker* (6M en total) y 105.060 bloques leídos de disco para devolver 1 rutina. No hay índice en `rutinas."usuarioId"` | `CREATE INDEX ON rutinas ("usuarioId")` |
| **2** | **Mis tarifas** | 31,5 % · 1.808 ms para 1 fila | `Parallel Seq Scan` sobre `suscripciones` (filtra `"usuarioId"`) y sobre las 6M `tarifas`, unidas con *hash join*. Ninguna FK tiene índice | `CREATE INDEX ON suscripciones ("usuarioId")` y `CREATE INDEX ON tarifas ("suscripcionId")`: el plan pasa a *nested loop* por índice |
| **3** | **Impagas por usuario** | 29,6 % · 1.698 ms · 0,1 filas/llamada | Mismo patrón que #2, más el filtro `pagado = false AND activo = true` aplicado después de leer las 6M tarifas | Los índices de #2. Opcional: índice parcial `ON tarifas ("suscripcionId") WHERE NOT pagado AND activo` |
| **4** | **Socios activos** | La de mayor tiempo medio: 16 s · 5,4M filas por llamada | *Merge join* que recorre `usuarios` completa por PK (150.608 bloques de disco) y todo `usuario_roles`. El problema no es el plan: el endpoint **no tiene paginación** y manda 5,4M filas a Node, que se queda sin memoria | Paginar (`LIMIT`/*keyset* por `id`) y filtrar del lado del servidor. Con eso alcanza un índice en `usuario_roles (id_rol, id_usuario)` |
| **5** | **Pagos por rango de fechas** (sin endpoint) | 3,3 s de media · único con derrames a disco (18 archivos temporales, ~14 MiB por *worker*) | `Parallel Seq Scan on pagos` (descarta 1,8M filas por *worker*), *hash join* con las 6M `tarifas` y `Sort Method: external merge` porque ~485k filas no entran en `work_mem = 10MB`. Además, `fecha` es `VARCHAR`: el `BETWEEN` funciona por orden de texto | `CREATE INDEX ON pagos (fecha)` (mejor si se migra a `DATE`), paginar el reporte, y el índice en `tarifas` por PK ya alcanza para el *join* por id |
| **6** | **Dashboard: tarifas pagadas** | 2,2 s de media · 4,8M filas por llamada | `Seq Scan on tarifas` que devuelve 4,8M precios para que Node los sume con `reduce` | `SELECT sum(precio::numeric) … WHERE pagado AND activo`: 1 fila en vez de 4,8M. Además `precio` es `VARCHAR`, conviene `NUMERIC` |
| **7** | **Dashboard: usuarios por rol** | 952 ms de media | `Parallel Seq Scan on usuario_roles` (6M) + `HashAggregate` para obtener 3 números | Índice en `usuario_roles (id_rol)` para un *index-only scan*, o contadores/vista materializada si el dashboard se consulta seguido |
| **8** | **Dashboard: usuarios por estado** | 392 ms de media, 2 consultas por llamada | Dos `Parallel Seq Scan` completos de `usuarios` (7,3 s en frío) para contar `estado = true` y `estado = false` | Una sola consulta `SELECT estado, count(*) … GROUP BY estado` (la mitad de lecturas); con un índice en `(estado)`, *index-only scan* |
| **9** | **`verificarRol`** (middleware de roles) | La más frecuente: 2.208 llamadas = 2 por request autenticado | Las dos consultas son rápidas (*seq scan* de 3 filas en `roles` e *index-only scan* por PK en `usuario_roles`). El costo está en los viajes de ida y vuelta, no en el plan | Incluir el rol en el JWT al hacer login, o resolver permiso con **una** consulta `JOIN roles … WHERE nombre = ANY($roles)` |
| **10** | **Login** (3 consultas) | 277 logins × 3 consultas · email: media 27 ms, máx 776 ms | Cada consulta usa índice (`usuarios_email_key`, `usuario_roles_pkey`, `roles_pkey`), pero se hacen 3 viajes secuenciales y el `SELECT` trae `password_hash` y todas las columnas | Una sola consulta `usuarios JOIN usuario_roles JOIN roles WHERE email = $1`. Prioridad baja frente a #1–#8 |

### Candidatas descartadas

| Consulta | Por qué no se optimiza ahora |
|---|---|
| **Usuario por DNI** | Ya usa el índice único `usuarios_dni_key`: 13,5 ms de media y 0,2 % del tiempo. El máximo (462 ms) se dio con la carga concurrente de las consultas #1–#3 y en el `EXPLAIN` aislado es de milisegundos |
| **Ejercicios por nombre (ILIKE)** (sin endpoint) | 0,35 ms de media: `ejercicios` es un catálogo de 200 filas (SCRUM-35) y el *seq scan* entra en un bloque. Un `ILIKE '%…%'` no usa B-tree; si el catálogo creciera, la mejora sería un índice GIN con `pg_trgm`. Hoy no se justifica |

### Orden sugerido para el ticket de optimización

1. Índices en las FK `rutinas."usuarioId"`, `suscripciones."usuarioId"` y `tarifas."suscripcionId"`: atacan #1–#3, el **93,6 %** del tiempo, sin cambiar código.
2. Dashboard (#6–#8): agregar en SQL en vez de en Node.
3. Paginación de socios activos (#4) y del reporte de pagos (#5).
4. Viajes a la base por request (#9, #10).

Para comparar, repetir `ejercitar.sh` con la misma muestra y contrastar `top_consultas.txt` antes y después.

## Evidencias (`docs/evidencias/SCRUM-39/`)

| Archivo | Contenido |
|---|---|
| `pgbadger.html` | **Reporte pgBadger** (abrir en el navegador): *Top → Time consuming queries / Most frequent queries / Slowest queries*, temporales y aplicaciones |
| `postgresql.log` | Log del servidor en la ventana de captura (entrada de pgBadger) |
| `top_consultas.txt` | Salida de `top_consultas.sql`: resumen, tops, texto completo y escaneos por tabla |
| `explain_candidatas.txt` | `EXPLAIN (ANALYZE, BUFFERS)` de las 10 candidatas y de las 2 descartadas |
| `workload.log` | Resumen HTTP por endpoint (llamadas, p50/p95/máx, status) |
| `consultas_psql.log` | Tiempos de cada sentencia ejecutada con psql |
| `muestra_socios.tsv`, `ventana.txt` | Socios usados (datos ficticios del dataset) e inicio de la captura |
| `00_habilitar.log`, `99_restaurar.log`, `backend.log`, `pgbadger.log` | Salida de cada paso |

## Riesgos y notas

- **No correr con el perfil `cluster`**: `log_min_duration_statement = 0` y la carga generan WAL y log que la réplica tendría que reproducir.
- El runner restaura `log_min_duration_statement` también si falla (`trap EXIT`). Para comprobarlo: `SHOW log_min_duration_statement;` tiene que dar `500ms`.
- `pg_stat_statements` acumula hasta el próximo `pg_stat_statements_reset()` o reinicio. `00_habilitar.sql` lo resetea al empezar cada corrida.
- El backend de prueba se levanta con el rate limit desactivado **solo** en esa instancia local (puerto 3039). No cambia la configuración de despliegue.
- En la primera corrida completa, `top_consultas.sql` falló por un `round(double precision, int)`. Se corrigió el *cast* y se ejecutaron a mano los pasos restantes (top, `docker logs`, pgBadger) sobre la misma ventana, así que las estadísticas no cambian.
