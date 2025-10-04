#!/usr/bin/env bash
# submit_folddisco_job.sh
# Orchestrate Option B: submit FoldDisco GPU search, then dependent benchmark job.
#
# QUICK CONFIG (edit these for a typical run; CLI flags can still override):
# -----------------------------------------------------------------------
# Percent threshold to run:
CFG_PERCENT=5
# Input files & directories:
CFG_IDS="/p/scratch/hai_1072/reimt/data/scop40pdb/PGP_out/ids.txt"
CFG_SCORES="/p/scratch/hai_1072/reimt/data/scop40pdb/PGP_out/conservation_pred.txt"
CFG_PDB_DIR="/p/scratch/hai_1072/reimt/data/scop40pdb/pdb"
CFG_INDEX="/p/scratch/hai_1072/reimt/data/scop40pdb/folddisco/index/index_scop40"
CFG_OUTPUT_BASE="/p/scratch/hai_1072/reimt/data/scop40pdb/folddisco"   # contains input/ and out/
CFG_LOOKUP="/p/scratch/hai_1072/reimt/data/scop40pdb/scop_lookup.fix.tsv"
# SLURM resources (defaults can be adjusted per site):
CFG_GPU_PARTITION="dc-hwai"
CFG_GPU_TIME="10:00:00"
CFG_CPU_PARTITION="dc-hwai"
CFG_CPU_TIME="2:00:00"
CFG_ACCOUNT="hai_1072"
CFG_GPUS=1
CFG_CPUS_GPU=4
CFG_MEM_GPU="64G"
CFG_CPUS_CPU=2
CFG_MEM_CPU="16G"
# Behavior toggles:
CFG_ARCHIVE=1              # 1=tar.gz motif dir after search
CFG_KEEP_INTERMEDIATE=0    # 1=keep benchmark intermediate files
CFG_JOB_PREFIX="fd"        # Job name prefix
# Run log (records resolved configuration & job IDs):
CFG_RUN_LOG="${CFG_OUTPUT_BASE}/run_submissions.log"
# -----------------------------------------------------------------------
# NOTE: To change just the percent, edit CFG_PERCENT above and re-run.
# CLI flags still override any CFG_* values; see --help for details.

set -euo pipefail

percent="$CFG_PERCENT"; ids="$CFG_IDS"; scores="$CFG_SCORES"; pdb_dir="$CFG_PDB_DIR"; index="$CFG_INDEX"; output_base="$CFG_OUTPUT_BASE"; lookup="$CFG_LOOKUP";
gpu_partition="$CFG_GPU_PARTITION"; gpu_time="$CFG_GPU_TIME"; cpu_partition="$CFG_CPU_PARTITION"; cpu_time="$CFG_CPU_TIME"; account="$CFG_ACCOUNT";
gpus="$CFG_GPUS"; cpus_gpu="$CFG_CPUS_GPU"; mem_gpu="$CFG_MEM_GPU"; cpus_cpu="$CFG_CPUS_CPU"; mem_cpu="$CFG_MEM_CPU"; archive=$CFG_ARCHIVE; keep_intermediate=$CFG_KEEP_INTERMEDIATE
job_name_prefix="$CFG_JOB_PREFIX"; search_script="$(dirname "$0")/folddisco_search_job.sh"; bench_script="$(dirname "$0")/folddisco_benchmark_job.sh"; run_log="$CFG_RUN_LOG"

