# SCRUM-35 — Carga del dataset de 6M en producción

Ejecución de los scripts de `database/dataset/` (ver [docs/SCRUM-35-dataset-6m.md](../../SCRUM-35-dataset-6m.md)) sobre la base de **producción** (`gymhub_db_prod`, proyecto `gymhub-produccion`), el **20/11/2026**.

## Previo
- La base tenía solo las filas del seed (condición que valida `01_preparar.sql`).
- Backup manual antes de cargar: `pg_dump -Fc`, validado con `pg_restore --list` (9 tablas con datos). Guardado en el volumen de backups (`antes_dataset_6m_20261120_005555.dump`) y en `produccion/` del servidor (no versionado).
- Recursos: Docker Desktop con 16 GB de RAM y 12 CPU; ~880 GB libres.

## Ejecución
Mismos pasos que `cargar.sh`, con el contenedor y el usuario de producción:

```bash
docker exec -i gymhub_db_prod psql -X -q -v ON_ERROR_STOP=1 -U <DB_USER> -d <DB_NAME> -f - < database/dataset/<paso>.sql
```

| Paso | Tiempo | Log |
|---|---|---|
| 01_preparar | 0 s | [01_preparar.log](01_preparar.log) |
| 02_generar | 2 min 47 s | [02_generar.log](02_generar.log) |
| 03_restaurar_indices | 4 min 2 s | [03_restaurar_indices.log](03_restaurar_indices.log) |
| 04_verificar | 3 min 24 s | [04_verificar.log](04_verificar.log) |
| **Total** | **10 min 14 s** | |

## Resultado
- `04_verificar.sql`: **todos los chequeos OK**. Conteos exactos (6.000.000 en las 7 tablas de datos; 200 ejercicios, 3 roles), 0 huérfanos en las 8 FK, unicidad de DNI, email y transacción, y coherencia de fechas y montos.
- Base: **5,2 GB** (antes 8 MB).
- Réplica (`gymhub_db_replica_prod`): en streaming, atraso de 0 bytes al terminar y 6.000.000 usuarios.
- Sin alertas activas en Prometheus al terminar.

## Tiempos de la API con 6M filas (desde el servidor, por Nginx)

| Endpoint | Tiempo |
|---|---|
| `GET /api/usuarios/` (página 1) | 11 ms |
| `GET /api/usuarios/?page=5000` | 36 ms |
| `GET /api/pagos/`, `/tarifas/`, `/suscripciones/` | 14 – 28 ms |
| `GET /api/suscripciones/?q=12345` | 10 ms |
| `GET /api/usuarios/socios/list?q=<dni>` | 12 ms |
| `GET /api/dashboard/stats` | **10 s** ⚠️ |

El dashboard del admin cuenta usuarios activos e inactivos y suma las tarifas pagadas recorriendo millones de filas en cada pedido: queda como caso de optimización.
