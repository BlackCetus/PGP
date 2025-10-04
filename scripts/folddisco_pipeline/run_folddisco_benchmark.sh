#!/usr/bin/env bash
set -euo pipefail

# run_folddisco_benchmark.sh
# Clean pipeline to generate SCOP benchmark metrics from FoldDisco motif outputs.
#
# Steps:
#   1. Combine motif outputs -> triplets (query_id target_id score)
#   2. Sort by score (desc) for global ranking
#   3. First-hit benchmark (bench.noselfhit.awk)
#   4. Cumulative PR benchmark (bench.fdr.noselfhit.awk)
#   5. Weighted Top1 metrics
#   6. PR AUC metrics
#   7. Summary TSV
#
# Example:
#   ./run_folddisco_benchmark.sh \
#       --motif-dir /p/scratch/.../folddisco/out/20 \
#       --lookup /p/scratch/.../scop_lookup.fix.tsv \
#       --out-dir /p/scratch/.../folddisco/out \
#       --label 20
#
# Required:
#   --motif-dir DIR   Directory with *_motif.out files
#   --lookup FILE     SCOP lookup (first column IDs)
#   --out-dir DIR     Output directory
# Optional:
#   --label STR       Label prefix (default: run)
#   --pattern GLOB    Motif file pattern (default: *_motif.out)
#   --score-col N     Score column (0-based, default 1)
#   --target-col N    Target column (0-based, default 0)
#   --keep-nonlookup  Keep IDs not in lookup
#   --keep-self       Keep self hits
#   --no-header       Omit header in combined TSV
#   --no-lower        Disable lowercase normalization
#   --dry-run         Show planned config and exit
#   --help            Show this help
#
# Outputs in out-dir:
#   <label>_pairs.scop.tsv
#   <label>_pairs.scop.sorted.tsv
#   first_hit_<label>.tsv
#   pr_curve_<label>.tsv
#   metrics_first_hit_<label>.txt
#   metrics_pr_auc_<label>.txt
#   summary_<label>.tsv

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMBINE_PY="${SCRIPT_DIR}/combine_motif_outputs.py"
BENCH_FIRST_AWK="${SCRIPT_DIR}/bench.noselfhit.awk"
BENCH_PR_AWK="${SCRIPT_DIR}/bench.fdr.noselfhit.awk"
METRIC_FIRST_AWK="${SCRIPT_DIR}/first_hit_metrics.awk"
METRIC_PRAUC_AWK="${SCRIPT_DIR}/pr_auc_metrics.awk"

motif_dir=""; lookup=""; out_dir=""; label="run"; pattern="*_motif.out"; score_col=1; target_col=0
keep_nonlookup=0; keep_self=0; add_header=1; lower=1; dry_run=0; keep_intermediate=0

print_help(){ sed -n '1,/^SCRIPT_DIR/p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --motif-dir) motif_dir=$2; shift 2;;
    --lookup) lookup=$2; shift 2;;
    --out-dir) out_dir=$2; shift 2;;
    --label) label=$2; shift 2;;
    --pattern) pattern=$2; shift 2;;
    --score-col) score_col=$2; shift 2;;
    --target-col) target_col=$2; shift 2;;
    --keep-nonlookup) keep_nonlookup=1; shift;;
    --keep-self) keep_self=1; shift;;
    --no-header) add_header=0; shift;;
    --no-lower) lower=0; shift;;
  --dry-run) dry_run=1; shift;;
  --keep-intermediate) keep_intermediate=1; shift;;
    --help|-h) print_help; exit 0;;
    *) echo "[ERROR] Unknown argument: $1" >&2; exit 2;;
  esac
done

[[ -z $motif_dir || -z $lookup || -z $out_dir ]] && { echo "[ERROR] --motif-dir, --lookup, --out-dir required" >&2; exit 2; }

if [[ $dry_run -eq 1 ]]; then
  echo "[DRY-RUN] Configuration:" >&2
  printf '  motif_dir=%s\n  lookup=%s\n  out_dir=%s\n  label=%s\n  pattern=%s\n  score_col=%s\n  target_col=%s\n' \
    "$motif_dir" "$lookup" "$out_dir" "$label" "$pattern" "$score_col" "$target_col" >&2
  exit 0
