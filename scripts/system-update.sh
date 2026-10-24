#!/usr/bin/env bash
# Apply every apt upgrade while staying on the NVIDIA $NVIDIA_BRANCH driver branch (pinned by
# install.sh, see etc/apt-preferences-nvidia), then reboot when the update needs it.
#
# A reboot is also what fixes "Failed to initialize NVML: Driver/library version mismatch":
# apt replaces the NVIDIA userspace libraries right away, but the new kernel module is only
# loaded at boot, and until then no GPU container can be (re)started. So before rebooting
# this checks that the kernel GRUB will boot has an NVIDIA module matching the userspace,
# otherwise the box would come back without its GPU.
#
# Usage: system-update.sh [--no-reboot]
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/lib.sh"

NO_REBOOT=0
[[ "${1:-}" == "--no-reboot" ]] && NO_REBOOT=1

maintenance_lock || { warn "another maintenance job is still running"; exit 1; }

# needrestart in automatic mode restarts services still using replaced libraries.
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
APT=(apt-get -y -q -o DPkg::Lock::Timeout=900
  -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

started="$(now_iso)"
status_set system "$(jq -nc --arg t "$started" '{state: "running", started: $t}')"

problems=()
finish() {
  local state="$1" reboot_reasons="$2"
  status_set system "$(jq -nc \
    --arg state "$state" --arg started "$started" --arg finished "$(now_iso)" \
    --argjson upgraded "$(json_array "${upgradable[@]}")" \
    --argjson problems "$(json_array "${problems[@]}")" \
    --arg kernel "$(uname -r)" --arg reboot "$reboot_reasons" \
    --arg nv_loaded "$(nvidia_loaded_version)" --arg nv_user "$(nvidia_userspace_version)" \
    '{state: $state, started: $started, finished: $finished, upgraded: $upgraded, problems: $problems,
      kernel: $kernel, reboot_pending: $reboot, nvidia_loaded: $nv_loaded, nvidia_installed: $nv_user}')"
}

# --- upgrade -----------------------------------------------------------------
dpkg --configure -a
if ! retry 3 apt-get -q -o DPkg::Lock::Timeout=900 update; then
  problems+=("apt-get update failed")
fi
mapfile -t upgradable < <(apt list --upgradable 2>/dev/null | sed -n 's|^\([^/]*\)/.*|\1|p')
log "${#upgradable[@]} packages upgradable"

if ((${#upgradable[@]})); then
  if ! "${APT[@]}" full-upgrade; then
    problems+=("apt-get full-upgrade failed")
    "${APT[@]}" -f install || true
  fi
fi
"${APT[@]}" autoremove --purge || problems+=("apt-get autoremove failed")
apt-get -q autoclean >/dev/null

# --- NVIDIA sanity -----------------------------------------------------------
nv_user="$(nvidia_userspace_version)"
if [[ -z "$nv_user" ]]; then
  problems+=("nvidia-utils-$NVIDIA_BRANCH is not installed")
fi
other_branches="$(dpkg-query -W -f='${Status} ${Package}\n' 'nvidia-driver-*' 2>/dev/null |
  awk '/ installed /{print $NF}' | grep -vx "nvidia-driver-$NVIDIA_BRANCH" | tr '\n' ' ')"
[[ -n "$other_branches" ]] && problems+=("unexpected NVIDIA driver installed: $other_branches")

# The kernel GRUB boots by default (GRUB_DEFAULT=0) is the newest one installed.
next_kernel="$(find /boot -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' | sed 's/^vmlinuz-//' | sort -V | tail -1)"
next_module() { modinfo -k "$next_kernel" -F version nvidia 2>/dev/null; }
if [[ -n "$nv_user" && "$(next_module)" != "$nv_user" ]]; then
  log "no NVIDIA $nv_user module for kernel $next_kernel yet, installing it"
  "${APT[@]}" install "linux-modules-nvidia-$NVIDIA_BRANCH-$next_kernel"
fi
nvidia_ready=1
if [[ -n "$nv_user" && "$(next_module)" != "$nv_user" ]]; then
  nvidia_ready=0
  problems+=("kernel $next_kernel has NVIDIA module '$(next_module)' but userspace is $nv_user: not rebooting into it")
fi

# --- reboot ------------------------------------------------------------------
reasons=()
if [[ -f /var/run/reboot-required ]]; then
  reasons+=("$(sort -u /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ' | sed 's/ $//')")
  [[ -z "${reasons[-1]}" ]] && reasons[-1]="reboot-required"
fi
nv_loaded="$(nvidia_loaded_version)"
[[ -n "$nv_user" && -n "$nv_loaded" && "$nv_loaded" != "$nv_user" ]] && reasons+=("NVIDIA $nv_loaded -> $nv_user")
[[ "$(uname -r)" != "$next_kernel" ]] && reasons+=("kernel $(uname -r) -> $next_kernel")
reason="$(IFS=';'; echo "${reasons[*]}")"

if ((${#problems[@]})); then state=failed; else state=ok; fi
finish "$state" "$reason"
((${#problems[@]})) && notify "System update: problems" "$(printf '%s\n' "${problems[@]}")" high

if [[ -n "$reason" ]]; then
  if ((NO_REBOOT || !AUTO_REBOOT)); then
    log "reboot needed but disabled: $reason"
  elif ((!nvidia_ready)); then
    warn "reboot needed but skipped because the NVIDIA module isn't ready: $reason"
  else
    safe_reboot "$reason" && status_set system '{"state": "rebooting"}'
  fi
fi

[[ $state == ok ]]
