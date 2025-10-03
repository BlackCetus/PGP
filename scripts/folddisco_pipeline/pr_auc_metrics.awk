#!/usr/bin/awk -f
# pr_auc_metrics.awk
# Compute PR AUC (family, superfamily, fold) from cumulative precision/recall file
# Input columns (tab-separated) as produced by bench.fdr.noselfhit.awk (no header assumed):
#   PREC_FAM PREC_SFAM PREC_FOLD RECALL_FAM RECALL_SFAM RECALL_FOLD TP_FAM
# If a header is present (first token non-numeric) it will be skipped.
# Usage:
#   awk -f pr_auc_metrics.awk pr_curve_10.tsv
BEGIN{FS="\t"; OFS="\t"}
{
  # Skip header if first field is non-numeric and this is the first record
  if(NR==1 && $1 ~ /[^0-9.]/){ next }
  prec_fam=$1; prec_sfam=$2; prec_fold=$3; rec_fam=$4; rec_sfam=$5; rec_fold=$6;
  if(seen){
    fam_auc  += (rec_fam  - last_rec_fam )  * (prec_fam   + last_prec_fam ) / 2.0
    sfam_auc += (rec_sfam - last_rec_sfam) * (prec_sfam  + last_prec_sfam) / 2.0
    fold_auc += (rec_fold - last_rec_fold) * (prec_fold  + last_prec_fold) / 2.0
  }
  last_prec_fam=prec_fam; last_rec_fam=rec_fam;
  last_prec_sfam=prec_sfam; last_rec_sfam=rec_sfam;
  last_prec_fold=prec_fold; last_rec_fold=rec_fold;
  seen=1
}
END{
  if(!seen){ print "ERROR: no numeric rows" > "/dev/stderr"; exit 1 }
  printf "Family_PR_AUC\t%.6f\n", fam_auc
  printf "Superfamily_PR_AUC\t%.6f\n", sfam_auc
  printf "Fold_PR_AUC\t%.6f\n", fold_auc
}
