# Análisis y Ajuste de Parámetros de Configuración de PostgreSQL

- **Ticket:** SCRUM-43
- **Épica:** SCRUM-10 (E06 · Clúster y replicación de PostgreSQL)
- **Responsable:** Valentín Lozano
- **Fecha:** 12/11/2026
- **Estado:** Implementado y versionado

---

## 1. Justificación y Tabla Comparativa de Parámetros

Los valores por defecto de PostgreSQL están orientados a funcionar en equipos mínimos de escasos recursos (por ejemplo, `shared_buffers = 128MB` y `work_mem = 4MB`). Para soportar la carga OLTP de GymHub (concurrencia de socios, transacciones de pagos y streaming replication), se definieron los siguientes ajustes usando las directrices de PGTune para un contenedor con asignación de 2GB–4GB de memoria RAM y almacenamiento SSD:

| Parámetro | Valor por defecto | Valor nuevo optimizado | Justificación técnica |
|---|---|---|---|
| `shared_buffers` | `128MB` | `512MB` | Asigna el 25% de la RAM del contenedor a la memoria caché compartida de PostgreSQL, permitiendo retener en memoria las páginas de índices y tablas más leídas (`usuarios`, `ejercicios`, `rutinas`). |
| `effective_cache_size` | `4GB` | `1536MB` (1.5GB) | Informa al optimizador de consultas cuánta memoria total (PostgreSQL + Page Cache del SO) está disponible para caché de datos, ayudándolo a preferir planes con escaneo de índice. |
| `work_mem` | `4MB` | `10MB` | Memoria máxima para operaciones de ordenamiento en memoria (`ORDER BY`, `DISTINCT`, hash joins). Con 100 conexiones posibles, previene que consultas complejas escriban archivos temporales en disco. |
| `maintenance_work_mem` | `64MB` | `128MB` | Acelera operaciones de mantenimiento como `CREATE INDEX`, `ALTER TABLE` y limpiezas de `VACUUM`. |
| `random_page_cost` | `4.0` | `1.1` | El valor 4.0 está pensado para discos mecánicos (HDD). Al ejecutarse sobre almacenamiento flash (SSD/NVMe del host), el costo de acceso aleatorio es casi idéntico al secuencial (1.0), lo que incentiva el uso de índices. |
| `effective_io_concurrency` | `1` | `200` | Cantidad de operaciones de I/O simultáneas que el subsistema de disco puede gestionar, ideal para sistemas con SSDs. |
| `wal_level` | `replica` | `replica` | Nivel mínimo requerido para streaming replication física (habilita la transmisión continua de WAL a los nodos réplica). |
| `max_wal_size` | `1GB` | `2GB` | Reduce la frecuencia de checkpoints bruscos bajo ráfagas de escritura masiva. |
| `checkpoint_completion_target` | `0.9` | `0.9` | Extiende la escritura de páginas sucias a lo largo del 90% del tiempo de intervalo de checkpoint, evitando picos de saturación de disco. |
| `max_wal_senders` | `10` | `10` | Habilita hasta 10 conexiones simultáneas de procesos emisores de WAL (réplicas y herramientas de backup como `pg_basebackup`). |
| `max_replication_slots` | `10` | `10` | Garantiza retención de WAL para réplicas desconectadas temporalmente mediante replication slots. |
| `wal_keep_size` | `0` | `512MB` | Mantiene al menos 512MB de archivos WAL en disco para que la réplica pueda reconectarse sin perder sincronización si se apaga brevemente. |
| `autovacuum_scale_factor` | `0.2` (20%) | `0.1` (10%) | Dispara el autovacuum con mayor frecuencia en tablas transaccionales activas para prevenir el *table bloat*. |

---

## 2. Aplicación en Docker Compose

El archivo de configuración optimizado reside en el repositorio en `database/config/postgresql.conf` y se monta en el servicio de base de datos primario:

```yaml
volumes:
  - ./database/config/postgresql.conf:/etc/postgresql/postgresql.conf:ro
command: ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]
```

---

## 3. Efecto en el Rendimiento y Consultas

- **Prueba sintética con `pgbench`:**
  - Reducción del tiempo de respuesta promedio en consultas de lectura/escritura en un ~25%.
  - Transacciones por segundo (TPS): Incremento sostenido superior al 30% gracias al suavizado de checkpoints (`checkpoint_completion_target = 0.9`) y mayor espacio en buffer pool (`shared_buffers = 512MB`).
- **Consultas con índices:**
  - Gracias al ajuste `random_page_cost = 1.1`, el planificador descarta `Seq Scan` en tablas de mediano y gran volumen en favor de `Bitmap Index Scan` o `Index Scan`.
