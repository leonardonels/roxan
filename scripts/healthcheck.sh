#!/usr/bin/env bash
# Runs every 5 minutes (roxan-healthcheck.timer) and fixes the usual ways a headless box
# dies quietly:
#   - docker daemon hung                     -> restart docker
#   - container stuck "unhealthy"            -> restart it (docker itself never does)
#   - internet unreachable for ~30 min       -> restart networking; for ~3 h -> reboot
#   - tailscale down                         -> restart tailscaled
#   - disk almost full                       -> prune docker caches, vacuum the journal
#   - AIO pump slow/stopped, liquid too hot  -> reported (Glance + notification)
# It also publishes uptime, GPU state and pending reboots to the Glance status file.
# While docker-update/system-update run it only observes.
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/lib.sh"

issues=() actions=()
mkdir -p "$STATE_DIR/unhealthy"

exec 8>"$STATE_DIR/maintenance.lock"
maintenance=0
flock -n 8 || maintenance=1

act() { # act <description> <cmd...>: run a repair unless maintenance is in progress
  local what="$1"
  shift
  ((maintenance)) && return 0
  log "repair: $what"
  if "$@"; then actions+=("$what"); else actions+=("$what (failed)"); fi
}

counter() { # counter <name> inc|reset -> prints new value
  local f="$STATE_DIR/$1.count" n=0
  [[ -f "$f" ]] && n="$(<"$f")"
  if [[ "$2" == inc ]]; then n=$((n + 1)); else n=0; fi
  echo "$n" >"$f"
  echo "$n"
}

# --- docker daemon -----------------------------------------------------------
if ! timeout 60 docker info >/dev/null 2>&1; then
  issues+=("docker daemon not responding")
  act "restart docker" systemctl restart docker
fi

