#!/usr/bin/env bash
# Update every running compose project under compose/:
#   1. pull new images for all projects first (the host resolves DNS through pi-hole, so
#      nothing may be recreated before every download is done),
#   2. recreate only the projects whose images changed and wait for them to be healthy; GPU
#      containers must also pass a CUDA smoke test,
#   3. if a project doesn't come back or fails that test, re-tag the images it was running
#      before and bring it up again (rollback), except for DOCKER_NO_ROLLBACK projects,
#   4. let Nextcloud AIO update itself through its own updater.
# Results go to the journal, to the Glance status file and (optionally) to ntfy/Telegram.
#
# Usage: docker-update.sh [--check | --gpu-test] [project...]
#   --check     only pull and report what would be updated, don't recreate anything
#   --gpu-test  only run the CUDA smoke test on the running GPU projects
#   project     limit the run to these compose/ folders
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/lib.sh"

CHECK=0 GPU_TEST=0
[[ "${1:-}" == "--check" ]] && { CHECK=1; shift; }
[[ "${1:-}" == "--gpu-test" ]] && { GPU_TEST=1; shift; }
ONLY=("$@")

((GPU_TEST)) || maintenance_lock || { warn "another maintenance job is still running"; exit 1; }

updated=() current=() failed=() rolled_back=() skipped=()
declare -A services snapshot
started="$(now_iso)"
start_s=$(date +%s)

((CHECK || GPU_TEST)) || status_set docker "$(jq -nc --arg t "$started" '{state: "running", started: $t}')"

dc() {
  local project="$1"
  shift
  (cd "$COMPOSE_DIR/$project" && docker compose "$@")
}

uses_gpu() {
  dc "$1" config --format json 2>/dev/null | jq -e '
    [.services[] | select(.runtime == "nvidia"
      or ([.deploy.resources.reservations.devices[]?.driver] | index("nvidia")))] | length > 0' >/dev/null
}

# Docker here uses the containerd image store, where an image ID is the manifest digest: every
# rebuild gets a new one even when nothing changed, so compare layers + config instead.
content_key() {
  docker image inspect -f '{{json .RootFS.Layers}} {{json .Config}}' "$1" 2>/dev/null | sha256sum | cut -c1-32
}

# Records "<image ref> <image id>" for every running container of the project, and tags each
# image as roxan-rollback:<project>-<n>. The containerd store deletes an untagged image as soon
# as no container uses it any more, so without this there would be nothing to roll back to.
take_snapshot() {
  local p="$1" ref id n=0
  snapshot[$p]="$(dc "$p" ps -q --status running | xargs -r docker inspect -f '{{.Config.Image}} {{.Image}}' | sort -u)"
  while read -r ref id; do
    [[ -z "$ref" || "$ref" == *@* ]] && continue # digest-pinned refs never move
    # Fails if the running image is already gone, e.g. its tag was rebuilt by hand since.
    docker tag "$id" "roxan-rollback:$p-$((n++))" 2>/dev/null ||
      warn "$p: can't keep the running image of $ref, a rollback won't be possible"
  done <<<"${snapshot[$p]}"
}

# True if any image ref of the project now has different content than what its container runs.
changed() {
  local ref id
  while read -r ref id; do
    [[ "$(content_key "$ref")" != "$(content_key "$id")" ]] && return 0
  done <<<"${snapshot[$1]}"
  return 1
}

# A cached rebuild yields an identical image under a new ID: point the ref back at the image
# that is running, so the duplicate gets pruned and the rollback tag can be dropped.
relink() {
  local ref id
  while read -r ref id; do
    [[ -z "$ref" || "$ref" == *@* ]] && continue
    [[ "$(docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null)" != "$id" ]] && docker tag "$id" "$ref"
  done <<<"${snapshot[$1]}"
}

