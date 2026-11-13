# Proyecto Demo HIA — GymHub

> **Práctica Integradora Final**  
> Aplicación web integral para la gestión de gimnasios (socios, rutinas asistidas por IA, cuotas y pagos).  
> Arquitectura contenerizada con frontend en Angular, backend en Node.js/Express y clúster de alta disponibilidad en PostgreSQL 16.

---

## 1. Requisitos Previos

Para ejecutar el proyecto en cualquier entorno limpio (Windows 11 / macOS / Linux) se requiere:
- **Docker Desktop** (con Docker Compose v2.20+ habilitado).
- **Node.js** v20 o superior y **npm** v10+ (solo necesario si se desea desarrollo local fuera de contenedores).
- **Git**.

---

## 2. Configuración Inicial de Entorno

El proyecto incluye plantillas con valores listos para usar en desarrollo:

```bash
# 1. Clonar el repositorio
git clone https://github.com/valentiniriar/proyecto_demo_hia.git
cd proyecto_demo_hia

# 2. Configurar variables de entorno generales
cp .env.example .env

# 3. Configurar variables de entorno del backend
cp backend/.env.example backend/.env
```

> [!NOTE]
> En `backend/.env` se debe definir una clave aleatoria para `JWT_SECRET` (ej: `JWT_SECRET=gymhub_secret_key_super_segura_123456`). Las claves de servicios externos (MercadoPago, Google OAuth, Groq, YouTube) son opcionales para la ejecución base del sistema.

---

## 3. Puesta en Marcha con Docker Compose

El proyecto cuenta con orquestación modular con redes y perfiles aislados.

### 3.1 Modo Desarrollo (Recomendado)
Levanta todos los servicios con hot-reload y puertos locales habilitados para debugging:

```bash
docker compose -f compose.yaml -f compose.dev.yaml up -d
```

**Servicios disponibles en desarrollo:**
- **Frontend SPA (Angular/Nginx):** [http://localhost:8080](http://localhost:8080)
- **API REST (Express):** [http://localhost:3000](http://localhost:3000)
- **Documentación Swagger:** [http://localhost:3000/api/docs](http://localhost:3000/api/docs)
- **PostgreSQL Primario:** `localhost:5433` (usuario: `demo_hia`, clave: `demo_hia_pass`, base: `demo_hia`)
- **pgAdmin 4 (Administración BD):** [http://localhost:5050](http://localhost:5050) (usuario: `admin@gymhub.com`, clave: `admin1234`)

### 3.2 Modo Clúster con Alta Disponibilidad y Replicación (E06)
Para desplegar el clúster completo con nodo réplica en Hot Standby por streaming físico:

```bash
docker compose -f compose.yaml -f compose.dev.yaml --profile cluster up -d
```
- **PostgreSQL Réplica (Solo Lectura):** `localhost:5434`

### 3.3 Modo Producción
En producción se utilizan imágenes inmutables de GHCR y **ningún puerto de base de datos se expone al exterior**:

```bash
docker compose -f compose.yaml -f compose.prod.yaml --profile prod up -d
```

---

## 4. Usuarios Demo Pre-cargados

El script inicial `database/02_seed.sql` genera automáticamente usuarios con distintos roles para pruebas (contraseña para todos: `admin123` o `123456` según el rol):

| Rol | Email | Uso / Permisos |
|---|---|---|
| **Administrador** | `admin@gymhub.com` | Gestión de socios, cobros, reportes globales y usuarios. |
| **Entrenador** | `entrenador@gymhub.com` | Creación y asignación de rutinas, generación asistida con IA. |
| **Socio** | `socio@gymhub.com` | Visualización de rutina personal, estado de cuota y pagos. |

---

## 5. Pruebas y Control de Calidad (CI)

Para ejecutar la suite de calidad en el backend:

```bash
cd backend
npm install
npm run lint         # Análisis estático de código con ESLint
npm test:ci          # Smoke tests unitarios y de integración de endpoints críticos
```

---

## 6. Resolución de Problemas Frecuentes (Troubleshooting)

1. **Conflicto con puerto 5432 preexistente:**
   - La base de datos de GymHub en desarrollo escucha en el puerto host `5433` precisamente para evitar colisiones con PostgreSQL locales.
2. **Reiniciar la base de datos desde cero:**
   ```bash
   docker compose down -v
   docker compose -f compose.yaml -f compose.dev.yaml up -d
   ```
3. **Verificar estado de salud de la API y conexión a BD:**
   - Consultar el endpoint de healthcheck: `curl http://localhost:3000/api/health` (debe devolver `{ "status": "ok", "db": "up" }`).
