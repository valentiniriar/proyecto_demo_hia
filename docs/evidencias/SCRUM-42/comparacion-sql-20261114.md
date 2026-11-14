# SCRUM-42 — EXPLAIN ANALYZE, consultas equivalentes

**Fecha:** 2026-11-14T14:49-03:00

Se ejecutaron exclusivamente SELECT bajo `default_transaction_read_only=on` y `statement_timeout=8000`, tres veces por versión, alternando el orden para atenuar efectos de caché. Las alternativas SQL comparadas producen la misma clase de resultado, pero **no reproducen literalmente cada operación de Sequelize original ni miden tráfico y procesamiento JS**. No se afirma mejora de aplicación ni extrapolación a millones de registros.

| Caso | Baseline SQL (mediana ms) | Alternativa optimizada (mediana ms) |
|---|---:|---:|
| socios | 0.642 | 0.243 |
| roles | 0.163 | 0.215 |

**Pendiente de cierre:** comparar el comportamiento real anterior/posterior de controladores con datos representativos y `EXPLAIN ANALYZE` del SQL efectivamente generado.