print_help(){ sed -n '1,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --percent) percent=$2; shift 2;;
    --ids) ids=$2; shift 2;;
    --scores) scores=$2; shift 2;;
    --pdb-dir) pdb_dir=$2; shift 2;;
    --index) index=$2; shift 2;;
    --output-base) output_base=$2; shift 2;;
    --lookup) lookup=$2; shift 2;;
    --gpu-partition) gpu_partition=$2; shift 2;;
    --gpu-time) gpu_time=$2; shift 2;;
    --cpu-partition) cpu_partition=$2; shift 2;;
    --cpu-time) cpu_time=$2; shift 2;;
    --account) account=$2; shift 2;;
    --gpus) gpus=$2; shift 2;;
    --cpus-gpu) cpus_gpu=$2; shift 2;;
    --mem-gpu) mem_gpu=$2; shift 2;;
    --cpus-cpu) cpus_cpu=$2; shift 2;;
    --mem-cpu) mem_cpu=$2; shift 2;;
    --no-archive) archive=0; shift;;
    --keep-intermediate) keep_intermediate=1; shift;;
    --job-prefix) job_name_prefix=$2; shift 2;;
    --help|-h) print_help; exit 0;;
    *) echo "[ERROR] Unknown arg: $1" >&2; exit 2;;
  esac
done

[[ -z $percent || -z $ids || -z $scores || -z $pdb_dir || -z $index || -z $output_base || -z $lookup ]] && { echo "[ERROR] Missing required args (check config block at top)" >&2; exit 2; }

search_job_name="${job_name_prefix}_search_${percent}"
bench_job_name="${job_name_prefix}_bench_${percent}"

echo "[CONFIG] percent=$percent ids=$ids scores=$scores" >&2
echo "[CONFIG] pdb_dir=$pdb_dir index=$index output_base=$output_base" >&2
echo "[CONFIG] gpu_part=$gpu_partition cpu_part=$cpu_partition acct=$account" >&2
echo "[SUBMIT] Search job ($percent)" >&2
search_jid=$(sbatch --parsable \
  -J "$search_job_name" -A "$account" -p "$gpu_partition" -t "$gpu_time" \
  --gres=gpu:${gpus} --cpus-per-task="$cpus_gpu" --mem="$mem_gpu" \
  "$search_script" \
    --percent "$percent" \
    --ids "$ids" \
    --scores "$scores" \
    --pdb-dir "$pdb_dir" \
    --index "$index" \
    --output-base "$output_base" \
    $([[ $archive -eq 1 ]] && echo --archive)
)

echo "[INFO] Search job id: $search_jid" >&2

echo "[SUBMIT] Benchmark job (afterok:$search_jid)" >&2
bench_args=(--percent "$percent" --lookup "$lookup" --output-base "$output_base")
[[ $keep_intermediate -eq 1 ]] && bench_args+=(--keep-intermediate)
bench_jid=$(sbatch --parsable \
  -J "$bench_job_name" -A "$account" -p "$cpu_partition" -t "$cpu_time" \
  --cpus-per-task="$cpus_cpu" --mem="$mem_cpu" \
  --dependency=afterok:${search_jid} \
  "$bench_script" "${bench_args[@]}")

echo "[INFO] Benchmark job id: $bench_jid" >&2

echo "--- Submission Summary ---"
echo -e "percent\tsearch_job\tbenchmark_job"
echo -e "${percent}\t${search_jid}\t${bench_jid}"

if [[ -n ${run_log} ]]; then
  mkdir -p "$(dirname "$run_log")"
  {
    echo "timestamp=$(date -Iseconds)"
    echo "percent=$percent"
    echo "ids=$ids"
    echo "scores=$scores"
    echo "pdb_dir=$pdb_dir"
    echo "index=$index"
    echo "output_base=$output_base"
    echo "lookup=$lookup"
    echo "gpu_partition=$gpu_partition gpu_time=$gpu_time"
    echo "cpu_partition=$cpu_partition cpu_time=$cpu_time"
    echo "gpus=$gpus cpus_gpu=$cpus_gpu mem_gpu=$mem_gpu"
    echo "cpus_cpu=$cpus_cpu mem_cpu=$mem_cpu"
    echo "archive=$archive keep_intermediate=$keep_intermediate"
    echo "search_job=$search_jid benchmark_job=$bench_jid"
    echo "---"
  } >> "$run_log"
  echo "[LOG] Appended run metadata to $run_log" >&2
fi
