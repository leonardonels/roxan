#!/usr/bin/env bash
# Print the full maintenance report: what the Glance widget only counts (which projects were
# updated or failed, upgraded packages, health issues, repairs), then the recent journal.
#
# Usage: report.sh [--json] [journal window, default: -7d]
#   --json  print the raw report file instead
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/lib.sh"

[[ "${1:-}" == "--json" ]] && { jq . "$REPORT_FILE"; exit; }
since="${1:--7d}"

[[ -f "$REPORT_FILE" ]] || { warn "no report yet ($REPORT_FILE)"; exit 1; }

jq -r '
  def list(name; a): if (a // []) | length > 0 then "  \(name): " + ((a // []) | join(", ")) else empty end;
  def when(t): t // "never";
  (.docker // {}) as $d | (.system // {}) as $s | (.health // {}) as $h |
  "DOCKER UPDATES  \($d.state // "never run")  (finished \(when($d.finished)), \($d.duration_s // 0)s)",
  list("updated"; $d.updated), list("up to date"; $d.current), list("rolled back"; $d.rolled_back),
  list("FAILED"; $d.failed), list("skipped"; $d.skipped),
  "",
  "SYSTEM UPDATES  \($s.state // "never run")  (finished \(when($s.finished)))",
  "  kernel \($s.kernel // "?"), NVIDIA installed \($s.nvidia_installed // "?") / loaded \($s.nvidia_loaded // "?")",
  (if ($s.reboot_pending // "") != "" then "  reboot pending: \($s.reboot_pending)" else empty end),
  list("PROBLEMS"; $s.problems), list("upgraded"; $s.upgraded),
  (if .reboot then "  last auto-reboot \(.reboot.at): \(.reboot.reason)" else empty end),
  "",
  "HEALTH  \($h.state // "no data")  (checked \(when($h.checked)), up \($h.uptime // "?"))",
  "  GPU \($h.gpu // "?"), disks " + ([($h.disks // [])[] | "\(.mount) \(.used_pct)%"] | join(", ")),
  (if $h.reboot_required then "  reboot required" else empty end),
  list("ISSUES"; $h.issues),
  (if $h.last_repair then "  last repair \($h.last_repair): " + (($h.last_repair_actions // []) | join("; ")) else empty end)
' "$REPORT_FILE"

echo
echo "== warnings and failures in the journal since $since"
journalctl -u roxan-docker-update -u roxan-system-update -u roxan-healthcheck --since "$since" \
  --no-pager -o short-iso | grep -E 'WARN|FAIL|failed|rolled back|repair' | tail -40
echo
echo "full logs: journalctl -u roxan-docker-update -u roxan-system-update -u roxan-healthcheck --since $since"
