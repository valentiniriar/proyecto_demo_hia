# API de GymHub (Node.js + Express)
# Build:  docker build -t gymhub-backend ./backend
# Run:    docker run --env-file backend/.env -p 3000:3000 gymhub-backend

# --- Etapa 1: dependencias de producción ---------------------------------
FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
# --omit=dev: nodemon y demás herramientas de desarrollo no entran a la imagen.
# --ignore-scripts=false es el default; bcrypt usa binarios precompilados (prebuilds musl).
RUN npm ci --omit=dev && npm cache clean --force

# --- Etapa 2: imagen final -----------------------------------------------
FROM node:22-alpine
ENV NODE_ENV=production \
    PORT=3000
WORKDIR /app

COPY --from=deps --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node . .

# Usuario sin privilegios (viene en la imagen oficial de Node).
USER node

EXPOSE 3000

# Marca el contenedor como unhealthy si la API no responde o la base no está disponible.
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -qO- "http://127.0.0.1:${PORT}/api/health" > /dev/null || exit 1

CMD ["node", "index.js"]
