#!/bin/sh
# Runs ON the router (deploy.sh calls it). Idempotent: an existing
# /root/cake-turbo/config.sh is kept on redeploy.
#
#   sh install.sh             install / update, take over from cake-autorate
#   sh install.sh --rollback  stop cake-turbo, give the line back to cake-autorate

set -e
SRC=$(cd "$(dirname "$0")" && pwd)
DEST=/root/cake-turbo
CA_INIT=/etc/init.d/cake-autorate

if [ "${1:-}" = "--rollback" ]; then
	[ -x /etc/init.d/cake-turbo ] && { /etc/init.d/cake-turbo stop; /etc/init.d/cake-turbo disable; }
	if [ -x "$CA_INIT" ]; then "$CA_INIT" enable; "$CA_INIT" start; echo "cake-autorate restored"; fi
	exit 0
fi

have() { command -v "$1" >/dev/null 2>&1; }

# --- dependencies (OpenWrt 24.x = opkg, 25.x = apk) ---
pkgs=""
have bash  || pkgs="$pkgs bash"
have fping || pkgs="$pkgs fping"
have tc    || pkgs="$pkgs tc-full"
if [ -n "$pkgs" ]; then
	echo "installing:$pkgs"
	if have apk; then apk update && apk add $pkgs
	else opkg update && opkg install $pkgs; fi || true
fi
for c in bash fping tc; do have "$c" || { echo "missing $c after package install; aborting" >&2; exit 1; }; done
bash -c '[ -n "${EPOCHREALTIME:-}" ]' || { echo "bash on this router is < 5.0; cannot run" >&2; exit 1; }

mkdir -p "$DEST"
cp "$SRC/cake-turbo.sh" "$DEST/"
chmod +x "$DEST/cake-turbo.sh"

# --- config: a pushed site config wins; else a fresh install imports ---
if [ -f "$SRC/config.site.sh" ]; then
	[ -f "$DEST/config.sh" ] && cp "$DEST/config.sh" "$DEST/config.sh.bak"
	cp "$SRC/config.site.sh" "$DEST/config.sh"
	echo "installed pushed site config"
elif [ ! -f "$DEST/config.sh" ]; then
	cp "$SRC/config.sh" "$DEST/config.sh"
	vals=""
	for f in /root/cake-autorate/config.primary.sh /root/cake-autorate/config.*.sh; do
		[ -f "$f" ] || continue
		vals=$(bash -c '. "$1" >/dev/null 2>&1; echo "$dl_if $ul_if $base_dl_shaper_rate_kbps $base_ul_shaper_rate_kbps"' _ "$f")
		echo "imported from $f"
		break
	done
	if [ -z "$(echo "$vals" | tr -d ' ')" ] && have uci; then
		wan=$(uci -q get sqm.@queue[0].interface || true)
		if [ -n "$wan" ]; then
			vals="ifb4$wan $wan $(uci -q get sqm.@queue[0].download) $(uci -q get sqm.@queue[0].upload)"
			echo "imported from SQM (sqm.@queue[0])"
		fi
	fi
	set -- $vals
	[ -n "${1:-}" ] && sed -i "s|^DL_IF=\"[^\"]*\"|DL_IF=\"$1\"|" "$DEST/config.sh"
	[ -n "${2:-}" ] && sed -i "s|^UL_IF=\"[^\"]*\"|UL_IF=\"$2\"|" "$DEST/config.sh"
	[ -n "${3:-}" ] && sed -i "s|^DL_BASE_KBPS=\"[^\"]*\"|DL_BASE_KBPS=\"$3\"|" "$DEST/config.sh"
	[ -n "${4:-}" ] && sed -i "s|^UL_BASE_KBPS=\"[^\"]*\"|UL_BASE_KBPS=\"$4\"|" "$DEST/config.sh"
fi

echo "--- $DEST/config.sh (link section) ---"
sed -n '/^DL_IF=/,/^MIN_PCT=/p' "$DEST/config.sh"
. "$DEST/config.sh"
if [ -z "$DL_BASE_KBPS" ] || [ -z "$UL_BASE_KBPS" ]; then
	echo "plan rates not set: edit $DEST/config.sh, then: /etc/init.d/cake-turbo enable && /etc/init.d/cake-turbo start" >&2
	start=0
else
	start=1
fi

# --- take over from cake-autorate (files kept for --rollback) ---
if [ -x "$CA_INIT" ]; then "$CA_INIT" stop 2>/dev/null || true; "$CA_INIT" disable 2>/dev/null || true; fi
for pid in $(ps w | grep '[c]ake-autorate.sh' | awk '{print $1}'); do kill "$pid" 2>/dev/null || true; done

cp "$SRC/cake-turbo.init" /etc/init.d/cake-turbo
chmod +x /etc/init.d/cake-turbo
if [ "$start" = 1 ]; then
	/etc/init.d/cake-turbo enable
	/etc/init.d/cake-turbo restart
	sleep 3
	bash "$DEST/cake-turbo.sh" status
fi
