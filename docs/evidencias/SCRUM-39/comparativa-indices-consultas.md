# Comparativa de consultas: sin índice vs con índice (dataset 6M)

> [!NOTE]
> **Estado: ejecutado el 2026-11-18** (`comparar.sh`, de 01:33 a 01:38 UTC del 19/11). Las evidencias están en [`indices/`](indices/). La columna "Referencia SCRUM-39" sale de [`explain_candidatas.txt`](explain_candidatas.txt), medida sin índices.
>
> **Entorno:** Linux nativo (Docker Engine, sin Docker Desktop), 4 CPU y 5 GB de RAM en el host, PostgreSQL 16.16 (`postgres:16-alpine`), `shared_buffers = 512MB`, `work_mem = 10MB`, `jit = on`, 2 *workers* por *gather*. Dataset recargado desde cero con `database/dataset/cargar.sh` (12 min). Las huellas de `04_verificar` coinciden con las de [SCRUM-36](../SCRUM-36/SCRUM-36-ejecucion-carga-masiva.md), así que es el mismo dataset que midió SCRUM-39. Socio `21037`, suscripción `3727420` (E5).

## Objetivo

Medir con `EXPLAIN (ANALYZE, BUFFERS)` el efecto real de los índices propuestos en [SCRUM-39.1](../../SCRUM-39.1-explicacion-indices.md), sobre las mismas consultas y la misma base:

- **Lecturas**: tiempo, bloques leídos y tipo de plan, antes y después.
- **Escrituras**: cuánto más cuestan `INSERT` y `UPDATE` con los índices nuevos, y cuánto mejoran los `DELETE` con FK.
- **Almacenamiento**: tamaño real de cada índice.
- **Decisión**: confirmar los índices de prioridad 1 y decidir con datos los condicionales.

## Índices comparados

| Índice | Prioridad | Consultas |
|---|---|---|
| `idx_rutinas_usuario` → `rutinas ("usuarioId")` | 1 | L1 |
| `idx_suscripciones_usuario` → `suscripciones ("usuarioId")` | 1 | L2, L3, E4 |
| `idx_tarifas_suscripcion` → `tarifas ("suscripcionId")` | 1 | L2, L3, E5 |
| `uq_pagos_transaccion` → `pagos (transaccion)` `UNIQUE` | 1 | L4 |
| `idx_usuarios_estado` → `usuarios (estado)` | Condicional | L5, L6 |
| `idx_usuario_roles_rol` → `usuario_roles (id_rol)` | Condicional | L7 |
| `idx_pagos_fecha_id` → `pagos (fecha, id)` | Condicional | L8, L9, L10 |

## Metodología

### Scripts (`database/analisis/indices/`)

```
database/analisis/indices/
├── comparar.sh              # runner: fase SIN -> fase CON -> resumen; salida en docs/evidencias/SCRUM-39/indices/
├── crear_indices.sql        # el script de SCRUM-39.1 (CONCURRENTLY); -v condicionales=1 agrega los condicionales
├── eliminar_indices.sql     # vuelve a la base de SCRUM-39; -v solo_condicionales=1 deja los de prioridad 1
├── explain_lecturas.sql     # L1–L11: EXPLAIN (ANALYZE, BUFFERS), un plan por encabezado
├── explain_escrituras.sql   # E1–E5: EXPLAIN (ANALYZE, BUFFERS, WAL) dentro de BEGIN ... ROLLBACK
└── tamanio_indices.sql      # tamaño de tablas e índices, idx_scan
```

### Cómo se mide

