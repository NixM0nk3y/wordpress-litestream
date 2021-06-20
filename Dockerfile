#
#
#

FROM caddy:2-alpine as caddy

FROM php:7.4-fpm-alpine

ARG WORDPRESS_VERSION="5.7.2"
ARG WORDPRESS_SHA1="8d19761595182c25d107813b55b911a22e7c809b"

ARG WORDPRESS_SQLITE_VERSION="1.1.0"
ARG WORDPRESS_SQLITE_SHA1="a55c1e0323bae9b5394cb280989fa18951f0d20c"

ARG S6_OVERLAY_VERSION="2.2.0.3"
ARG S6_OVERLAY_SHA1="26076034def39e7256de128edb3fae53559a2af6"

ARG LITESTREAM_VERSION="0.3.4"
ARG LITESTREAM_SHA1="37eaa667d99370b3cbba408b22bc708afd6a9669"

# persistent dependencies
RUN set -eux; \
	apk add --no-cache \
        libcap \
# in theory, docker-entrypoint.sh is POSIX-compliant, but priority is a working, consistent image
		bash \
# BusyBox sed is not sufficient for some of our sed expressions
		sed \
# Ghostscript is required for rendering PDF previews
		ghostscript \
	;

# install the PHP extensions we need (https://make.wordpress.org/hosting/handbook/handbook/server-environment/#php-extensions)
RUN set -ex; \
	\
	apk add --no-cache --virtual .build-deps \
		$PHPIZE_DEPS \
		freetype-dev \
		libjpeg-turbo-dev \
		libpng-dev \
		libzip-dev \
	; \
	\
	docker-php-ext-configure gd \
		--with-freetype \
		--with-jpeg \
	; \
	docker-php-ext-install -j "$(nproc)" \
		bcmath \
		exif \
		gd \
		mysqli \
		zip \
	; \
	\
	runDeps="$( \
		scanelf --needed --nobanner --format '%n#p' --recursive /usr/local/lib/php/extensions \
			| tr ',' '\n' \
			| sort -u \
			| awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
	)"; \
	apk add --no-network --virtual .wordpress-phpexts-rundeps $runDeps; \
	apk del --no-network .build-deps

# set recommended PHP.ini settings
# see https://secure.php.net/manual/en/opcache.installation.php
RUN set -eux; \
	docker-php-ext-enable opcache; \
	{ \
		echo 'opcache.memory_consumption=128'; \
		echo 'opcache.interned_strings_buffer=8'; \
		echo 'opcache.max_accelerated_files=4000'; \
		echo 'opcache.revalidate_freq=2'; \
		echo 'opcache.fast_shutdown=1'; \
	} > /usr/local/etc/php/conf.d/opcache-recommended.ini
# https://wordpress.org/support/article/editing-wp-config-php/#configure-error-logging
RUN { \
# https://www.php.net/manual/en/errorfunc.constants.php
# https://github.com/docker-library/wordpress/issues/420#issuecomment-517839670
		echo 'error_reporting = E_ERROR | E_WARNING | E_PARSE | E_CORE_ERROR | E_CORE_WARNING | E_COMPILE_ERROR | E_COMPILE_WARNING | E_RECOVERABLE_ERROR'; \
		echo 'display_errors = Off'; \
		echo 'display_startup_errors = Off'; \
		echo 'log_errors = On'; \
		echo 'error_log = /dev/stderr'; \
		echo 'log_errors_max_len = 1024'; \
		echo 'ignore_repeated_errors = On'; \
		echo 'ignore_repeated_source = Off'; \
		echo 'html_errors = Off'; \
	} > /usr/local/etc/php/conf.d/error-logging.ini

RUN set -eux; \
	\
	curl -o wordpress.tar.gz -fL "https://wordpress.org/wordpress-${WORDPRESS_VERSION}.tar.gz"; \
	echo "${WORDPRESS_SHA1} *wordpress.tar.gz" | sha1sum -c -; \
	\
