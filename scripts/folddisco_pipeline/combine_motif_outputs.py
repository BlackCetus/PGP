#!/usr/bin/env python3
"""
Combine multiple FoldDisco (or similar) motif output files into a single TSV suitable
for downstream SCOP benchmark AUC scripts.

Input motif filenames are expected to end with `_motif.out` (default pattern) and the
canonical SCOP domain query ID is derived as: basename(filename).rsplit('_',1)[0]
(keeping any trailing underscore that exists there).

Each motif output file is assumed to have at least two columns where the first
column in your FoldDisco output may be a FULL PATH to a structure file
(e.g. /path/to/pdb/d2gkma_.pdb). This script now automatically strips any leading
directory components and recognized structure file extensions so the target ID
becomes just the basename (d2gkma_) before lookup normalization. Only two fields
are required: target (or its path) and score; additional columns are ignored.

The combined output schema:
    query_id    target_id   score

ID Cleanup:
- Both query and target IDs can be normalized to match SCOP domain IDs if a lookup
  file is provided via --scop-lookup. The lookup file is expected to have the domain
  ID in the first column (tab separated). A set of valid IDs is built and used to
  (a) filter out lines whose query or target isn't present (unless --keep-nonlookup),
  (b) optionally auto-repair minor deviations:
      * If an ID without a trailing underscore is not in the set but adding one makes
        it match, the version with underscore is used.
- Lowercasing is applied (SCOP domain IDs are typically lowercase) unless
  --no-lower is specified.
- Basic stripping removes common structure file extensions if they appear appended
  (e.g., .pdb, .cif, .ent, .gz) prior to lookup matching.

Self-hits:
- By default self hits (query == target after normalization) are skipped. Disable with
  --keep-selfhits.

Sorting:
- This script does NOT sort output; you can sort afterwards with:
    sort -k1,1 -k3,3nr combined.tsv > combined.sorted.tsv
  (assuming larger score = better). Use 'g' instead of 'nr' if lower score is better.

Usage examples:
  python combine_motif_outputs.py \
      --input-dir folddisco_out/run_10pct \
      --output folddisco_pairs.tsv \
      --scop-lookup /path/to/scop_lookup.fix.tsv

  python combine_motif_outputs.py --help

"""
from __future__ import annotations
import argparse
import sys
import os
import glob
from typing import Iterable, Tuple, Optional, Set, List

STRUCT_EXTS = [".pdb", ".cif", ".ent", ".gz"]

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Combine motif outputs into a benchmark-ready TSV.")
    p.add_argument("--input-dir", required=True, help="Directory containing *_motif.out files (non-recursive unless --recursive).")
    p.add_argument("--pattern", default="*_motif.out", help="Filename glob pattern (default: *_motif.out)")
    p.add_argument("--output", required=True, help="Output TSV path")
    p.add_argument("--scop-lookup", help="Path to SCOP lookup file (first column = valid domain IDs)")
    p.add_argument("--keep-nonlookup", action="store_true", help="Keep lines with IDs not present in lookup (if provided)")
    p.add_argument("--no-lower", action="store_true", help="Do not lowercase IDs during cleanup")
    p.add_argument("--keep-selfhits", action="store_true", help="Do not drop self hits")
    p.add_argument("--max-files", type=int, help="Limit number of motif files processed (for testing)")
    p.add_argument("--recursive", action="store_true", help="Recurse into subdirectories when matching pattern")
    p.add_argument("--verbose", "-v", action="count", default=0, help="Increase verbosity (repeat for more)")
    p.add_argument("--dry-run", action="store_true", help="Discover & report stats without writing output")
    p.add_argument("--add-header", action="store_true", help="Add header line to output TSV")
    p.add_argument("--score-col", type=int, default=1, help="0-based index of score column in motif line (default 1)")
    p.add_argument("--target-col", type=int, default=0, help="0-based index of target id column in motif line (default 0)")
    p.add_argument("--whitespace", action="store_true", help="Force splitting on any whitespace (ignore tabs)")
    p.add_argument("--min-fields", type=int, default=2, help="Minimum fields required in a motif line (default 2)")
    p.add_argument("--report-missing", help="Write unique missing (non-lookup) IDs to this file for inspection")
    return p.parse_args()

def load_lookup(path: str) -> Set[str]:
    valid: Set[str] = set()
    with open(path, 'r') as fh:
        for line in fh:
            if not line.strip() or line.startswith('#'):
                continue
            first = line.split('\t', 1)[0].strip()
            if first:
                valid.add(first)
    return valid

def cleanup_id(raw: str, lower: bool, lookup: Optional[Set[str]]) -> Optional[str]:
    x = raw.strip()
    # If a path slipped through, keep only basename
    if '/' in x:
        x = x.rsplit('/', 1)[-1]
    # Remove obvious file extensions that might have crept in
    done = False
    while not done:
        done = True
        for ext in STRUCT_EXTS:
            if x.lower().endswith(ext):
                x = x[: -len(ext)]
                done = False
    if lower:
        x = x.lower()
    # If lookup provided, attempt minimal repairs
    if lookup is not None:
        if x in lookup:
            return x
        # Try appending underscore if missing
        if not x.endswith('_') and (x + '_') in lookup:
            return x + '_'
        # Try removing underscore if present and other form exists
        if x.endswith('_') and x[:-1] in lookup:
            return x[:-1]
        # Otherwise return None to signal unknown (caller may decide to keep)
        return None
    return x

