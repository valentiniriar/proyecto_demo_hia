# SCRUM-42 — Optimización en producción con el dataset de 6M

Después de cargar 6M filas por tabla en producción ([SCRUM-35-produccion](../SCRUM-35-produccion/README.md)), las pantallas del socio y el dashboard del admin se volvieron lentas. Fecha: **20/11/2026**.

## Problema

| Endpoint | Tiempo con 6M filas |
|---|---|
| `GET /api/rutinas/mis-rutinas` (socio) | **4,2 s** |
| `GET /api/tarifas/mis-tarifas` (socio) | **4,3 s** |
| `GET /api/dashboard/stats` (admin) | **10,1 s** |

**Causa:** PostgreSQL **no crea índices en las columnas de las FK** (`rutinas."usuarioId"`, `suscripciones."usuarioId"`, `tarifas."suscripcionId"`), así que cada consulta recorría las 6M filas (`Parallel Seq Scan`). Los índices se habían medido y aprobado en SCRUM-39 ([comparativa](../SCRUM-39/comparativa-indices-consultas.md)), pero solo se crearon a mano en una base de desarrollo y nunca llegaron a producción.

El dashboard es otro caso: son agregados (`COUNT`, `SUM`) sobre **todas** las filas, y ningún índice evita recorrerlas. SCRUM-39 ya había descartado `usuarios(estado)` y `usuario_roles(id_rol)` con mediciones.

## Solución

1. **Índices:** [`database/migraciones/001_indices_optimizacion.sql`](../../../database/migraciones/001_indices_optimizacion.sql) crea los 4 índices confirmados en SCRUM-39, con `CREATE INDEX CONCURRENTLY` (sin bloquear la app). Aplicada en la primaria, llegó sola a la réplica. Log: [migracion-001.txt](migracion-001.txt).

   | Índice | Creación | Tamaño |
   |---|---|---|
   | `idx_rutinas_usuario` | 7,6 s | 112 MB |
   | `idx_suscripciones_usuario` | 6,3 s | 112 MB |
   | `idx_tarifas_suscripcion` | 4,6 s | 118 MB |
   | `uq_pagos_transaccion` (UNIQUE) | 6,1 s | 181 MB |

2. **Dashboard** (`backend/src/controllers/dashboard.controller.js`): consultas en paralelo, activos e inactivos en una sola pasada (`COUNT(*) FILTER`), y resultado **cacheado 5 minutos** (`DASHBOARD_CACHE_MS`). Las visitas simultáneas comparten un solo cálculo. Tests: `backend/test/dashboard.test.js`.

## Mediciones en la base (réplica, de donde lee el backend)

Script: [`database/analisis/medir-produccion.sql`](../../../database/analisis/medir-produccion.sql). Planes completos: [antes.txt](antes.txt) y [despues-indices.txt](despues-indices.txt).

| # | Consulta | Antes | Después | Plan después |
|---|---|---:|---:|---|
| M1 | Mis rutinas (`rutinas` por `usuarioId`) | 1.771 ms | **1,5 ms** | `Index Scan idx_rutinas_usuario` (~1.200×) |
| M2 | Mis tarifas (`tarifas` ⋈ `suscripciones` por `usuarioId`) | 2.210 ms | **2,6 ms** | 2 × `Index Scan` (~870×) |
| M3 | Suscripciones de un socio | 1.073 ms | **1,5 ms** | `Index Scan idx_suscripciones_usuario` (~700×) |
| M4 | Pagos de una tarifa (`tarifaId`) | 2.391 ms | 2.001 ms | Sin índice **a propósito**: la app nunca filtra pagos por tarifa |
| M5–M8 | Agregados del dashboard | 0,7 – 3 s c/u | igual | Recorren toda la tabla: se resuelve con caché, no con índices |

**Costo de los índices:** 523 MB en total, y cada `INSERT` en esas tablas mantiene un índice más. SCRUM-39 midió el impacto en escrituras con los mismos índices: ninguna operación subió más de 2× en tiempo ni en WAL.

## Endpoints de la API, por Nginx

| Endpoint | Antes | Después |
|---|---:|---:|
| `GET /api/rutinas/mis-rutinas` | 4,21 s | **0,035 s** |
| `GET /api/tarifas/mis-tarifas` | 4,28 s | **0,014 s** |
