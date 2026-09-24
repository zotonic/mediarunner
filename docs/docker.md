# Docker

Build a self-contained mediarunner image on the official minimal `ubuntu:26.04`
base. The runtime includes Erlang, ImageMagick 7, Ghostscript, ffmpeg, fonts,
`file`, and the native sandbox helper. ClamAV and wkhtmltopdf are not installed.
PostgreSQL runs separately.

## Build

From the mediarunner checkout:

```sh
scripts/build-docker.sh
```

Select a Zotonic branch, tag or commit containing media runner support:

```sh
ZOTONIC_REF=imagemagick-sandbox \
MEDIARUNNER_IMAGE=mediarunner:ubuntu26.04 \
    scripts/build-docker.sh --pull
```

The default Zotonic ref is `master`. Pin a commit for repeatable builds. Additional
arguments are passed to `docker build`, for example `--platform linux/amd64`.
The script works from any directory and includes the current mediarunner sources,
including uncommitted changes. Local configuration and data are excluded.
Build tools remain in the build stage, not the final image.

## Configure and run

Copy the configuration examples outside the checkout and replace the hostname,
PostgreSQL credentials and administrator password:

```sh
cp -R docker/config ../mediarunner-config
# Edit ../mediarunner-config/zotonic.config and
# ../mediarunner-config/site_config.d/mediarunner/site.config before starting.
docker network create mediarunner
```

Attach your PostgreSQL server to that network under the name `postgres`, or set
`dbhost` to an accessible external server. Create the configured database and role
first. The database must use UTF-8 and the role must own its schema.

```sh
docker run -d --name mediarunner --network mediarunner \
    --restart unless-stopped --stop-timeout 60 \
    --ulimit nofile=65536:65536 \
    --mount type=bind,src="$(cd ../mediarunner-config && pwd)",dst=/etc/zotonic,readonly \
    --mount type=volume,src=mediarunner-data,dst=/var/lib/zotonic \
    -p 80:8000 -p 443:8443 \
    mediarunner:ubuntu26.04
```

The container runs as UID/GID `10001`. Configuration must be readable by that
user. Docker initializes the named data volume with the image's ownership; for
bind-mounted data, create the directories with ownership `10001:10001` first.
The volume holds cache/results, site data, TLS material and logs. Keep PostgreSQL
storage persistent too. Do not share one data volume between active runners.

Use Zotonic's TLS modules, such as `mod_ssl_letsencrypt`, to install certificates;
activate them through the admin and follow their normal DNS/HTTP setup. The
example publishes the standard external HTTP/HTTPS ports. Production clients
require a trusted certificate. A reverse proxy can also terminate TLS, provided
its forwarding and Zotonic's public URL configuration agree.

Check the dashboard's sandbox status after startup. Linux needs Landlock ABI 3+
and seccomp support on the **host kernel**, including Docker Desktop's Linux VM.
The image does not need `--privileged`, host networking or additional capabilities.
Do not remove host security restrictions to conceal a sandbox setup error.
Set CPU/memory limits appropriate for the workload; explicitly configure worker
counts if needed. The disk reserve applies to the filesystem backing the volume,
so also enforce a host storage budget.

```sh
docker logs -f mediarunner
```

To inspect the image without starting the site:

```sh
docker run --rm mediarunner:ubuntu26.04 magick -version
docker run --rm mediarunner:ubuntu26.04 ffmpeg -version
```