# CUDA smoke test for the project's GPU containers: a small matmul where PyTorch is installed,
# otherwise `nvidia-smi -L`; containers with neither are not checked. Catches updates that come
# up "healthy" but can't use the GPU, e.g. a PyTorch build without Pascal (sm_61) kernels.
gpu_smoke_test() {
  local p="$1" c name py
  for c in $(dc "$p" ps -q --status running); do
    docker inspect -f '{{.HostConfig.Runtime}} {{json .HostConfig.DeviceRequests}}' "$c" |
      grep -qE '^nvidia |"gpu"' || continue
    name="$(docker inspect -f '{{.Name}}' "$c")" name="${name#/}"
    py="$(docker exec "$c" sh -c 'for p in python3 /opt/venv/bin/python python; do
      command -v "$p" >/dev/null 2>&1 && "$p" -c "import torch" 2>/dev/null && { echo "$p"; exit; }; done' 2>/dev/null)"
    if [[ -n "$py" ]]; then
      if ! timeout 300 docker exec "$c" "$py" -c \
        'import torch; x = torch.randn(256, 256, device="cuda"); assert torch.isfinite(x @ x).all()' >/dev/null 2>&1; then
        warn "$p: CUDA smoke test failed in $name (PyTorch can't run on the GPU)"
        return 1
      fi
      log "   $name: CUDA ok"
    elif docker exec "$c" sh -c 'command -v nvidia-smi' >/dev/null 2>&1; then
      if ! timeout 60 docker exec "$c" nvidia-smi -L >/dev/null 2>&1; then
        warn "$p: nvidia-smi failed in $name"
        return 1
      fi
      log "   $name: nvidia-smi ok"
    fi
  done
}

# One "<status>/<health>/<restart count>" line per container of the given services.
services_state() {
  dc "$1" ps -aq "${@:2}" | xargs -r docker inspect -f \
    '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}/{{.RestartCount}}'
}

# `up --wait` gives up as soon as a container exits, but some restart once on their own and then
# come up fine (Immich after migrating its database): keep polling until the timeout, and only
# accept a state that is running/healthy and unchanged (no new restart) over two polls.
bring_up() {
  local -a svc
  local deadline=$((SECONDS + DOCKER_WAIT_TIMEOUT)) state prev=""
  read -ra svc <<<"${services[$1]}"
  dc "$1" up -d --no-build --wait --wait-timeout "$DOCKER_WAIT_TIMEOUT" "${svc[@]}" && return 0
  ((SECONDS < deadline)) && log "   $1: not up yet, waiting in case it restarts on its own"
  while ((SECONDS < deadline)); do
    sleep 15
    state="$(services_state "$1" "${svc[@]}")"
    if [[ -n "$state" ]] && ! grep -qvE '^running/(healthy|none)/' <<<"$state"; then
      [[ "$state" == "$prev" ]] && return 0
    fi
    prev="$state"
  done
  return 1
}

rollback() {
  local p="$1" ref id n=0
  while read -r ref id; do
    [[ -z "$ref" || "$ref" == *@* ]] && continue
    docker tag "roxan-rollback:$p-$((n++))" "$ref" || return 1
  done <<<"${snapshot[$p]}"
  bring_up "$p"
}

