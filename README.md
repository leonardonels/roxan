# Roxan Homelab

This repository contains the configuration and reference files for my personal homelab, `roxan`. It is based on an Ubuntu 24.04 LTS server running Docker. The typical deployment location on the server is `/opt/docker/roxan/`.

## Table of Contents
 - [System Specifications](#system-specifications)
 - [Containers](#containers)
   - [Cloudflared](#cloudflared)
   - [Crafty](#crafty)
   - [CUDA](#cuda)
   - [FloraTech](#floratech)
   - [Glance](#glance)
   - [GPU Hot](#gpu-hot)
   - [Immich App](#immich-app)
   - [InvokeAI](#invokeai)
   - [n8n](#n8n)
   - [Nextcloud](#nextcloud)
   - [Ollama](#ollama)
   - [Pi-hole](#pi-hole)
   - [Playit](#playit)
   - [Portainer IO](#portainer-io)
   - [Vaultwarden](#vaultwarden)

## System Specifications

Host: `roxan`

```text
OS:     Ubuntu 24.04.4 LTS x86_64
Host:   ITX-C246
Kernel: 6.8.0-101-generic
CPU:    Intel i3-8350K (4) @ 4.000GHz
GPU 1:  Intel CoffeeLake-S GT2 [UHD Graphics 630]
GPU 2:  NVIDIA GeForce RTX 2080 Ti Rev. A
Memory: 32 GB (31990MiB)
```

## Containers

Below is a brief description of each container/stack managed in this repository, located in the `compose/` directory.

### Cloudflared
Cloudflare Tunnel daemon, providing secure and fast connections to the local network without opening ports on the router.
- **Image**: `cloudflare/cloudflared:latest`

### Crafty
A control panel for managing Minecraft servers, allowing easy deployment and administration.
- **Image**: `registry.gitlab.com/crafty-controller/crafty-4:latest`

### CUDA
Docker environment configured with NVIDIA toolkit for running CUDA workloads, leveraging the RTX 2080 Ti.
- **Image**: Custom (`build: .`)
- **Dockerfile contents**: Built from `nvidia/cuda:12.8.0-devel-ubuntu24.04`, installed with Python 3, PyTorch with GPU-optimized packages, OpenMPI, and general development tools. Sets `utf-8` locale explicitly.

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
- **Image**: `ghcr.io/invoke-ai/invokeai:latest`

### n8n
An extendable workflow automation tool for connecting different services and APIs.
- **Image**: `docker.n8n.io/n8nio/n8n`

### Nextcloud
A self-hosted productivity platform for file storage, sharing, and collaboration.
- **Image**: `ghcr.io/nextcloud-releases/all-in-one:latest`

### Ollama
A tool to run, manage, and interact with large language models locally.
- **Image**: `ollama/ollama`

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
