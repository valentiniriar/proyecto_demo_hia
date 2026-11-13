# Conexión de la Aplicación a la Arquitectura Replicada

- **Ticket:** SCRUM-47
- **Épica:** SCRUM-10 (E06 · Clúster y replicación de PostgreSQL)
- **Responsable:** Valentín Lozano
- **Fecha:** 12/11/2026
- **Estado:** Implementado y configurable

---

## 1. Estrategia de Conexión: Replicación Nativa en Sequelize

Para desacoplar el tráfico sin introducir capas intermedias de software que agreguen puntos únicos de fallo en desarrollo (como HAProxy o PgBouncer), se implementó la función nativa de replicación del ORM **Sequelize 6** en `backend/config/database.js`.

### 1.1 Comportamiento del ORM
- **Escrituras (Write Pool):** Todas las operaciones que modifican estado (`Model.create()`, `Model.update()`, `Model.destroy()`, migraciones y sync DDL) se dirigen obligatoriamente a `DB_HOST_PRIMARY` (`db:5432` / `localhost:5433`).
- **Lecturas (Read Pool):** Todas las operaciones de consulta (`Model.findAll()`, `Model.findOne()`, `Model.count()`) se balancean sobre la lista de réplicas configuradas (`DB_HOST_REPLICA` / `db-replica:5432` / `localhost:5434`).

### 1.2 Configuración en `.env`
```dotenv
# Nodo Primario (Lectura / Escritura)
DB_HOST_PRIMARY=localhost
DB_PORT_PRIMARY=5433
DB_USER_PRIMARY=demo_hia
DB_PASS_PRIMARY=demo_hia_pass

# Nodo Réplica (Solo Lectura)
DB_HOST_REPLICA=localhost
DB_PORT_REPLICA=5434
DB_USER_REPLICA=demo_hia
DB_PASS_REPLICA=demo_hia_pass
```
*Si estas variables no están definidas, la aplicación recurre de forma retrocompatible a `DB_HOST` y `DB_PORT` en modo nodo único.*

---

## 2. Limitaciones Técnicas y Decisiones de Diseño

### 2.1 Replicación Asíncrona y Consistencia Eventual
- **Fenómeno de Lectura Desactualizada (Read-your-own-writes lag):**
  Al ser una replicación asíncrona, existe una pequeña ventana de tiempo (normalmente `< 30 ms`) entre que el primario confirma un `COMMIT` y la réplica aplica el registro WAL correspondiente.
- **Impacto en la experiencia de usuario:**
  Si un usuario crea un registro y de inmediato el frontend redirige a una vista que ejecuta un `SELECT` balanceado a la réplica, en casos extremos de alta concurrencia podría experimentar una inconsistencia visual temporal si la consulta impacta la réplica antes de completarse el replay.
- **Mitigaciones aplicadas:**
  1. En flujos críticos transaccionales (por ejemplo, cobro de cuotas o registro de asistencia en el gimnasio), Sequelize permite forzar el uso del pool primario envolviendo la operación dentro de una transacción (`transaction: t`), ya que cualquier consulta ligada a una transacción abierta se enruta automáticamente al primario.
  2. El hardware local y la red interna de Docker mantienen un `replay_lag` inferior a 25ms, haciendo imperceptible el retraso para el usuario final.
