# Orquestación de Contenedores y Configuración Separada Dev / Prod

- **Ticket:** SCRUM-53
- **Épica:** SCRUM-11 (E07 · Contenerización de la aplicación web)
- **Responsable:** Valentín Lozano
- **Fecha:** 12/11/2026
- **Estado:** Implementado y validado

---

## 1. Estructura de Archivos Docker Compose

Se adoptó el patrón estándar moderno de Docker Compose modular:

1. **`compose.yaml` (Base):**
   - Define los servicios nucleares: `frontend`, `backend`, `db` (primario), `db-replica` (standby) y `backup`.
   - Políticas de resiliencia (`restart: unless-stopped`).
   - Límites de recursos hardware (`limits.cpus` y `limits.memory`) por servicio para prevenir que un contenedor agote la memoria del servidor.
   - Definición de redes segmentadas:
     - `frontend_net`: Conecta exclusivamente `frontend` (Nginx) y `backend` (Express). La base de datos no tiene presencia en esta red.
     - `db_net`: Conecta `backend`, `db`, `db-replica`, `backup` y `pgadmin`. El tráfico web externo no tiene acceso directo a esta red.

2. **`compose.dev.yaml` (Desarrollo):**
   - Construcción de imágenes desde código fuente (`build.context`).
   - Mapeo de puertos en localhost (`127.0.0.1:5433` para primario, `5434` para réplica, `3000` para backend, `8080` para frontend, `5050` para pgAdmin).
   - Variables de entorno por defecto orientadas a desarrollo.

3. **`compose.prod.yaml` (Producción):**
   - Descarga de imágenes pre-compiladas e inmutables desde **GitHub Container Registry (GHCR)** (`ghcr.io/valentiniriar/...`).
   - **Cero puertos de base de datos expuestos:** `ports: []` en `db` y `db-replica`, garantizando que PostgreSQL solo sea accesible de forma interna por la red Docker `db_net`.
   - Variables de entorno obligatorias inyectadas vía archivo protegido `.env`.

---

## 2. Comandos de Puesta en Marcha

- **Modo Desarrollo:**
  ```bash
  docker compose -f compose.yaml -f compose.dev.yaml up -d
  ```

- **Modo Producción:**
  ```bash
  docker compose -f compose.yaml -f compose.prod.yaml --profile prod up -d
  ```

- **Verificación de logs e integridad:**
  ```bash
  docker compose -f compose.yaml -f compose.dev.yaml ps
  docker compose -f compose.yaml -f compose.dev.yaml logs -f backend
  ```
