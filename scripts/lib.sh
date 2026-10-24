#!/usr/bin/env bash
# Shared helpers for the roxan maintenance scripts. Sourced, not executed.

ROXAN_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
SCRIPTS_DIR="$ROXAN_ROOT/scripts"
# shellcheck source=roxan.conf
source "${ROXAN_CONF:-$SCRIPTS_DIR/roxan.conf}"
# shellcheck disable=SC1091
[[ -f "$SCRIPTS_DIR/roxan.env" ]] && source "$SCRIPTS_DIR/roxan.env"

STATE_DIR="${STATE_DIR:-/var/lib/roxan}"
# Served by Glance at /assets/roxan-status.json and rendered by the "Roxan" widget in glance.yml.
STATUS_FILE="${STATUS_FILE:-$ROXAN_ROOT/data/glance/assets/roxan-status.json}"
STATUS_OWNER="$(stat -c %U:%G "$ROXAN_ROOT")"
mkdir -p "$STATE_DIR"

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

now_iso() { date -u +%FT%TZ; }

in_list() {
  local needle="$1" item
  shift
  for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
  return 1
}

# json_array a b c -> ["a","b","c"]
json_array() {
  if (($# == 0)); then echo '[]'; else printf '%s\n' "$@" | jq -R . | jq -sc .; fi
}

# retry <attempts> <cmd...>: run cmd until it succeeds, backing off 30s, 60s, ...
retry() {
  local attempts="$1" i
  shift
  for ((i = 1; i <= attempts; i++)); do
    "$@" && return 0
    ((i < attempts)) && sleep $((i * 30))
  done
  return 1
}

# Take the lock shared by docker-update and system-update so they never overlap.
maintenance_lock() {
  exec 8>"$STATE_DIR/maintenance.lock"
  flock -w "${1:-7200}" 8
}

# status_set <section> <json-object>: merge the object into .<section> of the status file.
status_set() {
  local section="$1" json="$2"
  (
    flock -w 30 9 || exit 1
    local tmp
    tmp="$(mktemp "$STATE_DIR/status.XXXXXX")"
    { jq -e 'type == "object"' "$STATUS_FILE" >/dev/null 2>&1 && cat "$STATUS_FILE" || echo '{}'; } |
      jq --arg s "$section" --argjson v "$json" --arg t "$(now_iso)" \
        '.[$s] = ((.[$s] // {}) + $v) | .updated_at = $t' >"$tmp" &&
      install -m 644 "$tmp" "$STATUS_FILE" &&
      chown "$STATUS_OWNER" "$STATUS_FILE" 2>/dev/null
    rm -f "$tmp"
  ) 9>"$STATE_DIR/status.lock"
}

# notify <title> <message> [ntfy priority: min|low|default|high|urgent]
notify() {
  local title="$1" msg="$2" prio="${3:-default}"
  if [[ -n "${NTFY_URL:-}" ]]; then
    curl -fsS -m 20 -H "Title: $HOSTNAME: $title" -H "Priority: $prio" -H "Tags: computer" \
      -d "$msg" "$NTFY_URL" >/dev/null || warn "ntfy notification failed"
  fi
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    curl -fsS -m 20 "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
      --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
      --data-urlencode "text=[$HOSTNAME] $title"$'\n'"$msg" >/dev/null || warn "telegram notification failed"
  fi
  return 0
}

# --- NVIDIA ------------------------------------------------------------------
# NVML works, i.e. the loaded kernel module matches the installed userspace libraries.
gpu_ok() { timeout 60 nvidia-smi -L >/dev/null 2>&1; }
nvidia_loaded_version() { sed -n 's/.*Kernel Module *\([0-9.]*\).*/\1/p' /proc/driver/nvidia/version 2>/dev/null; }
nvidia_userspace_version() { dpkg-query -W -f='${Version}' "nvidia-utils-$NVIDIA_BRANCH" 2>/dev/null | cut -d- -f1; }

# --- reboot ------------------------------------------------------------------
# safe_reboot <reason>: reboot in one minute unless an automatic reboot already happened
# within REBOOT_MIN_INTERVAL_H. Returns 1 when the reboot was refused.
safe_reboot() {
  local reason="$1" stamp="$STATE_DIR/last-reboot" last=0
  [[ -f "$stamp" ]] && last="$(<"$stamp")"
  if (($(date +%s) - last < REBOOT_MIN_INTERVAL_H * 3600)); then
    warn "reboot needed ($reason) but the last automatic reboot was less than ${REBOOT_MIN_INTERVAL_H}h ago"
    return 1
  fi
  date +%s >"$stamp"
  status_set reboot "$(jq -nc --arg t "$(now_iso)" --arg r "$reason" '{at: $t, reason: $r}')"
  notify "Rebooting" "$reason"
  log "rebooting in 1 minute: $reason"
  shutdown -r +1 "roxan maintenance: $reason"
}
