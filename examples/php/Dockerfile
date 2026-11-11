# Imagem de produção de uma aplicação PHP (Laravel ou PHP puro) com Apache. Ajuste à vontade.
FROM composer:2 AS deps
WORKDIR /app
COPY . .
RUN if [ -f composer.json ]; then \
      composer install --no-dev --optimize-autoloader --no-interaction --no-scripts --ignore-platform-reqs; \
    fi

FROM php:8.3-apache
# Extensões comuns (PostgreSQL e MySQL) e mod_rewrite (rotas do Laravel)
RUN apt-get update -y && apt-get install -y --no-install-recommends libpq-dev libzip-dev \
  && docker-php-ext-install pdo_pgsql pdo_mysql zip \
  && a2enmod rewrite && rm -rf /var/lib/apt/lists/*
# Sem root: o compose escolhe o UID, então o Apache ouve na {{PORTA_APP}} e grava em pastas abertas
RUN sed -i 's/Listen 80/Listen {{PORTA_APP}}/' /etc/apache2/ports.conf \
  && sed -i 's/:80>/:{{PORTA_APP}}>/' /etc/apache2/sites-available/000-default.conf \
  && chmod -R a+rwX /var/run/apache2 /var/lock/apache2 /var/log/apache2
# Raiz pública: public/ no Laravel, a própria pasta no PHP puro
ENV APACHE_DOCUMENT_ROOT=/var/www/html{{PHP_PUBLICO}}
RUN sed -ri 's#/var/www/html#${APACHE_DOCUMENT_ROOT}#g' /etc/apache2/sites-available/*.conf \
  && sed -ri 's#AllowOverride None#AllowOverride All#g' /etc/apache2/apache2.conf
WORKDIR /var/www/html
COPY --from=deps /app ./
# Laravel grava em storage/ e bootstrap/cache
RUN mkdir -p storage bootstrap/cache && chmod -R a+rwX storage bootstrap/cache
# {{CRIAR_PASTAS_DOCKERFILE}}
EXPOSE {{PORTA_APP}}
