# Relevamiento de infraestructura y definición de componentes a contenerizar

- **Ticket:** SCRUM-24
- **Épica:** SCRUM-5 (E01 · Selección y diagnóstico de la aplicación)
- **Responsable:** Valentín Lozano
- **Fecha:** 12/11/2026
- **Estado:** Completado

---

## 1. Relevamiento de la infraestructura y ejecución actual

### 1.1 Entorno del host de desarrollo
- **Sistema Operativo base del equipo:** Windows 11 Pro / macOS (desarrollo multi-plataforma).
- **Runtime de Node.js:** Node.js v20+ / v22 (LTS).
- **Gestor de paquetes:** npm v10+.
- **Motor de contenedores:** Docker Desktop con Docker Compose v2+.
- **Forma de ejecución inicial:**
  - **Frontend:** Ejecución en el host mediante Angular CLI (`ng serve` en `http://localhost:4200`).
  - **Backend:** Ejecución en el host mediante Node.js / nodemon (`npm run dev` en `http://localhost:3000`).
  - **Base de datos:** Contenedor Docker único (`postgres:16-alpine` mapeando puerto `5433:5432`).
  - **Visor de base de datos:** Adminer 4 (`adminer:4` en `http://localhost:8080`).

### 1.2 Dependencias externas del sistema
La aplicación interactúa con servicios en la nube a través de HTTPS:
- MercadoPago API (Checkout / Pagos).
- YouTube Data API v3 (Listado de videos de ejercicios).
- Google OAuth 2.0 (Autenticación de usuarios).
- Groq Cloud API (`llama-3.1-8b-instant` para generación de rutinas asistidas por IA).
- Open Food Facts (Información nutricional de alimentos).
- Servicio SMTP / Resend (Envío de correos transaccionales).

---

## 2. Definición de componentes a contenerizar

Para alcanzar una arquitectura robusta, reproducible, altamente disponible y segura, se define la contenedorización total de los componentes del sistema, divididos en redes aisladas según su función y criticidad.

### 2.1 Matriz de servicios, imágenes, redes y exposición de puertos

