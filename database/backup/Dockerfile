FROM postgres:16-alpine

RUN apk add --no-cache tzdata bash

WORKDIR /scripts

COPY backup.sh /scripts/backup.sh
RUN chmod +x /scripts/backup.sh

# Script de entrada para configurar crond y ejecutar el primer backup al iniciar
COPY entrypoint.sh /scripts/entrypoint.sh
RUN chmod +x /scripts/entrypoint.sh

VOLUME ["/backups"]

ENTRYPOINT ["/scripts/entrypoint.sh"]
