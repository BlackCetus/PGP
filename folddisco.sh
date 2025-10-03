#!/bin/bash
# Job metadata
#SBATCH --job-name=run_folddisco20
#SBATCH --account=hai_1072
#SBATCH --partition=dc-hwai
#SBATCH --time=12:00:00
#SBATCH --no-requeue
# Log files
#SBATCH --output=/p/project/hai_1072/reimt/logs/%j/%u_%x.out
#SBATCH --error=/p/project/hai_1072/reimt/logs/%j/%u_%x.err
# GPU specific
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=64G
#SBATCH --gres=gpu:1

set -euo pipefail

# Ensure project accounting / environment variables (quiet if already set)
jutil env activate -p hai_1072 >/dev/null 2>&1 || echo "[WARN] jutil env activate skipped"

# Explicit activation: first conda env 'hiwi', then overlay venv 'torch_gpu_pip'
export MAMBA_ROOT_PREFIX=/p/project1/hai_1072/reimt/conda/miniforge3
export CONDARC=/p/project1/hai_1072/reimt/condarc
source "$MAMBA_ROOT_PREFIX/etc/profile.d/conda.sh"
conda activate hiwi
echo "[INFO] Activated conda env: $CONDA_PREFIX"
which python || true

VENV_DIR=/p/project/hai_1072/reimt/hiwi/PGP/venvs/torch_gpu_pip
if [[ -d "$VENV_DIR" ]]; then
  # shellcheck source=/dev/null
  source "$VENV_DIR/bin/activate"
  echo "[INFO] Overlaid venv: $VIRTUAL_ENV"
else
  echo "[ERROR] CUDA venv not found at $VENV_DIR" >&2
  exit 3
fi

# Load CUDA module if required by site setup (currently commented)
# module load CUDA/12.0 || echo "[WARN] Could not load CUDA/12.0 (adjust if needed)"

python - <<'EOF'
import torch, sys
print('[VERIFY] torch:', torch.__version__, 'cuda:', torch.version.cuda, 'avail:', torch.cuda.is_available())
if not torch.cuda.is_available():
    print('[ERROR] CUDA not available in job allocation', file=sys.stderr)
    sys.exit(2)
print('[VERIFY] device0:', torch.cuda.get_device_name(0))
EOF

nvidia-smi || echo "[WARN] nvidia-smi failed"

start_ts=$(date +%s)
# You can drop srun here since this script itself is the primary step with the GPU allocation.
# Keeping it does no harm for a single task, but remove if you prefer.
folddisco query \
  -i /p/scratch/hai_1072/reimt/data/scop40pdb/folddisco/index/index_scop40 \
  -q /p/scratch/hai_1072/reimt/data/scop40pdb/folddisco/input/folddisco_in_20.txt \
  --skip-match \

end_ts=$(date +%s)

echo "[INFO] Elapsed: $((end_ts - start_ts)) s"