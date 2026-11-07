-- =====================================================================
--  Proyecto Demo HIA - Esquema relacional (PostgreSQL 16)
--  Equivale exactamente a lo que genera Sequelize (sequelize.sync) a partir
--  de los modelos de backend/src/models. Se ejecuta automaticamente al crear
--  el contenedor (ver docker-compose.yml).
--
--  Nota: las columnas "createdAt"/"updatedAt" y las FK "xxxId" van entre
--  comillas porque Sequelize las nombra en camelCase.
-- =====================================================================

-- ---------- Seguridad: usuarios y roles (N:M) ----------

CREATE TABLE IF NOT EXISTS usuarios (
    id            SERIAL PRIMARY KEY,
    nombre        VARCHAR(255) NOT NULL,
    apellido      VARCHAR(255) NOT NULL,
    dni           VARCHAR(255) NOT NULL UNIQUE,
    email         VARCHAR(255) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    google_id     VARCHAR(255),
    estado        BOOLEAN      NOT NULL DEFAULT TRUE,
    "createdAt"   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    "updatedAt"   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS roles (
    id     SERIAL PRIMARY KEY,
    nombre VARCHAR(255) NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS usuario_roles (
    id_usuario INTEGER NOT NULL REFERENCES usuarios (id) ON UPDATE CASCADE ON DELETE CASCADE,
    id_rol     INTEGER NOT NULL REFERENCES roles (id)    ON UPDATE CASCADE ON DELETE CASCADE,
    PRIMARY KEY (id_usuario, id_rol)
);

-- ---------- Entrenamiento: ejercicios y rutinas (N:M) ----------

CREATE TABLE IF NOT EXISTS ejercicios (
    id          SERIAL PRIMARY KEY,
    nombre      VARCHAR(255) NOT NULL,
    descripcion VARCHAR(255) NOT NULL,
    youtube_url VARCHAR(255) NOT NULL,
    activo      BOOLEAN      NOT NULL,
    "createdAt" TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    "updatedAt" TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS rutinas (
    id          SERIAL PRIMARY KEY,
    dia_semana  VARCHAR(255) NOT NULL,
    turno       VARCHAR(255) NOT NULL,
    nombre      VARCHAR(255) NOT NULL,
    descripcion VARCHAR(255) NOT NULL,
    activo      BOOLEAN      NOT NULL,
    "createdAt" TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    "updatedAt" TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    "usuarioId" INTEGER REFERENCES usuarios (id) ON UPDATE CASCADE ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS rutina_ejercicios (
    id_rutina    INTEGER NOT NULL REFERENCES rutinas (id)    ON UPDATE CASCADE ON DELETE CASCADE,
    id_ejercicio INTEGER NOT NULL REFERENCES ejercicios (id) ON UPDATE CASCADE ON DELETE CASCADE,
    PRIMARY KEY (id_rutina, id_ejercicio)
);

-- ---------- Facturacion: suscripciones -> tarifas (cuotas) -> pagos ----------

CREATE TABLE IF NOT EXISTS suscripciones (
    id           SERIAL PRIMARY KEY,
    fecha_inicio VARCHAR(255) NOT NULL,
    fecha_fin    VARCHAR(255) NOT NULL,
    precio       VARCHAR(255) NOT NULL,
    activo       BOOLEAN      NOT NULL,
    "createdAt"  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    "updatedAt"  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    "usuarioId"  INTEGER REFERENCES usuarios (id) ON UPDATE CASCADE ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS tarifas (
    id              SERIAL PRIMARY KEY,
    anio            VARCHAR(255) NOT NULL,
    mes             VARCHAR(255) NOT NULL,
    precio          VARCHAR(255) NOT NULL,
    pagado          BOOLEAN      NOT NULL,
    activo          BOOLEAN      NOT NULL,
    "createdAt"     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    "updatedAt"     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    "suscripcionId" INTEGER REFERENCES suscripciones (id) ON UPDATE CASCADE ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS pagos (
    id          SERIAL PRIMARY KEY,
    fecha       VARCHAR(255) NOT NULL,
    transaccion VARCHAR(255) NOT NULL,
    monto       VARCHAR(255) NOT NULL,
    activo      BOOLEAN      NOT NULL,
    "createdAt" TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    "updatedAt" TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    "tarifaId"  INTEGER REFERENCES tarifas (id) ON UPDATE CASCADE ON DELETE SET NULL
);
