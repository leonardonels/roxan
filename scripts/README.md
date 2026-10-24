# Maintenance scripts

Unattended upkeep for a Docker Compose server: weekly updates of the OS and of every compose
project (with rollback), and a keep-alive healthcheck every 5 minutes. Results show up in a
**Roxan maintenance** banner at the top of the Glance home page and, optionally, as ntfy/Telegram
notifications. Nothing here depends on which services you run: it works on any `compose/<name>/`
folder layout.

## Install

```bash
sudo ./scripts/install.sh      # safe to re-run after a git pull; --uninstall to remove
sudo reboot                    # loads the new kernel/NVIDIA module and the docker daemon settings
```

Review [`roxan.conf`](roxan.conf) first (see [Settings](#settings)), then optionally fill in
`scripts/roxan.env` (created from `roxan.env.example`, gitignored) for notifications.

## Schedule

| Timer | When | Script |
|---|---|---|
| `roxan-system-update.timer` | Sun 03:30 | `system-update.sh` |
| `roxan-docker-update.timer` | Sun 05:00 | `docker-update.sh` |
| `roxan-healthcheck.timer` | every 5 min | `healthcheck.sh` |

All timers are `Persistent`: a run missed while the box was off happens at the next boot. The two
update jobs share a lock, so they never overlap; the healthcheck only observes while they run. The
system update goes first so that, if it reboots, the docker update runs on the fresh kernel and driver.

## What each script does

### `system-update.sh`

`apt full-upgrade`, then reboots when the kernel, libc or NVIDIA driver changed.

- The NVIDIA driver stays on the **580 branch**, the last one that supports Pascal:
  `etc/apt-preferences-nvidia` makes every package of a newer branch (590, 595, 610, ...)
  uninstallable, while 580.x point releases still come in. (Glob patterns, not a regex: a regex there
  slows every apt command by ~10 s.)
- Before rebooting it checks that the kernel GRUB will boot has an NVIDIA module matching the installed
  userspace, installing it if missing; if it still doesn't match, it doesn't reboot and reports why.
- Automatic reboots are limited to one per 20 h (`REBOOT_MIN_INTERVAL_H`), against reboot loops.

`--no-reboot` to skip the reboot.

### `docker-update.sh`

For every compose project under `compose/` that has running containers (stopped projects are left
alone):

1. **Pull everything first.** The host resolves DNS through Pi-hole, a container on this same box, so
   nothing is recreated until every download is done. Pulls are retried 3 times.
2. **Rebuild** the projects in `DOCKER_REBUILD` with `build --pull`, so their base images stay current
   (here: `invokeai`, whose Dockerfile re-installs a Pascal-capable PyTorch on each new release).
   Builds are retried twice.
3. **Recreate only what changed**, with `docker compose up --wait`. Changes are detected by image
   *content* (layers + config), because with the containerd image store every rebuild gets a new ID.
4. **GPU smoke test**: GPU containers must run a small CUDA matmul (or `nvidia-smi` if they have no
   PyTorch). This catches updates that look "Up" but can't use the GPU, like a PyTorch build without
   Pascal support.
5. **Rollback**: a project that doesn't come back running/healthy, or fails the smoke test, goes back
   to the images it ran before. They are kept as `roxan-rollback:<project>-<n>` tags taken before
   pulling (the containerd store deletes an untagged image as soon as no container uses it), and the
   rolled-back project must pass the smoke test again.
6. Pi-hole and cloudflared are updated last. Nextcloud AIO updates itself through its own updater
   (`/daily-backup.sh` with `AUTOMATIC_UPDATES=1`). GPU projects are skipped while the NVIDIA
   driver/library versions don't match (until the next reboot).
7. Dangling images and build cache older than 30 days are pruned.

```bash
sudo ./scripts/docker-update.sh --check           # pull and list what would update, change nothing
sudo ./scripts/docker-update.sh immich-app glance # update only these
sudo ./scripts/docker-update.sh --gpu-test         # just run the CUDA smoke test on the GPU projects
```

Rebuilding an image by hand (`docker compose build`) right before a run leaves nothing to roll back
to, since the old image is already gone; the run warns about it.

### `healthcheck.sh`

Every 5 minutes, fixes the usual ways a headless box dies quietly:

| Problem | Action |
|---|---|
| Docker daemon not responding | restart docker |
| container `unhealthy` for 3 checks (docker never restarts these) | restart it, at most once per hour |
| internet unreachable ~30 min / ~3 h | restart systemd-networkd / reboot |
| Tailscale down | restart tailscaled |
| `/` above 90% | prune docker build cache and dangling images, vacuum the journal |
| AIO pump below 1000 rpm, liquid ≥ 50 °C, or OpenLinkHub not answering | report + urgent notification (at most every 6 h) |
| NVIDIA driver/library mismatch, reboot pending | report (the system update fixes it) |

The cooler check reads the OpenLinkHub API (`COOLER_API`); leave it empty if you have no such cooler.

### `install.sh`

Installs the timers and, from `etc/`:

- unattended-upgrades keeps doing daily security updates, but no longer touches kernel/NVIDIA
  packages; those wait for the weekly run, which reboots right after. (Upgrading the NVIDIA libraries
  mid-week is what broke NVML with `Driver/library version mismatch`.)
- kernel panic/oops → reboot after 10 s; the hardware watchdog (`iTCO_wdt`) if the board has one,
  so a frozen kernel resets the machine
- GRUB boots on its own after an unclean shutdown instead of waiting at the menu
- journald capped at 1 GB; docker logs rotated (20 MB × 3 per container) and `live-restore`, so
  containers survive a docker daemon upgrade
- DNS that survives Pi-hole being down (it runs on this host, so it's down at every boot until
  its container starts): containers get `DNS_SERVERS` (Pi-hole, then 1.1.1.1) via `daemon.json`, and
  the host stops using Tailscale MagicDNS (`tailscale set --accept-dns=false`) so systemd-resolved's
  list applies: Pi-hole, then 1.1.1.1 / 8.8.8.8

## Glance banner and notifications

Each script writes its section of `data/glance/assets/roxan-status.json` (gitignored), which Glance
serves and the **Roxan maintenance** widget in `data/glance/config/glance.yml` renders: docker update
(updated / up to date / rolled back / failed / skipped), system update (kernel, NVIDIA loaded vs
installed, pending reboot, problems, last automatic reboot) and health (issues, uptime, last repair).

With `NTFY_URL` and/or `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` in `roxan.env`, you also get:

| Event | Priority |
|---|---|
| docker update failed or rolled something back | high |
| docker update applied updates | low |
| system update problems | high |
| automatic reboot (with the reason) | default |
| healthcheck repaired something | high |
| cooler problem | urgent |

## Settings

Everything lives in [`roxan.conf`](roxan.conf). The values you will most likely change:

| Setting | What |
|---|---|
| `DNS_SERVERS` | resolvers for containers: your Pi-hole first, a public one after |
| `DOCKER_SKIP` / `DOCKER_REBUILD` / `DOCKER_LAST` | projects never touched / rebuilt weekly / updated last |
| `NEXTCLOUD_AIO_PROJECT` | compose folder of Nextcloud AIO, empty if you don't run it |
| `NVIDIA_BRANCH`, `AUTO_REBOOT`, `REBOOT_MIN_INTERVAL_H` | driver branch to stay on, reboot policy |
| `PING_HOSTS`, `NET_RESTART_AFTER`, `NET_REBOOT_AFTER` | connectivity check and its escalation |
| `DISK_MOUNTS`, `DISK_WARN_PCT` | disks watched for free space |
| `COOLER_API`, `PUMP_MIN_RPM`, `LIQUID_MAX_C` | AIO cooler check, empty `COOLER_API` to disable |

The NVIDIA pin itself (`etc/apt-preferences-nvidia`) hard-codes the 580 branch: edit it together with
`NVIDIA_BRANCH`, or leave both out on a machine without an NVIDIA GPU.

## Logs and testing

```bash
systemctl list-timers 'roxan-*'
journalctl -u roxan-docker-update -u roxan-system-update -u roxan-healthcheck --since -7d
```

The scripts honour `ROXAN_CONF`, `STATE_DIR` and `STATUS_FILE`, so they can be tried without root
and without touching the real state, e.g. `STATE_DIR=/tmp/x STATUS_FILE=/tmp/x/s.json
./scripts/healthcheck.sh`, or a `ROXAN_CONF` that sources `roxan.conf` and points `COMPOSE_DIR` at a
throwaway project (that's how the rollback and smoke test were tested).

## Before leaving for a long time

- BIOS: set **Restore on AC power loss → Power On**, so the box comes back after a power cut.
- Nextcloud AIO: consider enabling its daily borg backup in the AIO interface.
- Fill in `roxan.env`, so problems reach your phone and not only the dashboard.
- Check that the Roxan maintenance widget shows the system update, docker update and health as `ok`.
