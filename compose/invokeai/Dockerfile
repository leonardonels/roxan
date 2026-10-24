# The official image ships PyTorch built for CUDA 12.8, which dropped Pascal (sm_61, the
# GTX 1080 Ti). Reinstall the same torch/torchvision versions the image pins, from PyTorch's
# cu126 index, whose builds still include Pascal. Rebuilt weekly by scripts/docker-update.sh
# (DOCKER_REBUILD), so it follows new InvokeAI releases.
FROM ghcr.io/invoke-ai/invokeai:latest

RUN set -eu; \
    py=/opt/venv/bin/python; \
    torch="$($py -c 'import importlib.metadata as m; print(m.version("torch").split("+")[0])')"; \
    vision="$($py -c 'import importlib.metadata as m; print(m.version("torchvision").split("+")[0])')"; \
    echo "reinstalling torch==$torch torchvision==$vision from cu126"; \
    uv pip install --python "$py" --no-cache --reinstall-package torch --reinstall-package torchvision \
      "torch==$torch" "torchvision==$vision" --index-url https://download.pytorch.org/whl/cu126; \
    $py -c 'import torch; archs = torch._C._cuda_getArchFlags().split(); print(torch.__version__, archs); assert "sm_60" in archs or "sm_61" in archs, "no Pascal kernels"'