# upstream tarballs include ./wordpress/ so this gives us /usr/src/wordpress
	tar -xzf wordpress.tar.gz -C /usr/src/; \
	rm wordpress.tar.gz; \
    \
    curl -o wp-sqlite-db.tar.gz -fL "https://github.com/aaemnnosttv/wp-sqlite-db/archive/refs/tags/v${WORDPRESS_SQLITE_VERSION}.tar.gz"; \
    echo "${WORDPRESS_SQLITE_SHA1} *wp-sqlite-db.tar.gz" | sha1sum -c -; \
    \
    tar -xzf wp-sqlite-db.tar.gz -C /usr/src/; \
    mv /usr/src/wp-sqlite-db-${WORDPRESS_SQLITE_VERSION}/src/db.php /usr/src/wordpress/wp-content; \
    rm wp-sqlite-db.tar.gz; \
	\
	chown -R www-data:www-data /usr/src/wordpress; \
    mkdir /var/run/wpdata; \
    chown -R www-data:www-data /var/run/wpdata; \
# pre-create wp-content (and single-level children) for folks who want to bind-mount themes, etc so permissions are pre-created properly instead of root:root
# wp-content/cache: https://github.com/docker-library/wordpress/issues/534#issuecomment-705733507
	mkdir wp-content; \
	for dir in /usr/src/wordpress/wp-content/*/ cache; do \
		dir="$(basename "${dir%/}")"; \
		mkdir "wp-content/$dir"; \
	done; \
	chown -R www-data:www-data wp-content; \
	chmod -R 777 wp-content 

COPY ./wordpress/php-fpm.conf /usr/local/etc/php-fpm.d/zz-docker.conf
COPY --chown=www-data:www-data ./wordpress/wp-config-docker.php /usr/src/wordpress/
COPY ./wordpress/docker-entrypoint.sh /usr/local/bin/

# Install our s6 init system
#
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-amd64.tar.gz /tmp/
RUN echo "${S6_OVERLAY_SHA1} *s6-overlay-amd64.tar.gz" | sha1sum -c -; \
    gunzip -c /tmp/s6-overlay-amd64.tar.gz | tar -xf - -C /

COPY ./etc/services.d /etc/services.d
COPY ./etc/cont-init.d /etc/cont-init.d

# Download the static build of Litestream directly into the path & make it executable.
ADD https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-v${LITESTREAM_VERSION}-linux-amd64-static.tar.gz /tmp/litestream.tar.gz
RUN echo "${LITESTREAM_SHA1} *litestream.tar.gz" | sha1sum -c -; \
    tar -C /usr/local/bin -xzf /tmp/litestream.tar.gz; \
    rm /tmp/litestream.tar.gz

# Copy Litestream configuration file.
COPY ./etc/litestream.yml /etc/litestream.yml

# Copy in caddy and configure
COPY --from=caddy /usr/bin/caddy /usr/bin/caddy
COPY ./etc/Caddyfile /etc/Caddyfile

# set up nsswitch.conf for Go's "netgo" implementation
# - https://github.com/docker-library/golang/blob/1eb096131592bcbc90aa3b97471811c798a93573/1.14/alpine3.12/Dockerfile#L9
RUN chmod 0755 /usr/bin/caddy; \
    adduser -D -S -s /bin/bash -G www-data caddy; \
    setcap cap_net_bind_service=+ep `readlink -f /usr/bin/caddy`; \
    mkdir -p /etc/caddy; \
    mkdir -p /var/run/caddy; \
    chown caddy /var/run/caddy /etc/caddy; \
    [ ! -e /etc/nsswitch.conf ] && echo 'hosts: files dns' > /etc/nsswitch.conf;

ENV XDG_CONFIG_HOME=/etc/caddy XDG_DATA_HOME=/var/run/caddy

# Sync disks is enabled so that data is properly flushed.
ENV S6_SYNC_DISKS=1

ENTRYPOINT ["/init"]
