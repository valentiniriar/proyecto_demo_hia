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

`DB_NAME`, `DB_USER`, `DB_PASS`, `PGADMIN_DEFAULT_EMAIL` y `PGADMIN_DEFAULT_PASSWORD` son **obligatorias** en `.env` (no versionado): si falta alguna, `docker compose` falla con un mensaje y no arranca. Si tu `.env` es anterior, copiá las variables `PGADMIN_*` desde `.env.example`.

La base es un **cluster PostgreSQL con failover automático** (Patroni + etcd + HAProxy). Qué es, cómo probar que al bajar el maestro otro nodo toma el control solo y cómo se migra producción: [`docs/implementacion-patroni.MD`](docs/implementacion-patroni.MD).

Perfiles disponibles en [`docker-compose.yml`](docker-compose.yml) (el `-f docker-compose.yml` es necesario porque en la carpeta también está `compose.yaml`):

| Perfil | Comando | Servicios | Puerto en el host |
|---|---|---|---|
| `dev` | `docker compose -f docker-compose.yml --profile dev up -d` | `etcd`, `pg-1`, `haproxy` (base de 1 nodo) | `localhost:${DB_PORT:-5433}` (líder), `:${DB_REPLICA_PORT:-5434}` (lecturas), `:7000` (estado de HAProxy) |
| `cluster` | se agrega a `dev`: `... --profile dev --profile cluster up -d` | `pg-2`, `pg-3` (réplicas; failover automático) | — (por HAProxy) |
| `tools` | se agrega al perfil elegido, p. ej. `... --profile dev --profile tools up -d` | `pgadmin` | `127.0.0.1:${PGADMIN_PORT:-5050}` |
| `adminer` | se agrega al perfil elegido, p. ej. `... --profile dev --profile adminer up -d` | `adminer` | `127.0.0.1:8080` |