1. **Misma base, mismas consultas, mismo socio.** Se usan los textos exactos que envía Sequelize (los de `explain_candidatas.sql`) y el socio `21037` de la muestra de SCRUM-39. Las únicas consultas nuevas son las variantes que proponen SCRUM-39 y SCRUM-39.1: el `GROUP BY` de L6 y las páginas de L9 y L10.
2. **Fase SIN**: `eliminar_indices.sql`, luego `VACUUM (ANALYZE)` de las 6 tablas, reinicio del contenedor y las lecturas 3 veces seguidas. Al final, las escrituras.
3. **Fase CON**: `crear_indices.sql -v condicionales=1`, `VACUUM (ANALYZE)`, tamaños, reinicio y lo mismo que en la fase SIN.
4. **Corrida 1 = caché fría, corridas 2 y 3 = caliente.** El reinicio vacía `shared_buffers`, pero no la caché de archivos de la VM de Docker Desktop. Por eso la corrida 1 es "fría" para PostgreSQL y puede no serlo del todo para el disco. Se informan las dos: la fría muestra el costo de disco (`shared read`) y la caliente, el de CPU.
   - **En Linux nativo (sin Docker Desktop)** pasa lo mismo, pero más marcado: el contenedor usa la caché de páginas del propio host, y `docker restart` no la vacía. La corrida 1 es fría para PostgreSQL (`shared_buffers` vacío), pero los bloques pueden venir de la RAM del host y no del disco. Por eso, en esta corrida, `shared read` cuenta bloques que no estaban en `shared_buffers`, no necesariamente lecturas físicas. Para una caché fría de verdad habría que correr `sync; echo 3 | sudo tee /proc/sys/vm/drop_caches` antes de cada fase. El runner no lo hace.
5. **`VACUUM (ANALYZE)` en las dos fases**: así las estadísticas son las mismas y el *visibility map* está al día. Sin eso, los *index-only scan* de L5 a L7 harían `Heap Fetches` y la comparación sería injusta para el índice.
6. **Configuración sin tocar**: `jit`, el paralelismo y `work_mem` quedan como en `postgresql.conf` (SCRUM-43), igual que los usa la app. Si con índice desaparece el JIT porque el costo estimado baja del umbral, esa ganancia es real y se cuenta.
7. **Escrituras en `BEGIN ... ROLLBACK`**: `EXPLAIN ANALYZE` de un `INSERT`, `UPDATE` o `DELETE` lo ejecuta de verdad. El `ROLLBACK` descarta los cambios y el runner corre `VACUUM` al final para limpiar las tuplas muertas.
8. **Estado final**: el runner borra los condicionales y deja solo los de prioridad 1. Si la comparativa justifica algún condicional, se crea en el ticket de optimización.

### Cómo ejecutar

```bash
docker compose -f docker-compose.yml --profile dev up -d --no-deps db-dev
./database/analisis/indices/comparar.sh            # ~15-25 min; ver variables en el encabezado del script
```

> [!WARNING]
> Solo contra la base de **desarrollo** (`demo_hia_db_dev`) y sin el perfil `cluster`. El paso 1 **borra** los índices de SCRUM-39.1 si existen, y la creación genera ~0,6 a 0,9 GB de WAL.

### Cómo leer cada plan

| Dato del `EXPLAIN` | Qué indica |
|---|---|
| `Execution Time` | Tiempo total en el servidor, sin red. Es la columna de las tablas de abajo |
| `Buffers: shared hit=… read=…` | Páginas de 8 KB leídas: `hit` desde `shared_buffers` y `read` desde disco o caché del SO. **Es la medida más estable**: no depende de la carga de la máquina |
| Nodo de acceso | `Seq Scan` / `Parallel Seq Scan` (recorre la tabla) contra `Index Scan` / `Index Only Scan` / `Bitmap Heap Scan` (usa el índice). Confirma que el planificador eligió el índice |
| `Rows Removed by Filter` | Filas leídas y descartadas. Con un buen índice tiende a 0 |
| `Sort Method: external merge` / `temp written` | Derrame a disco por falta de `work_mem` |
| `Trigger for constraint …` (E4, E5) | Tiempo de las acciones de FK (`SET NULL`, `CASCADE`) |
| `WAL: records=… bytes=…` (E1–E5) | WAL generado. Cada índice extra suma registros |

## Consultas medidas

