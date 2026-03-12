# NVIDIA CUDA Docker Guide

## Overview
This guide covers the always-on CUDA container managed by Docker Compose for this directory.

Primary setup:
- Service: `ai-lab`
- Container name: `scalable-ai-lab`
- Image: `nvidia/cuda:12.8.0-devel-ubuntu24.04`
- Workspace mount: `/opt/docker/roxan/data/cuda` -> `/workspace`
- Restart policy: `unless-stopped`

## Prerequisites
- Docker installed with NVIDIA Container Toolkit
- GPU drivers installed on host
- Docker daemon configured for GPU access

## Compose-Managed Container (Always On)

The container is expected to be created and kept running by Compose.

### Start or Recreate Service

```bash
docker compose -f /opt/docker/roxan/compose/cuda/docker-compose.yml up -d
```

### Enter the Running Container

```bash
docker compose -f /opt/docker/roxan/compose/cuda/docker-compose.yml exec ai-lab /bin/bash
```

You can also attach directly by container name:

```bash
docker exec -it scalable-ai-lab /bin/bash
```

### Meme test
```bash
pip install cowpy --break-system-packages
python3 -c "from cowpy import cow; msg = cow.milk_random_cow('Scalable AI is easy\!'); print(msg)"
```

### Real test
```bash
mpirun --allow-run-as-root -n 4 python3 -c "import torch; from mpi4py import MPI; print(f'Rank {MPI.COMM_WORLD.Get_rank()} sees GPU: {torch.cuda.is_available()}')"
```

### Check Service Status

```bash
docker compose -f /opt/docker/roxan/compose/cuda/docker-compose.yml ps
docker ps --filter name=scalable-ai-lab
```

## One-Off Alternative (Not Default)

If you need a temporary standalone container instead of the compose-managed one:

```bash
docker run --gpus all -it \
    -v /opt/docker/roxan/data/cuda:/workspace \
    nvidia/cuda:12.8.0-devel-ubuntu24.04 /bin/bash
```

## Key Features
- **CUDA 12.8.0**: Latest development tools and libraries
- **Ubuntu 24.04**: Modern base OS
- **Pre-installed**: nvcc, cuDNN, TensorRT, and development headers
- **Compose service ports**: Jupyter (`8888`) and TensorBoard (`6006`)

## Common Tasks

### Check CUDA Installation
```bash
nvcc --version
nvidia-smi
```

### Compile CUDA Code
```bash
nvcc -o output_binary source.cu
```

### Run Jupyter in the Existing Container
```bash
jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root
```

### Run TensorBoard in the Existing Container
```bash
tensorboard --logdir /workspace --host 0.0.0.0 --port 6006
```

### Use System Libraries
- cuBLAS, cuFFT, cuSPARSE available in `/usr/local/cuda`
- Include paths: `-I/usr/local/cuda/include`
- Library paths: `-L/usr/local/cuda/lib64`

## Tips
- Use `docker compose exec ai-lab /bin/bash` for daily work instead of creating new containers
- Keep projects in `/workspace` for persistence via the bind mount
- GPU access is configured via NVIDIA device reservations and `NVIDIA_VISIBLE_DEVICES=all`
- Install additional packages with `apt-get` as needed
