# Nodo PostgreSQL 16 administrado por Patroni (failover automático).
#
# Se parte de postgres:16-alpine A PROPÓSITO, igual que la base anterior: misma libc (musl) y por lo tanto
# mismas collations, y mismo uid del usuario postgres (70). Así Patroni puede ADOPTAR los volúmenes de datos
# que ya existen (los 6M de filas) sin dump/restore y sin riesgo de índices de texto inconsistentes.
FROM postgres:16-alpine

ARG PATRONI_VERSION=4.1.4

RUN apk add --no-cache python3 py3-pip py3-psycopg2 \
 && pip install --no-cache-dir --break-system-packages "patroni[etcd3]==${PATRONI_VERSION}" \
 && mkdir -p /etc/patroni \
 && chown postgres:postgres /etc/patroni

COPY --chown=postgres:postgres patroni.yml /etc/patroni/patroni.yml
COPY --chmod=0755 post-bootstrap.sh /scripts/post-bootstrap.sh

USER postgres
EXPOSE 5432 8008

# Patroni arranca, configura y vigila a PostgreSQL: decide si este nodo es líder o réplica.
# El chmod reemplaza lo que hacía el entrypoint de la imagen oficial: un volumen nuevo se crea con permisos
# abiertos y PostgreSQL se niega a arrancar si el directorio de datos no es 0700.
CMD ["sh", "-c", "chmod 0700 /var/lib/postgresql/data && exec patroni /etc/patroni/patroni.yml"]
