#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# CUDA PyTorch Environment Setup with Fallback (conda -> venv)
# -----------------------------------------------------------------------------
# This script attempts to create / use a conda environment first. If conda
# channel access (conda-forge) is blocked (network errors), it falls back to a
# self-contained Python venv in ./venvs/${ENV_NAME}. It then installs the
# CUDA-enabled PyTorch wheels from the specified index and verifies GPU usage.
# -----------------------------------------------------------------------------

# Configuration (override via env vars or CLI flags)
ENV_NAME=${ENV_NAME:-torch_gpu_pip}
PYTHON_VERSION=${PYTHON_VERSION:-3.10}
INDEX_URL=${INDEX_URL:-https://download.pytorch.org/whl/cu121}
MAMBA_ROOT=${MAMBA_ROOT:-/p/project1/hai_1072/reimt/conda/miniforge3}
VENV_DIR=${VENV_DIR:-"$(pwd)/venvs/${ENV_NAME}"}
FORCE_REINSTALL=0
ONLY_VERIFY=0
SKIP_CONDA=0

usage() {
  cat <<EOF
Usage: $0 [options]
Options:
  --force              Reinstall torch stack even if already present.
  --only-verify        Do not (re)install, just verify CUDA availability.
  --skip-conda         Skip attempting conda env creation; go straight to venv.
  --index-url URL      Override PyTorch wheel index (default: ${INDEX_URL}).
  --env-name NAME      Set environment / venv name (default: ${ENV_NAME}).
  --python VERSION     Python version for conda path (default: ${PYTHON_VERSION}).
  -h|--help            Show this help.
Environment variables may also be used to override: ENV_NAME, INDEX_URL, PYTHON_VERSION, MAMBA_ROOT, VENV_DIR.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE_REINSTALL=1; shift ;;
    --only-verify) ONLY_VERIFY=1; shift ;;
    --skip-conda) SKIP_CONDA=1; shift ;;
    --index-url) INDEX_URL="$2"; shift 2 ;;
    --env-name) ENV_NAME="$2"; VENV_DIR="$(pwd)/venvs/${ENV_NAME}"; shift 2 ;;
    --python) PYTHON_VERSION="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[ERROR] Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

say() { echo "[INFO] $*" >&2; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERROR] $*" >&2; }

have_conda=0
if [[ -f "${MAMBA_ROOT}/etc/profile.d/conda.sh" ]]; then
  # shellcheck source=/dev/null
  source "${MAMBA_ROOT}/etc/profile.d/conda.sh" || true
  if command -v conda >/dev/null 2>&1; then
    have_conda=1
  fi
fi

activated_method=""

try_activate_conda_env() {
  if (( have_conda )) && conda env list | grep -q "^${ENV_NAME} "; then
    say "Activating existing conda env ${ENV_NAME}"
    conda activate "${ENV_NAME}"
    activated_method="conda"
    return 0
  fi
  return 1
}

create_conda_env() {
  say "Creating conda env ${ENV_NAME} (Python ${PYTHON_VERSION})"
  if ! mamba env create -f env_gpu_pip.yaml; then
    warn "Conda env creation failed (likely network)."
    return 1
  fi
  return 0
}

create_or_use_venv() {
  if [[ -d "${VENV_DIR}" ]]; then
    say "Using existing venv ${VENV_DIR}"
  else
    say "Creating venv ${VENV_DIR}"
    mkdir -p "$(dirname "${VENV_DIR}")"
    # Prefer conda base python if available; else system python
    if command -v python3 >/dev/null 2>&1; then
      python3 -m venv "${VENV_DIR}"
    else
      err "python3 not found for venv creation"; return 2
    fi
  fi
  # shellcheck source=/dev/null
  source "${VENV_DIR}/bin/activate"
  activated_method="venv"
}

ensure_environment() {
  if (( ONLY_VERIFY )); then
    if ! try_activate_conda_env; then
      if [[ -d "${VENV_DIR}" ]]; then
        create_or_use_venv || return 1
      else
        err "No environment to verify (missing conda env and venv)."; return 2
      fi
    fi
    return 0
  fi

  if (( SKIP_CONDA )); then
    say "Skipping conda per user request; using venv fallback."
    create_or_use_venv || return 1
    return 0
  fi

  # Attempt conda path
  if try_activate_conda_env; then
    return 0
  fi
  if (( have_conda )); then
    if create_conda_env; then
      conda activate "${ENV_NAME}" || true
      activated_method="conda"
      return 0
    else
      warn "Falling back to venv after conda failure."
    fi
  else
    warn "Conda not available; using venv fallback."
  fi
  create_or_use_venv || return 1
}

install_torch_stack() {
  # Always upgrade pip first for better wheel resolution.
  python - <<'EOF'
import sys
print('[VERIFY] Python executable:', sys.executable)
print('[VERIFY] Python version:', sys.version.split()[0])
EOF
  pip install --upgrade pip wheel setuptools
  if (( FORCE_REINSTALL )); then
    say "Force reinstall: removing existing torch packages if present."
    pip uninstall -y torch torchvision torchaudio || true
  fi

  if python -c 'import torch' 2>/dev/null && (( FORCE_REINSTALL == 0 )); then
    say "torch already importable; will still attempt upgrade to CUDA wheel." >&2
  fi

  say "Installing torch stack from ${INDEX_URL}"
  # Use --extra-index-url in case default index is needed for deps when in venv.
  pip install --no-cache-dir --upgrade \
    torch torchvision torchaudio \
    --index-url "${INDEX_URL}" || {
      err "Primary install attempt failed; retrying with extra-index fallback."
      pip install --no-cache-dir --upgrade torch torchvision torchaudio \
        --extra-index-url "${INDEX_URL}" || {
          err "Failed to install torch stack."; return 3; }
    }
}

verify_cuda() {
  python - <<'EOF'
import sys, torch, json
print('[VERIFY] torch.__version__ =', torch.__version__)
print('[VERIFY] torch.version.cuda =', torch.version.cuda)
print('[VERIFY] torch.cuda.is_available() =', torch.cuda.is_available())
if not torch.cuda.is_available():
    print('[DIAG] CUDA not available. Potential causes:')
    print('  - Running on a login node without GPUs (needs srun interactive).')
    print('  - Missing driver / incompatible CUDA capability on node.')
    print('  - CPU-only wheel resolved (network filtering of CUDA index).')
    sys.exit(2)
print('[VERIFY] Device count =', torch.cuda.device_count())
print('[VERIFY] First device =', torch.cuda.get_device_name(0))
x = torch.randn(512,512, device='cuda') @ torch.randn(512,512, device='cuda')
print('[VERIFY] Matmul OK; mean=', float(x.mean()))
EOF
}

main() {
  ensure_environment
  if (( ONLY_VERIFY )); then
    say "Verification-only mode."
    verify_cuda && { say "Verification complete."; exit 0; }
    err "Verification failed."; exit 2
  fi
  install_torch_stack
  verify_cuda
  say "SUCCESS: CUDA-enabled PyTorch environment ready (${ENV_NAME}; method=${activated_method})."
}

main "$@"
