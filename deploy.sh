#!/usr/bin/env bash
# Run from this PC:  ./deploy.sh root@<router-ip> [--rollback]
#   SITE_CONFIG=path/to/config.sh ./deploy.sh ...   also push that config
#     (replaces the router's /root/cake-turbo/config.sh; old one kept as .bak)
# Ships the files with tar over ssh (OpenWrt's dropbear has no sftp-server,
# so plain modern scp fails without -O).
set -euo pipefail
host=${1:?usage: deploy.sh root@<router-ip> [--rollback]}
here=$(cd "$(dirname "$0")" && pwd)
stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
cp "$here"/{cake-turbo.sh,config.sh,cake-turbo.init,install.sh} "$stage/"
if [[ -n ${SITE_CONFIG:-} ]]; then
	bash -n "$SITE_CONFIG"
	cp "$SITE_CONFIG" "$stage/config.site.sh"
	echo "pushing site config: $SITE_CONFIG"
fi
tar cz -C "$stage" . |
	ssh "$host" 'rm -rf /tmp/cake-turbo-src && mkdir -p /tmp/cake-turbo-src && tar xz -C /tmp/cake-turbo-src'
ssh "$host" "sh /tmp/cake-turbo-src/install.sh ${2:-}"
