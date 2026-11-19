# Comparativa de consultas: sin índice vs con índice (dataset 6M)

> [!NOTE]
> **Estado: pendiente de ejecución.** Los scripts están listos y **no se ejecutaron**. Las celdas marcadas *pendiente* se completan con la salida de `comparar.sh`, en `docs/evidencias/SCRUM-39/indices/`. La columna "Referencia SCRUM-39" ya tiene valores: son los planes de [`explain_candidatas.txt`](explain_candidatas.txt), medidos sin índices.

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
| L1 | Mis rutinas | 6.398,9 | *pendiente* | *pendiente* | *pendiente* | *pendiente* | *pendiente* |
| L2 | Mis tarifas | 5.463,8 | *pendiente* | *pendiente* | *pendiente* | *pendiente* | *pendiente* |
| L3 | Impagas por usuario | 845,0 | *pendiente* | *pendiente* | *pendiente* | *pendiente* | *pendiente* |
| L4 | Pago duplicado MP | — (no medida) | *pendiente* | *pendiente* | *pendiente* | *pendiente* | *pendiente* |

### Índices condicionales

| Id | Consulta | Referencia SCRUM-39 (fría) | Sin índice: fría | Sin índice: caliente | Con índice: fría | Con índice: caliente | Mejora |
|---|---|--:|--:|--:|--:|--:|--:|
| L5 | Activos, `count(*)` | 7.353,1 | *pendiente* | *pendiente* | *pendiente* | *pendiente* | *pendiente* |
| L6 | Por estado, `GROUP BY` | — | *pendiente* | *pendiente* | *pendiente* | *pendiente* | *pendiente* |
| L7 | Por rol | 1.569,9 | *pendiente* | *pendiente* | *pendiente* | *pendiente* | *pendiente* |
| L8 | Pagos de un mes, sin paginar | 13.987,3 | *pendiente* | *pendiente* | *pendiente* | *pendiente* | *pendiente* |
| L9 | Pagos, primera página | — | *pendiente* | *pendiente* | *pendiente* | *pendiente* | *pendiente* |
| L10 | Pagos, página *keyset* | — | *pendiente* | *pendiente* | *pendiente* | *pendiente* | *pendiente* |

### Control

| Id | Consulta | Sin índice: caliente | Con índice: caliente | ¿Cambió el plan? |
|---|---|--:|--:|---|
| L11 | Socios paginados | *pendiente* | *pendiente* | *pendiente* (se espera que no) |

### Bloques leídos y plan

Bloques = `shared hit + read` del nodo raíz, en la corrida fría.

| Id | Referencia SCRUM-39: bloques | Plan sin índice (SCRUM-39) | Sin índice: bloques | Con índice: bloques | Plan con índice | Plan esperado con índice |
|---|--:|---|--:|--:|---|---|
| L1 | 105.066 | `Parallel Seq Scan on rutinas` | *pendiente* | *pendiente* | *pendiente* | `Index Scan using idx_rutinas_usuario` → *nested loop* |
| L2 | 123.912 | 2 × `Parallel Seq Scan` + `Parallel Hash Join` | *pendiente* | *pendiente* | *pendiente* | `Index Scan` suscripciones → `Index Scan` tarifas (*nested loop*) |
| L3 | 123.913 | Igual que L2 | *pendiente* | *pendiente* | *pendiente* | Igual que L2 |
| L4 | — | (esperado) `Seq Scan on pagos` completo | *pendiente* | *pendiente* | *pendiente* | `Index Scan using uq_pagos_transaccion`, 0 filas |
| L5 | 134.217 | `Parallel Seq Scan on usuarios` | *pendiente* | *pendiente* | *pendiente* | `Index Only Scan using idx_usuarios_estado`, `Heap Fetches: 0` |
| L6 | — | — | *pendiente* | *pendiente* | *pendiente* | `Index Only Scan` + `GroupAggregate` |
| L7 | 26.563 | `Parallel Seq Scan on usuario_roles` | *pendiente* | *pendiente* | *pendiente* | `Index Only Scan using idx_usuario_roles_rol` |
| L8 | 124.389 (+5.289 temp) | `Parallel Seq Scan on pagos` + `external merge` | *pendiente* | *pendiente* | *pendiente* | Probablemente sigue con *seq scan* o *bitmap* (8 % de la tabla) |
| L9 | — | — | *pendiente* | *pendiente* | *pendiente* | `Limit` → `Index Scan using idx_pagos_fecha_id`, sin `Sort` |
| L10 | — | — | *pendiente* | *pendiente* | *pendiente* | Igual que L9, con `Index Cond: (ROW(fecha, id) > …)` |
| L11 | — | — | *pendiente* | *pendiente* | *pendiente* | `usuarios_pkey` + `usuario_roles_pkey`, sin cambios |

## Resultados: escrituras

