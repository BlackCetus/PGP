#!/usr/bin/env python3
"""Simplified FoldDisco input generator.

Requirements:
    --ids ids.txt                  (lines with >ID, order defines protein order)
    --scores conservation_pred.txt (each line: whitespace or comma separated scores for that protein, same order as ids)
    --pdb-dir /path/to/pdb         (PDB files named <ID>_.pdb)
    --percent X                    (top X percent of residues by score)
    --out manifest.tsv             (TSV manifest listing one row per ID)
Optional:
    --with-output-path             (add 3rd column designating per-ID output target file)
    --output-dir DIR               (directory where those per-ID output target paths live; required if --with-output-path)
    --min-residues N               (floor on number selected)

Assumptions:
    - Chain letter is derivable from the ID. The ID format observed: d1twfa__A or d1y5ia2_A etc.
        The portion after the final underscore is treated as the chain if it is a single letter.
        By default chains are merged per base ID (e.g. d1twfa) aggregating motif residues from all chains.
        Use --per-chain to retain one row per chain-specific ID.
  - Residue numbering uses sequence indices starting at 1 (since we don't read PDB).
  - Motif residue syntax: <Chain><SeqIndex> or ranges collapsed (A10-15).
  - If a score line is shorter than expected, we just use its length; no external length source.
    - If a line in the conservation file is a single long string of digits (e.g. 555000670...), each digit is interpreted as an individual residue score.
    - PDB filename resolution (in merged mode) tries: <original_id>_.pdb, <original_id>.pdb, <base_id>_.pdb, <base_id>.pdb and uses the first that exists.

Example:
  generate_folddisco_input_simple.py \
    --ids ids.txt \
    --scores conservation_pred.txt \
    --pdb-dir /p/scratch/.../pdb \
    --percent 5 \
    --out folddisco_input.tsv
"""
from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path
from typing import List, Tuple

import re

ID_RE = re.compile(r'^>([^\s]+)')

# python scripts/generate_folddisco_input.py --ids /p/scratch/hai_1072/reimt/data/scop40pdb/PGP_out/ids.txt --scores /p/scratch/hai_1072/reimt/data/scop40pdb/PGP_out/conservation_pred.txt --pdb-dir /p/scratch/hai_1072/reimt/data/scop40pdb/pdb --percent 20 --out /p/scratch/hai_1072/reimt/data/scop40pdb/folddisco/input/folddisco_in.txt --with-output-path --output-dir /p/scratch/hai_1072/reimt/data/scop40pdb/folddisco/out --verbose
def parse_args():
    p = argparse.ArgumentParser(description="Generate FoldDisco TSV (simple: ids + scores only)")
    p.add_argument('--ids', required=True)
    p.add_argument('--scores', required=True, help='conservation_pred.txt')
    p.add_argument('--pdb-dir', required=True)
    p.add_argument('--percent', type=float, default=5.0)
    p.add_argument('--min-residues', type=int, default=1)
    p.add_argument('--out', required=True, help='Path to write the TSV manifest (always two columns unless --with-output-path adds a third)')
    p.add_argument('--with-output-path', action='store_true', help='Append third column with per-ID output file (in --output-dir)')
    p.add_argument('--output-dir', help='Directory to house per-ID output files referenced in third column (required with --with-output-path)')
    p.add_argument('--per-chain', action='store_true', help='Do not merge chains; keep one row per original ID including chain suffix')
    p.add_argument('--verbose', action='store_true')
    return p.parse_args()


def read_ids(path: Path) -> List[str]:
    ids: List[str] = []
    chains: List[str] = []
    with path.open() as fh:
        for line in fh:
            m = ID_RE.match(line)
            if not m:
                continue
            raw = m.group(1)
            ids.append(raw)
    return ids


def read_scores(path: Path) -> List[List[float]]:
    all_scores: List[List[float]] = []
    with path.open() as fh:
        for line in fh:
            line = line.strip()
            if not line:
                all_scores.append([])
                continue
            # Detect if the line is one long un-delimited digit sequence (e.g. conservation digits)
            if re.fullmatch(r'[0-9]+', line):
                # Interpret each digit as an integer score (optionally normalize later)
                row = [float(int(ch)) for ch in line]
            else:
                parts = [p for p in re.split(r'[\s,;]+', line) if p]
                row: List[float] = []
                for p_ in parts:
                    try:
                        row.append(float(p_))
                    except ValueError:
                        row.append(float('nan'))
            all_scores.append(row)
    return all_scores


def collapse_ranges(chain: str, indices: List[int]) -> List[str]:
    if not indices:
        return []
    indices = sorted(set(indices))
    tokens: List[str] = []
    start = prev = indices[0]
    for x in indices[1:]:
        if x == prev + 1:
            prev = x
            continue
        if start == prev:
            tokens.append(f"{chain}{start}")
        else:
            tokens.append(f"{chain}{start}-{prev}")
        start = prev = x
    if start == prev:
        tokens.append(f"{chain}{start}")
    else:
        tokens.append(f"{chain}{start}-{prev}")
    return tokens



def extract_chain(id_str: str) -> str:
    # Take text after last underscore; fallback 'A'
    if '_' in id_str:
        c = id_str.split('_')[-1]
        # chain can be a single letter or digit
        if c and len(c) == 1 and (c.isalpha() or c.isdigit()):
            return c
    # try trailing letter or digit
    m = re.search(r'([A-Za-z0-9])$', id_str)
    if m:
        return m.group(1)
    return 'A'



