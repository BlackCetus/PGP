#!/bin/bash
# Job metadata
#SBATCH --job-name=prott5_batch_predict
#SBATCH --account=hai_1072
#SBATCH --partition=dc-hwai
#SBATCH --time=02:00:00
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

# Miniforge (mamba) installation root
export MAMBA_ROOT_PREFIX=/p/project1/hai_1072/reimt/conda/miniforge3
export CONDARC=/p/project1/hai_1072/reimt/condarc

# Source conda shell hook
source "$MAMBA_ROOT_PREFIX/etc/profile.d/conda.sh"
conda activate hiwi

# Load CUDA module if required by your environment (adjust version)
#module load CUDA/12.0 || echo "[WARN] Could not load CUDA/12.0 (adjust if needed)"

echo "[INFO] Environment active: $CONDA_PREFIX"
which python || true
python -c "import torch, sys; print('Python:', sys.version); print('Torch CUDA available:', torch.cuda.is_available())" 2>/dev/null || echo "[INFO] Torch not installed yet"
nvidia-smi || echo "[INFO] nvidia-smi unavailable (no GPU on this node?)"

echo "[INFO] GPU job environment prepared."

python prott5_batch_predictor.py \
  --input /p/scratch/hai_1072/reimt/data/scop40pdb/seqs/scop40.fasta \
  --output /p/scratch/hai_1072/reimt/data/scop40pdb/PGP_out \
  --fmt cons,bind
