#!/usr/bin/awk -f
# first_hit_metrics.awk
# Compute mean first-hit success rates (family, superfamily, fold)
# Input: bench.noselfhit.awk output (tab-separated) with header:
#   NAME SCOP FAM SFAM FOLD FP FAMCNT SFAMCNT FOLDCNT
# Usage:
#   awk -f first_hit_metrics.awk first_hit_10.tsv
BEGIN{FS="\t"; OFS="\t"}
NR==1 {next} # skip header
{
  fam += $3; sfam += $4; fold += $5; n++
}
END{
  if(n==0){print "ERROR: no data" > "/dev/stderr"; exit 1}
  printf "Family_Top1\t%.6f\n", fam/n
  printf "Superfamily_Top1\t%.6f\n", sfam/n
  printf "Fold_Top1\t%.6f\n", fold/n
}
