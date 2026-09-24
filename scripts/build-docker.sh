#!/usr/bin/env bash
# Build from the mediarunner checkout, independent of the caller's directory.
set -euo pipefail
mediarunner_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
exec docker build \
    --file "$mediarunner_dir/docker/Dockerfile" \
    --tag "${MEDIARUNNER_IMAGE:-mediarunner:ubuntu26.04}" \
    --build-arg "ZOTONIC_REF=${ZOTONIC_REF:-master}" \
    "$@" "$mediarunner_dir"
