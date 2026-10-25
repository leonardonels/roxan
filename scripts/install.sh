#!/usr/bin/env bash
# Install (or refresh) the roxan maintenance setup on this host. Safe to run again after a
# `git pull`. Run as root:  sudo ./scripts/install.sh   (or --uninstall)
set -euo pipefail
SCRIPTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROXAN_ROOT="$(dirname "$SCRIPTS_DIR")"
UNITS=(roxan-docker-update roxan-system-update roxan-healthcheck)

[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0 $*" >&2; exit 1; }
# shellcheck source=roxan.conf
source "$SCRIPTS_DIR/roxan.conf"

# <source in scripts/etc> <destination>
FILES=(
  "apt-preferences-nvidia /etc/apt/preferences.d/roxan-nvidia"
  "unattended-upgrades.conf /etc/apt/apt.conf.d/52roxan-unattended"
  "journald.conf /etc/systemd/journald.conf.d/roxan.conf"
  "sysctl.conf /etc/sysctl.d/90-roxan.conf"
  "grub.cfg /etc/default/grub.d/99-roxan.cfg"
)

if [[ "${1:-}" == "--uninstall" ]]; then
  for u in "${UNITS[@]}"; do
    systemctl disable --now "$u.timer" 2>/dev/null || true
    rm -f "/etc/systemd/system/$u.service" "/etc/systemd/system/$u.timer"
  done
  for f in "${FILES[@]}"; do rm -f "${f#* }"; done
  rm -f /etc/systemd/system.conf.d/roxan-watchdog.conf /etc/modules-load.d/roxan-watchdog.conf
  systemctl daemon-reload
  update-grub
  echo "uninstalled (docker daemon.json left as is)"
  exit 0
fi

echo "== tools"
command -v jq >/dev/null || apt-get install -y -q jq

echo "== config files"
for f in "${FILES[@]}"; do
  src="$SCRIPTS_DIR/etc/${f%% *}" dst="${f#* }"
  install -D -m 644 "$src" "$dst"
  echo "  $dst"
done
sysctl -q --system
systemctl restart systemd-journald
update-grub

echo "== hardware watchdog"
if modprobe iTCO_wdt 2>/dev/null && compgen -G '/dev/watchdog*' >/dev/null; then
  echo iTCO_wdt >/etc/modules-load.d/roxan-watchdog.conf
  install -D -m 644 "$SCRIPTS_DIR/etc/watchdog.conf" /etc/systemd/system.conf.d/roxan-watchdog.conf
  systemctl daemon-reexec
  echo "  enabled: $(systemctl show -p RuntimeWatchdogUSec --value) via $(ls /dev/watchdog*|head -1)"
else
  echo "  no hardware watchdog available (iTCO_wdt didn't load; is TCO/watchdog enabled in the BIOS?), skipped"
fi

echo "== docker daemon: log rotation, live-restore, DNS with fallback"
# Applied by dockerd on its next start (the reboot after install); log limits only affect
# containers created after that, i.e. from the next docker-update on.
daemon=/etc/docker/daemon.json
[[ -s $daemon ]] || echo '{}' >"$daemon"
tmp="$(mktemp)"
jq --argjson dns "$(printf '%s\n' "${DNS_SERVERS[@]}" | jq -R . | jq -sc .)" \
  '. + {"log-driver": "json-file", "log-opts": {"max-size": "20m", "max-file": "3"}, "live-restore": true, "dns": $dns}' \
  "$daemon" >"$tmp"
if ! cmp -s "$tmp" "$daemon"; then
  cp "$daemon" "$daemon.bak-$(date +%F)"
  install -m 644 "$tmp" "$daemon"
  echo "  updated $daemon (backup: $daemon.bak-$(date +%F)), takes effect at the next reboot"
fi
rm -f "$tmp"

echo "== host DNS: systemd-resolved instead of Tailscale MagicDNS"
# With MagicDNS the host's only resolver is 100.100.100.100, which forwards to this box's own
# Pi-hole: no Pi-hole, no DNS at all. resolved's list (/etc/systemd/resolved.conf + netplan) has
# Pi-hole first and public resolvers after it. Only this host stops using MagicDNS; the tailnet's
# DNS settings and other devices are unchanged.
if command -v tailscale >/dev/null && [[ "$(tailscale debug prefs 2>/dev/null | jq -r '.CorpDNS')" == true ]]; then
  tailscale set --accept-dns=false
  sleep 2
fi
if grep -q '^nameserver 100\.100\.100\.100' /etc/resolv.conf; then
  # Tailscale didn't restore its backup: point resolv.conf back at resolved's generated file.
  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
fi
echo "  resolv.conf: $(grep '^nameserver' /etc/resolv.conf | awk '{print $2}' | tr '\n' ' ')"

echo "== repo fixes"
# immich's compose file reads compose/immich-app/.env, but the file lives in data/immich-app/.
if [[ ! -e "$ROXAN_ROOT/compose/immich-app/.env" && -f "$ROXAN_ROOT/data/immich-app/.env" ]]; then
  sudo -u "$(stat -c %U "$ROXAN_ROOT")" ln -s ../../data/immich-app/.env "$ROXAN_ROOT/compose/immich-app/.env"
  echo "  linked compose/immich-app/.env -> data/immich-app/.env"
fi
if [[ ! -f "$SCRIPTS_DIR/roxan.env" ]]; then
  install -m 600 -o "$(stat -c %U "$ROXAN_ROOT")" "$SCRIPTS_DIR/roxan.env.example" "$SCRIPTS_DIR/roxan.env"
  echo "  created scripts/roxan.env: add ntfy/Telegram settings there for notifications"
fi
chmod 600 "$SCRIPTS_DIR/roxan.env"

echo "== systemd units"
# HOME of the repo owner, so `~` in compose files means the same as when they run compose by hand.
owner_home="$(getent passwd "$(stat -c %U "$ROXAN_ROOT")" | cut -d: -f6)"
for u in "${UNITS[@]}"; do
  for ext in service timer; do
    sed -e "s|@ROXAN_ROOT@|$ROXAN_ROOT|g" -e "s|@OWNER_HOME@|$owner_home|g" \
      "$SCRIPTS_DIR/systemd/$u.$ext" >"/etc/systemd/system/$u.$ext"
  done
done
systemctl daemon-reload
for u in "${UNITS[@]}"; do systemctl enable --now "$u.timer"; done
systemctl start roxan-healthcheck.service

echo
systemctl list-timers 'roxan-*' --no-pager
echo
echo "done. Logs: journalctl -u roxan-docker-update -u roxan-system-update -u roxan-healthcheck"