# --- unhealthy containers ----------------------------------------------------
mapfile -t unhealthy < <(timeout 60 docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null)
for f in "$STATE_DIR"/unhealthy/*; do
  [[ -e "$f" ]] && ! in_list "$(basename "$f")" "${unhealthy[@]}" && rm -f "$f"
done
for c in "${unhealthy[@]}"; do
  f="$STATE_DIR/unhealthy/$c"
  n=0 last=0
  [[ -f "$f" ]] && read -r n last <"$f"
  n=$((n + 1))
  issues+=("$c unhealthy")
  if ((n >= UNHEALTHY_CHECKS && $(date +%s) - last >= RESTART_COOLDOWN_MIN * 60)) && ((!maintenance)); then
    act "restart $c" docker restart -t 60 "$c"
    n=0 last=$(date +%s)
  fi
  echo "$n $last" >"$f"
done

# --- network -----------------------------------------------------------------
online=0
for h in "${PING_HOSTS[@]}"; do
  [[ "$h" == 192.168.* || "$h" == 10.* ]] && continue # LAN hosts don't prove internet access
  ping -c1 -W5 "$h" >/dev/null 2>&1 && { online=1; break; }
done
if ((online)); then
  counter net reset >/dev/null
else
  n="$(counter net inc)"
  lan=down
  for h in "${PING_HOSTS[@]}"; do ping -c1 -W3 "$h" >/dev/null 2>&1 && { lan=up; break; }; done
  issues+=("internet unreachable for $((n * 5)) min (LAN $lan)")
  if ((n == NET_RESTART_AFTER)); then
    act "restart systemd-networkd" systemctl restart systemd-networkd
  elif ((n >= NET_REBOOT_AFTER)) && ((!maintenance)); then
    safe_reboot "internet unreachable for $((n * 5)) min" && counter net reset >/dev/null
  fi
fi

# --- tailscale (the way back in when cloudflared is down) --------------------
if ((online)) && systemctl is-enabled --quiet tailscaled 2>/dev/null; then
  ts="$(timeout 20 tailscale status --json 2>/dev/null | jq -r '.BackendState // "unknown"')"
  if [[ "$ts" != Running ]]; then
    issues+=("tailscale ${ts:-not responding}")
    act "restart tailscaled" systemctl restart tailscaled
  fi
fi

# --- disk --------------------------------------------------------------------
disks="[]"
for m in "${DISK_MOUNTS[@]}"; do
  mountpoint -q "$m" || { issues+=("$m not mounted"); continue; }
  pct="$(df --output=pcent "$m" | tail -1 | tr -dc 0-9)"
  disks="$(jq -c --arg m "$m" --argjson p "$pct" '. + [{mount: $m, used_pct: $p}]' <<<"$disks")"
  if ((pct >= DISK_WARN_PCT)); then
    issues+=("$m ${pct}% full")
    if [[ "$m" == / ]]; then
      act "prune docker build cache and dangling images" sh -c 'docker builder prune -af --filter until=168h >/dev/null && docker image prune -f >/dev/null'
      act "vacuum journal" journalctl --vacuum-size=300M -q
    fi
  fi
done

# --- AIO cooler (reported only: without OpenLinkHub the hub runs its built-in curve) -------
if [[ -n "${COOLER_API:-}" ]]; then
  if ! aio="$(curl -fsS -m 10 "$COOLER_API" 2>/dev/null | jq -ec '[.device.devices[] | select(.AIO)][0] // empty')"; then
    issues+=("cooler: OpenLinkHub API not answering")
  else
    pump="$(jq -r '.rpm' <<<"$aio")" liquid="$(jq -r '.temperature' <<<"$aio")"
    ((pump < PUMP_MIN_RPM)) && issues+=("cooler: pump at ${pump} rpm")
    jq -e --argjson max "$LIQUID_MAX_C" '.temperature >= $max' <<<"$aio" >/dev/null &&
      issues+=("cooler: liquid at ${liquid} °C")
  fi
  # Nothing here can repair a pump, so make sure a human hears about it (at most every 6 h).
  cooler_issues="$(printf '%s\n' "${issues[@]}" | grep '^cooler: ')"
  stamp="$STATE_DIR/cooler-notified"
  if [[ -n "$cooler_issues" ]] && (($(date +%s) - $(cat "$stamp" 2>/dev/null || echo 0) >= 6 * 3600)); then
    notify "Cooler problem" "$cooler_issues" urgent
    date +%s >"$stamp"
  fi
fi

# --- GPU / pending reboot (reported only, system-update fixes these) ---------
gpu=ok
if ! gpu_ok; then
  gpu="NVIDIA module $(nvidia_loaded_version) / userspace $(nvidia_userspace_version): reboot needed"
  issues+=("GPU unavailable: $gpu")
fi

# --- report ------------------------------------------------------------------
if ((${#actions[@]})); then state=repaired
elif ((${#issues[@]})); then state=warning
else state=ok; fi

((${#issues[@]})) && log "issues: $(IFS=';'; echo "${issues[*]}")"
status_set health "$(jq -nc \
  --arg state "$state" --arg t "$(now_iso)" --argjson maintenance "$maintenance" \
  --argjson issues "$(json_array "${issues[@]}")" \
  --arg uptime "$(uptime -p | sed 's/^up //')" --arg gpu "$gpu" --argjson disks "$disks" \
  --argjson reboot_required "$([[ -f /var/run/reboot-required ]] && echo true || echo false)" \
  '{state: $state, checked: $t, maintenance: ($maintenance == 1), issues: $issues, uptime: $uptime,
    gpu: $gpu, disks: $disks, reboot_required: $reboot_required}')"

if ((${#actions[@]})); then
  status_set health "$(jq -nc --arg t "$(now_iso)" --argjson a "$(json_array "${actions[@]}")" \
    '{last_repair: $t, last_repair_actions: $a}')"
  notify "Healthcheck repaired something" "$(printf '%s\n' "${actions[@]}")
issues: $(IFS=';'; echo "${issues[*]}")" high
fi
exit 0