| Id | Consulta | Origen | Índice que debería usar |
|---|---|---|---|
| L1 | Mis rutinas | `rutina.controller.js` `getMisRutinas` | `idx_rutinas_usuario` |
| L2 | Mis tarifas | `tarifa.controller.js` `getMisTarifas` | `idx_suscripciones_usuario` + `idx_tarifas_suscripcion` |
| L3 | Impagas por usuario | `tarifa.controller.js` `getCuotasImpagasPorUsuario` | `idx_suscripciones_usuario` + `idx_tarifas_suscripcion` |
| L4 | Pago duplicado de MercadoPago (`LIMIT 1`, transacción inexistente) | `pago.controller.js:78` | `uq_pagos_transaccion` |
| L5 | Usuarios activos, `count(*)` original | `dashboard.controller.js` | `idx_usuarios_estado` (*index-only*) |
| L6 | Usuarios por estado, `GROUP BY` reescrita | Propuesta SCRUM-39 #8 | `idx_usuarios_estado` (*index-only*) |
| L7 | Usuarios por rol | `dashboard.controller.js` | `idx_usuario_roles_rol` (*index-only*) |
| L8 | Pagos de un mes, sin paginar (octubre 2026, ~485k filas) | Sin endpoint (SCRUM-39) | Se espera que **no** use el índice |
| L9 | Pagos de un mes, primera página (`LIMIT 50`) | Propuesta SCRUM-39 #5 | `idx_pagos_fecha_id` |
| L10 | Pagos de un mes, página *keyset* desde el 15/10 | Propuesta SCRUM-39 #5 | `idx_pagos_fecha_id` |
| L11 | **Control**: socios paginados por *keyset* sobre `id` | Propuesta SCRUM-39 #4 | `usuarios_pkey` + `usuario_roles_pkey` (ya existen): **no debería cambiar** |
| E1 | `INSERT` de 100.000 tarifas | Alta de suscripción | Costo: +1 índice en `tarifas` |
| E2 | `INSERT` de 100.000 pagos | Registro de pago | Costo: +1 o +2 índices en `pagos` |
| E3 | `UPDATE pagado` de 100.000 tarifas | Crear y anular pago | Costo: +1 índice si el `UPDATE` no es HOT |
| E4 | `DELETE` de un usuario | `deleteUsuario` (FK `SET NULL` en rutinas y suscripciones) | Beneficio: `idx_rutinas_usuario`, `idx_suscripciones_usuario` |
| E5 | `DELETE` de una suscripción | `deleteSuscricion` (FK `SET NULL` en tarifas) | Beneficio: `idx_tarifas_suscripcion` |

## Resultados: lecturas

Tiempos en ms (`Execution Time`). "Fría" es la corrida 1 y "caliente" el promedio de las corridas 2 y 3. Mejora = sin / con, sobre la corrida caliente.

### Índices de prioridad 1

| Id | Consulta | Referencia SCRUM-39 (fría) | Sin índice: fría | Sin índice: caliente | Con índice: fría | Con índice: caliente | Mejora |
|---|---|--:|--:|--:|--:|--:|--:|
| L1 | Mis rutinas | 6.398,9 | 6.494,9 | 4.623,1 | 3,60 | 0,30 | **~15.500×** |
| L2 | Mis tarifas | 5.463,8 | 3.925,3 | 7.842,9 | 1,68 | 0,15 | **~53.000×** |
| L3 | Impagas por usuario | 845,0 | 1.034,4 | 7.352,4 | 7,42 | 0,38 | **~19.000×** |
| L4 | Pago duplicado MP | — (no medida) | 3.905,0 | 999,4 | 1,54 | 0,06 | **~15.500×** |

Con índice, las cuatro consultas bajan de segundos a **menos de 8 ms en frío y menos de 0,4 ms en caliente**. Sobre la corrida fría, que es la más comparable con la referencia, la mejora va de ~140× (L3) a ~2.500× (L4).

> [!NOTE]
> **L2 y L3 sin índice tardan más en caliente que en frío** (7,8 s contra 3,9 s). Los planes son idénticos y leen los mismos bloques (~123.900). La diferencia está en el `Parallel Seq Scan on tarifas`: 0,4 s en la corrida 1 y 3,3 s en las corridas 2 y 3. Con 5 GB de RAM en el host y 5,5 GB de base, la caché del SO no retiene las tablas entre consultas: cada *seq scan* desaloja lo que había leído el anterior. Los *seq scan* grandes usan un *ring buffer* y no quedan en `shared_buffers`, así que sin índice "caliente" no garantiza estar en memoria. Las conclusiones no cambian, porque la diferencia con índice es de 3 a 4 órdenes de magnitud en cualquiera de las dos corridas.

