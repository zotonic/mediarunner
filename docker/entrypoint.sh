#!/bin/sh
# Run the prebuilt site; configuration and secrets are supplied at runtime.
set -eu
if [ "$#" -eq 0 ]; then
    set -- start_nodaemon
fi
if [ "$1" = start_nodaemon ]; then
    test -r "$ZOTONIC_CONFIG_DIR/zotonic.config" || {
        echo "Mount a readable zotonic.config in $ZOTONIC_CONFIG_DIR" >&2
        exit 1
    }
    exec /opt/zotonic/bin/zotonic "$@"
fi
exec "$@"