- Estado del cluster: `docker exec demo_hia_pg_1 patronictl -c /etc/patroni/patroni.yml list` (en Git Bash, antes `export MSYS_NO_PATHCONV=1`).
- Reiniciar desde cero (borra los datos): `docker compose -f docker-compose.yml --profile dev --profile cluster down -v && docker compose -f docker-compose.yml --profile dev up -d`
- pgAdmin 4 (http://127.0.0.1:5050): `docker compose -f docker-compose.yml --profile dev --profile tools up -d`. Espera a que la BD esté `healthy`. Se entra con `PGADMIN_DEFAULT_EMAIL` / `PGADMIN_DEFAULT_PASSWORD` del `.env`, y el servidor "GymHub PostgreSQL (db)" ya viene cargado (la contraseña es `DB_PASS`).
- Adminer, alternativa liviana (http://127.0.0.1:8080): `docker compose -f docker-compose.yml --profile dev --profile adminer up -d`
  (sistema: PostgreSQL · servidor: `db` · usuario/clave/base: los de tu `.env`)

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

### Demo en clase (en 3 comandos)

```bash
# 1. App completa en la PC → http://localhost:8080 (usuarios en la sección 4)
docker compose -f compose.yaml -f compose.dev.yaml up -d --build

# 2. Publicarla en Internet con HTTPS (Cloudflare Tunnel, sin cuenta) → muestra la URL para el aula
bash infra/cloudflared/demo-publica.sh
#    al terminar:  bash infra/cloudflared/demo-publica.sh --detener

# 3. (opcional) Herramientas para mostrar: Mantis http://localhost:8990 · Grafana http://localhost:3001
bash infra/mantis/setup.sh
(cd infra/monitoring && docker compose up -d)
```

Plan B si falla Internet o el túnel: mostrar la app en `http://localhost:8080` (ver `docs/SCRUM-85-disponibilidad-y-riesgos.md`, sección 6). Documentos de referencia para la defensa: publicación (`docs/10-publicacion-internet.md`), incidencias (`docs/12-gestion-incidencias.md`) y seguridad (`docs/14-informe-seguridad.md`).

### 3.2 Modo Clúster con Alta Disponibilidad y Failover Automático (E06)
Cluster Patroni de 3 nodos (1 líder + 2 réplicas por streaming), etcd y HAProxy:

```bash
docker compose -f compose.yaml -f compose.dev.yaml --profile cluster up -d
```
- **Líder (escrituras):** `localhost:5433` · **Lecturas:** `localhost:5434` · **Estado de HAProxy:** http://localhost:7000
- Prueba de failover (bajar el maestro y ver que otro toma el control): `bash database/patroni/failover-demo.sh devb`. Ver [`docs/implementacion-patroni.MD`](docs/implementacion-patroni.MD).

### 3.3 Modo Producción
En producción se utilizan imágenes inmutables de GHCR y **ningún puerto de base de datos se expone al exterior**:

```bash
docker compose -f compose.yaml -f compose.prod.yaml --profile prod up -d
```

---

## 4. Usuarios Demo Pre-cargados

El script inicial `database/02_seed.sql` genera automáticamente usuarios con distintos roles para pruebas (**contraseña de los tres: `demo1234`**; solo desarrollo, cambiarla antes de dejar la app publicada mucho tiempo):

| Rol | Email | Uso / Permisos |
|---|---|---|
| **Administrador** | `admin@demo.com` | Gestión de socios, cobros, reportes globales y usuarios. |
| **Entrenador** | `entrenador@demo.com` | Creación y asignación de rutinas, generación asistida con IA. |
| **Socio** | `socio@demo.com` | Visualización de rutina personal, estado de cuota y pagos. |

---

## 5. Pruebas y Control de Calidad (CI)

Para ejecutar la suite de calidad en el backend:

```bash
cd backend
npm install
npm run lint         # Análisis estático de código con ESLint
npm run test:ci      # Smoke tests unitarios y de integración de endpoints críticos
```

---

## 6. Resolución de Problemas Frecuentes (Troubleshooting)

1. **Conflicto con puerto 5432 preexistente:**
   - La base de datos de GymHub en desarrollo escucha en el puerto host `5433` precisamente para evitar colisiones con PostgreSQL locales.
2. **Reiniciar la base de datos desde cero:**
   ```bash
   docker compose -f compose.yaml -f compose.dev.yaml down -v
   docker compose -f compose.yaml -f compose.dev.yaml up -d
   ```
3. **Verificar estado de salud de la API y conexión a BD:**
   - Consultar el endpoint de healthcheck: `curl http://localhost:3000/api/health` (debe devolver `{ "status": "ok", "db": "up" }`).

## Usuarios de prueba

Cargados por `database/02_seed.sql` (**solo desarrollo**). Contraseña de los tres: `demo1234`

| Rol | Email |
|---|---|
| admin | admin@demo.com |
| entrenador | entrenador@demo.com |
| socio | socio@demo.com |

## Dataset de prueba (SCRUM-35)

Hay un dataset masivo para pruebas de rendimiento: **6.000.000 filas** en cada tabla de datos, `ejercicios` con 200 (catálogo) y `roles` con 3. Respeta todas las FK y es reproducible. Necesita unos 10 GB libres y entre 15 y 30 minutos de carga. Detalle, justificación y advertencias en [`docs/SCRUM-35-dataset-6m.md`](docs/SCRUM-35-dataset-6m.md).

```bash
docker compose -f docker-compose.yml --profile dev down -v && docker compose -f docker-compose.yml --profile dev up -d   # base limpia (1 nodo: la carga es más rápida)
./database/dataset/cargar.sh                                                 # carga y verificación
```

Para volver a la base chica, repetir la primera línea.

## Modelo de datos

```mermaid
erDiagram
    usuarios ||--o{ usuario_roles : tiene
    roles ||--o{ usuario_roles : asigna
    usuarios ||--o{ rutinas : "se le asignan"
    rutinas ||--o{ rutina_ejercicios : incluye
    ejercicios ||--o{ rutina_ejercicios : "forma parte"
    usuarios ||--o{ suscripciones : contrata
    suscripciones ||--o{ tarifas : "genera cuotas"
    tarifas ||--o{ pagos : "se abona con"

    usuarios {
        int id PK
        string dni UK
        string email UK
        string nombre
        string apellido
        string password_hash
        string google_id
        boolean estado
    }
    roles {
        int id PK
        string nombre UK
    }
    usuario_roles {
        int id_usuario PK,FK
        int id_rol PK,FK
    }
    ejercicios {
        int id PK
        string nombre
        string descripcion
        string youtube_url
        boolean activo
    }
    rutinas {
        int id PK
        int usuarioId FK
        string dia_semana
        string turno
        string nombre
        string descripcion
        boolean activo
    }
    rutina_ejercicios {
        int id_rutina PK,FK
        int id_ejercicio PK,FK
    }
    suscripciones {
        int id PK
        int usuarioId FK
        string fecha_inicio
        string fecha_fin
        string precio
        boolean activo
    }
    tarifas {
        int id PK
        int suscripcionId FK
        string anio
        string mes
        string precio
        boolean pagado
        boolean activo
    }
    pagos {
        int id PK
        int tarifaId FK
        string fecha
        string transaccion
        string monto
        boolean activo
    }
```

Todas las tablas (salvo `roles`, `usuario_roles` y `rutina_ejercicios`) tienen además `createdAt` y `updatedAt`.

El backend mantiene `sequelize.sync()` al arrancar: si una tabla no existe la crea, pero **no modifica** las existentes. Si se cambia un modelo de Sequelize, hay que reflejar el cambio en `database/01_schema.sql` y recrear la base (`docker compose -f docker-compose.yml --profile dev --profile cluster down -v`).

## Notas para el equipo

- **Nunca subir `.env`** (está en `.gitignore`); solo se versiona `.env.example`.
- Flujo de trabajo (ramas, commits, Pull Requests y Definition of Done): ver [`CONTRIBUTING.md`](CONTRIBUTING.md). Resumen: rama `feature/SCRUM-XX-...` desde `develop`, PR hacia `develop` con revisión de al menos otra persona, y `develop → main` al cierre de cada sprint.
- Las URLs de la API están escritas a mano en `frontend/src/app/services/*.ts` (`http://localhost:3000/...`); si se despliega, conviene centralizarlas en un `environment`.