### Índices condicionales

| Id | Consulta | Referencia SCRUM-39 (fría) | Sin índice: fría | Sin índice: caliente | Con índice: fría | Con índice: caliente | Mejora |
|---|---|--:|--:|--:|--:|--:|--:|
| L5 | Activos, `count(*)` | 7.353,1 | 6.251,4 | 653,3 | 365,3 | 301,7 | 2,2× |
| L6 | Por estado, `GROUP BY` | — | 1.102,2 | 737,7 | 430,6 | 441,0 | 1,7× |
| L7 | Por rol | 1.569,9 | 1.712,9 | 736,8 | 1.034,6 | 532,3 | 1,4× (**no usa el índice**) |
| L8 | Pagos de un mes, sin paginar | 13.987,3 | 8.367,3 | 5.065,0 | 5.836,0 | 3.989,3 | 1,3× |
| L9 | Pagos, primera página | — | 1.244,7 | 1.367,9 | 2,94 | 4,47 | **~300×** |
| L10 | Pagos, página *keyset* | — | 626,9 | 584,6 | 2,83 | 5,93 | **~100×** |

- **L5 y L6** usan `Parallel Index Only Scan using idx_usuarios_estado` con `Heap Fetches: 0`, como se esperaba. Los bloques bajan de ~134.000 a ~5.000, pero el tiempo solo baja a la mitad: igual hay que contar 6M entradas del índice. Además desaparece el JIT, porque el costo estimado baja del umbral.
- **L7 no usa `idx_usuario_roles_rol`.** Sigue con `Parallel Seq Scan on usuario_roles` en las tres corridas, con los mismos 26.563 bloques. La consulta hace `COUNT("id_usuario")` y el índice es solo `(id_rol)`: no cubre `id_usuario`, así que no es *index-only*, y recorrer el índice más el *heap* le cuesta al planificador más que el *seq scan*. La baja de 737 a 532 ms es ruido de caché, no efecto del índice. Ver la decisión.
- **L8** pasa a `Parallel Bitmap Heap Scan` + `Bitmap Index Scan on idx_pagos_fecha_id`, pero sigue leyendo ~126.000 bloques, haciendo `external merge` a disco y el *seq scan* de `tarifas` para el `LEFT JOIN`. Es lo esperado: sin paginar, el índice no resuelve la consulta. La dispersión de la fase CON (5,4 s y 2,6 s) es de la caché del SO.
- **L9 y L10** pasan a `Limit` → `Index Scan using idx_pagos_fecha_id`, sin `Sort` ni `Gather`, con ~245 bloques en lugar de ~68.000. L10 usa `Index Cond: (ROW(fecha, id) > ROW('2026-10-15', 0))`, es decir, la *keyset* aprovecha el índice compuesto. En caliente la corrida 2 dio 8–11 ms y la 3 menos de 1 ms. El promedio queda sesgado, pero todo está muy por debajo de los 10 ms.

### Control

| Id | Consulta | Sin índice: caliente | Con índice: caliente | ¿Cambió el plan? |
|---|---|--:|--:|---|
| L11 | Socios paginados | 448,6 | 489,9 | **No.** El mismo `Merge Join` de `usuarios_pkey` + `usuario_roles_pkey` y los mismos 8.206 bloques. La diferencia de ±10 % es el ruido de la medición |

### Bloques leídos y plan

Bloques = `shared hit + read` del nodo raíz, en la corrida fría.