update_nextcloud_aio() {
  local master=nextcloud-aio-mastercontainer before after i aio_errors
  if ! docker ps --format '{{.Names}}' | grep -qx "$master"; then
    skipped+=("$NEXTCLOUD_AIO_PROJECT (not running)")
    return
  fi
  if ! gpu_ok; then
    skipped+=("$NEXTCLOUD_AIO_PROJECT (NVIDIA driver mismatch, reboot pending)")
    return
  fi
  if ((CHECK)); then
    skipped+=("$NEXTCLOUD_AIO_PROJECT (updated by AIO, not checked)")
    return
  fi
  aio_images() { docker ps -q --filter name=nextcloud-aio- | xargs -r docker inspect -f '{{.Name}} {{.Image}}' | sort; }
  aio_docker() { docker exec "$master" docker info >/dev/null 2>&1; }
  # The updater prints PHP fatal errors but still exits 0, so its output is checked too.
  aio_updater() {
    local out rc
    out="$(timeout 3600 docker exec --env AUTOMATIC_UPDATES=1 "$master" /daily-backup.sh 2>&1)"
    rc=$?
    printf '%s\n' "$out"
    grep -q 'Fatal error' <<<"$out" && aio_errors=1
    return "$rc"
  }
  log "== $NEXTCLOUD_AIO_PROJECT: running the AIO updater"
  # The mastercontainer bind-mounts /var/run/docker.sock: when dockerd restarts (a Docker upgrade
  # in system-update.sh) it keeps the old, dead socket until the container itself is restarted.
  if ! aio_docker; then
    log "   $master can't reach Docker (stale socket after a dockerd restart), restarting it"
    docker restart "$master" >/dev/null
    for ((i = 0; i < 40; i++)); do
      aio_docker && break
      sleep 15
    done
    if ! aio_docker; then
      failed+=("$NEXTCLOUD_AIO_PROJECT (mastercontainer can't reach Docker)")
      return
    fi
  fi
  before="$(aio_images)" aio_errors=0
  # Same procedure as the AIO docs: if the mastercontainer updates itself the exec gets cut
  # off; wait for it to come back and run the updater once more for the other containers.
  if ! aio_updater; then
    for ((i = 0; i < 60; i++)); do
      docker ps --format '{{.Names}}' | grep -qx nextcloud-aio-watchtower || break
      sleep 30
    done
    for ((i = 0; i < 60; i++)); do
      docker ps --format '{{.Names}}' | grep -qx "$master" && break
      sleep 30
    done
    aio_errors=0
    aio_updater
  fi
  # The updater doesn't report failures, so check the result ourselves.
  for ((i = 0; i < 40; i++)); do
    [[ "$(docker inspect -f '{{.State.Health.Status}}' nextcloud-aio-apache 2>/dev/null)" == healthy ]] && break
    sleep 15
  done
  after="$(aio_images)"
  if [[ "$(docker inspect -f '{{.State.Health.Status}}' nextcloud-aio-apache 2>/dev/null)" != healthy ]]; then
    failed+=("$NEXTCLOUD_AIO_PROJECT (apache not healthy after AIO update)")
  elif ((aio_errors)); then
    failed+=("$NEXTCLOUD_AIO_PROJECT (AIO updater errors, see journal)")
  elif [[ "$before" != "$after" ]]; then
    updated+=("$NEXTCLOUD_AIO_PROJECT")
  else
    current+=("$NEXTCLOUD_AIO_PROJECT")
  fi
}

