FROM zerodowntime/centos:7 as builder

ARG REDIS_VERSION=5.0.6
ARG REDIS_DOWNLOAD_URL=http://download.redis.io/releases/redis-5.0.6.tar.gz
ARG REDIS_DOWNLOAD_SHA=6624841267e142c5d5d5be292d705f8fb6070677687c5aad1645421a936d22b3

RUN set -ex; \
    \
    yum -y install \
    coreutils \
    gcc \
    linux-headers \
    make \
    musl-dev \
    wget \
    ; \
    \
    wget -O redis.tar.gz "$REDIS_DOWNLOAD_URL"; \
    echo "$REDIS_DOWNLOAD_SHA *redis.tar.gz" | sha256sum -c -; \
    mkdir -p /usr/src/redis; \
    tar -xzf redis.tar.gz -C /usr/src/redis --strip-components=1; \
    rm redis.tar.gz; \
    \
    # disable Redis protected mode [1] as it is unnecessary in context of Docker
    # (ports are not automatically exposed when running inside Docker, but rather explicitly by specifying -p / -P)
    # [1]: https://github.com/antirez/redis/commit/edd4d555df57dc84265fdfb4ef59a4678832f6da
    grep -q '^#define CONFIG_DEFAULT_PROTECTED_MODE 1$' /usr/src/redis/src/server.h; \
    sed -ri 's!^(#define CONFIG_DEFAULT_PROTECTED_MODE) 1$!\1 0!' /usr/src/redis/src/server.h; \
    grep -q '^#define CONFIG_DEFAULT_PROTECTED_MODE 0$' /usr/src/redis/src/server.h; \
    # for future reference, we modify this directly in the source instead of just supplying a default configuration flag because apparently "if you specify any argument to redis-server, [it assumes] you are going to specify everything"
    # see also https://github.com/docker-library/redis/issues/4#issuecomment-50780840
    # (more exactly, this makes sure the default behavior of "save on SIGTERM" stays functional by default)
    \
    make -C /usr/src/redis -j "$(nproc)"; \
    make -C /usr/src/redis install


FROM zerodowntime/centos:7

# add our user and group first to make sure their IDs get assigned consistently, regardless of whatever dependencies get added
RUN groupadd -r redis && useradd -r -g redis redis

# copy all redis binaries
COPY --from=builder /usr/local/bin/redis-* /usr/local/bin/

RUN mkdir /data && chown redis:redis /data
VOLUME /data
WORKDIR /data

COPY confd/templates  /etc/confd/templates
COPY confd/conf.d     /etc/confd/conf.d
COPY docker-entrypoint.sh /usr/local/bin/

COPY liveness-probe.sh /opt/liveness-probe.sh
COPY readiness-probe.sh /opt/readiness-probe.sh

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["/etc/redis.conf"]
EXPOSE 6379