| Id | Referencia SCRUM-39: bloques | Plan sin índice (SCRUM-39) | Sin índice: bloques | Con índice: bloques | Plan con índice | Plan esperado con índice |
|---|--:|---|--:|--:|---|---|
| L1 | 105.066 | `Parallel Seq Scan on rutinas` | 105.068 | 10 | `Index Scan using idx_rutinas_usuario` → *nested loop* | `Index Scan using idx_rutinas_usuario` → *nested loop* ✅ |
| L2 | 123.912 | 2 × `Parallel Seq Scan` + `Parallel Hash Join` | 123.912 | 15 | `Index Scan using idx_suscripciones_usuario` → `Index Scan using idx_tarifas_suscripcion` (*nested loop*) | `Index Scan` suscripciones → `Index Scan` tarifas (*nested loop*) ✅ |
| L3 | 123.913 | Igual que L2 | 123.913 | 16 | Igual que L2, + `usuarios_pkey` | Igual que L2 ✅ |
| L4 | — | (esperado) `Seq Scan on pagos` completo | 68.182 | 3 | `Index Scan using uq_pagos_transaccion`, 0 filas | `Index Scan using uq_pagos_transaccion`, 0 filas ✅ |
| L5 | 134.217 | `Parallel Seq Scan on usuarios` | 134.217 | 4.666 | `Parallel Index Only Scan using idx_usuarios_estado`, `Heap Fetches: 0` | `Index Only Scan using idx_usuarios_estado`, `Heap Fetches: 0` ✅ |
| L6 | — | — | 134.233 | 5.079 | `Parallel Index Only Scan` + `Partial GroupAggregate` | `Index Only Scan` + `GroupAggregate` ✅ |
| L7 | 26.563 | `Parallel Seq Scan on usuario_roles` | 26.563 | 26.563 | `Parallel Seq Scan on usuario_roles` (sin cambios) | `Index Only Scan using idx_usuario_roles_rol` ❌ |
| L8 | 124.389 (+5.289 temp) | `Parallel Seq Scan on pagos` + `external merge` | 124.389 (+5.289 temp) | 126.033 (+5.287 temp) | `Parallel Bitmap Heap Scan` (`idx_pagos_fecha_id`) + `external merge` | Probablemente sigue con *seq scan* o *bitmap* (8 % de la tabla) ✅ |
| L9 | — | — | 68.470 (+4.162 temp) | 241 | `Limit` → `Index Scan using idx_pagos_fecha_id`, sin `Sort` | `Limit` → `Index Scan using idx_pagos_fecha_id`, sin `Sort` ✅ |
| L10 | — | — | 68.412 | 247 | Igual que L9, con `Index Cond: (ROW(fecha, id) > ROW('2026-10-15', 0))` | Igual que L9, con `Index Cond: (ROW(fecha, id) > …)` ✅ |
| L11 | — | — | 8.206 | 8.206 | `usuarios_pkey` + `usuario_roles_pkey`, sin cambios | `usuarios_pkey` + `usuario_roles_pkey`, sin cambios ✅ |

Los bloques sin índice coinciden con la referencia de SCRUM-39: exactamente en L2, L3, L5, L7 y L8, y con 2 bloques de diferencia en L1. Esto confirma que es el mismo dataset y el mismo plan. Los tiempos varían con la máquina; los bloques, no.

## Resultados: escrituras

| Id | Operación | Índices en la tabla (sin → con) | Sin índice: ms | Con índice: ms | Sin índice: WAL | Con índice: WAL | Diferencia |
|---|---|---|--:|--:|--:|--:|--:|
| E1 | `INSERT` 100k tarifas | 1 → 2 | 3.655,0 | 4.045,8 | 16,0 MiB | 25,0 MiB | ms ×1,11 · WAL ×1,56 |
| E2 | `INSERT` 100k pagos | 1 → 3 (`transaccion`, `fecha, id`) | 4.124,6 | 4.689,9 | 17,5 MiB | 34,0 MiB | ms ×1,14 · WAL ×1,94 |
| E3 | `UPDATE pagado` 100k tarifas | 1 → 2 | 775,9 | 948,6 | 32,9 MiB | 41,0 MiB | ms ×1,22 · WAL ×1,24 |
| E4 | `DELETE` de 1 usuario | — | 6.645,6 | 50,8 | — | — | **~130× más rápido** |
| E5 | `DELETE` de 1 suscripción | — | 1.223,2 | 3,3 | — | — | **~370× más rápido** |

WAL = `WAL: bytes` del nodo `Insert`/`Update`. Una sola corrida por fase (`corrida 1`).

