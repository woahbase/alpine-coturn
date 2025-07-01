# syntax=docker/dockerfile:1
#
ARG IMAGEBASE=frommakefile
#
FROM ${IMAGEBASE}
#
RUN set -xe \
    && apk add --no-cache --purge -uU \
        # bind-tools \
        hiredis \
        libcrypto3 \
        libmicrohttpd \
        libpq \
        libssl3 \
        mariadb-connector-c \
        # mongo-c-driver \
        sqlite-libs \
        coturn \
        libcap \
    && setcap CAP_NET_BIND_SERVICE=+ep /usr/bin/turnserver \
    && apk del --purge libcap \
    && rm -rf /var/cache/apk/* /tmp/*
#
COPY root/ /
#
VOLUME /var/lib/coturn/
#
EXPOSE 3478/udp 3478/tcp 5349/udp 5349/tcp
#
ENTRYPOINT ["/init"]
