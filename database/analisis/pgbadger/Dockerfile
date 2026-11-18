# SCRUM-39 - pgBadger en contenedor (no hace falta instalar Perl ni pgBadger en el host).
# Uso: docker build -t gymhub-pgbadger:13.1 database/analisis/pgbadger
#      docker run --rm -v "$PWD/docs/evidencias/SCRUM-39:/data" gymhub-pgbadger:13.1 [opciones] /data/postgresql.log
FROM perl:5.40-slim

ARG PGBADGER_VERSION=13.1
ADD https://github.com/darold/pgbadger/archive/refs/tags/v${PGBADGER_VERSION}.tar.gz /tmp/pgbadger.tar.gz

RUN tar -xzf /tmp/pgbadger.tar.gz -C /tmp \
 && install -m 0755 /tmp/pgbadger-${PGBADGER_VERSION}/pgbadger /usr/local/bin/pgbadger \
 && rm -rf /tmp/pgbadger*

USER nobody
WORKDIR /data
ENTRYPOINT ["pgbadger"]
