#!/usr/bin/env bash
# SLURM CPU benchmark job for a completed FoldDisco search
# Log files
#SBATCH --output=/p/project/hai_1072/reimt/logs/%j/%u_%x.out
#SBATCH --error=/p/project/hai_1072/reimt/logs/%j/%u_%x.err
# Example submission (dependent on search job id 12345):
#   sbatch --dependency=afterok:12345 folddisco_benchmark_job.sh \
#     --percent 20 \
#     --lookup /path/scop_lookup.fix.tsv \
#     --output-base /path/folddisco
#
# Required:
#   --percent N
#   --lookup FILE
#   --output-base DIR   (same base used for search; expects out/<percent>/ with motif files)
# Optional:
#   --env-mamba DIR
#   --conda-env NAME
#   --venv-dir DIR
#   --keep-intermediate (pass through to benchmark runner)
#   --no-clean (override cleanup; same as --keep-intermediate)
#   --help

set -euo pipefail

percent=""; lookup=""; output_base=""; keep_intermediate=0
# Default root, auto-detect if missing
mamba_root="/p/project1/hai_1072/reimt/conda/miniforge3"; conda_env="hiwi"; venv_dir="/p/project/hai_1072/reimt/hiwi/PGP/venvs/torch_gpu_pip"
scripts_root=""

print_help(){ sed -n '1,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --percent) percent=$2; shift 2;;
    --lookup) lookup=$2; shift 2;;
    --output-base) output_base=$2; shift 2;;
    --env-mamba) mamba_root=$2; shift 2;;
    --conda-env) conda_env=$2; shift 2;;
    --venv-dir) venv_dir=$2; shift 2;;
  --scripts-root) scripts_root=$2; shift 2;;
    --keep-intermediate|--no-clean) keep_intermediate=1; shift;;
    --help|-h) print_help; exit 0;;
    *) echo "[ERROR] Unknown arg: $1" >&2; exit 2;;
  esac
done

[[ -z $percent || -z $lookup || -z $output_base ]] && { echo "[ERROR] Missing required args" >&2; exit 2; }

# Project accounting activation (cluster-specific)
jutil env activate -p hai_1072 >/dev/null 2>&1 || echo "[WARN] jutil env activate skipped" >&2

# Auto-detect alt root
if [[ ! -d "$mamba_root" ]]; then
  for alt in /p/project/hai_1072/reimt/conda/miniforge3; do
    [[ -d "$alt" ]] && { echo "[INFO] Switching Mamba root to detected path: $alt" >&2; mamba_root="$alt"; break; }
  done
fi

export MAMBA_ROOT_PREFIX="$mamba_root"
export CONDARC="${MAMBA_ROOT_PREFIX%/}/condarc"
if [[ -f "$MAMBA_ROOT_PREFIX/etc/profile.d/conda.sh" ]]; then
  # shellcheck source=/dev/null
  source "$MAMBA_ROOT_PREFIX/etc/profile.d/conda.sh"
  (conda info --envs || true) >&2
  set +e
  conda activate "$conda_env" 2>/dev/null
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    if [[ -d "$MAMBA_ROOT_PREFIX/../envs/$conda_env" ]]; then
      echo "[INFO] Retrying activation via full path" >&2
      set +e; conda activate "$MAMBA_ROOT_PREFIX/../envs/$conda_env" 2>/dev/null; rc=$?; set -e
    fi
    if [[ $rc -ne 0 ]]; then
      echo "[WARN] Could not activate conda env '$conda_env' (rc=$rc). Continuing with venv only." >&2
    else
      echo "[INFO] Activated conda env (full path): $conda_env" >&2
    fi
  else
    echo "[INFO] Activated conda env: $conda_env" >&2
  fi
fi

# Normalize working directory to submission directory if available
if [[ -n ${SLURM_SUBMIT_DIR:-} ]]; then
  cd "$SLURM_SUBMIT_DIR" 2>/dev/null || echo "[WARN] Could not cd to SLURM_SUBMIT_DIR=$SLURM_SUBMIT_DIR" >&2
fi
if [[ -d "$venv_dir" ]]; then
  # shellcheck source=/dev/null
  source "$venv_dir/bin/activate"
fi

motif_dir="$output_base/out/${percent}"
out_dir="$output_base/out"
[[ -d "$motif_dir" ]] || { echo "[ERROR] Motif dir missing: $motif_dir" >&2; exit 3; }

echo "[INFO] Benchmarking percent=$percent job=$SLURM_JOB_ID host=$HOSTNAME" >&2
# Fixed scripts root (absolute) to avoid Slurm spool relocation issues
SCRIPTS_ROOT="/p/project/hai_1072/reimt/hiwi/PGP/scripts/folddisco_pipeline"
runner="$SCRIPTS_ROOT/run_folddisco_benchmark.sh"
if [[ ! -f $runner ]]; then
  echo "[ERROR] Expected benchmark runner missing at $runner (adjust SCRIPTS_ROOT if moved)" >&2
  exit 5
fi
echo "[INFO] Using benchmark runner: $runner" >&2
keep_flag=()
[[ $keep_intermediate -eq 1 ]] && keep_flag+=(--keep-intermediate)

"$runner" \
  --motif-dir "$motif_dir" \
  --lookup "$lookup" \
  --out-dir "$out_dir" \
  --label "$percent" \
  "${keep_flag[@]}"

echo "[DONE] Benchmark job complete (percent=$percent)" >&2
