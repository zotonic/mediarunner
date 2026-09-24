#!/usr/bin/env bash
# Exercise the built image and its entrypoint with disposable PostgreSQL storage.
set -euo pipefail
site_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=${MEDIARUNNER_IMAGE:-mediarunner:ubuntu26.04}
smoke_name=mediarunner-smoke-$$
smoke_dir=$(mktemp -d "${TMPDIR:-/tmp}/mediarunner-docker.XXXXXXXX")
cleanup() {
    result=$?
    trap - EXIT
    if (( result != 0 )); then
        docker logs "$smoke_name" >&2 2>/dev/null || true
        docker logs "$smoke_name-db" >&2 2>/dev/null || true
    fi
    docker rm -fv "$smoke_name" "$smoke_name-db" >/dev/null 2>&1 || true
    docker network rm "$smoke_name" >/dev/null 2>&1 || true
    rm -rf "$smoke_dir"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Run with the image's USER and default Docker security restrictions.
docker run --rm -i "$image" sh -s <<'CONTAINER'
set -eu
test "$(id -u)" = 10001
test -w /var/lib/zotonic/data
! command -v clamd
! command -v clamscan
ffmpeg -version >/dev/null
ffprobe -version >/dev/null
magick -version
printf '%%!PS\n/Helvetica findfont 12 scalefont setfont 72 720 moveto (PDF smoke) show showpage\n' >/tmp/smoke.ps
gs -q -dBATCH -dNOPAUSE -sDEVICE=pdfwrite -sOutputFile=/tmp/smoke.pdf /tmp/smoke.ps
erl -noshell -pa _build/default/lib/*/ebin -eval '
    Release = erlang:system_info(otp_release),
    io:format("OTP ~s~n", [Release]),
    true = list_to_integer(Release) >= 28,
    {ok, _} = application:ensure_all_started(erlexec),
    {ok, _} = z_exec:sandbox_status(),
    {ok, _} = z_exec:run_local(imagemagick_pdf,
        "magick /tmp/smoke.pdf[0] -thumbnail 90x90 /tmp/smoke.png",
        #{read => ["/tmp/smoke.pdf"], write => ["/tmp/smoke.png"]}),
    halt().'
file /tmp/smoke.png | grep 'PNG image data'
# The PDF exception must grant reading only.
if magick /tmp/smoke.png /tmp/denied.pdf >/tmp/pdf-write.log 2>&1; then
    echo 'PDF writing should remain denied' >&2
    exit 1
fi
grep -i 'security policy' /tmp/pdf-write.log
CONTAINER

mkdir -p "$smoke_dir/site_config.d/mediarunner"
cp "$site_dir/docker/config/erlang.config" "$smoke_dir/"
sed 's/CHANGE-ME/docker-smoke-only/g' "$site_dir/docker/config/zotonic.config" > "$smoke_dir/zotonic.config"
sed 's/CHANGE-ME/docker-smoke-only/g' "$site_dir/docker/config/site_config.d/mediarunner/site.config" \
    > "$smoke_dir/site_config.d/mediarunner/site.config"
chmod -R a+rX "$smoke_dir"
docker network create "$smoke_name" >/dev/null
docker run -d --name "$smoke_name-db" --network "$smoke_name" --network-alias postgres \
    -e POSTGRES_USER=zotonic -e POSTGRES_PASSWORD=docker-smoke-only -e POSTGRES_DB=zotonic \
    "${POSTGRES_IMAGE:-postgres:16}" >/dev/null
for n in $(seq 1 60); do
    if docker exec "$smoke_name-db" pg_isready -U zotonic >/dev/null 2>&1; then break; fi
    sleep 1
done
docker exec "$smoke_name-db" pg_isready -U zotonic >/dev/null
# No command override: test the real entrypoint and CMD.
docker run -d --name "$smoke_name" --network "$smoke_name" \
    --mount "type=bind,src=$smoke_dir,dst=/etc/zotonic,readonly" \
    -p 127.0.0.1::8443 "$image" >/dev/null
port=$(docker port "$smoke_name" 8443/tcp | cut -d: -f2)
for n in $(seq 1 120); do
    # The disposable site uses Zotonic's generated self-signed certificate.
    status=$(curl --insecure --silent --max-time 2 -o "$smoke_dir/logon.html" -w '%{http_code}' \
        -H 'Host: media.example.com' "https://127.0.0.1:$port/logon" || true)
    if [[ "$status" == 200 ]] && grep -qi 'Media runner' "$smoke_dir/logon.html"; then
        installed=$(docker exec "$smoke_name-db" psql -U zotonic -d zotonic -Atc \
            "select to_regclass('mediarunner.mediarunner_job') is not null")
        if [[ "$installed" == t ]]; then
            echo 'Docker smoke passed: OTP, sandbox, PDF policy and mediarunner logon/database.'
            exit 0
        fi
    fi
    [[ $(docker inspect -f '{{.State.Running}}' "$smoke_name") == true ]] || break
    sleep 1
done
echo 'Mediarunner did not become ready' >&2
exit 1