def base_id(id_str: str) -> str:
    """Strip a trailing underscore + single chain (letter or digit) if present, else return unchanged."""
    if '_' in id_str:
        parts = id_str.split('_')
        if parts[-1] and len(parts[-1]) == 1 and (parts[-1].isalpha() or parts[-1].isdigit()):
            return '_'.join(parts[:-1])
    return id_str


def resolve_pdb_path(pdb_dir: Path, original_id: str, merged: bool) -> Path:
    """Try multiple filename patterns to locate an existing PDB.

    Patterns tried in order (first existing is returned):
      1. original_id + '_.pdb'
      2. original_id + '.pdb'
      3. base_id(original_id) + '_.pdb'
      4. base_id(original_id) + '.pdb'
    If none exist, returns the first pattern path (even if missing) so caller can warn.
    """
    b = base_id(original_id)
    candidates = [
        pdb_dir / f"{original_id}_.pdb",
        pdb_dir / f"{original_id}.pdb",
        pdb_dir / f"{b}_.pdb",
        pdb_dir / f"{b}.pdb",
    ]
    for c in candidates:
        if c.exists():
            return c
    # Try glob for versioned files: <base_id>*.pdb
    import glob
    globbed = sorted(pdb_dir.glob(f"{b}*.pdb"))
    if globbed:
        return globbed[0]
    return candidates[0]


def select_indices(scores: List[float], percent: float, min_res: int) -> List[int]:
    # treat NaN as very low score
    indexed: List[Tuple[int, float]] = []
    import math as _m
    for i, s in enumerate(scores, start=1):  # residue indices start at 1
        if _m.isnan(s):
            val = -1e9
        else:
            val = s
        indexed.append((i, val))
    if not indexed:
        return []
    indexed.sort(key=lambda t: t[1], reverse=True)
    k = max(min_res, math.ceil(len(indexed) * (percent / 100.0)))
    top = indexed[:k]
    return [i for i, _ in top]


def main():
    args = parse_args()
    ids = read_ids(Path(args.ids))
    score_lines = read_scores(Path(args.scores))
    if len(score_lines) != len(ids):
        sys.exit(f"Mismatch: {len(ids)} ids vs {len(score_lines)} score lines")
    if args.with_output_path and not args.output_dir:
        sys.exit('--output-dir required with --with-output-path')
    out_dir = Path(args.output_dir) if args.output_dir else None
    if args.percent == int(args.percent):
        percent_str = str(int(args.percent))
    else:
        percent_str = str(args.percent).replace('.', 'p')
    # If using output_dir, create a subdir for the percent value
    if out_dir:
        out_dir = out_dir / percent_str
        out_dir.mkdir(parents=True, exist_ok=True)

    # Modify output filename to include _<percent> before extension
    out_path = Path(args.out)
    import re as _re
    stem = out_path.stem
    # Remove trailing _<number> or _<number.number> or _<number>p<number> if present
    stem = _re.sub(r'_(\d+(?:\.\d+)?|\d+p\d+)$', '', stem)
    out_path = out_path.with_name(f"{stem}_{percent_str}{out_path.suffix}")

    if args.verbose:
        print(f"Output file will be: {out_path}", file=sys.stderr)

    rows: List[str] = []
    if args.per_chain:
        # original behavior
        for id_str, scores in zip(ids, score_lines):
            if not scores:
                continue
            chain = extract_chain(id_str)
            sel = select_indices(scores, args.percent, args.min_residues)
            motif_parts = collapse_ranges(chain, sel)
            if not motif_parts:
                continue
            motif = ','.join(motif_parts)
            pdb_path = Path(args.pdb_dir) / f"{id_str}_.pdb"
            if args.with_output_path and out_dir is not None:
                stem = f"{id_str}_motif"
                out_file = out_dir / f"{stem}.out"
                row = f"{pdb_path}\t{motif}\t{out_file}"
            else:
                row = f"{pdb_path}\t{motif}"
            rows.append(row)
    else:
        # merge chains by base ID
        from collections import defaultdict
        grouped_scores = defaultdict(list)  # base_id -> list of (chain, indices)
        chain_sel_map = defaultdict(list)   # base_id -> list of (chain, selected_indices)
        id_to_scores = list(zip(ids, score_lines))
        for id_str, scores in id_to_scores:
            if not scores:
                continue
            chain = extract_chain(id_str)
            sel = select_indices(scores, args.percent, args.min_residues)
            if not sel:
                continue
            b = base_id(id_str)
            chain_sel_map[b].append((chain, sel))
        for b, chain_lists in chain_sel_map.items():
            # build combined motif tokens across chains (each chain collapsed separately)
            chain_tokens: List[str] = []
            for chain, indices in chain_lists:
                chain_tokens.extend(collapse_ranges(chain, indices))
            motif = ','.join(chain_tokens)
            pdb_path = resolve_pdb_path(Path(args.pdb_dir), b, merged=True)
            if args.verbose and not pdb_path.exists():
                print(f"WARNING: PDB not found for base ID {b} (tried variants)", file=sys.stderr)
            if args.with_output_path and out_dir is not None:
                stem = f"{b}_motif"
                out_file = out_dir / f"{stem}.out"
                row = f"{pdb_path}\t{motif}\t{out_file}"
            else:
                row = f"{pdb_path}\t{motif}"
            rows.append(row)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open('w') as fh:
        fh.write('\n'.join(rows) + ('\n' if rows else ''))
    if args.verbose:
        print(f"Wrote {len(rows)} rows to {out_path}", file=sys.stderr)


if __name__ == '__main__':
    main()
