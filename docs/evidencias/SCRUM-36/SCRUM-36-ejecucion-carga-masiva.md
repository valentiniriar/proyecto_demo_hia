# SCRUM-36 — Ejecución de la carga masiva: volumen, tamaño, tiempos e integridad

## Objetivo

Ejecutar el dataset de prueba que preparó [SCRUM-35](../../SCRUM-35-dataset-6m.md) (`database/dataset/cargar.sh`) y documentar el resultado con evidencia de **pgAdmin** y en este informe.

## Criterios de aceptación y dónde se cumple cada uno

| # | Criterio | Consulta | Captura de pgAdmin | Sección del informe |
|---|---|---|---|---|
| 1 | Tabla con la cantidad de registros por tabla (`SELECT count(*)`) | [C1](#c1--cantidad-de-registros-por-tabla) | 01, 02 | [Volumen](#1-volumen-cantidad-de-registros) |
| 2 | Tamaño de la BD y de cada tabla e índice (`pg_database_size`, `pg_total_relation_size`) | [C2](#c2--tamaño-de-la-base-de-cada-tabla-y-de-cada-índice) | 03, 04, 05 | [Tamaño](#2-tamaño) |
| 3 | Método de generación y tiempo de carga medido | log de `cargar.sh` | — | [Método y tiempos](#3-método-de-generación-y-tiempo-de-carga) |
| 4 | Restricciones de integridad (PK, FK, UNIQUE, CHECK) listadas | [C3](#c3--restricciones-de-integridad-pk-fk-unique-check), [C4](#c4--not-null-por-tabla), [C5](#c5--huérfanos-integridad-referencial-efectiva) | 06, 07, 08, 09 | [Integridad](#4-restricciones-de-integridad) |
| 5 | Evidencia en pgAdmin y en el informe | todas | 01 a 09 | [Evidencias](#5-evidencias) |

---


## Parte A — Instrucciones de ejecución

### A.1 Preparar la máquina

| Requisito | Cómo comprobarlo |
|---|---|
| ≥ 10 GB libres en el disco donde Docker Desktop guarda sus datos | Docker Desktop → *Settings → Resources → Disk usage* |
| Docker Desktop con ≥ 4 GB de RAM y ≥ 2 CPU | *Settings → Resources*, o `docker info --format "{{.NCPU}} CPU / {{.MemTotal}} bytes"` |
| `.env` en la raíz con `DB_NAME`, `DB_USER`, `DB_PASS` y `PGADMIN_*` | `cp .env.example .env` si no existe |
| Git Bash (en Windows) para ejecutar el `.sh` | Viene con Git for Windows |
| **Sin** el perfil `cluster` levantado | `docker ps` no tiene que mostrar el contenedor réplica |
| Cerrar los programas pesados | La carga usa CPU y disco durante 15–30 min, y las mediciones salen mejor sin competencia |

Para el informe, anotar el entorno en el que se midió, porque los tiempos dependen del hardware:

```bash
docker info --format "CPUs: {{.NCPU}} | RAM Docker: {{.MemTotal}} | Server: {{.ServerVersion}}"
docker exec demo_hia_db_dev psql -U demo_hia -d demo_hia -Atc "SELECT version();"
```

### A.2 Levantar una base limpia junto con pgAdmin

```bash
# Desde la raíz del repo. Borra los datos actuales de la base dev.
docker compose --profile dev --profile tools down -v
docker compose --profile dev --profile tools up -d
docker compose --profile dev ps        # db-dev tiene que estar "healthy"
```

### A.3 Ejecutar la carga midiendo el tiempo

```bash
mkdir -p docs/evidencias/SCRUM-36
time ./database/dataset/cargar.sh 2>&1 | tee docs/evidencias/SCRUM-36/ejecucion.log
```

Qué deja la ejecución:

- Por cada paso, una línea `<== [paso] OK en N s` y, al final, `Carga terminada en X min Y s`.
- El tiempo de cada sentencia SQL (`Time: … ms`, del `\timing` de psql) en `docs/evidencias/SCRUM-35/<paso>.log`.
- El tiempo total *real* que imprime `time` al terminar.
- Al final de `04_verificar`, el mensaje `NOTICE: SCRUM-35: todos los chequeos OK …`. Si en cambio aparece `ERROR`, **no se sigue**: se revisa el log del paso que falló.

Para resumir los tiempos de los logs:

```bash
grep -h "OK en" docs/evidencias/SCRUM-36/ejecucion.log
grep -h "^Time:" docs/evidencias/SCRUM-35/02_generar.log            # una línea por tabla, en orden de carga
grep -h "^Time:" docs/evidencias/SCRUM-35/03_restaurar_indices.log  # una por cada PK/UNIQUE/FK y el VACUUM
```

> [!IMPORTANT]
> Los scripts de carga **se ejecutan con `cargar.sh` (psql), no desde pgAdmin**. Usan metacomandos propios de psql (`\set`, `\timing`, `\echo`, `\pset`) que el Query Tool de pgAdmin no entiende. pgAdmin se usa **después** de la carga, solo para consultar y sacar las capturas de evidencia.

### A.4 Entrar a pgAdmin

1. Abrir <http://127.0.0.1:5050> y entrar con `PGADMIN_DEFAULT_EMAIL` / `PGADMIN_DEFAULT_PASSWORD` del `.env`.
2. En el *Object Explorer*: **Servers → GymHub PostgreSQL (db)**. Viene precargado desde `database/pgadmin/servers.json`. La contraseña es `DB_PASS`.
3. Ir a **Databases → demo_hia → Schemas → public → Tables**.
4. Para las consultas: clic derecho sobre `demo_hia` → **Query Tool**. Se pega la consulta y se ejecuta con **F5** (▶). El resultado aparece en la pestaña *Data Output* y el tiempo de la consulta en la barra inferior: ese número es lo que va en la captura.

Guardar las capturas en `docs/evidencias/SCRUM-36/` con los nombres de la [tabla de evidencias](#5-evidencias).

---


## Parte B — Consultas para pgAdmin (Query Tool)

Son de solo lectura: se pueden ejecutar todas las veces que haga falta.

### C1 — Cantidad de registros por tabla

`count(*)` exacto, no la estimación de las estadísticas. Tarda unos segundos.

```sql
SELECT tabla, to_char(filas, 'FM999G999G999') AS filas, esperado,
       CASE WHEN filas = esperado THEN 'OK' ELSE 'REVISAR' END AS estado
FROM (VALUES
    ('usuarios',          (SELECT count(*) FROM usuarios),          6000000),
    ('usuario_roles',     (SELECT count(*) FROM usuario_roles),     6000000),
    ('rutinas',           (SELECT count(*) FROM rutinas),           6000000),
    ('rutina_ejercicios', (SELECT count(*) FROM rutina_ejercicios), 6000000),
    ('suscripciones',     (SELECT count(*) FROM suscripciones),     6000000),
    ('tarifas',           (SELECT count(*) FROM tarifas),           6000000),
    ('pagos',             (SELECT count(*) FROM pagos),             6000000),
    ('ejercicios',        (SELECT count(*) FROM ejercicios),        200),
    ('roles',             (SELECT count(*) FROM roles),             3)
) v(tabla, filas, esperado)
UNION ALL
SELECT 'TOTAL', to_char(sum(n), 'FM999G999G999'), NULL, NULL
FROM (VALUES ((SELECT count(*) FROM usuarios)), ((SELECT count(*) FROM usuario_roles)),
             ((SELECT count(*) FROM rutinas)), ((SELECT count(*) FROM rutina_ejercicios)),
             ((SELECT count(*) FROM suscripciones)), ((SELECT count(*) FROM tarifas)),
             ((SELECT count(*) FROM pagos)), ((SELECT count(*) FROM ejercicios)),
             ((SELECT count(*) FROM roles))) t(n);
```

Resultado esperado: 7 tablas con `6.000.000`, `ejercicios` con `200`, `roles` con `3` y un total de `42.000.203`.

### C2 — Tamaño de la base, de cada tabla y de cada índice

```sql
-- C2.a  Tamaño total de la base
SELECT current_database() AS base,
       pg_size_pretty(pg_database_size(current_database())) AS tamanio,
       pg_database_size(current_database())                 AS bytes;

-- C2.b  Por tabla: datos (heap + TOAST), índices y total
SELECT c.relname                                         AS tabla,
       to_char(c.reltuples::bigint, 'FM999G999G999')     AS filas_estimadas,
       pg_size_pretty(pg_table_size(c.oid))              AS datos,
       pg_size_pretty(pg_indexes_size(c.oid))            AS indices,
       pg_size_pretty(pg_total_relation_size(c.oid))     AS total,
       round(100.0 * pg_total_relation_size(c.oid)
             / pg_database_size(current_database()), 1)  AS pct_base
FROM pg_class c
WHERE c.relkind = 'r' AND c.relnamespace = 'public'::regnamespace
ORDER BY pg_total_relation_size(c.oid) DESC;

-- C2.c  Por índice
SELECT i.indrelid::regclass                          AS tabla,
       i.indexrelid::regclass                        AS indice,
       CASE WHEN i.indisprimary THEN 'PK'
            WHEN i.indisunique  THEN 'UNIQUE'
            ELSE 'secundario' END                    AS tipo,
       pg_get_indexdef(i.indexrelid)                 AS definicion,
       pg_size_pretty(pg_relation_size(i.indexrelid)) AS tamanio
FROM pg_index i
JOIN pg_class c ON c.oid = i.indrelid
WHERE c.relnamespace = 'public'::regnamespace
ORDER BY pg_relation_size(i.indexrelid) DESC;
```

`pg_total_relation_size` = datos (heap + TOAST) + índices. `filas_estimadas` sale de las estadísticas que actualizó el `VACUUM ANALYZE` del paso 3, y tiene que coincidir aproximadamente con C1.

### C3 — Restricciones de integridad (PK, FK, UNIQUE, CHECK)

```sql
-- C3.a  Listado completo
SELECT conrelid::regclass AS tabla,
       CASE contype WHEN 'p' THEN 'PRIMARY KEY' WHEN 'f' THEN 'FOREIGN KEY'
                    WHEN 'u' THEN 'UNIQUE'      WHEN 'c' THEN 'CHECK'
                    WHEN 'x' THEN 'EXCLUDE'     ELSE contype::text END AS tipo,
       conname                    AS nombre,
       pg_get_constraintdef(oid)  AS definicion,
       CASE WHEN convalidated THEN 'validada' ELSE 'NOT VALID' END AS estado
FROM pg_constraint
WHERE connamespace = 'public'::regnamespace
ORDER BY conrelid::regclass::text,
         array_position(ARRAY['p','u','f','c','x']::"char"[], contype), conname;

-- C3.b  Resumen por tipo
SELECT CASE contype WHEN 'p' THEN 'PRIMARY KEY' WHEN 'f' THEN 'FOREIGN KEY'
                    WHEN 'u' THEN 'UNIQUE'      WHEN 'c' THEN 'CHECK' END AS tipo,
       count(*) AS cantidad
FROM pg_constraint
WHERE connamespace = 'public'::regnamespace AND contype IN ('p','f','u','c')
GROUP BY contype
UNION ALL
SELECT 'CHECK', 0
WHERE NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE connamespace = 'public'::regnamespace AND contype = 'c');
```

Resultado esperado de C3.b: **9 PRIMARY KEY, 8 FOREIGN KEY, 3 UNIQUE** (`usuarios.dni`, `usuarios.email` y `roles.nombre`) y **0 CHECK**.

### C4 — NOT NULL por tabla

El esquema (`database/01_schema.sql`) no declara restricciones `CHECK`. Las reglas de dominio a nivel columna se expresan con `NOT NULL`, que en PostgreSQL 16 no figura en `pg_constraint` y por eso se lista aparte:

```sql
SELECT table_name AS tabla,
       count(*) FILTER (WHERE is_nullable = 'NO')  AS columnas_not_null,
       count(*)                                    AS columnas_total,
       string_agg(column_name, ', ' ORDER BY ordinal_position)
           FILTER (WHERE is_nullable = 'YES')      AS columnas_que_aceptan_null
FROM information_schema.columns
WHERE table_schema = 'public'
GROUP BY table_name
ORDER BY table_name;
```

Las columnas que aceptan NULL son las FK de Sequelize (`"usuarioId"`, `"suscripcionId"`, `"tarifaId"`, con `ON DELETE SET NULL`) y `usuarios.google_id`.

### C5 — Huérfanos (integridad referencial efectiva)

Las FK ya garantizan la integridad, porque se crearon validadas. Esta consulta la confirma contando huérfanos de verdad: todas las filas tienen que dar 0. Recorre las 42M filas, así que tarda alrededor de un minuto.

```sql
-- Docker limita /dev/shm a 64 MB y el hash join paralelo sobre 6M filas no entra:
-- sin esta línea, la consulta falla con "could not resize shared memory segment".
SET enable_parallel_hash = off;

SELECT fk, huerfanos FROM (VALUES
  ('usuario_roles.id_usuario → usuarios',
     (SELECT count(*) FROM usuario_roles h WHERE NOT EXISTS (SELECT 1 FROM usuarios p WHERE p.id = h.id_usuario))),
  ('usuario_roles.id_rol → roles',
     (SELECT count(*) FROM usuario_roles h WHERE NOT EXISTS (SELECT 1 FROM roles p WHERE p.id = h.id_rol))),
  ('rutinas.usuarioId → usuarios',
     (SELECT count(*) FROM rutinas h WHERE NOT EXISTS (SELECT 1 FROM usuarios p WHERE p.id = h."usuarioId"))),
  ('rutina_ejercicios.id_rutina → rutinas',
     (SELECT count(*) FROM rutina_ejercicios h WHERE NOT EXISTS (SELECT 1 FROM rutinas p WHERE p.id = h.id_rutina))),
  ('rutina_ejercicios.id_ejercicio → ejercicios',
     (SELECT count(*) FROM rutina_ejercicios h WHERE NOT EXISTS (SELECT 1 FROM ejercicios p WHERE p.id = h.id_ejercicio))),
  ('suscripciones.usuarioId → usuarios',
     (SELECT count(*) FROM suscripciones h WHERE NOT EXISTS (SELECT 1 FROM usuarios p WHERE p.id = h."usuarioId"))),
  ('tarifas.suscripcionId → suscripciones',
     (SELECT count(*) FROM tarifas h WHERE NOT EXISTS (SELECT 1 FROM suscripciones p WHERE p.id = h."suscripcionId"))),
  ('pagos.tarifaId → tarifas',
     (SELECT count(*) FROM pagos h WHERE NOT EXISTS (SELECT 1 FROM tarifas p WHERE p.id = h."tarifaId")))
) v(fk, huerfanos);
```

---


## Parte C — Qué capturar en pgAdmin y qué demuestra cada captura

Cada captura tiene que mostrar el **árbol del Object Explorer** a la izquierda, para que se vea servidor, base y tabla, y el **resultado o la pestaña** a la derecha. En el Query Tool tiene que aparecer también la barra inferior con el tiempo de ejecución y la cantidad de filas devueltas.

| N.º | Archivo | Dónde, en pgAdmin | Qué tiene que verse | Qué demuestra en el informe |
|---|---|---|---|---|
| 01 | `01-conteos-query-tool.png` | Query Tool → **C1** | Las 9 tablas con su `count(*)`, la columna `estado` en OK y el TOTAL | Criterio 1: volumen exacto de 6M por tabla de datos, medido con `count(*)` |
| 02 | `02-count-rows-pagos.png` | Clic derecho en *Tables → pagos* → **Count Rows** | El aviso de pgAdmin "Table rows counted: 6000000" | Criterio 1, con la herramienta propia de pgAdmin y no solo con SQL: confirma C1 por una vía independiente |
| 03 | `03-tamanio-base.png` | Clic en *Databases → demo_hia* → pestaña **Statistics** (o **Dashboard**) y C2.a en el Query Tool | El campo *Size* de la base y el resultado de `pg_database_size` | Criterio 2: tamaño total de la base. Los dos valores tienen que coincidir |
| 04 | `04-tamanio-por-tabla.png` | Query Tool → **C2.b** | Datos, índices y total de cada tabla, y el % sobre la base | Criterio 2: dónde se concentra el espacio. Se espera que `usuarios` sea la tabla más grande, por el email y el hash |
| 05 | `05-tamanio-por-indice.png` | Query Tool → **C2.c**, y *Tables → usuarios* → pestaña **Statistics** | El tamaño de cada índice (PK y UNIQUE); en Statistics, *Table size*, *Indexes size* y *Live tuples* | Criterio 2: el costo en disco de cada índice. Por ejemplo, `usuarios_email_key` pesa más que `usuarios_pkey` |
| 06 | `06-restricciones-listado.png` | Query Tool → **C3.a** y **C3.b** | Las 20 restricciones con su definición y estado "validada"; el resumen 9 PK · 8 FK · 3 UNIQUE · 0 CHECK | Criterio 4: inventario completo de restricciones y prueba de que ninguna quedó `NOT VALID` |
| 07 | `07-constraints-arbol.png` | *Tables → pagos → Constraints* y *Tables → usuarios → Constraints*, expandidos | En `pagos`: `pagos_pkey` y `pagos_tarifaId_fkey`. En `usuarios`: `usuarios_pkey`, `usuarios_dni_key` y `usuarios_email_key` | Criterio 4: las mismas restricciones vistas desde la interfaz gráfica, con los nombres de `01_schema.sql` |
| 08 | `08-erd-base.png` | Clic derecho en *demo_hia* → **ERD For Database** | El diagrama con las 9 tablas y las líneas de FK entre ellas | Criterio 4: las cadenas `usuarios → usuario_roles ← roles`, `suscripciones → tarifas → pagos` y `rutinas → rutina_ejercicios ← ejercicios` existen en el motor y no solo en el README |
| 09 | `09-huerfanos.png` | Query Tool → **C5** (y **C4** en otra pestaña) | Las 8 FK con `huerfanos = 0` y las columnas NOT NULL por tabla | Integridad efectiva: además de que las FK existen, ningún dato las viola |

> [!TIP]
> En pgAdmin, las cifras de la pestaña **Statistics** (por ejemplo *Live tuples*) son **estimaciones** que salen de las estadísticas del planificador. El número exacto es el de C1 o el de *Count Rows*: esos son los que van en el informe. Statistics se usa solo como evidencia visual del tamaño.

---

## Parte D — Informe de resultados

> Valores de la ejecución del 2026-11-13. Las salidas completas están en `docs/evidencias/SCRUM-36/` (`C1-conteos.txt` … `C5-huerfanos.txt`, `ejecucion.log`, `entorno.txt`) y en `docs/evidencias/SCRUM-35/*.log`. Las capturas de pgAdmin (01 a 09) se agregan aparte.

**Fecha de ejecución:** 2026-11-13, de 14:38 a 15:10 (UTC−3) · **Rama / commit:** `feature/SCRUM-35-dataset-6m` @ `73a846d`, con los scripts de `database/dataset/` sin commitear

**Entorno** (`entorno.txt`): notebook con Windows 11 y Docker Desktop 29.9.2 (WSL2, kernel 6.6.114) · **4 CPU** · **3,5 GB de RAM** para Docker · disco C: con 19 GB libres al empezar · **PostgreSQL 16.15** (`postgres:16-alpine`) con la configuración por defecto (`shared_buffers = 128MB`, `max_wal_size = 1GB`) · `/dev/shm` del contenedor: 64 MB (por defecto de Docker)

### 1. Volumen (cantidad de registros)

Fuente: C1 (`C1-conteos.txt`, captura 01). Se confirma con *Count Rows* (captura 02).

| Tabla | `count(*)` | Esperado | Estado |
|---|---:|---:|:---:|
| usuarios | 6.000.000 | 6.000.000 | OK |
| usuario_roles | 6.000.000 | 6.000.000 | OK |
| rutinas | 6.000.000 | 6.000.000 | OK |
| rutina_ejercicios | 6.000.000 | 6.000.000 | OK |
| suscripciones | 6.000.000 | 6.000.000 | OK |
| tarifas | 6.000.000 | 6.000.000 | OK |
| pagos | 6.000.000 | 6.000.000 | OK |
| ejercicios (catálogo) | 200 | 200 | OK |
| roles (catálogo) | 3 | 3 | OK |
| **Total** | **42.000.203** | 42.000.203 | OK |

El `count(*)` exacto de las 9 tablas tardó 34,6 s. `ejercicios` y `roles` son catálogos y no llevan 6M a propósito. La justificación está en [SCRUM-35 → Por qué ejercicios queda en 200](../../SCRUM-35-dataset-6m.md#por-qué-ejercicios-queda-en-200-y-no-en-6m).

### 2. Tamaño

Fuente: C2 (`C2-tamanios.txt`, capturas 03, 04 y 05).

**Tamaño total de la base (`pg_database_size`): 5.194 MB** (5.446.425.623 bytes, unos 5,1 GiB).

| Tabla | Datos | Índices | Total (`pg_total_relation_size`) | % de la base | Bytes por fila (total) |
|---|---:|---:|---:|---:|---:|
| usuarios | 1.049 MB | 630 MB | 1.679 MB | 32,3 % | ~293 |
| rutinas | 821 MB | 129 MB | 950 MB | 18,3 % | ~166 |
| pagos | 533 MB | 129 MB | 661 MB | 12,7 % | ~116 |
| suscripciones | 529 MB | 129 MB | 658 MB | 12,7 % | ~115 |
| tarifas | 438 MB | 129 MB | 567 MB | 10,9 % | ~99 |
| usuario_roles | 207 MB | 129 MB | 336 MB | 6,5 % | ~59 |
| rutina_ejercicios | 207 MB | 129 MB | 336 MB | 6,5 % | ~59 |
| ejercicios | 72 kB | 16 kB | 88 kB | 0,0 % | — |
| roles | 40 kB | 32 kB | 72 kB | 0,0 % | — |
| **Total** | **3.784 MB** | **1.404 MB** | **5.188 MB** | | |

| Índice | Tabla | Tipo | Tamaño |
|---|---|---|---:|
| usuarios_email_key | usuarios | UNIQUE | 321 MB |
| usuarios_dni_key | usuarios | UNIQUE | 181 MB |
| usuarios_pkey | usuarios | PK | 129 MB |
| pagos_pkey · tarifas_pkey · suscripciones_pkey · rutinas_pkey | (cada una) | PK `(id)` | 129 MB c/u |
| usuario_roles_pkey · rutina_ejercicios_pkey | (cada una) | PK compuesta | 129 MB c/u |
| ejercicios_pkey · roles_pkey · roles_nombre_key | catálogos | PK / UNIQUE | 16 kB c/u |

**Lectura:**

- `usuarios` concentra casi un tercio de la base. Es la tabla con las filas más anchas: email, nombre, apellido y un hash bcrypt de 60 caracteres, que dan unos 183 bytes de datos por fila. Además es la única con dos índices UNIQUE sobre texto.
- Los índices ocupan **1,4 GB, el 27 % de la base**. Solo `usuarios_email_key` (321 MB) pesa 2,5 veces una PK entera, porque indexa un texto de ~30 caracteres en lugar de un `integer`.
- Todas las PK de 6M filas pesan lo mismo (129 MB). Las compuestas de dos `integer` también, porque el B-tree reserva 8 bytes por clave igual que con una sola columna más el alineamiento.
- `rutinas` ocupa más que `pagos`, `tarifas` o `suscripciones` porque guarda nombre y descripción como texto libre.
- Las tablas intermedias (`usuario_roles`, `rutina_ejercicios`) pesan 59 bytes por fila. Casi todo es la cabecera de la tupla de PostgreSQL (~24 bytes) y el índice.

### 3. Método de generación y tiempo de carga

**Método** (detalle completo en [SCRUM-35](../../SCRUM-35-dataset-6m.md)):

- Generación **del lado del servidor** con `INSERT … SELECT … FROM generate_series(…)`, en orden padre → hijo. No hay archivos intermedios.
- Valores **deterministas**: la función hash `ds_rand(id, sal)`, basada en `hashint8extended`, reemplaza a `random()`. Las funciones son de una sola expresión y PostgreSQL las expande en línea (*inlining*, comprobado con `EXPLAIN VERBOSE` antes de la carga).
- **Restricciones eliminadas durante la carga** (PK, UNIQUE y FK) y recreadas al final. Así los índices se construyen una sola vez, ordenando, y las FK validan todas las filas de una vez.
- Ajustes de sesión: `synchronous_commit = off`, `work_mem = 64MB`, `maintenance_work_mem = 512MB` y `max_parallel_maintenance_workers = 2`.
- Se ejecutó con `database/dataset/cargar.sh` (psql dentro del contenedor con `ON_ERROR_STOP`). Antes se hizo una prueba en una base descartable (`ds_prueba`) con rangos chicos, para validar la sintaxis y el reparto por bloques.

**Tiempos medidos** (fuente: `ejecucion.log`, `ejecucion_04.log` y `docs/evidencias/SCRUM-35/*.log`):

| Paso | Qué hace | Duración |
|---|---|---:|
| 01_preparar | Validaciones previas, funciones y baja de restricciones | 1 s |
| 02_generar | Inserción de 41.999.986 filas | **524 s** (8 min 44 s) |
| 03_restaurar_indices | PK y UNIQUE (238 s) + 8 FK validadas (95 s) + VACUUM ANALYZE (103 s) | **436 s** (7 min 16 s) |
| **Carga (01 + 02 + 03)** | Base lista para usar | **961 s (16 min 1 s)** |
| 04_verificar | 30 chequeos, distribuciones, tamaños y huellas | 345 s (5 min 45 s) |
| **Total efectivo** | Carga y verificación | **1.306 s (21 min 46 s)** |

Detalle de `02_generar` (líneas `Time:` de `02_generar.log`):

| Tabla | Filas insertadas | Tiempo | Filas/s |
|---|---:|---:|---:|
| ejercicios | 197 | 0,02 s | — |
| usuarios | 5.999.997 | 135,8 s | ~44.200 |
| usuario_roles | 5.999.997 | 29,3 s | ~204.600 |
| suscripciones | 5.999.999 | 95,8 s | ~62.700 |
| tarifas | 5.999.998 | 78,9 s | ~76.100 |
| pagos | 5.999.999 | 84,0 s | ~71.400 |
| rutinas | 5.999.999 | 75,5 s | ~79.500 |
| rutina_ejercicios | 5.999.997 | 24,3 s | ~247.300 |
| **Total** | **41.999.986** | **524 s** | **~80.200** |

Detalle de `03_restaurar_indices` (líneas `Time:` de `03_restaurar_indices.log` y `03_restaurar_indices_vacuum.log`):

| Sentencia | Tiempo |
|---|---:|
| `usuarios`: PK + UNIQUE `dni` + UNIQUE `email` | 85,6 s |
| PK de `usuario_roles`, `rutinas`, `rutina_ejercicios`, `suscripciones`, `tarifas`, `pagos` | 19,4 · 51,7 · 15,5 · 17,6 · 30,7 · 17,5 s |
| FK de `usuario_roles` (2), `rutinas`, `rutina_ejercicios` (2), `suscripciones`, `tarifas`, `pagos` | 19,3 · 31,4 · 16,5 · 12,7 · 5,9 · 8,9 s |
| `setval` de las secuencias, `DROP FUNCTION`, `COMMIT` | < 0,1 s |
| `VACUUM (ANALYZE, PARALLEL 0)` de las 9 tablas | 103,1 s |

**Lectura:**

- **Inserción frente a índices:** generar los datos llevó el 55 % de la carga (524 s) y reconstruir restricciones y estadísticas el 45 % (436 s). Crear los índices al final, en lugar de mantenerlos durante los 42M `INSERT`, es lo que mantiene la carga en 16 minutos en una máquina de 4 CPU.
- **`usuarios` es la tabla más lenta** de generar (44.000 filas/s), por el armado de texto: nombre, apellido, email con `translate`/`lower` y un `numeric` para `google_id`. Las tablas intermedias, que son dos `integer`, se insertan entre 5 y 6 veces más rápido.
- `suscripciones`, `tarifas` y `pagos` recalculan en línea toda la cadena padre → hijo (socio → mes de alta → mes de inicio → precio) en lugar de hacer JOIN, y aun así se mantienen entre 62.000 y 76.000 filas/s.
- Las FK se validaron en 95 s para 8 relaciones de 6M filas (hash join de PostgreSQL), mucho menos de lo que costaría verificar fila por fila durante el `INSERT`.

**Incidencias durante la ejecución y cómo se resolvieron:**

| # | Paso | Error | Causa | Solución |
|---|---|---|---|---|
| 1 | 03 (último comando) | `could not resize shared memory segment … to 234379552 bytes: No space left on device` en el `VACUUM` | El vacuum paralelo guarda la lista de tuplas en memoria compartida (`/dev/shm`) según `maintenance_work_mem`, y Docker limita `/dev/shm` a 64 MB | Las restricciones ya estaban confirmadas (el `COMMIT` es anterior). Se volvió a correr solo el `VACUUM` con `PARALLEL 0`, y se corrigió `03_restaurar_indices.sql` para usarlo siempre |
| 2 | 04 y C5 | Mismo error (64 MB / 1 MB) en consultas con JOIN de 6M filas | El *hash join paralelo* arma la tabla hash en `/dev/shm` | `SET enable_parallel_hash = off` en `04_verificar.sql` y en C5. El resto del paralelismo sigue activo |

Para quien vuelva a ejecutar esto: con los scripts corregidos, la carga corre de punta a punta sin intervención. Una mejora opcional, que no se aplicó porque cambia la infraestructura compartida, es agregar `shm_size: 256mb` al servicio de la base en `docker-compose.yml`.

### 4. Restricciones de integridad

Fuente: C3 y C4 (`C3-restricciones.txt`, `C4-not-null.txt`, capturas 06, 07 y 08); C5 (`C5-huerfanos.txt`, captura 09).

| Tipo | Cantidad | Detalle |
|---|---:|---|
| PRIMARY KEY | **9** | Una por tabla. Compuestas en `usuario_roles (id_usuario, id_rol)` y `rutina_ejercicios (id_rutina, id_ejercicio)` |
| FOREIGN KEY | **8** | `usuario_roles` → `usuarios`, `roles` (CASCADE); `rutinas` → `usuarios` (SET NULL); `rutina_ejercicios` → `rutinas`, `ejercicios` (CASCADE); `suscripciones` → `usuarios` (SET NULL); `tarifas` → `suscripciones` (SET NULL); `pagos` → `tarifas` (SET NULL). Todas con `ON UPDATE CASCADE` |
| UNIQUE | **3** | `usuarios_dni_key (dni)`, `usuarios_email_key (email)`, `roles_nombre_key (nombre)` |
| CHECK | **0** | El esquema no define CHECK. Las reglas de columna son `NOT NULL` |
| NOT NULL | **52 de 57 columnas** | Aceptan NULL solo `pagos."tarifaId"`, `rutinas."usuarioId"`, `suscripciones."usuarioId"`, `tarifas."suscripcionId"` (FK de Sequelize con `ON DELETE SET NULL`) y `usuarios.google_id` |

**Estado de las FK:** las 8 están **validadas** (`convalidated = true`), ninguna `NOT VALID`. Como se crearon después de la carga y sin `NOT VALID`, PostgreSQL revisó las 42M filas hijas al crearlas.

**Huérfanos (C5): 0 en las 8 FK** (consulta `NOT EXISTS` sobre las 42M filas, 101 s).

**Verificación automática (`04_verificar.sql`):** los **30 de 30 chequeos dieron OK** (conteos, huérfanos, restricciones, unicidad y coherencia) y terminó con:

```
NOTICE:  SCRUM-35: todos los chequeos OK (conteos exactos, 0 huerfanos, unicidad y coherencia).
```

Además confirmó estas reglas de negocio, todas en 0 casos: tarifas impagas con pagos, pagadas sin pagos, suma de pagos distinta del precio, pagos anteriores al mes de su cuota o posteriores a la fecha de corte, `fecha_fin < fecha_inicio` y montos ≤ 0.

**Distribuciones obtenidas** (las de `04_verificar.log` que corresponden al criterio de "realistas" de SCRUM-35):

| Dato | Resultado |
|---|---|
| Tarifas | 80,0 % pagadas (4.800.000); 20,0 % impagas, de las cuales 743.958 siguen activas y 456.042 se dieron de baja por antigüedad |
| Pagos | 3.600.000 tarifas pagadas en un pago y 1.200.000 en dos partes; 68,7 % de los pagos en término (día 1 a 10) |
| Precio mensual p50 por año | 2021 $2.500 · 2022 $5.000 · 2023 $11.500 · 2024 $23.500 · 2025 $30.000 · 2026 $35.000 |
| Suscripciones | 20 % de bajas sin cuota (1.199.999), 70 % mensuales, 10 % trimestrales (599.999); 555.633 vigentes a la fecha de corte |
| Usuarios | Altas crecientes por año (204.679 en 2021 y 1.573.681 en 2025); 92 % activos; 8 % con Google; roles: 98,4 % socio, 1,5 % entrenador, 0,1 % admin |
| Rutinas | Tarde 40 %, Mañana 35 %, Noche 25 %; de lunes a viernes entre 16 % y 19 % por día, sábado 9 % y domingo 3 %; 25 % borradores sin ejercicios |

**Observaciones:**

- El esquema no tiene CHECK de dominio (por ejemplo `precio > 0` o `mes BETWEEN 1 AND 12`), y montos, fechas y precios se guardan como `VARCHAR`, herencia de Sequelize. El dataset igual los respeta, como comprueba `04_verificar`, pero el motor no lo impone. Queda como mejora posible: agregar esos CHECK y tipos nativos (`numeric` y `date`) en un ticket aparte, porque cambia el esquema y los modelos.
- Hay **1 rutina con turno `Manana`** (sin tilde): es la del seed (`02_seed.sql`). El frontend y el dataset usan `Mañana`. Conviene unificar el seed.

### Reproducibilidad

**No se verificó con una segunda carga**: se decidió hacer una sola ejecución. Estas son las huellas de esta corrida (sección "HUELLA" de `04_verificar.log`). Una carga futura desde cero tiene que dar exactamente los mismos valores:

| Tabla | Huella |
|---|---|
| usuarios | `d83f9d6d193e98d0c1bbd251f9b51deb` |
| usuario_roles | `c663e4f3aa536eafd601392e6a8656e3` |
| ejercicios | `528773273518e13cd9819d87621258b8` |
| rutinas | `016f13c878e50e65ffac4dcafdf99283` |
| rutina_ejercicios | `661a9b5bb7b81aa7df2872ed6583a01f` |
| suscripciones | `00452a03e8c3c5cd96c5e3890539b731` |
| tarifas | `8fd04f5863deaf22c91e0cdedf6de939` |
| pagos | `9ba51bdde7575ffcaf70bd2df707f12b` |

### 5. Evidencias

Todas en `docs/evidencias/SCRUM-36/`:

| Archivo | Contenido | Estado |
|---|---|---|
| `entorno.txt` | Hardware, versiones y parámetros de PostgreSQL | ✅ |
| `ejecucion.log` | Salida de `cargar.sh` (01 a 03) con `time`, incluido el error de `/dev/shm` en el VACUUM | ✅ |
| `ejecucion_04.log` | Salida de `cargar.sh 04_verificar` con `time` | ✅ |
| `../SCRUM-35/01_preparar.log` … `04_verificar.log` y `03_restaurar_indices_vacuum.log` | Salida de cada paso con los tiempos por sentencia | ✅ |
| `C1-conteos.txt` … `C5-huerfanos.txt` | Resultados de las consultas C1 a C5 | ✅ |
| `01-conteos-query-tool.png` | C1: `count(*)` por tabla | ⏳ pendiente (pgAdmin) |
| `02-count-rows-pagos.png` | *Count Rows* de pgAdmin sobre `pagos` | ⏳ pendiente |
| `03-tamanio-base.png` | Tamaño de la base (Statistics y C2.a) | ⏳ pendiente |
| `04-tamanio-por-tabla.png` | C2.b | ⏳ pendiente |
| `05-tamanio-por-indice.png` | C2.c y Statistics de `usuarios` | ⏳ pendiente |
| `06-restricciones-listado.png` | C3.a y C3.b | ⏳ pendiente |
| `07-constraints-arbol.png` | Nodo *Constraints* de `pagos` y `usuarios` | ⏳ pendiente |
| `08-erd-base.png` | ERD de la base | ⏳ pendiente |
| `09-huerfanos.png` | C5 y C4 | ⏳ pendiente |

### 6. Conclusión

Se cargaron **42.000.203 filas**: exactamente 6.000.000 en cada una de las 7 tablas de datos, 200 ejercicios y 3 roles. La base quedó en **5,2 GB** (3,8 GB de datos y 1,4 GB de índices). La carga llevó **16 min** en una máquina de 4 CPU con 3,5 GB de RAM para Docker, y la verificación 6 min más.

La integridad quedó garantizada por el motor (9 PK, 8 FK validadas y 3 UNIQUE) y comprobada por consulta: 0 huérfanos y 30/30 chequeos OK. La reproducibilidad está garantizada por diseño (valores deterministas) y quedan registradas las huellas, pero no se demostró con una segunda carga.

Falta solo la evidencia en pgAdmin (capturas 01 a 09). Con este volumen ya se pueden retomar las mediciones de SCRUM-42 a escala. Como punto de partida: las FK no tienen índice (`"usuarioId"`, `"suscripcionId"`, `"tarifaId"`), así que las consultas por socio van a hacer *seq scan* sobre 6M filas.

---


## Volver a la base chica

> [!CAUTION]
> Esto borra el dataset de 5 GB. Para recuperarlo hay que volver a cargarlo (~16 min).

```bash
docker compose --profile dev --profile tools down -v
docker compose --profile dev --profile tools up -d
```
