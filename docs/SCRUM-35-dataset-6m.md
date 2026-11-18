# SCRUM-35 — Dataset de prueba de 6M filas

## Objetivo

En SCRUM-42 se midió con `EXPLAIN ANALYZE` sobre una base de 3 usuarios, y quedó anotado que "para evaluar rendimiento a gran escala se requiere un conjunto de datos mayor". Esta tarea genera ese conjunto: un script SQL versionado y reproducible que carga datos masivos respetando todas las FK del esquema (`database/01_schema.sql`).

Las cadenas que se respetan son:

- `usuarios → usuario_roles ← roles`
- `suscripciones → tarifas → pagos`
- `rutinas → rutina_ejercicios ← ejercicios`

## Criterios de aceptación

El equipo ajustó el criterio original: en lugar de **≥ 6M**, se piden **exactamente 6M** filas.

| Criterio | Cómo se cumple |
|---|---|
| Script versionado en `database/dataset/` y reproducible | 4 scripts SQL y un runner. Todo el "azar" sale de una función hash determinista, así que dos cargas dan datos idénticos ([Reproducibilidad](#reproducibilidad)) |
| **Exactamente 6.000.000** filas en cada tabla de datos, DNI y email únicos | Los ids generados arrancan después de los del seed y terminan en 6.000.000. Hay `UNIQUE (dni)` y `UNIQUE (email)` |
| Integridad referencial verificada (0 huérfanos) | Las FK se recrean **con validación** y `04_verificar.sql` cuenta los huérfanos de cada FK |
| Distribuciones realistas de fechas, montos y estados pagado/impago | Ver [Distribuciones](#distribuciones-generadas) |

## Alcance por tabla

El total incluye las filas demo de `02_seed.sql`, así los usuarios `admin@demo.com`, `entrenador@demo.com` y `socio@demo.com` siguen sirviendo para entrar.

| Tabla | Total final | Demo (seed) | Generadas | Ids generados |
|---|---:|---:|---:|---|
| `usuarios` | 6.000.000 | 3 | 5.999.997 | 4 … 6.000.000 |
| `usuario_roles` | 6.000.000 | 3 | 5.999.997 | 1 por usuario generado |
| `roles` | 3 | 3 | 0 | Catálogo fijo, no se toca |
| `ejercicios` | **200** | 3 | 197 | 4 … 200 (catálogo, ver abajo) |
| `rutinas` | 6.000.000 | 1 | 5.999.999 | 2 … 6.000.000 |
| `rutina_ejercicios` | 6.000.000 | 3 | 5.999.997 | PK compuesta |
| `suscripciones` | 6.000.000 | 1 | 5.999.999 | 2 … 6.000.000 |
| `tarifas` | 6.000.000 | 2 | 5.999.998 | 3 … 6.000.000 |
| `pagos` | 6.000.000 | 1 | 5.999.999 | 2 … 6.000.000 |

### Por qué `ejercicios` queda en 200 y no en 6M

`ejercicios` es un **catálogo**, una tabla de dimensión, igual que `roles`; no es una tabla transaccional. Un gimnasio real maneja entre 100 y 300 ejercicios distintos, cada uno con su video. Si se cargaran 6M:

- **No sería realista.** Los nombres y las `youtube_url` serían texto de relleno sin significado, y ningún entrenador elige entre millones de ejercicios.
- **Distorsionaría las pruebas de rendimiento**, que son el motivo de este dataset. Con 6M ejercicios, cada uno aparecería en ~1 rutina, y la selectividad de `rutina_ejercicios.id_ejercicio` (y de los JOIN) no se parecería a producción. Con 200, cada ejercicio aparece en ~30.000 rutinas, que es el patrón real: pocos ejercicios muy reutilizados.
- **No ejercita nada del backend.** El catálogo se lista completo o se busca por PK, así que el volumen en esa tabla no aporta.

Por eso el criterio "6M en cada tabla de datos" se aplica a las **7 tablas transaccionales y de relación**, y los dos catálogos (`roles` y `ejercicios`) quedan con tamaños realistas.

Los 200 ejercicios salen de 40 ejercicios base reales (Sentadilla, Press de banca, Hip thrust…) combinados con 5 variantes ("con mancuernas", "en máquina", "en polea", "unilateral", "con banda elástica"). Así los 200 nombres son distintos y verosímiles. Las `youtube_url` tienen el formato correcto, pero sus ids son ficticios.

### Consecuencia de que el total sea "exactamente 6M"

Padres e hijos tienen el mismo total (6M rutinas y 6M `rutina_ejercicios`, 6M suscripciones y 6M tarifas, 6M tarifas y 6M pagos), así que **el promedio de hijos por padre es exactamente 1**. Para que no sea un 1:1 artificial, los hijos se reparten en bloques que suman lo mismo que tienen los padres:

| Relación | Bloque | Reparto | Lectura de negocio |
|---|---|---|---|
| suscripción → tarifas | 10 suscripciones → 10 tarifas | 2 con 0 · 7 con 1 · 1 con 3 | 20 % dadas de baja antes de la primera cuota, 70 % abono mensual, 10 % trimestral |
| tarifa → pagos | 5 tarifas → 5 pagos | 1 con 0 · 3 con 1 · 1 con 2 | **20 % impagas**, 80 % pagadas; de las pagadas, 1 de cada 4 en dos partes |
| rutina → ejercicios | 20 rutinas → 20 filas | 5 con 0 · 11 con 1 · 3 con 2 · 1 con 3 | 25 % borradores sin ejercicios (inactivos), el resto con 1 a 3 ejercicios |
| usuario → rol | — | 1 rol por usuario | ~0,1 % admin, ~1,5 % entrenador, resto socio |

Cómo se implementa:

- El padre de cada hijo se **calcula aritméticamente** a partir del número de hijo (`padre = f(k)`). No hay `JOIN`, `LIMIT`, tablas temporales ni ordenamientos.
- Dentro de cada bloque, la posición se rota con el hash (`ds_pos` y `ds_idx`), para que las suscripciones dadas de baja o las tarifas impagas no caigan siempre en ids terminados en 0.
- El último bloque de cada relación queda incompleto, porque los totales generados (5.999.997, 5.999.998, 5.999.999) no son múltiplos del tamaño del bloque. Ese tramo se resuelve con una "cola" explícita que ajusta el total exacto. Está documentada en cada función de `01_preparar.sql`.

## Archivos

```
database/dataset/
├── 01_preparar.sql            # validaciones previas, funciones ds_* y baja de PK/UNIQUE/FK
├── 02_generar.sql             # INSERT ... SELECT generate_series, de padres a hijos
├── 03_restaurar_indices.sql   # PK, UNIQUE y FK validadas, secuencias, DROP de ds_*, VACUUM ANALYZE
├── 04_verificar.sql           # conteos, huérfanos, unicidad, coherencia, distribuciones y huella
└── cargar.sh                  # runner: docker exec + psql -v ON_ERROR_STOP=1, logs en docs/evidencias/SCRUM-35/
```

Los scripts **no** se montan en `docker-entrypoint-initdb.d`, porque cada `up` con volumen nuevo tardaría varios minutos más. Se ejecutan a mano y solo cuando se necesita el volumen.

## Técnica de carga

### 1. Datos deterministas sin `random()`

`ds_rand(id, sal)` devuelve un número en [0, 1) a partir de `hashint8extended(id, sal)`. El mismo `(id, sal)` da siempre el mismo valor, sin importar el orden de ejecución ni el paralelismo, y por eso el dataset es reproducible. No se usan `random()` ni `setseed()`, que dependen del orden en que se recorren las filas. Cada atributo usa una "sal" distinta (por ejemplo 1 para el nombre y 2 para el apellido), así los atributos son independientes entre sí.

Todas las fechas se calculan contra una **fecha de corte fija** (`2026-11-13`, función `ds_corte()`) y nunca contra `now()`.

### 2. Baja de restricciones antes de cargar

La sugerencia del ticket es desactivar los índices secundarios durante la carga. Se hace en `01_preparar.sql`:

1. Se eliminan las 8 FK del esquema. Si no, PostgreSQL verificaría 6M veces "fila por fila" que el padre existe.
2. Se eliminan los `UNIQUE (dni)` y `UNIQUE (email)` de `usuarios`, y las PK de las 7 tablas que se cargan. Así cada `INSERT` no mantiene un B-tree, y el índice se arma después de una sola vez, ordenando, lo que es mucho más rápido.
3. Las restricciones se buscan en el catálogo (`pg_constraint`), así funciona aunque los nombres cambien si la base la creó Sequelize. `03_restaurar_indices.sql` las recrea con los nombres exactos de `01_schema.sql`.

### 3. `INSERT ... SELECT generate_series` en lugar de `COPY`

El ticket sugiere `generate_series + COPY`. Se usa `generate_series`, pero con `INSERT ... SELECT` del lado del servidor y no con `COPY`, por estos motivos:

- Los datos **nacen dentro de PostgreSQL**. `COPY` sirve para cargar un archivo externo (CSV), y para usarlo habría que generar ese CSV (`COPY ... TO`) y volver a leerlo (`COPY ... FROM`). Eso duplica la E/S en disco sin ganar nada.
- La ventaja propia de `COPY`, `COPY FREEZE`, que evita reescribir las filas en el primer `VACUUM`, exige hacer `TRUNCATE` de la tabla en la misma transacción. Eso borraría las filas demo del seed, que se decidió conservar.
- Con las restricciones eliminadas, `INSERT ... SELECT` en lote tiene el mismo costo por fila que `COPY`. El cuello de botella es escribir el heap y el WAL, no el protocolo.

### 4. Ajustes de rendimiento

| Ajuste | Dónde | Por qué |
|---|---|---|
| `synchronous_commit = off` | sesión (paso 2) | No espera el `fsync` del WAL en el `COMMIT` |
| `work_mem = 64MB` | sesión | Hash y sort de la verificación en memoria |
| `maintenance_work_mem = 512MB` | sesión (paso 3) | `CREATE INDEX` y validación de FK más rápidos (el contenedor tiene 2–4 GB, ver SCRUM-43) |
| `max_parallel_maintenance_workers = 2` | sesión (paso 3) | Construye los índices B-tree en paralelo |
| Funciones `ds_*` de **una sola expresión** e `IMMUTABLE` | paso 1 | PostgreSQL las expande en línea (*inlining*) dentro del `INSERT`, así que no paga una llamada a función por fila |
| Subconsultas con `OFFSET 0` | paso 2 | Cada valor intermedio (padre, mes, precio) se calcula una sola vez por fila, y las funciones reciben columnas simples, que es condición para el *inlining* |

### 5. Restauración = verificación de integridad

`03_restaurar_indices.sql` recrea las 8 FK **sin `NOT VALID`**. PostgreSQL recorre todas las filas hijas y falla si encuentra una sola que apunte a un padre inexistente. Lo mismo pasa con los `UNIQUE`. Si el paso 3 termina, la integridad referencial y la unicidad ya están garantizadas por el motor. `04_verificar.sql` lo confirma además con consultas explícitas.

## Distribuciones generadas

| Dato | Distribución |
|---|---|
| **Altas de usuarios** | Entre fines de 2020 y noviembre de 2026, sesgadas a lo reciente (`sqrt(u)`): el gimnasio crece y hay más altas en 2025–2026 que en 2021 |
| **Nombres** | 60 nombres × 60 apellidos frecuentes en Argentina |
| **DNI** | `20.000.000 + id`, de 20.000.004 a 26.000.000: único por construcción y en un rango realista |
| **Email** | `nombre.apellido.id@dominio` sin tildes: único por el id. Dominios: gmail 60 %, hotmail 20 %, yahoo 8 %, outlook 8 %, live 4 % |
| **Contraseña** | El mismo bcrypt de `demo1234` que usa el seed, así cualquier usuario generado puede entrar a probar |
| **Estado / Google** | 92 % activos; 8 % con `google_id` |
| **Suscripciones** | Inicio el día 1 de un mes, entre el alta del socio y noviembre de 2026. Mensual 70 %, trimestral 10 %, baja antes de facturar 20 %. `activo` si sigue vigente a la fecha de corte |
| **Precios** | Plan Básico 40 %, Estándar 30 %, Full 20 %, Premium 10 %. Base 2021 de $2.000 a $4.000, ajustada por inflación anual (índices 1,0 · 1,9 · 4,5 · 9,0 · 11,5 · 13,5 para 2021–2026): en 2026 va de ~$27.000 a ~$54.000. Trimestral con 10 % de descuento. Redondeo a $500 |
| **Tarifas (cuotas)** | Una por mes de suscripción, con el precio de la suscripción. 80 % pagadas y 20 % impagas. Las impagas de hace más de 6 meses quedan en un 70 % como `activo = false` (deuda dada de baja), así la deuda vigente se concentra en los meses recientes |
| **Pagos** | Solo de tarifas pagadas. El 85 % se paga entre el día 1 y el 10 del mes y el 15 % con mora de 11 a 45 días. Una de cada 4 tarifas pagadas se abona en dos partes: `floor(precio/2)` más el resto, con la segunda parte 7–20 días después. La suma siempre da el precio exacto. Ningún pago supera la fecha de corte. `transaccion = 'MP-0000000002'` … (única) |
| **Rutinas** | Asignadas solo a socios. Día y turno con los valores del frontend (`rutinas-list.component.html`): Lunes 19 %, Martes 17 %, Miércoles 19 %, Jueves 17 %, Viernes 16 %, Sábado 9 %, Domingo 3 %; Mañana 35 %, Tarde 40 %, Noche 25 %. Un 25 % son borradores (sin ejercicios, inactivos), y del resto el 88 % está activo |
| **Fechas técnicas** | `createdAt`/`updatedAt` coherentes con el negocio: el usuario se crea antes que su suscripción, la tarifa el día 1 de su mes y el pago en su fecha |

## Cómo ejecutar

> [!WARNING]
> **Antes de correrlo:** se necesitan unos **10 GB libres** en el disco de Docker Desktop y entre **15 y 30 minutos**. Conviene darle a Docker Desktop al menos 4 GB de RAM (*Settings → Resources*).

```bash
# 1. Base limpia (schema + seed, nada más). Borra los datos actuales.
docker compose --profile dev down -v
docker compose --profile dev up -d
docker compose --profile dev ps          # esperar "healthy"

# 2. Carga completa (Git Bash en Windows, o bash en Linux/macOS)
./database/dataset/cargar.sh

# Un solo paso (por ejemplo, repetir la verificación)
./database/dataset/cargar.sh 04_verificar
```

El runner lee `DB_USER` y `DB_NAME` del `.env`, comprueba que el contenedor `demo_hia_db_dev` esté `healthy` (se puede cambiar con `CONTAINER=...`), corre los 4 pasos con `ON_ERROR_STOP` y guarda la salida de cada uno en `docs/evidencias/SCRUM-35/<paso>.log`.

**Desde PowerShell, sin Git Bash**, paso por paso (`$OutputEncoding` evita que se rompan las tildes al pasar el archivo por el pipe):

```powershell
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
foreach ($p in '01_preparar','02_generar','03_restaurar_indices','04_verificar') {
  Get-Content "database\dataset\$p.sql" -Raw -Encoding UTF8 |
    docker exec -i demo_hia_db_dev psql -X -q -v ON_ERROR_STOP=1 -U demo_hia -d demo_hia -f -
  if ($LASTEXITCODE -ne 0) { Write-Error "Fallo $p"; break }
}
```

**Volver a la base chica:** `docker compose --profile dev down -v && docker compose --profile dev up -d`.

### Protecciones

- `01_preparar.sql` verifica que la base tenga **solo** las filas del seed. Si ya está cargada o tiene datos de más, aborta sin tocar nada, con el mensaje de cómo recrearla. Así es imposible duplicar la carga.
- Los pasos 1, 2 y 3 corren cada uno en una transacción. Si el paso 2 falla, no queda una carga a medias, pero las restricciones siguen eliminadas desde el paso 1. En ese caso hay que recrear la base (el runner lo avisa).
- Si en el esquema hay índices que no están en `01_schema.sql`, el paso 1 aborta en lugar de cargar con índices vivos.

## Verificación (`04_verificar.sql`)

Es de solo lectura. Imprime una tabla `chequeo | valor | esperado | estado` y termina con `RAISE EXCEPTION` si algún chequeo no da lo esperado:

| Grupo | Chequeos |
|---|---|
| Conteos | Las 7 tablas en 6.000.000, `roles` = 3 y `ejercicios` = 200 |
| Huérfanos | Las 8 FK con `LEFT JOIN padre … WHERE padre.id IS NULL`: tiene que dar 0. Esto también detecta FK nulas |
| Restricciones | 8 FK presentes y `convalidated`; los 2 UNIQUE de `usuarios` |
| Unicidad | Duplicados de `dni`, `email` y `pagos.transaccion`: 0 |
| Coherencia | Tarifas impagas con pagos: 0. Pagadas sin pagos: 0. Suma de pagos distinta del precio: 0. Pagos anteriores al mes de su cuota o posteriores al corte: 0. `fecha_fin < fecha_inicio`: 0. Montos ≤ 0: 0 |

Además muestra, a título informativo, las distribuciones de la tabla anterior (pagadas/impagas, impago y percentiles de precio por año, pagos en término y con mora, hijos por padre en cada relación, roles, dominios, turnos y días), el tamaño de cada tabla y la **huella** de cada tabla.

### Reproducibilidad

La huella es un `md5` de la suma de `hashtextextended(fila)` de las filas generadas. Se excluyen las del seed porque su `createdAt` es `NOW()` del momento en que se creó el contenedor. Para comprobar que el script es reproducible:

1. Cargar desde cero y guardar la sección "HUELLA" del log `04_verificar.log`.
2. `down -v`, `up -d`, volver a cargar.
3. Las 8 huellas tienen que coincidir.

## Pruebas end-to-end

1. Base limpia y `cargar.sh`: los 4 pasos tienen que terminar sin `ERROR`, y el último con `NOTICE: SCRUM-35: todos los chequeos OK`.
2. Volver a correr `cargar.sh` sobre la base ya cargada: `01_preparar` tiene que abortar con el mensaje "Base ya cargada…" sin modificar nada.
3. Repetir la carga desde cero y comparar las huellas ([Reproducibilidad](#reproducibilidad)).
4. Levantar el backend: `GET /api/health` tiene que devolver `ok`. Probar el login con `socio@demo.com` / `demo1234` y con un usuario generado, por ejemplo el que se obtiene con `SELECT email FROM usuarios WHERE id = 500001` (contraseña `demo1234`).

## Riesgos y advertencias

- **Disco**: se estiman unos 5–7 GB entre tablas e índices, más el WAL generado durante la carga.
- **Checkpoints**: con `max_wal_size = 2GB` (SCRUM-43), la carga dispara checkpoints frecuentes y PostgreSQL deja avisos `checkpoints are occurring too frequently` en `docker logs`. Es esperable y no afecta al resultado.
- **Replicación**: no cargar con el perfil `cluster` levantado. La réplica recibiría y reproduciría varios GB de WAL, y el lag crecería mucho (SCRUM-46). Conviene cargar en `dev` sin réplica.
- **Backups**: un `pg_dump` del dataset pesa varios GB. No hay que versionarlo, ni dejar que el flujo de backups de n8n (SCRUM-77) lo suba sin revisar el destino.
- **Solo desarrollo**: todos los usuarios generados comparten la contraseña `demo1234`. Este dataset nunca se carga en un entorno desplegado.
- **Sequelize**: `sequelize.sync()` no altera tablas existentes, y el esquema final es idéntico al de `01_schema.sql` (mismas restricciones y nombres; las funciones `ds_*` se borran). El backend arranca igual.
- **Sin índices en las FK**: `01_schema.sql` no tiene índices sobre `"usuarioId"`, `"suscripcionId"`, `"tarifaId"`, etc., y este ticket no los agrega para no cambiar el esquema. Con 6M filas, las consultas que filtran por esas columnas van a hacer *seq scan*. Ese es justamente el insumo para retomar las mediciones de SCRUM-42 a escala.

## Resultados

> Primera ejecución: 2026-11-13, en 4 CPU con 3,5 GB de RAM para Docker. El informe completo (volumen, tamaño, tiempos, restricciones y evidencia en pgAdmin) está en [SCRUM-36](evidencias/SCRUM-36/SCRUM-36-ejecucion-carga-masiva.md). Los logs están en `docs/evidencias/SCRUM-35/`.

| Paso | Duración |
|---|---:|
| 01_preparar | 1 s |
| 02_generar | 524 s (8 min 44 s) |
| 03_restaurar_indices | 436 s (7 min 16 s), con el VACUUM incluido |
| 04_verificar | 345 s (5 min 45 s) |
| **Total** | **1.306 s (21 min 46 s)**; la carga sola (01 a 03) son 16 min 1 s |

- Tamaño de la base: **5.194 MB** (datos 3.784 MB + índices 1.404 MB).
- Chequeos: **30 / 30 OK**. Conteos exactos, 0 huérfanos, unicidad y coherencia.
- Huellas iguales en dos cargas: **no verificado** (se hizo una sola carga). Las huellas de referencia están en SCRUM-36.
- Ajustes hechos a partir de esta ejecución: `VACUUM (ANALYZE, PARALLEL 0)` en el paso 3 y `enable_parallel_hash = off` en el paso 4. Docker limita `/dev/shm` a 64 MB, y el vacuum y el hash join paralelos se quedaban sin memoria compartida.
