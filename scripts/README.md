# Maintenance scripts

Unattended upkeep for `roxan`: weekly updates of the OS and of every compose project, and a
keep-alive healthcheck every 5 minutes. Status shows up in the **Roxan maintenance** widget at
the top of the Glance home page, and optionally as ntfy/Telegram notifications.

## Install

```bash
sudo ./scripts/install.sh      # safe to re-run after a git pull; --uninstall to remove
sudo reboot                    # loads the new kernel/NVIDIA module and the docker daemon settings
```

Then optionally fill in `scripts/roxan.env` (created from `roxan.env.example`) for notifications.

## Schedule

| Timer | When | Script |
|---|---|---|
| `roxan-system-update.timer` | Sun 03:30 | `system-update.sh` |
| `roxan-docker-update.timer` | Sun 05:00 | `docker-update.sh` |
| `roxan-healthcheck.timer` | every 5 min | `healthcheck.sh` |

All timers are `Persistent`: a run missed while the box was off happens at the next boot. The two
update jobs share a lock, so they never overlap; the healthcheck only observes while they run.

## What each script does

**`system-update.sh`**: `apt full-upgrade`, then reboots when the kernel, libc or NVIDIA driver
changed. The driver stays on the **580 branch**, the last one that supports Pascal:
`etc/apt-preferences-nvidia` makes every package of a newer branch (590, 595, 610, ...)
uninstallable, while 580.x point releases still come in. Before rebooting it checks that the kernel
GRUB will boot has an NVIDIA module matching the installed userspace; if not, it doesn't reboot and
reports the problem. Automatic reboots are limited to one per 20 h. `--no-reboot` to skip the reboot.

**`docker-update.sh`**: for every compose project under `compose/` that has running containers:
pull everything first (the host resolves DNS through pi-hole), then recreate only the projects whose
images changed, with `docker compose up --wait`. GPU containers must then pass a CUDA smoke test
(a small matmul where PyTorch is installed, else `nvidia-smi`), which catches updates that look
"Up" but can't use the GPU, like a PyTorch build without Pascal support. A project that doesn't come
back running/healthy or fails that test is **rolled back** to the images it ran before. pi-hole and cloudflared go last. Nextcloud AIO is
updated through its own updater (`/daily-backup.sh` with `AUTOMATIC_UPDATES=1`). GPU projects are
skipped while the NVIDIA driver/library versions don't match (until the next reboot).

```bash
sudo ./scripts/docker-update.sh --check           # pull and list what would update, change nothing
sudo ./scripts/docker-update.sh immich-app glance # update only these
sudo ./scripts/docker-update.sh --gpu-test         # just run the CUDA smoke test on the GPU projects
```

**`healthcheck.sh`**: restarts docker if the daemon hangs, restarts containers that stay
`unhealthy` (docker never does that itself), restarts tailscaled if it's down, prunes docker caches
when `/` passes 90%, and when the internet is unreachable restarts networking after ~30 min and
reboots after ~3 h.

`install.sh` also sets up, in `etc/`:
- unattended-upgrades keeps doing daily security updates, but no longer touches kernel/NVIDIA
  packages; those wait for the weekly run, which reboots right after. (Upgrading the NVIDIA libraries
  mid-week is what broke NVML with `Driver/library version mismatch`.)
- kernel panic/oops → reboot after 10 s; the hardware watchdog (`iTCO_wdt`) if the board has one,
  so a frozen kernel resets the machine
- GRUB boots on its own after an unclean shutdown instead of waiting at the menu
- journald capped at 1 GB; docker logs rotated (20 MB × 3 per container) and `live-restore`, so
  containers survive a docker daemon upgrade
- DNS that survives Pi-hole being down (it runs on this host, so it's down at every boot until
  its container starts): containers get `DNS_SERVERS` from `roxan.conf` (Pi-hole, then 1.1.1.1)
  via `daemon.json`, and the host stops using Tailscale MagicDNS (`tailscale set --accept-dns=false`)
  so systemd-resolved's list applies: Pi-hole, then 1.1.1.1 / 8.8.8.8

Settings (skip/rebuild lists, thresholds, NVIDIA branch) live in `roxan.conf`.

## Logs

```bash
systemctl list-timers 'roxan-*'
journalctl -u roxan-docker-update -u roxan-system-update -u roxan-healthcheck --since -7d
```

## Before leaving for a long time

- BIOS: set **Restore on AC power loss → Power On**, so the box comes back after a power cut.
- Nextcloud AIO: consider enabling its daily borg backup in the AIO interface.
- Check that the Roxan maintenance widget shows the system update, docker update and healthcheck as `ok`.
