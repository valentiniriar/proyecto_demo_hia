#!/usr/bin/env bash
# Despliegue y configuración inicial de Mantis para GymHub (SCRUM-70). Idempotente.
#   bash infra/mantis/setup.sh
#
# 1. Crea infra/mantis/.env con claves aleatorias (si no existe).
# 2. Construye y levanta Mantis + MariaDB.
# 3. Instala el esquema de la BD (solo la primera vez).
# 4. Ejecuta bootstrap.php: proyecto, categorías, usuarios, token de n8n.
# 5. Guarda las credenciales NUEVAS en infra/mantis/credenciales.local.json (ignorado por Git).
set -euo pipefail
# Git Bash (Windows) convierte rutas tipo /opt/... a C:/Program Files/Git/...: desactivarlo.
export MSYS_NO_PATHCONV=1

# En Git Bash, "pwd -W" da la ruta estilo C:/... que entiende Docker; en Linux/macOS, pwd.
DIR="$(cd "$(dirname "$0")" && (pwd -W 2>/dev/null || pwd))"
COMPOSE=(docker compose -f "$DIR/docker-compose.yml" --env-file "$DIR/.env")

rand() { openssl rand -base64 "$1" | tr -d '/+=\n' | cut -c1-"$2"; }

if [ ! -f "$DIR/.env" ]; then
  echo "→ Generando $DIR/.env con claves aleatorias"
  umask 077
  cat > "$DIR/.env" <<EOF
MANTIS_HOST_PORT=8990
MANTIS_DB_PASS=$(rand 32 32)
MANTIS_DB_ROOT_PASS=$(rand 32 32)
MANTIS_CRYPTO_SALT=$(openssl rand -base64 48 | tr -d '\n')
EOF
fi
# shellcheck disable=SC1091
set -a; . "$DIR/.env"; set +a

echo "→ Construyendo y levantando Mantis"
"${COMPOSE[@]}" up -d --build

echo "→ Esperando a que Mantis responda"
for _ in $(seq 1 60); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' gymhub-mantis 2>/dev/null)" = "healthy" ] && break
  sleep 3
done

instalado=$(docker exec gymhub-mantis-db mariadb -umantis -p"$MANTIS_DB_PASS" bugtracker -Nse \
  "SHOW TABLES LIKE 'mantis_user_table'" 2>/dev/null || true)

if [ -z "$instalado" ]; then
  echo "→ Instalando el esquema de Mantis"
  docker exec gymhub-mantis curl -fsS -o /dev/null -X POST http://127.0.0.1/admin/install.php \
    --data-urlencode "install=2" \
    --data-urlencode "db_type=mysqli" \
    --data-urlencode "hostname=mantis-db" \
    --data-urlencode "database_name=bugtracker" \
    --data-urlencode "db_username=mantis" \
    --data-urlencode "db_password=$MANTIS_DB_PASS" \
    --data-urlencode "admin_username=mantis" \
    --data-urlencode "admin_password=$MANTIS_DB_PASS" \
    --data-urlencode "timezone=America/Argentina/Buenos_Aires" \
    --data-urlencode "go=Install"
  docker exec gymhub-mantis-db mariadb -umantis -p"$MANTIS_DB_PASS" bugtracker -Nse \
    "SHOW TABLES LIKE 'mantis_user_table'" | grep -q mantis_user_table \
    || { echo "✖ La instalación del esquema falló"; exit 1; }
else
  echo "→ Esquema ya instalado"
fi

echo "→ Configurando proyecto, categorías, usuarios y token de n8n"
salida=$(docker exec gymhub-mantis php /opt/gymhub/bootstrap.php)

if echo "$salida" | grep -q '"password"\|"n8n_token": "'; then
  umask 077
  marca=$(date +%Y%m%d-%H%M%S)
  echo "$salida" > "$DIR/credenciales.local.json"
  cp "$DIR/credenciales.local.json" "$DIR/credenciales.local.$marca.json"
  echo "→ Credenciales NUEVAS guardadas en infra/mantis/credenciales.local.json (no se suben al repo)."
  echo "  Repartí cada contraseña a su integrante por un canal privado y pedí que la cambie al entrar."
else
  echo "→ No se generaron credenciales nuevas (todo ya existía)."
fi

echo "✔ Mantis listo en http://localhost:${MANTIS_HOST_PORT:-8990}"
