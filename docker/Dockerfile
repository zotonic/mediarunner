# Ubuntu's official image is minimal; there is no separate official slim tag.
FROM ubuntu:26.04 AS runtime
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 SHELL=/bin/sh
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates erlang-nox libseccomp2 libstdc++6 \
        imagemagick ghostscript ffmpeg file fonts-dejavu-core fonts-liberation \
        inotify-tools openssl dumb-init \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 zotonic \
    && useradd --uid 10001 --gid zotonic --create-home --shell /bin/sh zotonic
# Allow PDF previews while retaining the rest of the distribution's policy.
RUN sed -i '/<\/policymap>/i\  <policy domain="coder" rights="read" pattern="PDF" />' \
        /etc/ImageMagick-7/policy.xml

FROM runtime AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential git curl erlang-dev libseccomp-dev libssl-dev \
        autoconf automake libtool pkg-config \
    && rm -rf /var/lib/apt/lists/*
ARG ZOTONIC_REF=master
WORKDIR /opt/zotonic
RUN git init . \
    && git remote add origin https://github.com/zotonic/zotonic.git \
    && git fetch --depth 1 origin "${ZOTONIC_REF}" \
    && git checkout --detach FETCH_HEAD \
    && test -f apps/zotonic_core/src/media/z_media_runner.erl
COPY . apps_user/mediarunner/
RUN make \
    && make -C apps/zotonic_core/c_src \
    && test -x apps/zotonic_core/priv/bin/zotonic-sandbox \
    && rm -rf .git _build/default/lib/*/.git

FROM runtime
COPY --from=build --chown=zotonic:zotonic /opt/zotonic /opt/zotonic
ENV ZOTONIC_CONFIG_DIR=/etc/zotonic \
    ZOTONIC_DATA_DIR=/var/lib/zotonic/data \
    ZOTONIC_SECURITY_DIR=/var/lib/zotonic/security \
    ZOTONIC_LOG_DIR=/var/lib/zotonic/log \
    ERL_EPMD_ADDRESS=127.0.0.1
RUN mkdir -p /var/lib/zotonic/data /var/lib/zotonic/security /var/lib/zotonic/log \
    && chown -R zotonic:zotonic /var/lib/zotonic
COPY docker/entrypoint.sh /usr/local/bin/mediarunner-entrypoint
WORKDIR /opt/zotonic
USER zotonic
VOLUME ["/var/lib/zotonic"]
EXPOSE 8000 8443
ENTRYPOINT ["/usr/bin/dumb-init", "--", "/usr/local/bin/mediarunner-entrypoint"]
CMD ["start_nodaemon"]
