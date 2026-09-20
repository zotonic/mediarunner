#!/usr/bin/env bash
# Run from a Zotonic checkout containing this site under apps_user/mediarunner.
set -euo pipefail

ci_site_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ci_site_dir/../.."

if [[ ! -f apps/zotonic_core/src/support/z_media_runner.erl ]]; then
    echo 'This Zotonic checkout does not include the media runner client support.' >&2
    exit 1
fi

# Keep this basename distinct from the application: Erlang infers library names
# from directories above ebin, and must resolve mediarunner to the built site.
ci_dir=$(mktemp -d "${TMPDIR:-/tmp}/zmr-ci.XXXXXXXX")
export MEDIARUNNER_CI_DIR="$ci_dir"
export MEDIARUNNER_TEST_TLS_DIR="$ci_dir/tls"
export ZOTONIC_CONFIG_DIR="$ci_dir/config"
mkdir -p "$ci_dir/ebin" "$ci_dir/tls" "$ci_dir/config"
cp "$ci_site_dir/priv/zotonic_site.config" "$ci_dir/site.config.original"
cleanup() {
    cp "$ci_dir/site.config.original" "$ci_site_dir/priv/zotonic_site.config"
    rm -rf "$ci_dir"
}
trap cleanup EXIT

# A private test CA verifies real HTTPS callbacks without weakening TLS checks.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj '/CN=Mediarunner CI CA' \
    -keyout "$ci_dir/tls/ca.key" -out "$ci_dir/tls/ca.crt" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj '/CN=localhost' \
    -keyout "$ci_dir/tls/server.key" -out "$ci_dir/tls/server.csr" 2>/dev/null
cat > "$ci_dir/tls/server.ext" <<'EXT'
subjectAltName=DNS:localhost
extendedKeyUsage=serverAuth
EXT
openssl x509 -req -days 1 -in "$ci_dir/tls/server.csr" \
    -CA "$ci_dir/tls/ca.crt" -CAkey "$ci_dir/tls/ca.key" -CAcreateserial \
    -extfile "$ci_dir/tls/server.ext" -out "$ci_dir/tls/server.crt" 2>/dev/null

# Compile tests explicitly so a failed compilation cannot silently skip a suite.
erl -noshell -pa _build/default/lib/*/ebin -eval '
    Out = filename:join(os:getenv("MEDIARUNNER_CI_DIR"), "ebin"),
    Files = filelib:wildcard("apps_user/mediarunner/test/*.erl") ++
        ["apps/zotonic_core/test/z_media_runner_tests.erl", "apps/zotonic_core/test/z_media_imagemagick_tests.erl"],
    case lists:all(fun(File) ->
        case compile:file(File, [{outdir, Out}, report]) of
            {ok, _} -> true;
            _ -> false
        end
    end, Files) of true -> halt(0); false -> halt(1) end.'

erl -noshell -pa _build/default/lib/*/ebin "$ci_dir/ebin" -eval '
    case eunit:test([mediarunner_tests, z_media_runner_tests, z_media_imagemagick_tests], [verbose]) of
        ok -> halt(0);
        _ -> halt(1)
    end.'

# A separate VM starts the complete site; the integration test uses a disposable schema.
erl -noshell -pa _build/default/lib/*/ebin "$ci_dir/ebin" -eval 'spawn(fun mediarunner_ci:run/0).'
