#!/usr/bin/env bash
# SLURM GPU search job for FoldDisco (per single percent threshold)
# Log files (mirroring folddisco.sh pattern)
#SBATCH --output=/p/project/hai_1072/reimt/logs/%j/%u_%x.out
#SBATCH --error=/p/project/hai_1072/reimt/logs/%j/%u_%x.err
# This script is intended to be submitted via sbatch. Example:
#   sbatch -J fd_search_20 -p dc-hwai --gres=gpu:1 -t 12:00:00 \
#     folddisco_search_job.sh \
#       --percent 20 \
#       --ids /path/ids.txt \
#       --scores /path/conservation_pred.txt \
#       --pdb-dir /path/pdb \
#       --index /path/index_scop40 \
#       --output-base /path/folddisco \
#       --lookup /path/scop_lookup.fix.tsv (optional; just stored for provenance)
#
# Required arguments:
#   --percent N              Percentage (integer or float) of top residues
#   --ids FILE               IDs file (FASTA-like headers >ID)
#   --scores FILE            Conservation scores file
#   --pdb-dir DIR            Directory containing PDB files
#   --index PATH             FoldDisco index path (directory or index file)
#   --output-base DIR        Base directory under which input/, out/ etc. are managed
# Optional:
#   --env-mamba DIR          MAMBA_ROOT_PREFIX (default from existing folddisco.sh)
#   --conda-env NAME         Conda env name (default hiwi)
#   --venv-dir DIR           Python venv to overlay (default torch_gpu_pip under repo)
#   --skip-existing          Skip FoldDisco run if motif directory already populated
#   --archive                Create a tar.gz of motif directory after run (retain dir)
#   --verbose                More logging
#   --help                   Show help
#
# Outputs:
#   input/folddisco_in_<percent>.txt          (manifest)
#   out/<percent>/..._motif.out               (FoldDisco motif outputs)
#   out/<percent>_motifs.tar.gz (if --archive)
#   logs in Slurm output / error files

set -euo pipefail

percent=""; ids=""; scores=""; pdb_dir=""; index=""; output_base=""; verbose=0
# Default conda/Mamba root (will auto-detect if alternative path exists)
mamba_root="/p/project1/hai_1072/reimt/conda/miniforge3"
conda_env="hiwi"
venv_dir="/p/project/hai_1072/reimt/hiwi/PGP/venvs/torch_gpu_pip"
skip_existing=0
archive=0

# Original script directory may be lost after sbatch copies to spool; allow override
scripts_root=""

print_help(){ sed -n '1,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --percent) percent=$2; shift 2;;
    --ids) ids=$2; shift 2;;
    --scores) scores=$2; shift 2;;
    --pdb-dir) pdb_dir=$2; shift 2;;
    --index) index=$2; shift 2;;
    --output-base) output_base=$2; shift 2;;
    --env-mamba) mamba_root=$2; shift 2;;
    --conda-env) conda_env=$2; shift 2;;
    --venv-dir) venv_dir=$2; shift 2;;
  --scripts-root) scripts_root=$2; shift 2;;
    --skip-existing) skip_existing=1; shift;;
    --archive) archive=1; shift;;
    --verbose) verbose=1; shift;;
    --help|-h) print_help; exit 0;;
    *) echo "[ERROR] Unknown arg: $1" >&2; exit 2;;
  esac
done

[[ -z $percent || -z $ids || -z $scores || -z $pdb_dir || -z $index || -z $output_base ]] && { echo "[ERROR] Missing required args" >&2; exit 2; }

echo "[INFO] FoldDisco search job starting (percent=$percent job=$SLURM_JOB_ID host=$HOSTNAME)" >&2

# Attempt project accounting environment (cluster specific; harmless if absent)
jutil env activate -p hai_1072 >/dev/null 2>&1 || echo "[WARN] jutil env activate skipped" >&2

# Auto-detect alternate conda root if the configured one is missing and a sibling exists
if [[ ! -d "$mamba_root" ]]; then
  for alt in /p/project/hai_1072/reimt/conda/miniforge3; do
    if [[ -d "$alt" ]]; then
      echo "[INFO] Switching Mamba root to detected path: $alt" >&2
      mamba_root="$alt"; break
    fi
  done
