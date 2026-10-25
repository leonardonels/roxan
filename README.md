# Roxan: a home server you can leave alone

A small home server (Ubuntu 24.04 + Docker Compose) set up to run unattended for months: it updates
itself, rolls back updates that break things, repairs the usual failures on its own, and needs no
ports opened on the router. This repository is the complete, working setup of my server `roxan`, shared as
a template: take the parts you need, adapt the rest.

## What's worth copying

- **Unattended maintenance ([`scripts/`](scripts/README.md))**, independent of which services you run:
  - weekly OS update that reboots only when needed and only into a kernel with a working GPU driver,
    while pinning the NVIDIA driver branch
  - weekly update of every running compose project: pull everything first, recreate only what
    changed, **roll back** anything that doesn't come back healthy or loses the GPU
  - a healthcheck every 5 minutes that restarts unhealthy containers, a hung Docker daemon or a dead
    network, and survives the DNS server (Pi-hole) being down
  - results in a [Glance](#glance) dashboard banner, optionally pushed to your phone (ntfy/Telegram)
- **No ports opened on the router**: web services are published through a Cloudflare Tunnel (the
  Minecraft server through playit), and the host itself is reached over Tailscale. On top of that,
  [Cloudflare Access](#cloudflared) puts a login in front of every web service that has no reason to
  be public. Secrets live in gitignored `.env` files.
- **One folder per service**: `compose/<service>/` holds the compose file (and Dockerfile if any),
  `data/<service>/` its persistent data. Each one starts with `docker compose up -d`.
- **Problems documented in the open**: [`TODO-FIX.md`](TODO-FIX.md) lists what's still broken and how
  it was diagnosed.

## Using it for your own server

1. Prepare Ubuntu, Docker and the NVIDIA toolkit as in [Initial Server Setup](#initial-server-setup-from-scratch).
2. Clone to `/opt/docker/roxan`. The compose files use that absolute path; if you clone elsewhere,
   search-and-replace it.
3. Keep only the services you want from `compose/`. Services with an `.env.example` need a `.env`
   (`cp .env.example .env`, then fill it in).
4. Review [`scripts/roxan.conf`](scripts/roxan.conf): it is tuned for this box (Pi-hole address,
   NVIDIA 580 branch for a Pascal GPU, disks, cooler). Then `sudo ./scripts/install.sh` and reboot.

The hardware-specific parts (the NVIDIA driver pin, the Corsair cooler and EVGA GPU lighting) are
optional: leave out what doesn't match your machine.

## Table of Contents
 - [System Specifications](#system-specifications)
 - [Initial Server Setup from scratch](#initial-server-setup-from-scratch)
 - [Quick deployment guide](#quick-deployment-guide)
 - [Maintenance (auto-updates & keep-alive)](#maintenance)
 - [Containers](#containers)
   - [Cloudflared](#cloudflared)
   - [Crafty - Minecraft](#crafty)
   - [CUDA AI LAB](#cuda)
   - [FloraTech - Django Self Hosting](#floratech)
   - [Glance](#glance)
   - [GPU Hot](#gpu-hot)
   - [Immich App](#immich-app)
   - [InvokeAI](#invokeai)
   - [n8n](#n8n)
   - [Nextcloud](#nextcloud)
   - [Ollama - Nextcloud helper service](#ollama)
   - [OpenLinkHub - Corsair cooler](#openlinkhub)
   - [OpenRGB - GPU lighting](#openrgb)
   - [Pi-hole](#pi-hole)
   - [Playit - Minecraft Tunnel](#playit)
   - [Portainer IO](#portainer-io)
   - [Vaultwarden](#vaultwarden)
   - [SAM3](#sam3-test-container)

## System Specifications

Host: `roxan`

```text
OS:     Ubuntu 24.04.4 LTS x86_64
Host:   ITX-C246
Kernel: 6.8.0-147-generic
CPU:    Intel i3-8350K (4) @ 4.000GHz
GPU 1:  Intel CoffeeLake-S GT2 [UHD Graphics 630]
GPU 2:  NVIDIA GeForce GTX 1080 Ti (EVGA FTW3, Pascal)
Cooler: Corsair iCUE LINK H100i (240 mm AIO)
Memory: 32 GB (31990MiB)
```

### Initial Server Setup (From Scratch)

If you are setting up `roxan` on a fresh machine, follow these steps before deploying any containers:

1. **Install OS:** Install **Ubuntu 24.04 LTS** on the host machine.
2. **Update System:** 
   ```bash
   sudo apt update && sudo apt dist-upgrade -y
   ```
3. **Install Docker (Official Guide) & Dependencies:**
   ```bash
   # Add Docker's official GPG key:
   sudo apt-get update
   sudo apt-get install -y ca-certificates curl git build-essential
   sudo install -m 0755 -d /etc/apt/keyrings
   sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
   sudo chmod a+r /etc/apt/keyrings/docker.asc

   # Add the repository to Apt sources:
   echo \
     "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
     $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
     sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
   sudo apt-get update

   # Install Docker packages:
   sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

   # Post-installation steps for Linux (manage Docker as a non-root user)
   sudo usermod -aG docker $USER
   ```
   *(Log out and log back in for the Docker group changes to take effect).*
4. **Install NVIDIA Drivers & Container Toolkit:**
   ```bash
   # Install the appropriate NVIDIA driver (ubuntu-drivers will auto-install the recommended one)
   sudo apt install -y ubuntu-drivers-common
   sudo ubuntu-drivers autoinstall

   # Add the NVIDIA Container Toolkit repository
   curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
   curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
     sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
     sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

   sudo apt-get update
   sudo apt-get install -y nvidia-container-toolkit

   # Configure Docker to use the NVIDIA runtime
   sudo nvidia-ctk runtime configure --runtime=docker
   sudo systemctl restart docker
   ```
   *(A system reboot may be required after installing the NVIDIA driver).*
5. **Install Tailscale (VPN):**
   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   sudo tailscale up
   ```
6. **Prepare the Directory Structure:**
   ```bash
   sudo mkdir -p /opt/docker
   sudo chown -R $USER:$USER /opt/docker
   cd /opt/docker
   ```
7. **Clone the Repository:**
   ```bash
   git clone https://github.com/leonardonels/roxan.git
   cd roxan
   ```
8. **Install the maintenance timers** (auto-updates, keep-alive, NVIDIA 580 pin), see [Maintenance](#maintenance):
   ```bash
   sudo ./scripts/install.sh
   ```

### Quick Deployment Guide
To deploy any of the containers listed below, navigate to its respective directory inside the `compose/` folder and run Docker Compose.

For example, to start Pi-hole:
```bash
cd compose/pi-hole
docker compose up -d
```
*Note: Some containers may require `.env` files, specific directory structures in the `data/` folder, or initial configuration adjustments before they can start successfully.*

## Maintenance
`scripts/` keeps the server alive and up to date unattended, with status shown in Glance:
- **System update** (Sun 03:30): `apt full-upgrade` with the NVIDIA driver pinned to the 580 branch (last one with Pascal support), reboot when needed.
- **Docker update** (Sun 05:00): pulls and recreates every running compose project, with automatic rollback when a project doesn't come back healthy.
- **Healthcheck** (every 5 min): restarts unhealthy containers, a hung docker daemon, tailscale, networking; cleans up when the disk fills.

See [scripts/README.md](scripts/README.md) for the details.

## Containers
Below is a brief description of each container/stack managed in this repository, located in the `compose/` directory.

### Cloudflared
Cloudflare Tunnel daemon, providing secure and fast connections to the local network without opening ports on the router.
- **Image**: `cloudflare/cloudflared:latest`
- **Routes**: configured in the Cloudflare Zero Trust dashboard (token-based tunnel), one public hostname per service.
- **Cloudflare Access**: every hostname is behind an Access login (Cloudflare checks who you are before
  the request ever reaches the server), with deliberate exceptions:
  - **Nextcloud, Immich, Vaultwarden**: their mobile/desktop apps sync in the background and can't
    pass an Access login, so they rely on their own authentication. Keep them updated and use strong
    passwords + 2FA in the apps themselves.
  - **FloraTech**: a public university demo project, meant to be open.
  - **Glance, GPU Hot, Scrutiny**: read-only dashboards with nothing to log into and no actions to
    trigger, so there is nothing to protect.
  Everything that can change something (Portainer, Pi-hole, n8n, Crafty, InvokeAI, ...) must stay
  behind Access.

### Crafty
A control panel for managing Minecraft servers, allowing easy deployment and administration.
- **Image**: `registry.gitlab.com/crafty-controller/crafty-4:latest`

### CUDA
Docker environment configured with NVIDIA toolkit for running CUDA workloads, leveraging the RTX 2080 Ti.
- **Image**: Custom (`build: .`)
- **Dockerfile contents**: Built from `nvidia/cuda:12.8.0-devel-ubuntu24.04`, installed with Python 3, PyTorch from the cu126 index (keeps Pascal/GTX 1080 Ti support), OpenMPI, and general development tools. Sets `utf-8` locale explicitly.

### FloraTech
Custom project or service.
- **Image**: Custom (`build: .`)
- **Dockerfile contents**: Built from `python:3.11-slim`, this image clones the `leonardonels/floratech` repository directly, installs Django, Daphne, pandas, numpy, scikit-learn, joblib, requests, and pyTelegramBotAPI, and then collects static files.

### Glance
A self-hosted dashboard that aggregates feeds and widgets in one place.
- **Image**: `glanceapp/glance`

### GPU Hot
A tool or dashboard for monitoring GPU temperatures, metrics, and usage.
- **Image**: Custom (`build: .`)
- **Dockerfile contents**: Built from `nvidia/cuda:12.2.2-runtime-ubuntu22.04`, configured with Python 3 and runs `app.py`. Installed with the `requirements.txt` included in the container with an HTTP health check mapped to port 1312.

### Immich App
A very fast, self-hosted photo and video backup solution directly from your mobile phone.
- **Images**: 
  - `ghcr.io/immich-app/immich-server:${IMMICH_VERSION:-release}`
  - `ghcr.io/immich-app/immich-machine-learning:${IMMICH_VERSION:-release}`
  - `valkey:8` (and `postgres:14`)

### InvokeAI
A powerful creative engine for Stable Diffusion models, providing a UI for AI image generation.
- **Image**: Custom (`build: .`)
- **Dockerfile contents**: `ghcr.io/invoke-ai/invokeai:v6.14.2-cuda` (pinned: `latest` follows the main branch and its alphas) with its torch/torchvision reinstalled from PyTorch's cu126 index (same versions), since the official CUDA 12.8 build doesn't support the Pascal GTX 1080 Ti. Rebuilt by the weekly docker update; bump the tag in the Dockerfile for a new release.

### n8n
An extendable workflow automation tool for connecting different services and APIs.
- **Image**: `docker.n8n.io/n8nio/n8n`

### Nextcloud
A self-hosted productivity platform for file storage, sharing, and collaboration.
- **Image**: `ghcr.io/nextcloud-releases/all-in-one:latest`

### Ollama
A tool to run, manage, and interact with large language models locally.
- **Image**: `ollama/ollama`

### OpenLinkHub
Open-source iCUE replacement driving the Corsair iCUE LINK H100i (pump + 2× QX RGB fans) through the iCUE LINK System Hub: LEDs, speed profiles (all channels on `Quiet`), live RPM/temperature readout. Web UI and API on port `27003` (no authentication, LAN/Tailscale only); the Glance "Cooler" widget and `scripts/healthcheck.sh` read it. Tested 2026-10-24: on a clean stop (`docker stop`, shutdown) the hub immediately falls back to its built-in out-of-the-box mode (speeds and LEDs); after a crash (`kill -9`) its LEDs freeze and it falls back on its own after a short timeout. Cooling never depends on the container.
- **Image**: Custom (`build:` from the upstream repo, pinned to release `0.9.2`)

### OpenRGB
Sets the EVGA GTX 1080 Ti FTW3 LEDs (Nameplate + Backplate zones, static colour or off; the three iCX GPU/MEM/PWR status LEDs aren't controllable) at every start and every 6 h, since the card can't store a colour. Colours are set per zone by `COLORS` in the compose file (`000000` = off; OpenRGB's "Off" mode does nothing on this card). Runs without network, may open only I2C devices, and `data/openrgb/OpenRGB.json` enables only the FTW3 detector, so it never touches the Corsair hub.
- **Image**: Custom (`build: .`): official OpenRGB 1.0 Debian packages (checksum-pinned) on `debian:bookworm-slim`

### Pi-hole
A network-wide DNS sinkhole that protects devices from unwanted content and tracks without installing any client-side software.
- **Image**: `pihole/pihole:latest`

### Playit
Global proxy tool allowing you to host servers without port forwarding.
- **Image**: `ghcr.io/playit-cloud/playit-agent:latest`

### Portainer IO
A lightweight management UI to easily manage Docker environments, containers, networks, and volumes.
- **Image**: `portainer/portainer-ce:lts`

### Vaultwarden
An unofficial Bitwarden compatible server written in Rust, perfect for self-hosting a password manager.
- **Image**: `vaultwarden/server:latest`

### SAM3 Test Container
A fast and easy container to test Meta's SAM3 AI Model
- **Image**: Custom (`build: .`)
- **Dockerfile contents**: Built from `pytorch/pytorch:2.7.0-cuda12.6-cudnn9-devel` with requirements from the offical SAM3 repo.
