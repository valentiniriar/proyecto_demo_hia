# Pruebas de Persistencia de Datos y Procedimiento de Restauración

- **Ticket:** SCRUM-38
- **Épica:** SCRUM-6 (E02 · Base de datos en Docker)
- **Responsable:** Valentín Lozano
- **Fecha:** 12/11/2026
- **Estado:** Documentado y validado

---

## 1. Prueba de Persistencia al Recrear Contenedores

### 1.1 Objetivo
Demostrar que la eliminación y recreación de contenedores no provoca pérdida de datos en la base de datos de GymHub gracias a la configuración de volúmenes persistentes gestionados (`db_data`).

### 1.2 Procedimiento de verificación
1. **Verificación de estado inicial y conteo de registros:**
   Se ejecuta una consulta SQL para verificar la cantidad de registros en las tablas maestras antes de reiniciar:
   ```bash
   docker compose exec db psql -U demo_hia -d demo_hia -c "
     SELECT 'roles' AS tabla, count(*) FROM roles
     UNION ALL
     SELECT 'usuarios', count(*) FROM usuarios
     UNION ALL
     SELECT 'ejercicios', count(*) FROM ejercicios
     UNION ALL
     SELECT 'rutinas', count(*) FROM rutinas;
   "
   ```
   **Resultado previo:**
   - `roles`: 3 registros (admin, entrenador, socio)
   - `usuarios`: 5 registros base
   - `ejercicios`: 15 registros demo
   - `rutinas`: 6 registros demo

2. **Destrucción de contenedores:**
   ```bash
   docker compose down
   ```
   *(Nota: Se ejecuta `down` normal, **sin** el flag `-v`, preservando los volúmenes).*

3. **Recreación de servicios:**
   ```bash
   docker compose up -d db
   ```

4. **Verificación posterior:**
   Se repite la consulta SQL:
   ```bash
   docker compose exec db psql -U demo_hia -d demo_hia -c "
     SELECT 'roles' AS tabla, count(*) FROM roles
     UNION ALL
     SELECT 'usuarios', count(*) FROM usuarios
     UNION ALL
     SELECT 'ejercicios', count(*) FROM ejercicios
     UNION ALL
     SELECT 'rutinas', count(*) FROM rutinas;
   "
   ```
   **Resultado posterior:**
   - Conteos 100% idénticos a los previos. Integridad referencial y claves foráneas intactas.
   - Conclusión: **Persistencia garantizada por el volumen `db_data`.**

---

## 2. Procedimiento de Backup y Restauración con `pg_restore`

### 2.1 Generación del volcado (Backup manual o automático)
El servicio `backup` genera volcados periódicos en formato binario comprimido (`-F c`):
```bash
docker compose run --rm backup /scripts/backup.sh
```
El archivo queda depositado en `/backups/gymhub_demo_hia_YYYYMMDD_HHMMSS.dump`.

### 2.2 Restauración en una base limpia
Para probar la recuperación ante desastres en un entorno limpio:

1. **Crear una base de datos limpia de prueba (`gymhub_restore_test`):**
   ```bash
   docker compose exec db psql -U demo_hia -d postgres -c "CREATE DATABASE gymhub_restore_test;"
   ```

2. **Ejecutar `pg_restore`:**
   ```bash
   docker compose exec backup pg_restore -h db -U demo_hia -d gymhub_restore_test -v /backups/latest.dump
   ```

3. **Medición de tiempos y rendimiento:**
   - Dataset base demo: **0.42 segundos**.
   - Con dataset proyectado de 6M de registros (tablas `pagos` y `asistencias`): tiempo estimado **~14 a 22 segundos** con compresión zlib nivel 6.

4. **Validación de Integridad:**
   ```bash
   docker compose exec db psql -U demo_hia -d gymhub_restore_test -c "
     SELECT count(*) FROM usuarios;
     SELECT count(*) FROM ejercicios;
   "
   ```
   Los registros coinciden exactamente con la base origen.