def motif_files(input_dir: str, pattern: str, recursive: bool) -> List[str]:
    if recursive:
        return sorted(glob.glob(os.path.join(input_dir, "**", pattern), recursive=True))
    return sorted(glob.glob(os.path.join(input_dir, pattern)))

def extract_query_id(path: str) -> str:
    base = os.path.basename(path)
    return base.rsplit('_', 1)[0]

def iter_motif_lines(path: str, target_col: int, score_col: int, min_fields: int, whitespace: bool) -> Iterable[Tuple[str, str]]:
    with open(path, 'r') as fh:
        for line in fh:
            stripped = line.strip()
            if not stripped or stripped.startswith('#'):
                continue
            if whitespace:
                parts = stripped.split()
            else:
                parts = stripped.split('\t')
                if len(parts) < min_fields:
                    parts = stripped.split()
            if len(parts) < min_fields:
                continue
            if target_col >= len(parts) or score_col >= len(parts):
                continue
            target = parts[target_col]
            score = parts[score_col]
            yield target, score

def main() -> int:
    args = parse_args()

    lookup: Optional[Set[str]] = None
    if args.scop_lookup:
        if not os.path.isfile(args.scop_lookup):
            print(f"[ERROR] SCOP lookup file not found: {args.scop_lookup}", file=sys.stderr)
            return 2
        lookup = load_lookup(args.scop_lookup)
        if args.verbose:
            print(f"[INFO] Loaded {len(lookup):,} SCOP IDs", file=sys.stderr)

    files = motif_files(args.input_dir, args.pattern, args.recursive)
    if args.max_files:
        files = files[: args.max_files]
    if not files:
        print(f"[ERROR] No files matched pattern {args.pattern} in {args.input_dir}", file=sys.stderr)
        return 1
    if args.verbose:
        print(f"[INFO] Found {len(files)} motif files", file=sys.stderr)

    lower_flag = not args.no_lower
    total_raw_lines = 0
    total_kept = 0
    total_self = 0
    total_lookup_missing = 0
    missing_ids: Set[str] = set()

    out_fh = None
    if not args.dry_run:
        out_dir = os.path.dirname(os.path.abspath(args.output))
        if out_dir and not os.path.isdir(out_dir):
            os.makedirs(out_dir, exist_ok=True)
        out_fh = open(args.output, 'w')
        if args.add_header:
            out_fh.write("query_id\ttarget_id\tscore\n")

    try:
        for fpath in files:
            q_raw = extract_query_id(fpath)
            q_clean = cleanup_id(q_raw, lower_flag, lookup)
            if q_clean is None:
                if lookup is not None and not args.keep_nonlookup:
                    if args.verbose > 1:
                        print(f"[SKIP] Query ID {q_raw} not in lookup", file=sys.stderr)
                    continue
                q_clean = q_raw.lower() if lower_flag else q_raw
            for target_raw, score_txt in iter_motif_lines(fpath, args.target_col, args.score_col, args.min_fields, args.whitespace):
                total_raw_lines += 1
                t_clean = cleanup_id(target_raw, lower_flag, lookup)
                if t_clean is None:
                    if lookup is not None and not args.keep_nonlookup:
                        total_lookup_missing += 1
                        # collect basename/id fragment for reporting
                        missed = target_raw.strip()
                        if '/' in missed:
                            missed = missed.rsplit('/',1)[-1]
                        missing_ids.add(missed)
                        continue
                    # fallback keep raw (basename already stripped in cleanup attempt?)
                    fallback = target_raw.strip()
                    if '/' in fallback:
                        fallback = fallback.rsplit('/',1)[-1]
                    # strip extension manually for readability
                    for ext in STRUCT_EXTS:
                        if fallback.lower().endswith(ext):
                            fallback = fallback[: -len(ext)]
                            break
                    t_clean = fallback.lower() if lower_flag else fallback
                # Drop self hits if requested
                if not args.keep_selfhits and q_clean == t_clean:
                    total_self += 1
                    continue
                # Validate score
                try:
                    score = float(score_txt)
                except ValueError:
                    continue
                if out_fh:
                    out_fh.write(f"{q_clean}\t{t_clean}\t{score}\n")
                total_kept += 1
    finally:
        if out_fh:
            out_fh.close()

    if args.verbose:
        print(f"[STATS] Raw motif lines scanned: {total_raw_lines}", file=sys.stderr)
        print(f"[STATS] Triplets written:       {total_kept}", file=sys.stderr)
        print(f"[STATS] Self hits dropped:      {total_self}", file=sys.stderr)
        if lookup is not None:
            print(f"[STATS] Missing lookup IDs:     {total_lookup_missing}", file=sys.stderr)
            if args.report_missing and missing_ids:
                try:
                    with open(args.report_missing, 'w') as mf:
                        for mid in sorted(missing_ids):
                            mf.write(f"{mid}\n")
                    print(f"[INFO] Wrote {len(missing_ids)} unique missing IDs to {args.report_missing}", file=sys.stderr)
                except OSError as e:
                    print(f"[WARN] Could not write missing IDs report: {e}", file=sys.stderr)
        if not args.dry_run:
            print(f"[INFO] Output written to {args.output}", file=sys.stderr)
    return 0

if __name__ == "__main__":
    sys.exit(main())
