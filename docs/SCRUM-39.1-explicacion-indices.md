# SCRUM-39.1 — Índices propuestos para las consultas candidatas

## Objetivo

A partir de las 10 consultas elegidas en [SCRUM-39](SCRUM-39-analisis-consultas-pgbadger.md), decidir **qué índices agregar, cuáles no y por qué**. Para cada consulta se evalúan índices simples, compuestos y de cobertura, y cada índice se justifica por tres lados: qué consulta medida lo usa, cuánto cuesta en `INSERT`/`UPDATE` y cuánto ocupa.

Este documento **solo propone**. No crea índices ni cambia código; el script está en [Script propuesto](#script-propuesto) para aplicarlo en el ticket de optimización.

## Cómo responde a la consigna

| Consigna | Dónde |
|---|---|
| Evaluar índices simples, compuestos y de cobertura cuando correspondan | [Análisis por consulta](#análisis-por-consulta) y [Índices evaluados y descartados](#índices-evaluados-y-descartados) |
| No crear índices de forma indiscriminada: justificar su utilidad | [Criterios](#criterios-para-aceptar-un-índice) y la columna "Consulta que lo usa" del [resumen](#resumen-de-decisiones) |
| Impacto en inserciones y actualizaciones | [Impacto en escrituras](#impacto-en-escrituras) |
| Impacto en almacenamiento | [Impacto en almacenamiento](#impacto-en-almacenamiento) |

## Punto de partida

### Índices que ya existen

`database/01_schema.sql` (y `database/dataset/03_restaurar_indices.sql`) solo crean los índices implícitos de las `PRIMARY KEY` y los `UNIQUE`:

| Tabla | Índices actuales |
|---|---|
| `usuarios` | `usuarios_pkey (id)`, `usuarios_dni_key (dni)`, `usuarios_email_key (email)` |
| `usuario_roles` | `usuario_roles_pkey (id_usuario, id_rol)` |
| `roles` | `roles_pkey (id)`, `roles_nombre_key (nombre)` |
| `rutinas`, `suscripciones`, `tarifas`, `pagos`, `ejercicios` | Solo la PK `(id)` |
| `rutina_ejercicios` | `rutina_ejercicios_pkey (id_rutina, id_ejercicio)` |

**Ninguna FK tiene índice.** PostgreSQL indexa automáticamente la PK del lado padre, pero no la columna FK del lado hijo. Por eso las tres consultas por usuario (93,6 % del tiempo en SCRUM-39) terminan en *seq scan*.

### Tamaño de las tablas

El contenedor no estaba levantado al escribir este documento, así que los tamaños salen de los bloques leídos por los *seq scan* completos de `explain_candidatas.txt` (1 bloque = 8 KB). Hay que confirmarlos con la consulta de [Validación](#validación).

| Tabla | Filas | Bloques | Tamaño aprox. |
|---|--:|--:|--:|
| `usuarios` | 6.000.000 | 134.217 | 1,05 GB |
| `rutinas` | 6.000.000 | 105.060 | 820 MB |
| `pagos` | 6.000.000 | 68.182 | 533 MB |
| `suscripciones` | 6.000.000 | 67.718 | 529 MB |
| `tarifas` | 6.000.000 | 56.075 | 438 MB |
| `usuario_roles` | 6.000.000 | 26.549 | 207 MB |

**Referencia para estimar índices:** `usuario_roles_pkey`, un B-tree de 6M entradas `(int4, int4)`, ocupa 16.397 bloques (**128 MB**), según el *index-only scan* de C4. Un B-tree sobre una sola columna `int4` ocupa lo mismo, porque la tupla del índice se alinea a 8 bytes igual. Por eso cada índice sobre una FK entera de 6M filas se estima en **~130 MB**.

## Criterios para aceptar un índice

Un índice se agrega solo si cumple **todo** esto:

1. **Lo usa una consulta que existe y se midió** en SCRUM-39 (o, en un caso marcado, una que existe en el código). No se crean índices "por si acaso" ni para endpoints que no existen.
2. **Es selectivo para esa consulta**: devuelve una fracción chica de la tabla, o permite un *index-only scan* mucho más chico que la tabla.
3. **No indexa columnas que la app actualiza seguido.** Si un `UPDATE` cambia una columna indexada (incluidas las de `INCLUDE`), PostgreSQL no puede hacer una actualización **HOT** (*heap-only tuple*) y tiene que insertar una entrada nueva en **todos** los índices de la tabla. Es el caso de `tarifas.pagado`, que cambia con cada pago y con cada anulación.
4. **Sirve a varias consultas cuando se puede.** Se prefiere un índice simple que usan tres consultas antes que tres índices a medida.
5. **El tamaño es proporcional al beneficio.** Un índice de cobertura que copia media tabla para ahorrar una lectura de página no se justifica.

### Qué cuesta un índice

- **`INSERT`**: una inserción más en el B-tree por cada índice (bajar ~3 niveles, escribir una hoja y su registro de WAL).
- **`UPDATE`**: si no cambia ninguna columna indexada y hay lugar en la página, el `UPDATE` es HOT y los índices no se tocan. Si no, se actualizan **todos** los índices de la tabla, no solo el nuevo.
- **`DELETE`**: no toca el índice en el momento, pero `VACUUM` tiene que recorrerlo para limpiar las entradas muertas.
- **Almacenamiento y caché**: el índice ocupa disco y compite por los 512 MB de `shared_buffers`.
- **Replicación** (SCRUM-45): crear el índice genera WAL del tamaño del índice, que la réplica tiene que reproducir.

## Resumen de decisiones

| # | Índice | Tipo | Consulta que lo usa | Decisión |
|--:|---|---|---|---|
| 1 | `rutinas ("usuarioId")` | Simple | C1 Mis rutinas (32,5 % del tiempo) | **Crear** (prioridad 1) |
| 2 | `suscripciones ("usuarioId")` | Simple | C2 Mis tarifas, C3 Impagas (61,1 %) | **Crear** (prioridad 1) |
| 3 | `tarifas ("suscripcionId")` | Simple | C2, C3 y la validación de `deleteSuscricion` | **Crear** (prioridad 1) |
| 4 | `pagos (transaccion)` | Simple, `UNIQUE` | Control de pago duplicado de MercadoPago (`pago.controller.js:78`) | **Crear** (prioridad 1, no medido; ver [hallazgo](#hallazgo-fuera-de-la-muestra-pagos-transaccion)) |
| 5 | `usuario_roles (id_rol)` | Simple, *index-only* | C7 Dashboard por rol | **Condicional**: solo si el dashboard sigue lento después de reescribirlo |
| 6 | `usuarios (estado)` | Simple, *index-only* | C6 Dashboard por estado | **Condicional**: igual que #5 |
| 7 | `pagos (fecha, id)` | **Compuesto** | C8 Pagos por rango | **Condicional**: solo cuando exista el endpoint, y paginado |
| — | C4, C5, C9, C10, usuario por DNI, ILIKE | — | — | **Ningún índice nuevo**: se resuelven cambiando la consulta o ya tienen índice |

Los **compuestos y de cobertura** que se evaluaron y no se eligen, con el motivo de cada uno, están en [Índices evaluados y descartados](#índices-evaluados-y-descartados).

## Análisis por consulta

### C1 — Mis rutinas → `rutinas ("usuarioId")`

```sql
SELECT "Rutina".*, "ejercicios".* FROM rutinas AS "Rutina"
LEFT JOIN (rutina_ejercicios JOIN ejercicios ON ...) ON "Rutina".id = ...id_rutina
WHERE "Rutina"."usuarioId" = $1;
```

- **Plan actual**: `Parallel Seq Scan on rutinas` que descarta 6M filas y lee 105.060 bloques (820 MB) para devolver **1** rutina (6,4 s en frío, 1.864 ms de media). El *join* con ejercicios ya usa `rutina_ejercicios_pkey`: el problema es solo el filtro.
- **Simple** `("usuarioId")`: es lo que falta. Selectividad máxima (1,3 filas por usuario sobre 6M). El plan pasa a `Index Scan` → *nested loop* con la PK de `rutina_ejercicios`: unas pocas páginas en vez de 105.060.
- **Compuesto** `("usuarioId", activo)`: no aporta. La consulta no filtra por `activo`, y aunque lo hiciera, con 1,3 filas por usuario el filtro sobre el *heap* no cuesta nada.
- **Cobertura** `("usuarioId") INCLUDE (...)`: la consulta pide **todas** las columnas de `rutinas` (`dia_semana`, `turno`, `nombre`, `descripcion`…). Cubrirla sería duplicar la tabla de 820 MB dentro del índice para ahorrar 1 lectura de página por llamada. Descartado.
- **Uso extra**: `getRutinas` con filtro `idUsuario`, y el `ON DELETE SET NULL` de `rutinas."usuarioId"`. Hoy, **borrar un usuario recorre las 6M rutinas** para buscar las que apuntan a él.
- **Escrituras**: `rutinas` la modifican los entrenadores (alta, edición, baja: decenas por día). `"usuarioId"` casi no cambia en una edición, así que los `UPDATE` siguen siendo candidatos a HOT.
- **Tamaño**: ~130 MB.

### C2 Mis tarifas y C3 Impagas → `suscripciones ("usuarioId")` + `tarifas ("suscripcionId")`

```sql
-- C2 (C3 es igual, más WHERE pagado = false AND activo = true y ORDER BY anio, mes ASC)
SELECT "Tarifa".*, suscripcion.* FROM tarifas AS "Tarifa"
JOIN suscripciones AS suscripcion
  ON "Tarifa"."suscripcionId" = suscripcion.id AND suscripcion."usuarioId" = $1
ORDER BY "Tarifa".anio DESC, "Tarifa".mes DESC;
```

- **Plan actual**: dos *seq scan* completos, uno de `suscripciones` (67.718 bloques, para encontrar 1 fila) y otro de `tarifas` (56.075 bloques, 6M filas), unidos con *hash join*. Cada llamada lee ~1 GB para devolver 1 fila.
- **Hacen falta los dos índices**. Con uno solo, la consulta sigue recorriendo la otra tabla completa. Con ambos, el plan esperado es `Index Scan` sobre `suscripciones` (1 fila) → `Index Scan` sobre `tarifas` por `"suscripcionId"` (0 a 3 filas, según SCRUM-35) → `Sort` de 1 a 3 filas.
- **Un mismo par de índices sirve a C2 y C3**, y a `deleteSuscricion` (`Tarifa.findOne({ where: { suscripcionId } })`). También al `ON DELETE SET NULL` de `tarifas."suscripcionId"` y de `suscripciones."usuarioId"` cuando se borra una suscripción o un usuario.

**Alternativas evaluadas para C3, y por qué se descartan:**

| Alternativa | Por qué no |
|---|---|
| Parcial `tarifas ("suscripcionId") WHERE NOT pagado AND activo` (sugerida como opcional en SCRUM-39) | Sirve solo a C3. C2 necesita igual el índice completo, así que serían **dos** índices sobre la misma columna. Además, `pagado` cambia en cada pago (`pago.controller.js:93`) y en cada anulación (`:167`): la fila entra y sale del índice parcial y esos `UPDATE` dejan de ser HOT. Con 0 a 3 tarifas por suscripción, filtrar `pagado`/`activo` en el *heap* cuesta nada |
| Compuesto `tarifas ("suscripcionId", pagado, activo)` | Mismo problema de HOT: cada pago tendría que actualizar **todos** los índices de `tarifas`. La ganancia es nula con 0 a 3 filas por suscripción |
| Compuesto `tarifas ("suscripcionId", anio, mes)` para evitar el `Sort` | El orden es sobre las tarifas de **todas** las suscripciones del usuario, no de una sola, así que el índice no entrega las filas ya ordenadas. Además, ordenar 1 a 3 filas en memoria (`quicksort 25kB`) no es un costo |
| Cobertura `suscripciones ("usuarioId") INCLUDE (id, fecha_inicio, fecha_fin, precio, activo)` | Ahorra 1 lectura de página por llamada a cambio de copiar 4 columnas `VARCHAR` de 6M filas (cientos de MB). La consulta devuelve 1 fila, así que el *heap fetch* es despreciable |

- **Escrituras**:
  - `suscripciones`: se escribe en el alta, la edición y la baja de una suscripción. `"usuarioId"` no cambia después del alta.
  - `tarifas`: hay un `INSERT` por mes facturado y `UPDATE` de `pagado`/`activo` en cada pago o anulación. Como el índice está sobre `"suscripcionId"`, **los `UPDATE` de pago siguen siendo candidatos a HOT**. Por esta razón el índice es simple y no incluye `pagado`.
- **Tamaño**: ~130 MB cada uno.

### C8 Pagos por rango de fechas → `pagos (fecha, id)` (condicional)

```sql
SELECT "Pago".*, tarifa.anio, tarifa.mes, tarifa.precio, tarifa.activo
FROM pagos AS "Pago" LEFT JOIN tarifas AS tarifa ON "Pago"."tarifaId" = tarifa.id
WHERE "Pago".fecha BETWEEN '2026-10-01' AND '2026-10-31'
ORDER BY "Pago".fecha;
```

- **Plan actual**: `Parallel Seq Scan on pagos` (533 MB), *hash join* contra las 6M `tarifas` y `Sort ... external merge` (~14 MB a disco por *worker*). Es la única consulta con archivos temporales.
- **Hoy no hay endpoint** que haga esta consulta: `GET /api/pagos` trae la tabla entera. **Crear el índice ahora sería pagar el costo de escritura sin ninguna lectura que lo use.** Se crea junto con el endpoint.
- **Por qué compuesto `(fecha, id)` y no simple `(fecha)`**: un mes devuelve ~480.000 pagos (8 % de la tabla). Para ese volumen, un índice sobre `fecha` sin `LIMIT` no le gana a un *seq scan*: el planificador haría un *bitmap scan* que igual visita casi todas las páginas, porque las fechas de los pagos no siguen el orden físico de la tabla. El índice sirve cuando el reporte está **paginado** (SCRUM-39, mejora #5):
  ```sql
  WHERE (fecha, id) > ($ultima_fecha, $ultimo_id) AND fecha <= $hasta
  ORDER BY fecha, id LIMIT 50
  ```
  Con *keyset pagination* hace falta un desempate único, porque hay ~16.000 pagos por día con la misma `fecha`. `(fecha, id)` entrega las filas ya ordenadas: no hay `Sort`, no hay derrame a disco, y cada página lee ~50 entradas. El *join* con `tarifas` usa `tarifas_pkey`, que ya existe.
- **Cobertura** `(fecha, id) INCLUDE ("tarifaId", monto, transaccion, ...)`: la consulta pide las 8 columnas de `pagos`, así que cubrirla es copiar la tabla. Descartado.
- **`fecha` es `VARCHAR`**: con el formato fijo `YYYY-MM-DD`, el orden de texto coincide con el cronológico y el B-tree funciona. Migrarla a `DATE` achicaría el índice (4 bytes contra 11) y se recomienda en el mismo ticket del endpoint.
- **Escrituras**: `pagos` recibe 1 `INSERT` por pago y 1 `UPDATE` de `activo` por anulación. `fecha` no se modifica nunca, así que el índice solo suma costo en el `INSERT`, y como `fecha` es la fecha del día, la inserción cae siempre en la última hoja del B-tree.
- **Tamaño**: ~190 MB como `VARCHAR`. No hay deduplicación porque cada `(fecha, id)` es único. El simple `(fecha)` ocuparía ~45 MB gracias a la deduplicación de B-tree (PostgreSQL ≥ 13), pero no sirve para paginar.

### C7 Dashboard por rol → `usuario_roles (id_rol)` (condicional)

```sql
SELECT id_rol, COUNT(id_usuario) FROM usuario_roles GROUP BY id_rol;
```

- **Plan actual**: `Parallel Seq Scan` de las 6M filas (207 MB) + `HashAggregate` → 3 filas. 952 ms de media.
- **`id_rol` tiene 3 valores** (98,4 % socio). Como filtro, el índice no sirve. Sirve solo para que el conteo sea un ***index-only scan*** sobre un índice mucho más chico que la tabla: con la deduplicación, 6M entradas con 3 claves distintas ocupan ~40 MB, contra 207 MB del *heap*.
- **Compuesto `(id_rol, id_usuario)`** (sugerido en SCRUM-39 para C4): no se elige. Las entradas son únicas, así que no se deduplican y el índice ocupa ~128 MB. Además, la paginación de socios no lo necesita (ver C4). Solo se justificaría si existiera un listado paginado de un rol **minoritario** (admins, entrenadores), y ese endpoint no existe.
- **Por qué es condicional**: el dashboard lo usan solo los administradores (5 llamadas en la carga). Primero hay que aplicar las reescrituras de SCRUM-39 (#6 a #8). Si `getStats` sigue tardando más de **500 ms**, se crea este índice. Si no, no.
- **Escrituras**: 1 `INSERT` por alta de usuario (`auth.controller.js:101`, `usuario.controller.js:32`). `id_rol` nunca se actualiza. El costo es mínimo.
- **Alternativa sin índice**: si el dashboard tiene que responder en milisegundos, conviene más un contador o una vista materializada que cualquier índice.

### C6 Dashboard por estado → `usuarios (estado)` (condicional)

```sql
SELECT count(*) FROM usuarios WHERE estado = $1;   -- hoy, dos veces por llamada
```

- **Plan actual**: dos `Parallel Seq Scan` completos de `usuarios`, la tabla más grande (1,05 GB, no entra en `shared_buffers`). En frío tardan 7,3 s.
- **Un índice sobre un booleano es, en general, un antipatrón**: con 92 % `true`, nunca conviene para filtrar. Acá se evalúa con un fin distinto: un ***index-only scan*** que cuente sobre ~40 MB (deduplicado: 2 claves) en lugar de leer 1,05 GB.
- **Primero se reescribe la consulta**: `SELECT estado, count(*) FROM usuarios GROUP BY estado` (1 recorrido en vez de 2). El índice se crea solo si, después de eso, el dashboard sigue por encima de 500 ms. Es el mismo criterio que C7.
- **Escrituras**: `usuarios` es la tabla que más `UPDATE` recibe (edición de perfil). Los `UPDATE` que no tocan `estado` siguen siendo candidatos a HOT. Solo `activeUsuario`/`inactiveUsuario` (`usuario.controller.js:115-136`) cambian `estado`, y esos dejarían de ser HOT y actualizarían los 4 índices de la tabla. Es una operación de administrador, poco frecuente.
- **Requisito**: el *index-only scan* depende de que el *visibility map* esté al día. Si `autovacuum` se atrasa, aparecen `Heap Fetches` y la ventaja se pierde. Se controla con `EXPLAIN (ANALYZE)`.

### Consultas que no necesitan índice nuevo

| Consulta | Por qué no |
|---|---|
| **C4 Socios activos** | El problema es que devuelve 5,4M filas, y **ningún índice achica un resultado de 5,4M filas**. La solución es paginar (SCRUM-39 #4). Con *keyset* por `usuarios.id` (`WHERE u.estado AND u.id > $ultimo ORDER BY u.id LIMIT 50`), el plan recorre `usuarios_pkey` desde `$ultimo` y comprueba el rol con `usuario_roles_pkey (id_usuario, id_rol)`. **Los dos índices ya existen.** Esto ajusta la propuesta de SCRUM-39, que sugería agregar `(id_rol, id_usuario)` |
| **C5 Dashboard: tarifas pagadas** | Hoy devuelve 4,8M precios para sumarlos en Node. La solución es `SELECT sum(precio::numeric) ... WHERE pagado AND activo`. Se evaluó una cobertura `tarifas (pagado, activo) INCLUDE (precio)` o una parcial `tarifas (precio) WHERE pagado AND activo`. Las dos cubren el **80 % de la tabla** (el índice pesaría casi lo que la tabla) y las dos indexan `pagado`, así que **cada pago dejaría de ser HOT**. Descartadas: el *seq scan* de 438 MB que devuelve 1 fila es aceptable para un dashboard |
| **C9 `verificarRol`** | Las dos consultas ya están cubiertas: `roles` tiene 3 filas en 1 página (un *seq scan* le gana a cualquier índice) y la búsqueda en `usuario_roles` ya es un *index-only scan* sobre la PK (`Heap Fetches: 0`, 0,17 ms). El costo está en los viajes de ida y vuelta, no en el plan. Se resuelve en el código (rol en el JWT o una sola consulta) |
| **C10 Login** | Usa `usuarios_email_key`, `usuario_roles_pkey` y `roles_pkey`. Se evaluó una cobertura `usuarios (email) INCLUDE (id, password_hash, estado)` para que el login no lea el *heap*. Se descarta: copia el email y el hash bcrypt de 6M usuarios (~700 MB) para ahorrar 1 página por login, y `password_hash` quedaría duplicado en otro objeto. Además, la consulta hoy pide todas las columnas, así que igual leería el *heap* |
| **Usuario por DNI** (descartada en SCRUM-39) | Ya usa `usuarios_dni_key`: 2,6 ms en el `EXPLAIN` aislado |
| **Ejercicios ILIKE** (descartada en SCRUM-39) | Son 200 filas en 4 páginas. Un GIN con `pg_trgm` solo se justificaría si el catálogo creciera a decenas de miles de filas |

### Hallazgo fuera de la muestra: `pagos (transaccion)`

No figura en el top de SCRUM-39 porque la carga no pudo generar pagos reales de MercadoPago (dependen del servicio externo). Pero el código lo hace **en cada pago de un socio**:

```js
// pago.controller.js:78
const yaUsado = await Pago.findOne({ where: { transaccion: `MP-${pagoMP.id}` } });
```

- Sin índice, cada pago con MercadoPago hace un *seq scan* de los 6M pagos (533 MB) antes de registrarse, y esa es la operación más sensible de la app.
- El control además tiene una **condición de carrera**: dos notificaciones simultáneas del mismo pago pasan las dos el `findOne` y se registran dos veces. Un índice `UNIQUE` resuelve el rendimiento y además garantiza la unicidad en el motor.
- SCRUM-35 ya verifica que `transaccion` sea única en el dataset (`04_verificar.sql`). **Antes de crear el índice hay que repetir la verificación sobre la base real**, porque los pagos manuales de un administrador cargan `transaccion` a mano. Si aparecen duplicados legítimos, se usa un índice simple no único y la carrera se resuelve de otra forma.
  ```sql
  SELECT transaccion, count(*) FROM pagos GROUP BY transaccion HAVING count(*) > 1;
  ```
- **Escrituras**: 1 inserción en el índice por pago; `transaccion` nunca se actualiza.
- **Tamaño**: ~190 MB (claves de 13 caracteres, únicas, sin deduplicación).

## Índices evaluados y descartados

| Índice | Tipo | Para | Por qué no |
|---|---|---|---|
| `tarifas ("suscripcionId") WHERE NOT pagado AND activo` | Parcial | C3 | Duplica el índice de C2 y C3, y `pagado` cambia en cada pago (rompe HOT) |
| `tarifas ("suscripcionId", pagado, activo)` | Compuesto | C3 | Rompe HOT en cada pago. Ganancia nula con 0 a 3 filas por suscripción |
| `tarifas ("suscripcionId", anio, mes)` | Compuesto | C2, C3 | El orden abarca varias suscripciones. Ordenar 1 a 3 filas no cuesta |
| `tarifas (pagado, activo) INCLUDE (precio)` | Cobertura | C5 | Cubre el 80 % de la tabla y rompe HOT. Se resuelve con `SUM` en SQL |
| `rutinas ("usuarioId") INCLUDE (...)` | Cobertura | C1 | La consulta pide todas las columnas: sería duplicar la tabla |
| `suscripciones ("usuarioId") INCLUDE (...)` | Cobertura | C2, C3 | Cientos de MB para ahorrar 1 página por llamada |
| `pagos (fecha) INCLUDE (...)` | Cobertura | C8 | La consulta pide todas las columnas de `pagos` |
| `pagos (fecha)` | Simple | C8 | No permite *keyset* con desempate. Sin paginar, no le gana al *seq scan* para un mes |
| `usuario_roles (id_rol, id_usuario)` | Compuesto | C4, C7 | C4 se resuelve con las PK existentes. Para C7, el simple es 3 veces más chico |
| `usuarios (email) INCLUDE (id, password_hash, estado)` | Cobertura | C10 | ~700 MB para ahorrar 1 página por login, y duplica `password_hash` |
| `pagos ("tarifaId")` | Simple (FK) | — | Ninguna consulta busca pagos por tarifa (`anularPago` usa `findByPk`), y las tarifas no se borran: se anulan con `activo = false` |
| `rutina_ejercicios (id_ejercicio)` | Simple (FK) | — | Solo lo usaría el `ON DELETE CASCADE` al borrar un ejercicio, que es una operación excepcional sobre un catálogo de 200 filas |
| `ejercicios USING gin (nombre gin_trgm_ops)` | GIN | ILIKE | 200 filas: el *seq scan* entra en 4 páginas |

## Impacto en escrituras

| Tabla | Escrituras que hace la app | Índices hoy → después | Efecto |
|---|---|---|---|
| `rutinas` | Alta, edición y baja de rutinas (entrenadores) | 1 → 2 | +1 inserción de B-tree por rutina nueva. Las ediciones siguen siendo candidatas a HOT |
| `suscripciones` | Alta, edición y baja | 1 → 2 | +1 inserción por suscripción. `"usuarioId"` no cambia |
| `tarifas` | 1 `INSERT` por cuota. `UPDATE pagado` en cada pago y anulación | 1 → 2 | +1 inserción por cuota. **Los `UPDATE` de pago no tocan columnas indexadas**: siguen siendo candidatos a HOT (por eso se descartaron los índices con `pagado`) |
| `pagos` | 1 `INSERT` por pago, `UPDATE activo` por anulación | 1 → 2 (`transaccion`) → 3 si se crea el endpoint (`fecha, id`) | +1 o +2 inserciones por pago. `fecha` y `transaccion` no se actualizan nunca |
| `usuario_roles` | 1 `INSERT` por alta de usuario | 1 → 2 solo si se activa el condicional | `id_rol` no se actualiza |
| `usuarios` | Alta, edición de perfil, activar/desactivar, baja | 3 → 4 solo si se activa el condicional | Solo activar/desactivar deja de ser HOT |

**En volumen, el costo es bajo**: la app de un gimnasio hace decenas o cientos de escrituras por día, y cada índice agrega una inserción de B-tree de microsegundos. En cambio, cada lectura de C1 a C3 hoy recorre entre 820 MB y 1 GB.

**Los índices de FK también aceleran escrituras.** Hoy, `DELETE FROM usuarios` dispara el `ON DELETE SET NULL` de `rutinas."usuarioId"` y `suscripciones."usuarioId"`, y PostgreSQL busca las filas hijas con **dos *seq scan* de 6M filas** (~1,35 GB). Borrar una suscripción hace lo mismo sobre `tarifas`. Con los índices, esas búsquedas pasan a ser por índice.

**Carga masiva (SCRUM-35)**: el costo por fila sí importa en una carga de 6M filas. `01_preparar.sql` hoy borra solo las restricciones (PK, UNIQUE, FK) antes de cargar y `03_restaurar_indices.sql` las recrea al final. Si se agregan estos índices, hay que sumarlos a los dos scripts. Si no, la carga los mantendría fila por fila.

### Riesgo de HOT con `fillfactor = 100`

Las tablas se cargaron con el `fillfactor` por defecto (100 %), así que al principio las páginas no tienen lugar libre para una versión HOT de la fila. Los primeros `UPDATE` sobre `tarifas` van a otra página y actualizan los índices igual. Con el uso, `VACUUM` libera espacio y aparecen los HOT. Si después de aplicar los índices `n_tup_hot_upd` de `tarifas` queda muy por debajo de `n_tup_upd`, se puede bajar el `fillfactor` de `tarifas` a 90. Queda como seguimiento, no como parte de este cambio.

## Impacto en almacenamiento

Estimado con la referencia de `usuario_roles_pkey` (6M entradas = 128 MB) y la deduplicación de B-tree para las claves repetidas. Hay que confirmarlo con `pg_relation_size` después de crear cada índice.

| Índice | Prioridad | Tamaño estimado |
|---|---|--:|
| `rutinas ("usuarioId")` | 1 | ~130 MB |
| `suscripciones ("usuarioId")` | 1 | ~130 MB |
| `tarifas ("suscripcionId")` | 1 | ~125 MB |
| `pagos (transaccion)` `UNIQUE` | 1 | ~190 MB |
| **Subtotal prioridad 1** | | **~575 MB** (+11 % sobre los 5,2 GB de la base) |
| `usuario_roles (id_rol)` | Condicional | ~40 MB |
| `usuarios (estado)` | Condicional | ~40 MB |
| `pagos (fecha, id)` | Condicional (endpoint) | ~190 MB (~150 MB con `fecha DATE`) |
| **Total si se activan todos** | | **~845 MB** (+16 %) |

Comparación: los índices de prioridad 1 ocupan **~575 MB** y eliminan lecturas de **~1 GB por llamada** en las consultas que hoy suman el 93,6 % del tiempo de la base.

## Script propuesto

El script está en [`database/analisis/indices/crear_indices.sql`](../database/analisis/indices/crear_indices.sql), y la medición sin índice contra con índice, en [`evidencias/SCRUM-39/comparativa-indices-consultas.md`](evidencias/SCRUM-39/comparativa-indices-consultas.md). El archivo agrega dos controles al bloque de abajo: aborta si quedó un índice `INVALID` y crea `pagos (transaccion)` no único si hay duplicados.

> [!NOTE]
> No se ejecuta en este ticket. `CREATE INDEX CONCURRENTLY` no bloquea las escrituras mientras construye el índice (hace dos pasadas por la tabla), pero no puede correr dentro de una transacción: hay que ejecutar cada sentencia por separado, no con `psql -1`. Si una falla, queda un índice `INVALID` que hay que borrar con `DROP INDEX CONCURRENTLY` antes de reintentar.

```sql
-- ===== Prioridad 1: FK de las consultas por usuario (C1, C2, C3) =====
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_rutinas_usuario       ON rutinas       ("usuarioId");
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_suscripciones_usuario ON suscripciones ("usuarioId");
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tarifas_suscripcion   ON tarifas       ("suscripcionId");

-- ===== Prioridad 1: control de pago duplicado (verificar antes que no haya duplicados) =====
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS uq_pagos_transaccion ON pagos (transaccion);

ANALYZE rutinas; ANALYZE suscripciones; ANALYZE tarifas; ANALYZE pagos;

-- ===== Condicionales: solo si getStats sigue > 500 ms después de reescribirlo =====
-- CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_usuario_roles_rol ON usuario_roles (id_rol);
-- CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_usuarios_estado   ON usuarios (estado);

-- ===== Condicional: junto con el endpoint paginado de pagos por rango =====
-- CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_pagos_fecha_id ON pagos (fecha, id);
```

Para que el esquema siga siendo "equivalente a lo que genera Sequelize", como dice `01_schema.sql`, los índices que se apliquen también tienen que declararse en `indexes:` de cada modelo y agregarse a `01_schema.sql`, `01_preparar.sql` y `03_restaurar_indices.sql`.

## Validación

Después de aplicar el script, repetir `database/analisis/ejercitar.sh` con la misma muestra y comparar `top_consultas.txt`. Además:

```sql
-- Tamaño real de cada índice y si se está usando (idx_scan tiene que crecer)
SELECT relname AS tabla, indexrelname AS indice,
       pg_size_pretty(pg_relation_size(indexrelid)) AS tamanio, idx_scan
FROM pg_stat_user_indexes
WHERE schemaname = 'public'
ORDER BY pg_relation_size(indexrelid) DESC;

-- Que los UPDATE de pago sigan siendo HOT
SELECT relname, n_tup_upd, n_tup_hot_upd FROM pg_stat_user_tables WHERE relname = 'tarifas';
```

Resultados esperados, a confirmar con la corrida de comparación:

| Consulta | Plan esperado | Bloques por llamada |
|---|---|---|
| C1 Mis rutinas | `Index Scan using idx_rutinas_usuario` → *nested loop* con `rutina_ejercicios_pkey` | De ~105.000 a menos de 10 |
| C2 / C3 | `Index Scan using idx_suscripciones_usuario` → `Index Scan using idx_tarifas_suscripcion` | De ~124.000 a menos de 10 |

**Regla de retiro**: un índice que después de un período de uso normal sigue con `idx_scan = 0` no aporta nada y solo cuesta escrituras. Se borra con `DROP INDEX CONCURRENTLY`.

## Riesgos y notas

- **Réplica (SCRUM-45)**: crear los índices de prioridad 1 genera ~575 MB de WAL. Hay que hacerlo fuera de horario y vigilar el lag de replicación (SCRUM-46).
- **Tiempo de creación**: cada índice recorre 6M filas. Con `CONCURRENTLY` tarda más que un `CREATE INDEX` común, pero no bloquea a la app.
- **Los tamaños son estimaciones** calculadas a partir de los planes, porque la base no estaba levantada al escribir este documento. Los valores reales salen de la consulta de validación.
- **Los índices no reemplazan los cambios de código** de SCRUM-39: C4, C5, C9 y C10 se resuelven cambiando la consulta, y C8 necesita primero un endpoint paginado.