**Dónde está el costo de E1 y E2.** El `Execution Time` incluye el trigger de la FK hacia la tabla padre (`tarifas_suscripcionId_fkey` y `pagos_tarifaId_fkey`): ~3,3–3,7 s en las dos fases, porque valida 100.000 filas contra la PK. El nodo `Insert` solo, que es donde se mantienen los índices, sí sube bastante:

| Id | Nodo `Insert`/`Update`: sin → con (ms) | Registros WAL: sin → con |
|---|--:|--:|
| E1 | 327,0 → 545,3 (×1,67) | 203.305 → 304.670 (+1 entrada de índice por fila) |
| E2 | 409,6 → 1.057,6 (×2,58) | 203.305 → 404.390 (+2 entradas de índice por fila) |
| E3 | 774,8 → 947,3 (×1,22) | 301.370 → 401.933 (+1 por fila: el `UPDATE` no es HOT, como se esperaba) |

E2 se midió con **los dos** índices nuevos de `pagos`: `uq_pagos_transaccion` (prioridad 1) e `idx_pagos_fecha_id` (condicional). Solo con el de prioridad 1, el costo esperado queda a mitad de camino: +1 entrada por fila, como en E1.

Tiempo de cada `Trigger for constraint …` en E4 y E5:

| Id | Trigger | Sin índice: ms | Con índice: ms |
|---|---|--:|--:|
| E4 | `rutinas_usuarioId_fkey` | 4.938,0 | 40,0 |
| E4 | `suscripciones_usuarioId_fkey` | 1.706,7 | 9,8 |
| E4 | `usuario_roles_id_usuario_fkey` (control: ya usa la PK) | 0,63 | 0,67 |
| E5 | `tarifas_suscripcionId_fkey` | 1.223,1 | 3,1 |

El control (`usuario_roles`) no cambia, y los triggers que dependían de un *seq scan* bajan de segundos a milisegundos.

**Qué se espera:**
- **E1 a E3**: un poco más lentos y con más WAL en la fase CON. Es el costo de mantener los índices.
- **E3**: aunque `pagado` no está indexado, con `fillfactor = 100` las páginas no tienen lugar para HOT. Con el índice nuevo, cada `UPDATE` también escribe en `idx_tarifas_suscripcion`. Esa diferencia es el "peor caso" del costo de ese índice.
- **E4 y E5**: mucho más rápidos, porque hoy cada acción de FK es un *seq scan* de 6M filas.

## Resultados: almacenamiento y creación

Salida de `indices/tamanio_indices.txt` y tiempos de `indices/crear_indices.log`.

| Índice | Estimado SCRUM-39.1 | Real | Tiempo de creación |
|---|--:|--:|--:|
| `idx_rutinas_usuario` | ~130 MB | 112 MB | 13,6 s |
| `idx_suscripciones_usuario` | ~130 MB | 112 MB | 9,9 s |
| `idx_tarifas_suscripcion` | ~125 MB | 118 MB | 8,1 s |
| `uq_pagos_transaccion` | ~190 MB | 181 MB | 7,6 s (+7,7 s del chequeo previo de duplicados: no había, así que se creó `UNIQUE`) |
| `idx_usuario_roles_rol` | ~40 MB | 40 MB | 5,9 s |
| `idx_usuarios_estado` | ~40 MB | 40 MB | 5,3 s |
| `idx_pagos_fecha_id` | ~190 MB | 181 MB | 14,3 s |
| **Total prioridad 1** | **~575 MB** | **523 MB** | 39,2 s (+7,7 s) |
| **Total con condicionales** | **~845 MB** | **783 MB** | 64,8 s (+7,7 s) |

Los tamaños reales quedan entre un 5 % y un 14 % por debajo del estimado. Con los 7 índices, los índices por tabla suman +787 MB respecto de `04_verificar` de SCRUM-35: `pagos` 129 → 492 MB, `tarifas` 129 → 251 MB, `rutinas` y `suscripciones` 129 → 241 MB, `usuarios` 630 → 669 MB y `usuario_roles` 129 → 168 MB. La base completa medía 5.993 MB en ese momento (`tamanio_indices.txt`).

