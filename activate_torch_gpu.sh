#!/usr/bin/env bash
# Helper to activate the CUDA PyTorch environment (conda or venv fallback).
# Usage: source activate_torch_gpu.sh
set -euo pipefail
ENV_NAME=${ENV_NAME:-torch_gpu_pip}
MAMBA_ROOT=${MAMBA_ROOT:-/p/project1/hai_1072/reimt/conda/miniforge3}
VENV_DIR=${VENV_DIR:-"$(pwd)/venvs/${ENV_NAME}"}

if [[ -f "${MAMBA_ROOT}/etc/profile.d/conda.sh" ]]; then
  # shellcheck source=/dev/null
  source "${MAMBA_ROOT}/etc/profile.d/conda.sh" || true
  if conda env list | grep -q "^${ENV_NAME} "; then
    conda activate "${ENV_NAME}"
    echo "[INFO] Activated conda env ${ENV_NAME}" >&2
    return 0 2>/dev/null || exit 0
  fi
fi

if [[ -d "${VENV_DIR}" ]]; then
  # shellcheck source=/dev/null
  source "${VENV_DIR}/bin/activate"
  echo "[INFO] Activated venv ${VENV_DIR}" >&2
  return 0 2>/dev/null || exit 0
fi

echo "[ERROR] Neither conda env nor venv for ${ENV_NAME} found. Run ./setup_torch_gpu_env.sh first." >&2
return 1 2>/dev/null || exit 1