fi

mkdir -p "$out_dir"

combined="$out_dir/${label}_pairs.scop.tsv"
sorted="$out_dir/${label}_pairs.scop.sorted.tsv"
first_hit="$out_dir/first_hit_${label}.tsv"
pr_curve="$out_dir/pr_curve_${label}.tsv"
metrics_first="$out_dir/metrics_first_hit_${label}.txt"
metrics_pr="$out_dir/metrics_pr_auc_${label}.txt"
summary="$out_dir/summary_${label}.tsv"

echo "[1/7] Combining motif outputs" >&2
cmd=(python3 "$COMBINE_PY" --input-dir "$motif_dir" --output "$combined" --scop-lookup "$lookup" --pattern "$pattern" --score-col "$score_col" --target-col "$target_col")
[[ $keep_nonlookup -eq 1 ]] && cmd+=(--keep-nonlookup)
[[ $keep_self -eq 1 ]] && cmd+=(--keep-selfhits)
[[ $lower -eq 0 ]] && cmd+=(--no-lower)
[[ $add_header -eq 1 ]] && cmd+=(--add-header)
"${cmd[@]}" 1>&2

echo "[2/7] Sorting by score desc" >&2
if [[ $add_header -eq 1 ]]; then
  { head -n1 "$combined"; tail -n +2 "$combined" | sort -k3,3nr -k1,1 -k2,2; } > "$sorted"
else
  sort -k3,3nr -k1,1 -k2,2 "$combined" > "$sorted"
fi

echo "[3/7] First-hit benchmark" >&2
awk -F'\t' -f "$BENCH_FIRST_AWK" "$lookup" "$sorted" > "$first_hit"

echo "[4/7] PR benchmark" >&2
awk -F'\t' -f "$BENCH_PR_AWK" "$lookup" "$sorted" > "$pr_curve"

echo "[5/7] Top1 metrics" >&2
awk -f "$METRIC_FIRST_AWK" "$first_hit" > "$metrics_first"

echo "[6/7] PR AUC metrics" >&2
awk -f "$METRIC_PRAUC_AWK" "$pr_curve" > "$metrics_pr"

echo "[7/7] Summary" >&2
fam_top1=$(awk 'NR==1{next} {s+=$3;n++} END{if(n>0) printf "%.6f", s/n;}' "$first_hit")
sfam_top1=$(awk 'NR==1{next} {s+=$4;n++} END{if(n>0) printf "%.6f", s/n;}' "$first_hit")
fold_top1=$(awk 'NR==1{next} {s+=$5;n++} END{if(n>0) printf "%.6f", s/n;}' "$first_hit")
fam_auc=$(awk 'NR==1 && $1 ~ /[^0-9.]/ {next} {if(seen) a+=($4-rf)*( $1+pf)/2; pf=$1; rf=$4; seen=1} END{printf "%.6f", a}' "$pr_curve")
sfam_auc=$(awk 'NR==1 && $1 ~ /[^0-9.]/ {next} {if(seen) a+=($5-rs)*( $2+ps)/2; ps=$2; rs=$5; seen=1} END{printf "%.6f", a}' "$pr_curve")
fold_auc=$(awk 'NR==1 && $1 ~ /[^0-9.]/ {next} {if(seen) a+=($6-rf)*( $3+pf)/2; pf=$3; rf=$6; seen=1} END{printf "%.6f", a}' "$pr_curve")

echo -e "label\tfamily_top1\tsuperfamily_top1\tfold_top1\tfamily_pr_auc\tsuperfamily_pr_auc\tfold_pr_auc" > "$summary"
echo -e "${label}\t${fam_top1}\t${sfam_top1}\t${fold_top1}\t${fam_auc}\t${sfam_auc}\t${fold_auc}" >> "$summary"

echo "[DONE] Summary written: $summary" >&2
cat "$summary"

if [[ $keep_intermediate -eq 0 ]]; then
  echo "[CLEANUP] Removing intermediate files" >&2
  rm -f "$combined" "$sorted" || true
else
  echo "[CLEANUP] Keeping intermediate files (user requested)" >&2
fi

