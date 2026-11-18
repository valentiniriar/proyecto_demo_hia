# SCRUM-42 — Optimización de consultas Sequelize

## Objetivo

Reducir consultas innecesarias y evitar cargar grandes cantidades
de registros en memoria para realizar operaciones que puede
resolver PostgreSQL.

## Cambios realizados

### Listado de socios

Antes se consultaba usuario_roles para obtener los IDs de socios
y luego se realizaba otra consulta a usuarios.

Ahora se utiliza una asociación Sequelize con JOIN para filtrar
usuarios activos que tengan el rol socio.

### Conteo de usuarios por rol

Antes se cargaban los usuarios asociados a cada rol y se contaban
en JavaScript.

Ahora se utiliza COUNT y GROUP BY directamente en PostgreSQL.

## Controladores revisados

Se revisaron dashboard, tarifas, pagos, usuarios y ejercicios.

En los controladores examinados no se identificaron expresiones
LOWER(email), EXTRACT(year FROM fecha) ni ILIKE con comodín inicial.

## Pruebas realizadas

- Verificación de sintaxis Node.js: correcta.
- Listado de socios: resultado idéntico al original.
- Conteo de usuarios por rol: resultado idéntico al original.
- EXPLAIN (ANALYZE, BUFFERS): ejecutado en PostgreSQL.

### Resultados de EXPLAIN ANALYZE

- Filtro por id_rol: 7.738 ms.
- JOIN de socios: 2.350 ms.
- Agrupación por rol: 1.135 ms.

La base contenía 3 usuarios y 3 asignaciones de roles.
Estos tiempos corresponden a consultas diferentes y no permiten
afirmar una mejora porcentual directa ni medir escalabilidad.

## Conclusión

Se redujeron las consultas separadas y el procesamiento en memoria.
Las pruebas funcionales confirman que los resultados se mantienen.

Para evaluar rendimiento a gran escala se requiere un conjunto de
datos mayor y mediciones comparables.