| Id | Operación | Índices en la tabla (sin → con) | Sin índice: ms | Con índice: ms | Sin índice: WAL | Con índice: WAL | Diferencia |
|---|---|---|--:|--:|--:|--:|--:|
| E1 | `INSERT` 100k tarifas | 1 → 2 | *pendiente* | *pendiente* | *pendiente* | *pendiente* | *pendiente* |
| E2 | `INSERT` 100k pagos | 1 → 3 (`transaccion`, `fecha, id`) | *pendiente* | *pendiente* | *pendiente* | *pendiente* | *pendiente* |
| E3 | `UPDATE pagado` 100k tarifas | 1 → 2 | *pendiente* | *pendiente* | *pendiente* | *pendiente* | *pendiente* |
| E4 | `DELETE` de 1 usuario | — | *pendiente* | *pendiente* | — | — | *pendiente* |
| E5 | `DELETE` de 1 suscripción | — | *pendiente* | *pendiente* | — | — | *pendiente* |

Para E4 y E5, anotar también el tiempo de cada `Trigger for constraint …`:

| Id | Trigger | Sin índice: ms | Con índice: ms |
|---|---|--:|--:|
| E4 | `rutinas_usuarioId_fkey` | *pendiente* | *pendiente* |
| E4 | `suscripciones_usuarioId_fkey` | *pendiente* | *pendiente* |
| E4 | `usuario_roles_id_usuario_fkey` (control: ya usa la PK) | *pendiente* | *pendiente* |
| E5 | `tarifas_suscripcionId_fkey` | *pendiente* | *pendiente* |

**Qué se espera:**
- **E1 a E3**: un poco más lentos y con más WAL en la fase CON. Es el costo de mantener los índices.
- **E3**: aunque `pagado` no está indexado, con `fillfactor = 100` las páginas no tienen lugar para HOT. Con el índice nuevo, cada `UPDATE` también escribe en `idx_tarifas_suscripcion`. Esa diferencia es el "peor caso" del costo de ese índice.
- **E4 y E5**: mucho más rápidos, porque hoy cada acción de FK es un *seq scan* de 6M filas.

## Resultados: almacenamiento y creación

Salida de `indices/tamanio_indices.txt` y tiempos de `indices/crear_indices.log`.

| Índice | Estimado SCRUM-39.1 | Real | Tiempo de creación |
|---|--:|--:|--:|
| `idx_rutinas_usuario` | ~130 MB | *pendiente* | *pendiente* |
| `idx_suscripciones_usuario` | ~130 MB | *pendiente* | *pendiente* |
| `idx_tarifas_suscripcion` | ~125 MB | *pendiente* | *pendiente* |
| `uq_pagos_transaccion` | ~190 MB | *pendiente* | *pendiente* |
| `idx_usuario_roles_rol` | ~40 MB | *pendiente* | *pendiente* |
| `idx_usuarios_estado` | ~40 MB | *pendiente* | *pendiente* |
| `idx_pagos_fecha_id` | ~190 MB | *pendiente* | *pendiente* |
| **Total prioridad 1** | **~575 MB** | *pendiente* | |
| **Total con condicionales** | **~845 MB** | *pendiente* | |

## Decisión

Criterios fijados **antes** de medir, para no acomodarlos a los resultados:

| Índice | Se confirma si… | Resultado | Decisión |
|---|---|---|---|
| Prioridad 1 (L1–L4) | El plan usa el índice y el tiempo caliente baja al menos **10 veces** | *pendiente* | *pendiente* |
| `idx_usuarios_estado` | L6 **sin índice** (caliente) supera **500 ms** y con índice baja a menos de la mitad | *pendiente* | *pendiente* |
| `idx_usuario_roles_rol` | L7 **sin índice** (caliente) supera **500 ms** y con índice baja a menos de la mitad | *pendiente* | *pendiente* |
| `idx_pagos_fecha_id` | L9 y L10 bajan al menos **10 veces**. Se crea **junto con el endpoint** paginado, no antes. L8 sin paginar no cuenta: se espera que no use el índice | *pendiente* | *pendiente* |
| Costo en escrituras | E1–E3 no suben más de **2 veces** con los índices de prioridad 1 | *pendiente* | *pendiente* |

## Evidencias (`docs/evidencias/SCRUM-39/indices/`)

Se generan al ejecutar `comparar.sh`:

| Archivo | Contenido |
|---|---|
| `explain_sin_indices.txt` | Planes de L1–L11 (×3) y E1–E5 sin los índices nuevos |
| `explain_con_indices.txt` | Lo mismo con los índices creados |
| `resumen_tiempos.tsv` | `fase`, `id`, `consulta`, `corrida`, `execution_ms` de cada plan: la base para completar las tablas |
| `tamanio_indices.txt` | Tamaño de tablas e índices, e `idx_scan` |
| `crear_indices.log`, `eliminar_indices.log` | Salida de los scripts, con el tiempo de creación de cada índice (`\timing`) |
| `entorno.txt` | Versión, parámetros relevantes, socio y suscripción usados, inicio y fin |
