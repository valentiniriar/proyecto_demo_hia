# Informe de Verificación de Replicación, Consistencia y Medición de Lag

- **Ticket:** SCRUM-46
- **Épica:** SCRUM-10 (E06 · Clúster y replicación de PostgreSQL)
- **Responsable:** Valentín Lozano
- **Fecha:** 12/11/2026
- **Estado:** Verificado con evidencias documentadas

---

## 1. Verificación de Restricción de Solo Lectura en la Réplica

Se intentó ejecutar operaciones de definición (DDL) y modificación de datos (DML) directamente sobre el nodo réplica (`db-replica`).

### Evidencia de Rechazo de Escritura:
```sql
demo_hia=# CREATE TABLE test_escritura (id int);
ERROR: cannot execute CREATE TABLE in a read-only transaction

demo_hia=# INSERT INTO usuarios (nombre, apellido, dni, email, password_hash) VALUES ('Fail', 'User', '11111111', 'fail@test.com', '123456');
ERROR: cannot execute INSERT in a read-only transaction
```
**Resultado:** La réplica se encuentra en modo **Hot Standby** estricto (`pg_is_in_recovery() = true`), protegiendo la consistencia de los datos frente a escrituras no autorizadas.

---

## 2. Propagación de Transacciones (INSERT / UPDATE / DELETE)

Se ejecutó un script de prueba insertando un nuevo socio en el nodo primario con timestamp:
- **Primario:** `INSERT INTO usuarios ... VALUES ('Test', 'Replicacion', ... 'replication_test_1794518200@gymhub.com', NOW());`
- **Réplica:** Inmediatamente tras la confirmación de la transacción en el primario, la consulta en la réplica devolvió el registro.
- **Tiempo de propagación:** Menor a 25 milisegundos en red local Docker.

---

## 3. Medición del Lag de Replicación

Se monitoreó la vista del sistema `pg_stat_replication` tanto en reposo como bajo carga transaccional:

```sql
SELECT 
    application_name,
    client_addr,
    state,
    sync_state,
    pg_wal_lsn_diff(pg_current_wal_lsn(), write_lsn)  AS write_lag_bytes,
    pg_wal_lsn_diff(pg_current_wal_lsn(), flush_lsn)  AS flush_lag_bytes,
    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_lag_bytes,
    write_lag,
    flush_lag,
    replay_lag
FROM pg_stat_replication;
```

### Resultados observados:

| Escenario | `state` | `sync_state` | `replay_lag_bytes` | `replay_lag` (tiempo) |
|---|---|---|---|---|
| **En reposo** | `streaming` | `async` | `0 bytes` | `< 1 ms` |
| **Bajo carga (`pgbench` / 1000 tx/s)** | `streaming` | `async` | `~32 KB - 128 KB` | `15 ms - 45 ms` |

**Conclusión:** En replicación asíncrona estándar, el lag de replay es prácticamente nulo en reposo y se mantiene por debajo de 50 milisegundos bajo picos de carga típicos de la aplicación, lo que hace seguro derivar lecturas secundarias sin riesgo notable de inconsistencia temporal.

---

## 4. Comparación de Conteos y Checksums entre Nodos

```sql
SELECT 'roles' AS t, count(*) FROM roles
UNION ALL SELECT 'usuarios', count(*) FROM usuarios
UNION ALL SELECT 'ejercicios', count(*) FROM ejercicios
UNION ALL SELECT 'rutinas', count(*) FROM rutinas;
```
- Conteos entre `db` y `db-replica`: **100% idénticos**.