| Componente / Servicio | Imagen Docker base | Red Docker | Puerto interno | Puerto expuesto (Host) | Justificación y Nivel de Exposición |
|---|---|---|---|---|---|
| **Frontend (Web SPA)** | `nginx-unprivileged:alpine` | `web` | `8080` (HTTP) | `80:8080` (o `8080`) | **Expuesto públicamente** vía túnel Cloudflare. Sirve los estáticos compilados de Angular y actúa como reverse-proxy para `/api/`. |
| **Backend (API REST)** | `node:22-alpine` | `web`, `db` | `3000` | *Ninguno* (solo accesible vía proxy Nginx) | **Red interna.** No se expone directamente a Internet ni al host para evitar accesos no autenticados o ataques directos a Node. |
| **BD Primario (PostgreSQL)** | `postgres:16-alpine` | `db` | `5432` | `127.0.0.1:5433` (solo en perfil `dev`) | **Red interna `db`.** En producción solo accesible por el backend, réplica y pgAdmin. En desarrollo accesible en localhost para debugging. |
| **BD Réplica (PostgreSQL)** | `postgres:16-alpine` | `db` | `5432` | *Ninguno* | **Red interna `db`.** Réplica física de solo lectura sincronizada por streaming replication. |
| **Servicio de Backups** | `postgres:16-alpine` + cron/script | `db` | — | *Ninguno* | **Red interna `db`.** Contenedor periódico que genera dumps comprimidos con `pg_dump` y los almacena en volumen persistente cifrado. |
| **pgAdmin 4** | `dpage/pgadmin4` | `db` | `80` | `127.0.0.1:5050` (localhost únicamente) | **Red interna / Localhost.** Administración gráfica restringida a acceso interno por VPN o localhost con credenciales fuertes. |
| **Prometheus** | `prom/prometheus:latest` | `monitoring` | `9090` | `127.0.0.1:9090` | **Red interna `monitoring`.** Recolección de métricas de infraestructura y aplicación. |
| **Grafana** | `grafana/grafana:latest` | `monitoring` | `3000` | `127.0.0.1:3001` | **Red interna / Localhost.** Visualización de dashboards operativos. |
| **Alertmanager** | `prom/alertmanager:latest` | `monitoring` | `9093` | *Ninguno* (o `127.0.0.1:9093`) | **Red interna `monitoring`.** Envío de alertas hacia n8n/Slack/Mantis. |
| **Exporters (Node, cAdvisor, PostgreSQL, Blackbox)** | Imágenes oficiales de Prometheus | `monitoring`, `db`, `web` | `9100`, `8080`, `9187`, `9115` | *Ninguno* | **Red interna.** Métricas expuestas exclusivamente para el scraping de Prometheus. |
| **Mantis Bug Tracker** | `vtrifonov/mantisbt` / oficial | `tools` | `80` | `127.0.0.1:8081` | **Red interna `tools`.** Gestión formal de incidencias y auditoría de bugs. |
| **Base de datos Mantis** | `mariadb:10.11` | `tools` | `3306` | *Ninguno* | **Red interna `tools`.** Almacenamiento exclusivo de Mantis. |
| **Nextcloud** | `nextcloud:apache` | `tools` | `80` | `127.0.0.1:8082` | **Red interna `tools`.** Repositorio centralizado de evidencias y documentación del equipo. |
| **Base de datos Nextcloud** | `postgres:16-alpine` | `tools` | `5432` | *Ninguno* | **Red interna `tools`.** Almacenamiento exclusivo de Nextcloud. |
| **n8n (Workflow Automation)** | `n8nio/n8n:latest` | `tools`, `monitoring` | `5678` | `127.0.0.1:5678` | **Red interna `tools`.** Automatización de verificación de backups y alertas. Webhook protegido con Basic Auth / API Key. |
| **Cloudflare Tunnel (`cloudflared`)** | `cloudflare/cloudflared:latest` | `web` | — | *Ninguno* (conexión saliente) | **Túnel seguro.** Establece conexión saliente cifrada a Cloudflare Edge sin abrir puertos en el router. |

---

## 3. Criterios de Aislamiento y Políticas de Red

### 3.1 Redes definidas en Docker Compose
1. **`web` (Red pública controlada):**
   - Conecta `cloudflared`, `frontend (Nginx)` y `backend (API Express)`.
   - Nginx es el único punto de entrada: sirve los estáticos y redirige `/api/*` al backend internamente por DNS de Docker (`http://backend:3000`).
2. **`db` (Red de datos aislada):**
   - Conecta `backend`, `db-primary`, `db-replica`, `backup`, `pgadmin` y `postgres-exporter`.
   - El frontend y el mundo exterior no tienen ruta IP hacia esta red.
3. **`monitoring` (Red de observabilidad):**
   - Conecta Prometheus, Grafana, Alertmanager y los exporters.
   - Acceso solo desde `localhost` para el equipo técnico.
4. **`tools` (Red de gestión y herramientas de soporte):**
   - Conecta n8n, Mantis y Nextcloud con sus respectivas bases de datos.
   - Aislada completamente de la red de base de datos de producción (`db`).

### 3.2 Decisiones sobre Puertos y Seguridad
- **Cero puertos de datos abiertos a Internet:** PostgreSQL primario y réplica, MariaDB y las bases de datos de soporte nunca mapean puertos `0.0.0.0`.
- **Enlace a Localhost (`127.0.0.1`):** Las herramientas administrativas (pgAdmin, Grafana, Mantis, n8n) solo escuchan en el loopback local del servidor para acceso vía túnel SSH o VPN.
- **Acceso público unificado:** El acceso externo a la plataforma GymHub se realiza exclusivamente vía HTTPS a través de Cloudflare Tunnel apuntando al contenedor Nginx.