# --- discover projects, in update order ---------------------------------------
projects=()
for dir in "$COMPOSE_DIR"/*/; do
  p="$(basename "$dir")"
  compgen -G "$dir*compose.y*ml" >/dev/null || continue
  in_list "$p" "${DOCKER_LAST[@]}" "$NEXTCLOUD_AIO_PROJECT" && continue
  projects+=("$p")
done
for p in "${DOCKER_LAST[@]}"; do [[ -d "$COMPOSE_DIR/$p" ]] && projects+=("$p"); done

if ((GPU_TEST)); then
  rc=0
  for p in "${projects[@]}"; do
    ((${#ONLY[@]})) && ! in_list "$p" "${ONLY[@]}" && continue
    uses_gpu "$p" && [[ -n "$(dc "$p" ps -q --status running 2>/dev/null)" ]] || continue
    log "== $p"
    gpu_smoke_test "$p" || rc=1
  done
  exit "$rc"
fi

gpu_healthy=1
gpu_ok || { gpu_healthy=0; warn "NVIDIA driver/library mismatch: GPU projects will be skipped until the next reboot"; }

# --- phase 1: pull / build ---------------------------------------------------
pending=()
for p in "${projects[@]}"; do
  ((${#ONLY[@]})) && ! in_list "$p" "${ONLY[@]}" && continue
  if in_list "$p" "${DOCKER_SKIP[@]}"; then skipped+=("$p (DOCKER_SKIP)"); continue; fi

  if ! err="$(dc "$p" config -q 2>&1)"; then
    warn "$p: $err"
    failed+=("$p (invalid compose config)")
    continue
  fi
  mapfile -t svc < <(dc "$p" ps --status running --services 2>/dev/null | sed '/^$/d')
  if ((${#svc[@]} == 0)); then skipped+=("$p (not running)"); continue; fi
  if ((!gpu_healthy)) && uses_gpu "$p"; then
    skipped+=("$p (NVIDIA driver mismatch, reboot pending)")
    continue
  fi

  log "== $p: pulling ${svc[*]}"
  services[$p]="${svc[*]}"
  take_snapshot "$p"
  if ! retry 3 dc "$p" pull --quiet --ignore-buildable "${svc[@]}"; then
    failed+=("$p (pull failed)")
    continue
  fi
  if in_list "$p" "${DOCKER_REBUILD[@]}" && ! retry 2 dc "$p" build --pull --quiet "${svc[@]}"; then
    failed+=("$p (build failed)")
    continue
  fi
  if changed "$p"; then
    pending+=("$p")
  else
    relink "$p"
    current+=("$p")
  fi
done

# --- phase 2: recreate what changed ------------------------------------------
for p in "${pending[@]}"; do
  if ((CHECK)); then
    log "== $p: update available"
    updated+=("$p")
    continue
  fi
  log "== $p: recreating"
  if bring_up "$p" && gpu_smoke_test "$p"; then
    updated+=("$p")
    continue
  fi
  dc "$p" ps -a
  dc "$p" logs --no-color --tail 30
  if in_list "$p" "${DOCKER_NO_ROLLBACK[@]}"; then
    warn "$p did not come back healthy or failed the GPU check, NOT rolling back (DOCKER_NO_ROLLBACK)"
    failed+=("$p (unhealthy after update, not rolled back)")
    continue
  fi
  warn "$p did not come back healthy or failed the GPU check, rolling back"
  if rollback "$p" && gpu_smoke_test "$p"; then
    rolled_back+=("$p")
  else
    failed+=("$p (update AND rollback failed)")
  fi
done

if [[ -n "$NEXTCLOUD_AIO_PROJECT" ]] && { ((${#ONLY[@]} == 0)) || in_list "$NEXTCLOUD_AIO_PROJECT" "${ONLY[@]}"; }; then
  update_nextcloud_aio
fi

# --- cleanup and report ------------------------------------------------------
# Untagging only frees the images no container runs any more.
docker images roxan-rollback --format '{{.Repository}}:{{.Tag}}' | xargs -r docker rmi >/dev/null
if ((!CHECK)); then
  docker image prune -f >/dev/null
  docker builder prune -f --filter until=720h >/dev/null
fi

if ((${#failed[@]})); then state=failed
elif ((${#rolled_back[@]})); then state=warning
else state=ok; fi

log ""
if ((CHECK)); then log "available:   ${updated[*]:-none}"; else log "updated:     ${updated[*]:-none}"; fi
log "up to date:  ${current[*]:-none}"
log "rolled back: ${rolled_back[*]:-none}"
log "failed:      ${failed[*]:-none}"
log "skipped:     ${skipped[*]:-none}"

((CHECK)) && exit 0

status_set docker "$(jq -nc \
  --arg state "$state" --arg started "$started" --arg finished "$(now_iso)" \
  --argjson duration $(($(date +%s) - start_s)) \
  --argjson updated "$(json_array "${updated[@]}")" \
  --argjson current "$(json_array "${current[@]}")" \
  --argjson rolled_back "$(json_array "${rolled_back[@]}")" \
  --argjson failed "$(json_array "${failed[@]}")" \
  --argjson skipped "$(json_array "${skipped[@]}")" \
  '{state: $state, started: $started, finished: $finished, duration_s: $duration, updated: $updated,
    current: $current, rolled_back: $rolled_back, failed: $failed, skipped: $skipped}')"

if [[ $state != ok ]]; then
  notify "Docker update: $state" "updated: ${updated[*]:-none}
rolled back: ${rolled_back[*]:-none}
failed: ${failed[*]:-none}" high
elif ((${#updated[@]})); then
  notify "Docker update" "updated: ${updated[*]}" low
fi

[[ $state != failed ]]