fi

# If SLURM_SUBMIT_DIR is set, move there to make relative paths predictable (non-fatal if cd fails)
if [[ -n "${SLURM_SUBMIT_DIR:-}" ]]; then
  cd "$SLURM_SUBMIT_DIR" 2>/dev/null || echo "[WARN] Could not cd to SLURM_SUBMIT_DIR=$SLURM_SUBMIT_DIR" >&2
fi

# Activate conda + venv
export MAMBA_ROOT_PREFIX="$mamba_root"
export CONDARC="${MAMBA_ROOT_PREFIX%/}/condarc"
if [[ -f "$MAMBA_ROOT_PREFIX/etc/profile.d/conda.sh" ]]; then
  # shellcheck source=/dev/null
  source "$MAMBA_ROOT_PREFIX/etc/profile.d/conda.sh"
  # Show available envs for debugging (ignore failure)
  (conda info --envs || true) >&2
  set +e
  conda activate "$conda_env" 2>/dev/null
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    # Fallback: try absolute path activation if directory exists
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
else
  echo "[WARN] conda.sh not found at $MAMBA_ROOT_PREFIX (skipping conda activation)" >&2
fi
if [[ -d "$venv_dir" ]]; then
  # shellcheck source=/dev/null
  source "$venv_dir/bin/activate"
else
  echo "[ERROR] venv dir not found: $venv_dir" >&2; exit 3
fi

which python || true
which folddisco || { echo "[ERROR] folddisco binary not in PATH" >&2; exit 4; }

base_out="$output_base"
input_dir="$base_out/input"
motif_out_dir="$base_out/out"
mkdir -p "$input_dir" "$motif_out_dir"

manifest="$input_dir/folddisco_in_${percent}.txt"

# Fixed scripts root (absolute) to avoid Slurm spool relocation issues
SCRIPTS_ROOT="/p/project/hai_1072/reimt/hiwi/PGP/scripts/folddisco_pipeline"
gen_script="$SCRIPTS_ROOT/generate_folddisco_input.py"
if [[ ! -f $gen_script ]]; then
  echo "[ERROR] Expected generator script missing at $gen_script (adjust SCRIPTS_ROOT if moved)" >&2
  exit 7
fi
echo "[INFO] Using generator script: $gen_script" >&2

if [[ $skip_existing -eq 1 && -d "$motif_out_dir/$percent" && -n $(ls -1 "$motif_out_dir/$percent" 2>/dev/null | head -n1) ]]; then
  echo "[SKIP] Existing motif directory with files: $motif_out_dir/$percent" >&2
else
  echo "[STEP] Generating manifest: $manifest" >&2
  python "$gen_script" \
    --ids "$ids" \
    --scores "$scores" \
    --pdb-dir "$pdb_dir" \
    --percent "$percent" \
    --out "$manifest" \
    --with-output-path \
    --output-dir "$motif_out_dir" \
    --min-residues 1 \
    ${verbose:+--verbose}

  if [[ ! -s "$manifest" ]]; then
    echo "[ERROR] Manifest empty or missing: $manifest" >&2; exit 5
  fi

  echo "[STEP] Running FoldDisco query" >&2
  start_ts=$(date +%s)
  folddisco query -i "$index" -q "$manifest" --skip-match || { echo "[ERROR] FoldDisco query failed" >&2; exit 6; }
  end_ts=$(date +%s)
  echo "[INFO] FoldDisco runtime: $((end_ts-start_ts)) s" >&2
fi

if [[ $archive -eq 1 ]]; then
  echo "[STEP] Archiving motif outputs" >&2
  ( cd "$motif_out_dir" && tar czf "${percent}_motifs.tar.gz" "$percent" )
  ls -lh "$motif_out_dir/${percent}_motifs.tar.gz" >&2 || true
fi

echo "[DONE] Search job complete (percent=$percent)" >&2
