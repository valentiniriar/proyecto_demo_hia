# Mantis Bug Tracker 2.28.4 sobre PHP 8.3 + Apache (SCRUM-70).
# El código se descarga del release oficial y se verifica con SHA-256
# (mismo valor que publica el proyecto en mantisbt-2.28.4.tar.gz.digests).
FROM php:8.3-apache

ARG MANTIS_VERSION=2.28.4
ARG MANTIS_SHA256=a400bd2957154baad3412130031e893d5c18cf1ed1cfb38b77ee64afd1ed2a33

RUN apt-get update \
 && apt-get install -y --no-install-recommends libpng-dev libjpeg62-turbo-dev libfreetype6-dev \
 && docker-php-ext-configure gd --with-freetype --with-jpeg \
 && docker-php-ext-install -j"$(nproc)" mysqli gd \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    curl -fsSL -o /tmp/mantis.tar.gz \
      "https://sourceforge.net/projects/mantisbt/files/mantis-stable/${MANTIS_VERSION}/mantisbt-${MANTIS_VERSION}.tar.gz/download"; \
    echo "${MANTIS_SHA256}  /tmp/mantis.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/mantis.tar.gz -C /var/www/html --strip-components=1; \
    rm /tmp/mantis.tar.gz; \
    chown -R www-data:www-data /var/www/html

# Endurecimiento básico de PHP/Apache: sin versión en cabeceras ni listados.
RUN { \
      echo 'expose_php = Off'; \
      echo 'display_errors = Off'; \
      echo 'log_errors = On'; \
      echo 'date.timezone = America/Argentina/Buenos_Aires'; \
    } > /usr/local/etc/php/conf.d/gymhub.ini \
 && { \
      echo 'ServerTokens Prod'; \
      echo 'ServerSignature Off'; \
      echo '<Directory /var/www/html>'; \
      echo '  Options -Indexes'; \
      echo '  # Mantis trae .htaccess propios: ruteo de la API REST y bloqueo de carpetas internas.'; \
      echo '  AllowOverride All'; \
      echo '</Directory>'; \
      echo '# Instalador/administración de Mantis: solo desde dentro del contenedor (setup.sh).'; \
      echo '<Directory /var/www/html/admin>'; \
      echo '  Require local'; \
      echo '</Directory>'; \
      echo '<FilesMatch "^config_inc\.php$">'; \
      echo '  Require all denied'; \
      echo '</FilesMatch>'; \
    } > /etc/apache2/conf-enabled/gymhub-hardening.conf \
 && a2enmod rewrite headers

COPY entrypoint.sh /usr/local/bin/gymhub-mantis-entrypoint
COPY bootstrap.php /opt/gymhub/bootstrap.php
RUN chmod +x /usr/local/bin/gymhub-mantis-entrypoint

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=5 \
  CMD curl -fsS -o /dev/null http://127.0.0.1/login_page.php || exit 1

ENTRYPOINT ["gymhub-mantis-entrypoint"]
CMD ["apache2-foreground"]
