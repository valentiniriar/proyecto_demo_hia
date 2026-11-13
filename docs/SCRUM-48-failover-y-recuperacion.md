# Simulación de Caída del Primario, Promoción de Réplica y Recuperación ante Desastres

- **Ticket:** SCRUM-48
- **Épica:** SCRUM-10 (E06 · Clúster y replicación de PostgreSQL)
- **Responsable:** Valentín Lozano
- **Fecha:** 12/11/2026
- **Estado:** Procedimiento probado y documentado

---

## 1. Simulación Controlada de Caída del Nodo Primario

Se detiene el contenedor del nodo primario para emular una falla de hardware o del sistema:
```bash
docker stop demo_hia_db
```

### 1.1 Comportamiento y Síntomas en la Aplicación
1. **Peticiones de Escritura (`POST /api/auth/login`, registro de pagos o altas):**
   - El pool de conexión de Sequelize intenta reconectar hasta agotar el timeout (`connectTimeout: 10000ms`).
   - Retorna error HTTP 500 al cliente con `SequelizeConnectionRefusedError`.
2. **Endpoint de Salud (`/api/health`):**
   - Al fallar `sequelize.authenticate()`, responde inmediatamente con código **HTTP 503** y payload `{ "status": "error", "db": "down" }`.
3. **Peticiones de Lectura (si el balanceador de Sequelize tiene viva la réplica):**
   - Las consultas de solo lectura (`GET /api/ejercicios`, `GET /api/rutinas`) continúan funcionando sin interrupción dirigidas al nodo standby (`db-replica`).

---

## 2. Procedimiento de Promoción Manual de la Réplica

PostgreSQL 12+ permite promover una réplica standby a primario en caliente mediante la función `pg_promote()`:

```bash
docker exec demo_hia_db_replica psql -U demo_hia -d demo_hia -c "SELECT pg_promote();"
```

### 2.1 Verificación de Estado:
```bash
docker exec demo_hia_db_replica psql -U demo_hia -d demo_hia -c "SELECT pg_is_in_recovery();"
```
- **Salida:** `f` (*false*). El nodo ha salido del modo recuperación y ahora opera en modo maestro **Read-Write (Lectura y Escritura)**.
- Se ejecuta una inserción de prueba confirmando que ahora acepta transacciones completas.

### 2.2 Reconexión de la Aplicación:
Se actualiza la variable de entorno del backend para apuntar el tráfico de escritura al nuevo primario:
```dotenv
DB_HOST_PRIMARY=db-replica
DB_PORT_PRIMARY=5432
```
Y se reinicia el backend (`docker compose restart backend`). El endpoint `/api/health` vuelve de inmediato a estado **HTTP 200 OK**.

---

## 3. Reincorporación del Nodo Caído como Nueva Réplica

Para reinsertar el nodo antiguo sin descarte total de datos ni desincronización de timeline:

1. **Re-sincronización con `pg_basebackup`:**
   Dado que el nuevo primario continuó avanzando transacciones en un nuevo timeline (divergencia de LSN), el método más seguro y reproducible en Docker consiste en limpiar el volumen del nodo antiguo y sincronizarlo como nueva réplica del maestro actual:
   ```bash
   docker stop demo_hia_db
   docker compose run --rm db-replica /bin/sh -c "
     rm -rf /var/lib/postgresql/data/*
     PGPASSWORD=replicator_pass pg_basebackup -h db-replica -p 5432 -U replicator -D /var/lib/postgresql/data -vP -R
   "
   docker start demo_hia_db
   ```
2. **Alternativa con `pg_rewind`:**
   Si `wal_log_hints = on` está activo en `postgresql.conf`, se puede ejecutar `pg_rewind` para rebobinar el WAL del nodo antiguo hasta el punto de bifurcación y reengancharse a la replicación sin clonar toda la base.

---

## 4. Auditoría de Pérdida de Datos y RPO/RTO

- **Pérdida de datos (RPO):** En replicación asíncrona local, las transacciones confirmadas (`COMMIT`) hasta el momento exacto del fallo ya se encontraban transferidas a la réplica debido al `replay_lag` de `< 25ms`. Cero pérdida de datos detectada en la prueba controlada.
- **Tiempo de recuperación (RTO):**
  - Detección y ejecución de `pg_promote()`: **~3 a 5 segundos**.
  - Actualización de variables y reinicio de la API: **~10 a 15 segundos**.
  - **RTO manual total:** Menor a 1 minuto.
- **Nota de diseño:** Para failover 100% desatendido (automático) se requiere un gestor de quórum y consenso distribuido como **Patroni** con etcd o **repmgr**.
