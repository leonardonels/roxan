FROM nvidia/cuda:12.8.0-devel-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install locales and your tools
RUN apt-get update && apt-get install -y \
    locales \
    btop \
    tmux \
    vim \
    git \
    curl \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    libopenmpi-dev \
    openmpi-bin \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Generate the UTF-8 locale
RUN locale-gen en_US.UTF-8

# Set environment variables so every terminal session uses UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Set python3 as the default "python" command
RUN ln -s /usr/bin/python3 /usr/bin/python

# Install AI Libraries (PyTorch) & MPI
# We use the official PyTorch index to get the GPU-optimized version
RUN pip install --no-cache-dir --break-system-packages \
    torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cu124 \
    --extra-index-url https://pypi.org/simple \
    mpi4py

WORKDIR /workspace

# This ensures that when you 'attach', you are in a UTF-8 environment
CMD ["/bin/bash"]