## Decisión

Criterios fijados **antes** de medir, para no acomodarlos a los resultados:

| Índice | Se confirma si… | Resultado | Decisión |
|---|---|---|---|
| Prioridad 1 (L1–L4) | El plan usa el índice y el tiempo caliente baja al menos **10 veces** | Los 4 planes usan el índice; mejora en caliente de ~15.500× a ~53.000× (en frío, de ~140× a ~2.500×). Además, E4 y E5 bajan ~130× y ~370× | ✅ **Se confirman los 4.** Quedan creados en la base dev |
| `idx_usuarios_estado` | L6 **sin índice** (caliente) supera **500 ms** y con índice baja a menos de la mitad | L6: 737,7 → 441,0 ms (−40 %, 1,7×). Usa *index-only*, pero no llega a la mitad (umbral: 368,9 ms). L5 sí baja a la mitad (653 → 302 ms), pero el criterio se fijó sobre L6 | ❌ **No se confirma** (por poco). No se crea. Si el dashboard sigue siendo lento, revisar primero el JIT y el cacheo del resultado, antes de sumar 40 MB de índice |
| `idx_usuario_roles_rol` | L7 **sin índice** (caliente) supera **500 ms** y con índice baja a menos de la mitad | L7: 736,8 → 532,3 ms, pero **el planificador no usa el índice** (sigue el *seq scan*): `COUNT("id_usuario")` necesita una columna que `(id_rol)` no cubre | ❌ **No se confirma** tal como está propuesto. Alternativas para medir en el ticket de optimización: cambiar a `COUNT(*)` (`id_usuario` es `NOT NULL` por ser PK), o un índice `(id_rol, id_usuario)` que sea *index-only* |
| `idx_pagos_fecha_id` | L9 y L10 bajan al menos **10 veces**. Se crea **junto con el endpoint** paginado, no antes. L8 sin paginar no cuenta: se espera que no use el índice | L9 ~300× (1.368 → 4,5 ms) y L10 ~100× (585 → 5,9 ms), con `Index Scan` y sin `Sort`. L8 pasa a *bitmap*, con solo 1,3× | ✅ **Se confirma**, pero **se crea junto con el endpoint paginado** (SCRUM-39 #5), no ahora. El runner ya lo borró |
| Costo en escrituras | E1–E3 no suben más de **2 veces** con los índices de prioridad 1 | `Execution Time`: E1 ×1,11, E2 ×1,14, E3 ×1,22. WAL: ×1,56, ×1,94 y ×1,24. Solo el nodo `Insert` de E2 pasa de 2× (×2,58), pero se midió con **2** índices nuevos en `pagos` (uno condicional) | ✅ **Se cumple.** Con los índices de prioridad 1, ninguna operación sube más de 2× en tiempo total ni en WAL |

**Estado final de la base dev:** quedan creados y válidos (`indisvalid = true`) los 4 índices de prioridad 1: `idx_rutinas_usuario`, `idx_suscripciones_usuario`, `idx_tarifas_suscripcion` y `uq_pagos_transaccion`. Los 3 condicionales se borraron al final de `comparar.sh`.

## Evidencias (`docs/evidencias/SCRUM-39/indices/`)

Se generan al ejecutar `comparar.sh`:

| Archivo | Contenido |
|---|---|
| `explain_sin_indices.txt` | Planes de L1–L11 (×3) y E1–E5 sin los índices nuevos |
| `explain_con_indices.txt` | Lo mismo con los índices creados |
| `resumen_tiempos.tsv` | `fase`, `id`, `consulta`, `corrida`, `execution_ms` de cada plan: la base para completar las tablas |
| `tamanio_indices.txt` | Tamaño de tablas e índices, e `idx_scan` |
| `crear_indices.log`, `eliminar_indices.log` | Salida de los scripts, con el tiempo de creación de cada índice (`\timing`). **No se versionan**: el `.gitignore` excluye `*.log`. Los tiempos están copiados en la tabla de almacenamiento |
| `entorno.txt` | Versión, parámetros relevantes, socio y suscripción usados, inicio y fin |
