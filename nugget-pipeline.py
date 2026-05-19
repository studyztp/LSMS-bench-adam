#!/usr/bin/env python3
"""
nugget-pipeline.py
==================

Unified driver for the Nugget workflow on LSMS-bench-adam. Six stages in
sequence; --stage <name> picks just one.

Stages:
  base       configure + build the base toolchain; emit labeled bitcode and
             build-base/lsms-ir-bb.csv (BB id -> function map).
  analysis   build the analysis toolchain (reusing build-base/llvm-bc/), then
             run it once against the workload to produce
             <workload>/analysis-output.csv.
  markers    parse analysis-output.csv + lsms-ir-bb.csv, choose per-region
             marker BBs, write phasebound-markers.csv.
  phasebound build the phase-bound toolchain (one binary per marker row), then
             run every binary `--trials` times pinned to one core; write
             phasebound-results.csv and phasebound-summary.csv.
  baseline   build the base-measure toolchain (whole-ROI timer), run it
             `--trials` times; write base-measure-results.csv and
             base-measure-summary.csv.
  validate   sum phasebound mean_ns, compare to baseline mean, print a
             comparison table; write validation.csv.

Run with no --stage and the script walks all six in order. Each stage assumes
its prerequisites exist on disk and FileNotFoundErrors out if not -- nothing
is implicitly re-run.

Every path uses pathlib.Path. Pinning uses taskset -c <core>.
"""

import argparse
import collections    # defaultdict for per-region BB tables
import csv            # all CSV I/O (analysis output, markers, summaries)
import re             # nugget-binary discovery regex, "Time taken: N ns" regex
import shutil         # which() for tool checks; copytree() to mirror build-base/llvm-bc
import statistics     # mean / stdev across per-trial measurements
import subprocess     # cmake + taskset invocations
import sys            # clean exits with messages
import time           # wall-clock timing of subprocess runs
from pathlib import Path


# ----------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------

# All paths are anchored at the directory this script lives in. .resolve()
# makes them absolute so they survive any subprocess that changes cwd
# (the analysis / phase-bound / baseline runs all cd into the workload dir).
PROJECT_ROOT = Path(__file__).parent.resolve()

# Where the toolchain .cmake files and hook .c files live. Each stage
# picks one toolchain from here.
TOOLCHAIN_DIR = PROJECT_ROOT / "toolchain" / "Nugget"

# Everything the pipeline generates lives under here, keeping the project
# root focused on source/scripts/docs. data/ collects every CSV result;
# nugget-pipeline-logs/ collects per-trial stdout+stderr (useful for
# postmortems when a measurement returns "no-result"); workload dirs sit
# alongside (FePt/, etc.) and contain run-time inputs plus the hook-emitted
# analysis-output.csv.
EXPERIMENT_ROOT = PROJECT_ROOT / "experiment"
DATA_DIR = EXPERIMENT_ROOT / "data"
LOGS_ROOT = EXPERIMENT_ROOT / "nugget-pipeline-logs"

# Two CMake build directories. build-base is the source of
# build-base/llvm-bc/ which the other stages reuse (see reuse_base_bc).
# build-cpu-exec is shared by the analysis, phase-bound, and base-measure
# stages: each reconfigures it with its own toolchain via `cmake --fresh`,
# which wipes CMakeCache.txt but leaves shared build artefacts in place.
BUILD_BASE = PROJECT_ROOT / "build-base"
BUILD_CPU_EXEC = PROJECT_ROOT / "build-cpu-exec"

# Result/state CSVs all live under experiment/data/. The markers CSV is
# also consumed by the phase-bound toolchain at CMake configure time
# (path hardcoded in toolchain/Nugget/nugget-cpu-phasebound.cmake).
MARKERS_FILE = DATA_DIR / "phasebound-markers.csv"
PHASEBOUND_RESULTS = DATA_DIR / "phasebound-results.csv"     # raw, per-measurement
PHASEBOUND_SUMMARY = DATA_DIR / "phasebound-summary.csv"     # per-nugget mean/stdev
BASE_MEASURE_RESULTS = DATA_DIR / "base-measure-results.csv"
BASE_MEASURE_SUMMARY = DATA_DIR / "base-measure-summary.csv"
VALIDATION_FILE = DATA_DIR / "validation.csv"

# "Hook kind" tag. Has to match NUGGET_PHASEBOUND_HOOK_NAME set in
# toolchain/Nugget/nugget-cpu-phasebound.cmake: the toolchain bakes this
# name into every executable as lsms_main-nugget-<name>-<id>-exec, and the
# discovery regex below uses it to find them after the build.
NAME_TAG = "time"

# Both phase-bound and base-measure hooks print and write the same single
# line to result.txt: "Time taken: <N> ns". This regex extracts the integer
# N. read_time_ns() returns None if the line isn't present (= measurement
# failed / hook didn't reach the end marker).
_TIME_RE = re.compile(r"Time taken:\s*(\d+)\s*ns")

# Per-row nugget id encodes both the region and the marker margin used to
# pick its end-marker BB; the CMake helper appends '-m<margin>' to the row
# id so (margin, region) pairs map to distinct binary names in a single
# build dir. Example: 'region_07-m99' -> ('region_07', 99).
_NUGGET_ID_RE = re.compile(r"^(?P<region>.+)-m(?P<margin>\d+)$")


def parse_nugget_id(full_id: str) -> tuple:
    """Split a discovered nugget id ('region_07-m99') into ('region_07', 99).
    Returns (full_id, 0) if the trailing '-m<N>' tag is absent -- defensive
    against legacy un-tagged binaries that might still be sitting in the
    build dir from a previous schema."""
    m = _NUGGET_ID_RE.match(full_id)
    if not m:
        return full_id, 0
    return m.group("region"), int(m.group("margin"))


# ----------------------------------------------------------------------------
# Shared helpers
# ----------------------------------------------------------------------------

def require_file(path: Path, hint: str) -> None:
    """Exit cleanly if a prerequisite file is missing.

    Used at the top of stages that depend on earlier stages' outputs --
    rather than letting the user hit a cryptic FileNotFoundError or worse,
    a misleading downstream parse error.
    """
    if not path.exists():
        sys.exit(f"missing prerequisite: {path}\n  hint: {hint}")


def run_or_die(cmd, **kwargs) -> subprocess.CompletedProcess:
    """Run a subprocess and bail out on non-zero. Echoes the command first
    so the user can see (and copy-paste) exactly what's running.

    No stdout/stderr capture here -- cmake's progress output streams
    straight to the user's terminal, which is what we want for an
    interactive driver. Use run_pinned() for binary runs whose output we
    do want to capture to a file.
    """
    pretty = " ".join(str(c) for c in cmd)
    print(f"  $ {pretty}")
    proc = subprocess.run(cmd, **kwargs)
    if proc.returncode != 0:
        sys.exit(f"command failed (exit {proc.returncode}): {pretty}")
    return proc


def configure(build_dir: Path, toolchain: Path, fresh: bool = False) -> None:
    """cmake configure step. Same flags every stage uses; only the
    toolchain file (and thus the resulting executables) differs.

    fresh=True passes --fresh to cmake, which wipes CMakeCache.txt and
    CMakeFiles/ but leaves the rest of the build tree intact. The
    analysis / phase-bound / base-measure stages share build-cpu-exec
    but each uses a different toolchain file; --fresh forces cmake to
    re-read the new toolchain instead of refusing to change
    CMAKE_TOOLCHAIN_FILE in an existing cache. Shared compilation
    artefacts (objects, bitcodes) that don't depend on the swapped
    flags get reused across stages.
    """
    build_dir.mkdir(parents=True, exist_ok=True)
    cmd = ["cmake"]
    if fresh:
        cmd.append("--fresh")
    cmd += [
        "-S", str(PROJECT_ROOT),
        "-B", str(build_dir),
        f"-DCMAKE_TOOLCHAIN_FILE={toolchain}",
        "-DCMAKE_BUILD_TYPE=Release",
    ]
    run_or_die(cmd)


def cmake_build(build_dir: Path, target: str) -> None:
    """Thin wrapper around `cmake --build`. Kept separate from configure()
    because some stages build multiple targets (or aggregate targets that
    pull in many per-row execs)."""
    run_or_die(["cmake", "--build", str(build_dir), "--target", target])


def reuse_base_bc(dest_build: Path) -> None:
    """Mirror build-base/llvm-bc/ into <dest_build>/llvm-bc/.

    The analysis / phase-bound / baseline toolchains all declare a "fake"
    `lsms_main-base-bc` CMake target whose NUGGET_BC_FILE property points
    at <build>/llvm-bc/lsms_main-base-bc.bc. That file is only actually
    written by the BASE build. So before any non-base stage can build, we
    have to copy the labeled bitcode tree out of build-base/.
    shutil.copytree with dirs_exist_ok=True lets us re-run the stage
    without removing anything first.
    """
    src = BUILD_BASE / "llvm-bc"
    if not src.exists():
        sys.exit(f"{src} not found; run --stage base first.")
    shutil.copytree(src, dest_build / "llvm-bc", dirs_exist_ok=True)


def read_time_ns(result_path: Path) -> int | None:
    """Pull the nanosecond measurement out of a hook-written result.txt.
    Returns None if the file is missing or doesn't contain the expected
    line -- both signal a failed measurement (the hook didn't reach its
    end marker, the program crashed, etc.)."""
    if not result_path.exists():
        return None
    m = _TIME_RE.search(result_path.read_text())
    return int(m.group(1)) if m else None


def run_pinned(binary: Path, argv: list, cwd: Path, log: Path,
               core: int, timeout: float | None = None
               ) -> subprocess.CompletedProcess:
    """Run a binary pinned to a single CPU core, capturing all output to a
    log file.

    Pinning is critical: without it, the OS scheduler will migrate the
    process between cores, frequency-scaling will vary, and adjacent
    runs will see different cache states. taskset -c <core> keeps the
    process on one core for the whole run, which is what makes the
    measurements stable enough to compare. Default --core is 8 (a
    "middle" core on the user's machine; far enough from core 0 to
    avoid OS noise).

    stdout+stderr go to <log> so the script's own stdout stays readable
    even when 350+ binaries run in sequence.
    """
    log.parent.mkdir(parents=True, exist_ok=True)
    cmd = ["taskset", "-c", str(core), str(binary), *argv]
    with log.open("w") as f:
        return subprocess.run(
            cmd, cwd=str(cwd), stdout=f, stderr=subprocess.STDOUT,
            timeout=timeout,
        )


def write_long_form_results(rows: list, out_path: Path,
                            fieldnames: list) -> None:
    """Dump raw per-measurement rows as a CSV. extrasaction='ignore' so
    we can reuse the same row dicts across phasebound and baseline even
    though their column lists differ (e.g. baseline has no 'id' column
    in its output)."""
    with out_path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow(r)


def write_summary(rows: list, out_path: Path,
                  id_columns: tuple = ("id",)) -> None:
    """Group rows by the tuple of id_columns, compute n_ok / mean / stdev /
    min / max per group.

    id_columns lets phasebound pivot on (margin, id) while baseline keeps
    the single 'id' column. The header is written as the id_columns values
    followed by the aggregate columns.

    Failed measurements (status != 'ok' or blank time_ns) are excluded
    from the aggregate -- but the key still appears in the summary with
    n_ok=0 and blank stats so downstream tools see one row per group no
    matter what.

    Output ordering is first-seen: keeps the summary aligned with the
    discovery order of the binaries (which is the order users see in
    their terminal).
    """
    by_key = collections.defaultdict(list)
    order = []
    for r in rows:
        key = tuple(r[c] for c in id_columns)
        if key not in by_key:
            order.append(key)
        if r["status"] == "ok" and r["time_ns"] != "":
            by_key[key].append(int(r["time_ns"]))
        else:
            # touching the key with [] ensures it exists even if every
            # trial failed for this group -- we still want a row for it.
            by_key[key]
    with out_path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(list(id_columns) + ["n_ok", "mean_ns", "stdev_ns",
                                       "min_ns", "max_ns"])
        for key in order:
            samples = by_key[key]
            n = len(samples)
            prefix = list(key)
            if n == 0:
                # all trials failed; emit a row with blanks so the key
                # is still represented.
                w.writerow(prefix + [0, "", "", "", ""])
            elif n == 1:
                # stdev requires n >= 2; with one sample the stat is blank
                # and min == max == the sample itself.
                w.writerow(prefix + [1, samples[0], "", samples[0], samples[0]])
            else:
                w.writerow(prefix + [
                    n,
                    f"{statistics.mean(samples):.1f}",
                    f"{statistics.stdev(samples):.1f}",
                    min(samples), max(samples),
                ])


def discover_nugget_binaries(exec_dir: Path, name_tag: str) -> list:
    """Find every lsms_main-nugget-<name_tag>-<id>-exec in exec_dir.

    Returns a sorted list of (id, absolute_path) tuples. The <id> piece
    is what the markers CSV called the row (e.g. region_34), and is what
    --ids on the CLI matches against.

    Filters out non-executable files defensively -- shouldn't normally
    happen, but cmake sometimes leaves stale artefacts around when a
    build fails partway.
    """
    pat = re.compile(rf"^lsms_main-nugget-{re.escape(name_tag)}-(.+)-exec$")
    results = []
    for entry in sorted(exec_dir.iterdir()):
        m = pat.match(entry.name)
        # st_mode & 0o111 == any executable bit (user/group/other). We
        # could narrow to user-exec only, but any of them being set is a
        # good enough sanity check that this is a runnable file.
        if m and entry.is_file() and (entry.stat().st_mode & 0o111):
            results.append((m.group(1), entry.resolve()))
    return results


# ----------------------------------------------------------------------------
# Marker computation (stage 3)
# ----------------------------------------------------------------------------

def parse_ir_bb_csv(path: Path) -> dict:
    """Read build-base/lsms-ir-bb.csv into a dict keyed by BasicBlockID.

    Only used for human-readable annotations in the generated markers
    file -- the actual marker BB selection is driven by analysis-output.csv.
    """
    info = {}
    with path.open() as f:
        for row in csv.DictReader(f):
            info[int(row["BasicBlockID"])] = (
                row["FunctionName"], row["BasicBlockName"],
                int(row["BasicBlockInstCount"]),
            )
    return info


def parse_analysis_csv(path: Path) -> dict:
    """Read analysis-output.csv into per-region parallel lists.

    The file has three rows per region:
      bbv,<r>,0,<exec-count per BB ...>     -- how many times each BB fired
      csv,<r>,0,<inst-count stamp per BB ...>  -- when each BB last fired
      bb_id,<r>,0,<BB IDs ...>              -- which BB column i refers to
    The lists for one region share column ordering, so position i in all
    three refers to the same basic block. The trailing 'region_inst' row
    (which lists per-region totals) is irrelevant here and skipped.
    """
    regions = collections.defaultdict(dict)
    with path.open() as f:
        rdr = csv.reader(f)
        next(rdr)  # discard header line
        for row in rdr:
            if not row or row[0] == "region_inst":
                continue
            kind = row[0]
            region = int(row[1])
            # row[2] is the thread id (always 0 in the single-threaded
            # case). Per-BB data starts at column index 3.
            regions[region][kind] = [int(x) for x in row[3:]]
    return regions


def build_bbv_lookup(regions: dict) -> dict:
    """region -> {bb_id: bbv}. O(1) per-BB lookup; needed because
    cumulative_bbv() asks for one BB's value across many regions, and
    scanning the parallel lists each time would be O(N x regions)."""
    return {
        r: dict(zip(lists["bb_id"], lists["bbv"]))
        for r, lists in regions.items()
    }


def cumulative_bbv(bbv_lookup: dict, bb_id: int, last_inclusive: int) -> int:
    """Sum bbv[bb_id] over regions 0..last_inclusive inclusive.

    Used to compute start_count: the phase-bound hook's counter
    accumulates from nugget_roi_begin_ until the start marker fires, so
    if the same BB fired in earlier regions those entries also count.
    Without this cumulative sum, the start marker would fire prematurely
    -- the per-region bbv of region N-1 alone isn't enough.

    bbv_lookup.get(r, {}).get(bb_id, 0) handles missing keys (BB didn't
    fire in that region, or the region itself doesn't exist).
    """
    total = 0
    for r in range(last_inclusive + 1):
        total += bbv_lookup.get(r, {}).get(bb_id, 0)
    return total


def pick_end_marker(region_data: dict, forbidden_bb_ids=(),
                    margin: float = 1.0) -> tuple:
    """Return (bb_id, count) for a region's end marker.

    "End of region N" is operationally the BB column with the LARGEST
    csv stamp (cumulative inst count at last entry). Its bbv at that
    same column is the per-region execution count: trip the end marker
    that many times after start fires, and you land at the region
    boundary.

    margin: fraction in (0, 1] controlling how loose the end-marker
    selection is. With margin=1.0 (default) only the BB with the
    absolute max csv stamp qualifies -- original behaviour. With e.g.
    margin=0.99, any BB whose csv stamp is >= 0.99 * max_stamp is a
    candidate, and among candidates we pick the one with the SMALLEST
    bbv (fewest hook invocations -> lowest measurement overhead). Ties
    on bbv break toward the larger csv stamp (closer to the true end).
    The boundary shift is benign: region N's chosen end marker becomes
    region N+1's start marker, so the per-region split moves but the
    summed runtime across all regions is unchanged.

    forbidden_bb_ids: skip BBs that would collide with another marker
    in the same row. PhaseBoundPass iterates module BBs once and removes
    a marker from its search list when matched; two markers sharing a
    BB id would leave one unmatched and the pass would error. If every
    BB in the margin window is forbidden, fall back to the original
    "latest non-forbidden BB anywhere" rule so the build stays valid.
    """
    stamps = region_data["csv"]
    bb_ids = region_data["bb_id"]
    bbvs = region_data["bbv"]
    forbidden = set(forbidden_bb_ids)

    max_stamp = max(stamps) if stamps else 0
    threshold = max_stamp * margin  # margin=1.0 => threshold == max_stamp

    candidates = [
        i for i in range(len(stamps))
        if stamps[i] >= threshold and bb_ids[i] not in forbidden
    ]
    if candidates:
        # Smallest bbv wins; on tie, prefer the larger csv stamp so we
        # stay as close as possible to the true region-end ordering.
        i_best = min(candidates, key=lambda i: (bbvs[i], -stamps[i]))
        return bb_ids[i_best], bbvs[i_best]

    # Pathological fallback: every BB in the margin window is forbidden.
    # Walk the full csv-stamp ranking for any non-forbidden BB.
    order = sorted(range(len(stamps)), key=lambda i: stamps[i], reverse=True)
    for i in order:
        if bb_ids[i] not in forbidden:
            return bb_ids[i], bbvs[i]
    i_max = order[0]
    return bb_ids[i_max], bbvs[i_max]


# ----------------------------------------------------------------------------
# Stages
# ----------------------------------------------------------------------------

def stage_base(args) -> None:
    """Build the base toolchain: ir-bb-label-pass attaches a !bb.id
    metadata node to every basic block and dumps a CSV mapping ids back
    to functions. Every later stage depends on this output."""
    print("\n=== Stage 1: base build (ir-bb-label-pass) ===")
    toolchain = TOOLCHAIN_DIR / "nugget-cpu-base.cmake"
    configure(BUILD_BASE, toolchain)
    cmake_build(BUILD_BASE, "lsms_main-base-exec")

    # Verify the two outputs that downstream stages actually consume.
    # The exec itself isn't checked -- it's a side effect of getting the
    # bitcode produced.
    bc = BUILD_BASE / "llvm-bc" / "lsms_main-base-bc.bc"
    bb_csv = BUILD_BASE / "lsms-ir-bb.csv"
    if not bc.exists():
        sys.exit(f"expected output missing: {bc}")
    if not bb_csv.exists():
        sys.exit(f"expected output missing: {bb_csv}")
    print(f"  -> {bc.relative_to(PROJECT_ROOT)}")
    print(f"  -> {bb_csv.relative_to(PROJECT_ROOT)}")


def stage_analysis(args) -> None:
    """Build the analysis toolchain (phase-analysis-pass instruments every
    BB) and run it once against the workload to divide execution into
    fixed-size regions of ~100M instructions each.

    The run takes ~seconds (the full LSMS program runs to completion --
    no early exit here). All console output goes to a log file rather
    than the user's terminal; we just bracket the run with a t0/t1 wall
    timer so the user sees that work is happening.
    """
    print("\n=== Stage 2: analysis build + run (phase-analysis-pass) ===")
    toolchain = TOOLCHAIN_DIR / "nugget-cpu-analysis.cmake"
    # fresh=True because build-cpu-exec is shared with phasebound and
    # base-measure; each stage swaps the toolchain, so we have to wipe
    # CMakeCache.txt to let the new toolchain take effect.
    configure(BUILD_CPU_EXEC, toolchain, fresh=True)
    reuse_base_bc(BUILD_CPU_EXEC)
    cmake_build(BUILD_CPU_EXEC, "lsms_main-analysis-exec")

    binary = (BUILD_CPU_EXEC / "llvm-exec" / "lsms_main-analysis-exec").resolve()
    workdir = (PROJECT_ROOT / args.workload).resolve()
    if not workdir.is_dir():
        sys.exit(f"workload dir does not exist: {workdir}")

    # The phase-bound and baseline hooks write result.txt at end-marker /
    # roi_end time. If we don't clean it before this run, a later stage
    # could mistake a stale file for fresh output. Same for
    # analysis-output.csv (the analysis hook opens it with "w", which is
    # fine, but better to make a deletion explicit so a partial write is
    # never confused for a complete one).
    stale = workdir / "result.txt"
    if stale.exists():
        stale.unlink()

    output = workdir / "analysis-output.csv"
    if output.exists():
        output.unlink()

    log = LOGS_ROOT / "analysis" / "run.log"
    print(f"  running {binary.name} in {workdir.name}/ pinned to core {args.core}")
    print(f"  (this runs the full program; expect ~seconds depending on workload)")
    t0 = time.monotonic()
    proc = run_pinned(binary, [args.input], cwd=workdir, log=log,
                      core=args.core, timeout=args.timeout)
    wall = time.monotonic() - t0
    if proc.returncode != 0:
        sys.exit(f"analysis run failed (exit {proc.returncode}); see {log}")
    if not output.exists():
        sys.exit(f"analysis run did not produce {output}; see {log}")
    print(f"  done in {wall:.1f}s -> {output.relative_to(PROJECT_ROOT)}")


def stage_markers(args) -> None:
    """Read the analysis output, pick one end-marker BB per region, and
    write phasebound-markers.csv. No subprocess invocations here -- this
    is pure data processing, runs in a fraction of a second.
    """
    print("\n=== Stage 3: generate phasebound-markers.csv ===")
    workdir = (PROJECT_ROOT / args.workload).resolve()
    analysis = workdir / "analysis-output.csv"
    ir_bb = BUILD_BASE / "lsms-ir-bb.csv"
    require_file(analysis, "Run --stage analysis first.")
    require_file(ir_bb, "Run --stage base first.")

    bb_info = parse_ir_bb_csv(ir_bb)
    regions = parse_analysis_csv(analysis)
    bbv_lookup = build_bbv_lookup(regions)

    # warmup_bb_id is a dummy because warmup_count=0 makes phase-bound-pass
    # skip the warmup BB lookup entirely (no_warmup_marker=true). The dummy
    # still has to be a real BB id in the module though, because the pass
    # parses it before deciding to skip; BB 0 always exists post-O2.
    #
    # For region 0 we ALSO need a dummy start_bb_id: start_count=0 makes
    # the hook fire start immediately at nugget_roi_begin_ and ignore any
    # hits on start_bb_id, but the pass still instruments the BB. Picking
    # BB 1 keeps it distinct from the warmup dummy and from any plausible
    # region-0 end marker.
    DUMMY_WARMUP_BB = 0
    DUMMY_START_BB_ROW0 = 1

    # Build the CSV body in memory so we can write it atomically. CMake's
    # file(STRINGS ...) reads ASCII; em-dashes etc. confuse it, so the
    # comment headers below stay ASCII-only.
    margins = args.marker_margins_list
    lines = [
        "# PhaseBoundPass marker definitions -- one row per (margin, region).",
        "# Auto-generated by nugget-pipeline.py --stage markers.",
        "#",
        "# Layout: row for region N measures from the end-marker of region (N-1)",
        "# to the end-marker of region N. Region 0 has no previous region, so it",
        "# uses start_count=0 (the hook fires start immediately at nugget_roi_begin_).",
        "# warmup_count is 0 for every row -- the pass skips the warmup BB lookup,",
        "# so warmup_bb_id is a dummy placeholder.",
        "#",
        f"# --marker-margins: {','.join(str(m) for m in margins)}. For each margin, end_bb_id",
        "# is the BB with the smallest bbv among BBs whose csv stamp is >= margin% of",
        "# the region's max csv stamp. margin=100 recovers 'BB with the largest csv",
        "# stamp (entered last)'; smaller margins trade a tiny boundary shift for",
        "# fewer marker-hook calls. CMake's nugget_create_phasebound_execs_from_csv",
        "# appends '-m<margin>' to the row id so (margin, region) -> distinct binary.",
        "#",
        "# end_count: that BB's bbv in this region (per-region count).",
        "# start_count: CUMULATIVE bbv of the start BB across regions 0..N-1; the",
        "# hook counter accumulates from nugget_roi_begin_ until start fires.",
        "margin,id,warmup_bb_id,warmup_count,start_bb_id,start_count,end_bb_id,end_count",
    ]

    total_rows = 0
    for m_int in margins:
        margin = m_int / 100.0
        # Compute end markers in region order. For region N (N >= 1), forbid
        # region (N-1)'s end-marker BB -- otherwise start_bb_id == end_bb_id
        # in row N and the pass errors. pick_end_marker() falls back to the
        # next-largest csv stamp when needed. Recomputed per-margin because
        # the candidate set (and thus the picked BBs) depends on the margin.
        end_markers = {}
        for r_idx in sorted(regions):
            if r_idx == 0:
                forbidden = (DUMMY_START_BB_ROW0,)
            else:
                forbidden = (end_markers[r_idx - 1][0],)
            end_markers[r_idx] = pick_end_marker(regions[r_idx],
                                                 forbidden_bb_ids=forbidden,
                                                 margin=margin)

        lines.append(f"# --- margin={m_int}% ({len(end_markers)} regions) ---")
        for r_idx in sorted(end_markers):
            end_bb, end_count = end_markers[r_idx]
            fn, bbname, _ = bb_info.get(end_bb, ("?", "?", 0))
            bbname = bbname or "<entry>"
            if r_idx == 0:
                warmup_bb = DUMMY_WARMUP_BB
                start_bb = DUMMY_START_BB_ROW0
                start_count = 0
            else:
                warmup_bb = DUMMY_WARMUP_BB
                start_bb = end_markers[r_idx - 1][0]
                # Cumulative because the hook counter doesn't reset until a
                # marker fires; counting only region (N-1)'s bbv would fire
                # start too early whenever start_bb also fired in earlier
                # regions.
                start_count = cumulative_bbv(bbv_lookup, start_bb, r_idx - 1)
            # Inline comment row before each data row so a human reading the
            # CSV can see what function the end marker lives in without
            # cross-referencing lsms-ir-bb.csv.
            lines.append(
                f"# margin={m_int}%, region_{r_idx:02d} end marker: "
                f"bb={end_bb} in {fn} :: {bbname}"
            )
            lines.append(
                f"{m_int},region_{r_idx:02d},{warmup_bb},0,"
                f"{start_bb},{start_count},{end_bb},{end_count}"
            )
            total_rows += 1

    MARKERS_FILE.write_text("\n".join(lines) + "\n")
    print(f"  -> {MARKERS_FILE.relative_to(PROJECT_ROOT)} "
          f"({total_rows} rows: {len(margins)} margin(s) x "
          f"{len(regions)} regions)")


def _measure_loop(binaries: list, args, workdir: Path, log_dir: Path,
                  trials_outer: bool) -> list:
    """Run each binary `--trials` times under taskset, collecting a row
    per measurement.

    trials_outer=True: for trial in 1..N: for binary in binaries: run.
        Used in the phase-bound stage. Sweeping all binaries each trial
        spreads system-level noise (frequency scaling, page-cache state,
        co-tenant interference) evenly across binaries instead of letting
        whichever nugget happened to run during a noisy spell soak up
        all the variance.
    trials_outer=False: for trial in 1..N: run the single binary.
        Used in the baseline stage where there's only one binary anyway.
    """
    # result.txt is overwritten by every hook run; cleaning it before
    # each invocation guarantees we either get a fresh measurement or
    # see "no-result" status (rather than silently reading the previous
    # trial's number).
    rpath = workdir / "result.txt"
    rows = []

    def one_run(nid, binary, trial):
        """Single binary invocation. Returns one result row."""
        if rpath.exists():
            rpath.unlink()
        # Log naming: <id>.tNN.log for the multi-binary case so logs from
        # different nuggets don't collide; tNN.log for the single-binary
        # baseline case since there's only one id involved.
        log = log_dir / (
            f"{nid}.t{trial:02d}.log" if nid != "_baseline" else f"t{trial:02d}.log"
        )
        t0 = time.monotonic()
        try:
            proc = run_pinned(binary, [args.input], cwd=workdir, log=log,
                              core=args.core, timeout=args.timeout)
            rc = proc.returncode
            timed_out = False
        except subprocess.TimeoutExpired:
            # subprocess.run with timeout= raises rather than returning;
            # capture as a distinct status so we can tell it apart from
            # an exit-N failure downstream.
            rc = None
            timed_out = True
        wall = time.monotonic() - t0
        ns = read_time_ns(rpath)

        # Status precedence: timeout > no-result > non-zero exit > ok.
        # A binary that ran out of wallclock might still have written
        # result.txt partway through but we don't trust the number;
        # similarly a non-zero exit with a number is suspicious.
        if timed_out:
            status = "timeout"
        elif ns is None:
            status = "no-result"
        elif rc not in (0, None):
            status = f"exit-{rc}"
        else:
            status = "ok"
        return {
            "id": nid,
            "trial": trial,
            "time_ns": ns if ns is not None else "",
            "exit_code": rc if rc is not None else "",
            "status": status,
            "wall_s": f"{wall:.3f}",
            "log": str(log),
        }

    if trials_outer:
        # Phase-bound case: trial-major iteration order. Print the trial
        # banner up front so the user can see progress at a glance even
        # with hundreds of total runs (35 nuggets x 10 trials = 350 runs).
        for trial in range(1, args.trials + 1):
            print(f"  --- trial {trial}/{args.trials} ---")
            for i, (nid, binary) in enumerate(binaries, 1):
                row = one_run(nid, binary, trial)
                rows.append(row)
                # One status line per measurement so failures are
                # immediately visible during the run.
                if row["status"] == "ok":
                    print(f"  [{i:>2}/{len(binaries)}] {nid} ... "
                          f"{row['time_ns']} ns  (wall {row['wall_s']}s)")
                else:
                    print(f"  [{i:>2}/{len(binaries)}] {nid} ... "
                          f"{row['status']}  (see {row['log']})")
    else:
        # Baseline case: single binary, N trials. No nugget id columns
        # in the user-facing output -- just trial N/M and the time.
        nid, binary = binaries[0]
        for trial in range(1, args.trials + 1):
            row = one_run(nid, binary, trial)
            rows.append(row)
            if row["status"] == "ok":
                print(f"  [{trial:>2}/{args.trials}] {row['time_ns']} ns  "
                      f"(wall {row['wall_s']}s)")
            else:
                print(f"  [{trial:>2}/{args.trials}] {row['status']}  "
                      f"(see {row['log']})")
    return rows


def _annotate_per_id_stdev(rows: list) -> None:
    """Add a stdev_ns column to every raw row.

    Useful when someone inspects phasebound-results.csv directly without
    joining against the summary CSV: the per-id stdev is duplicated across
    each of that id's `--trials` rows so a single eyeball pass shows
    measurement variability alongside the raw numbers. Blank when n < 2
    (statistics.stdev requires at least two samples).

    Grouping is by (margin, id) when margin is present, so two regions
    with the same id but different margins get independent stdevs. Rows
    without a margin field (e.g. baseline) fall through to id-only.
    """
    samples_by_key = collections.defaultdict(list)
    for r in rows:
        if r["status"] == "ok" and r["time_ns"] != "":
            key = (r.get("margin", ""), r["id"])
            samples_by_key[key].append(int(r["time_ns"]))
    key_stdev = {}
    for key, s in samples_by_key.items():
        key_stdev[key] = f"{statistics.stdev(s):.1f}" if len(s) >= 2 else ""
    for r in rows:
        r["stdev_ns"] = key_stdev.get((r.get("margin", ""), r["id"]), "")


def stage_phasebound(args) -> None:
    """Build one phase-bound binary per row in phasebound-markers.csv,
    then run each binary `--trials` times pinned to one core.

    The phase-bound CMake toolchain reads phasebound-markers.csv at
    configure time and registers one target per row, plus an aggregate
    target lsms_main-nugget-<name>-all-exec that depends on all of them
    -- so we only need one `cmake --build` call to build the whole batch.
    """
    print("\n=== Stage 4: phase-bound build + measure ===")
    toolchain = TOOLCHAIN_DIR / "nugget-cpu-phasebound.cmake"
    # markers CSV is consumed at configure time, so it must exist
    # *before* we invoke cmake -- not after.
    require_file(MARKERS_FILE, "Run --stage markers first.")
    # fresh=True because build-cpu-exec is shared with analysis and
    # base-measure; the toolchain swap forces a cache wipe.
    configure(BUILD_CPU_EXEC, toolchain, fresh=True)
    reuse_base_bc(BUILD_CPU_EXEC)
    cmake_build(BUILD_CPU_EXEC, f"lsms_main-nugget-{NAME_TAG}-all-exec")

    exec_dir = BUILD_CPU_EXEC / "llvm-exec"
    binaries = discover_nugget_binaries(exec_dir, NAME_TAG)
    if not binaries:
        sys.exit(f"no nugget binaries found in {exec_dir}")

    # --ids lets the user re-measure a subset of nuggets without rebuilding.
    # Matching is permissive: a user-supplied token matches a binary if it
    # equals either the full discovery id ('region_07-m99') or just the
    # region part ('region_07'). That way `--ids region_05` re-measures
    # region_05 across every margin; `--ids region_05-m99` picks one row.
    if args.ids:
        wanted = {x.strip() for x in args.ids.split(",") if x.strip()}
        def _matches(full_id: str) -> bool:
            region, _ = parse_nugget_id(full_id)
            return full_id in wanted or region in wanted
        matched_tokens = set()
        for full_id, _ in binaries:
            region, _ = parse_nugget_id(full_id)
            if full_id in wanted:
                matched_tokens.add(full_id)
            if region in wanted:
                matched_tokens.add(region)
        missing = wanted - matched_tokens
        if missing:
            available = sorted({nid for nid, _ in binaries})
            sys.exit(
                f"--ids matched no binaries for: {sorted(missing)}\n"
                f"  available full ids: {available}"
            )
        binaries = [(nid, b) for nid, b in binaries if _matches(nid)]

    workdir = (PROJECT_ROOT / args.workload).resolve()
    if not workdir.is_dir():
        sys.exit(f"workload dir does not exist: {workdir}")

    log_dir = LOGS_ROOT / "phasebound"
    log_dir.mkdir(parents=True, exist_ok=True)

    print(f"  {len(binaries)} binary/binaries x {args.trials} trial(s), "
          f"pinned to core {args.core}")
    # trials_outer=True: spread system noise across binaries (see
    # _measure_loop docstring). _measure_loop's row dicts store the full
    # discovery id (e.g. 'region_07-m99') in r["id"]; we split that into
    # separate margin/region columns AFTER measurement so log naming and
    # the inner loop's bookkeeping stay simple.
    rows = _measure_loop(binaries, args, workdir, log_dir, trials_outer=True)
    for r in rows:
        region, margin = parse_nugget_id(r["id"])
        r["id"] = region
        r["margin"] = margin
    _annotate_per_id_stdev(rows)

    # Long-form results: one row per measurement. margin/id are now
    # separate columns; stdev_ns is the per-(margin, id) stdev replicated
    # to every row so a single CSV view shows both raw + variability.
    write_long_form_results(
        rows, PHASEBOUND_RESULTS,
        fieldnames=["margin", "id", "trial", "time_ns", "stdev_ns",
                    "exit_code", "status", "wall_s", "log"],
    )
    print(f"  -> {PHASEBOUND_RESULTS.relative_to(PROJECT_ROOT)} "
          f"({len(rows)} measurements)")

    # Summary: one row per (margin, id) pair. stage_validate sums by
    # margin to produce per-margin totals comparable against the single
    # whole-ROI baseline.
    write_summary(rows, PHASEBOUND_SUMMARY, id_columns=("margin", "id"))
    print(f"  -> {PHASEBOUND_SUMMARY.relative_to(PROJECT_ROOT)}")

    n_fail = sum(1 for r in rows if r["status"] != "ok")
    if n_fail:
        print(f"  WARNING: {n_fail}/{len(rows)} runs did not return a timing; "
              f"check {log_dir.relative_to(PROJECT_ROOT)}/")


def stage_baseline(args) -> None:
    """Build the whole-ROI baseline binary and run it `--trials` times.

    Unlike phase-bound, no LLVM instrumentation pass is applied: the
    base-measure hook simply wraps nugget_roi_begin_/end_ with
    clock_gettime. Same output format (result.txt with "Time taken: N ns"
    and exit(0) at roi_end), which lets the runner code be reused.
    """
    print("\n=== Stage 5: base-measure build + run (whole-ROI baseline) ===")
    toolchain = TOOLCHAIN_DIR / "nugget-cpu-base-measure.cmake"
    # fresh=True because build-cpu-exec is shared with analysis and
    # phasebound; the toolchain swap forces a cache wipe.
    configure(BUILD_CPU_EXEC, toolchain, fresh=True)
    reuse_base_bc(BUILD_CPU_EXEC)
    cmake_build(BUILD_CPU_EXEC, "lsms_main-base-measure-exec")

    binary = (BUILD_CPU_EXEC / "llvm-exec" / "lsms_main-base-measure-exec").resolve()
    workdir = (PROJECT_ROOT / args.workload).resolve()
    if not workdir.is_dir():
        sys.exit(f"workload dir does not exist: {workdir}")

    log_dir = LOGS_ROOT / "baseline"
    log_dir.mkdir(parents=True, exist_ok=True)

    print(f"  {args.trials} trial(s), pinned to core {args.core}")
    # Pass a single-element binaries list and trials_outer=False because
    # there's nothing to sweep -- just N back-to-back runs of the same
    # binary. The "_baseline" placeholder id is rewritten just below so
    # the summary table reads cleanly.
    rows = _measure_loop([("_baseline", binary)], args, workdir, log_dir,
                         trials_outer=False)

    # Relabel rows with a user-friendly id before writing. We used
    # "_baseline" inside the loop so the log file naming branch (tNN.log
    # vs <id>.tNN.log) could detect this case.
    for r in rows:
        r["id"] = "base-measure"

    # No id column in the raw output -- there's only one id and trial is
    # what differs. extrasaction='ignore' in write_long_form_results
    # drops the unused id/stdev_ns keys from the row dicts.
    write_long_form_results(
        rows, BASE_MEASURE_RESULTS,
        fieldnames=["trial", "time_ns", "exit_code", "status", "wall_s", "log"],
    )
    print(f"  -> {BASE_MEASURE_RESULTS.relative_to(PROJECT_ROOT)} "
          f"({len(rows)} trials)")

    # Summary has one data row (id=base-measure). Baseline is margin-
    # independent, so id_columns is just ("id",) here -- the phasebound
    # summary adds the margin column to its grouping instead.
    write_summary(rows, BASE_MEASURE_SUMMARY, id_columns=("id",))
    print(f"  -> {BASE_MEASURE_SUMMARY.relative_to(PROJECT_ROOT)}")

    n_fail = sum(1 for r in rows if r["status"] != "ok")
    if n_fail:
        print(f"  WARNING: {n_fail}/{len(rows)} runs did not return a timing; "
              f"check {log_dir.relative_to(PROJECT_ROOT)}/")


def stage_validate(args) -> None:
    """Compare Sigma per-region mean to the whole-ROI baseline mean, once
    per margin.

    Reads phasebound-summary (one row per (margin, id)) and base-measure-
    summary (single row), groups phasebound means by margin, sums each
    group, prints a per-margin comparison table, and writes
    validation.csv with one row per margin. No threshold check --
    whether 0.84 % or 5 % is "acceptable" depends on the user's purpose,
    so we just report and let them decide.
    """
    print("\n=== Stage 6: validate (Sigma per-region vs baseline, per margin) ===")
    require_file(PHASEBOUND_SUMMARY, "Run --stage phasebound first.")
    require_file(BASE_MEASURE_SUMMARY, "Run --stage baseline first.")

    # Group phasebound mean_ns by margin. Preserve first-seen order so
    # the validation table follows the order rows were laid down in
    # phasebound-summary (which itself follows --marker-margins descending).
    totals = collections.defaultdict(lambda: {"sum": 0.0, "n": 0})
    margin_order = []
    with PHASEBOUND_SUMMARY.open() as f:
        for row in csv.DictReader(f):
            m = row["mean_ns"]
            if not m:
                continue
            margin = int(row["margin"])
            if margin not in totals:
                margin_order.append(margin)
            totals[margin]["sum"] += float(m)
            totals[margin]["n"] += 1
    if not margin_order:
        sys.exit("phasebound-summary.csv has no successful measurements")

    # base-measure-summary.csv has a single data row; grab its mean and
    # stdev. break ensures we ignore any spurious extra rows.
    base_mean = None
    base_stdev = None
    with BASE_MEASURE_SUMMARY.open() as f:
        for row in csv.DictReader(f):
            if row["mean_ns"]:
                base_mean = float(row["mean_ns"])
                base_stdev = float(row["stdev_ns"]) if row["stdev_ns"] else None
            break
    if base_mean is None:
        sys.exit("base-measure-summary.csv has no successful measurement")

    # Aligned columns for the human-readable comparison. >20 pads to a
    # consistent width and the comma separator makes 9- and 10-digit
    # nanosecond counts readable at a glance.
    print()
    if base_stdev is not None:
        print(f"  base-measure (whole ROI):       {base_mean:>20,.0f} ns "
              f"= {base_mean/1e9:.3f} s  (stdev {base_stdev:,.0f} ns)")
    else:
        print(f"  base-measure (whole ROI):       {base_mean:>20,.0f} ns "
              f"= {base_mean/1e9:.3f} s")
    for margin in margin_order:
        total = totals[margin]["sum"]
        n_rows = totals[margin]["n"]
        diff = total - base_mean
        pct = (diff / base_mean) * 100.0
        print(f"  margin={margin:>3}%, sum ({n_rows} rows):  {total:>20,.0f} ns "
              f"= {total/1e9:.3f} s   diff {diff:>+15,.0f} ns ({pct:+.2f} %)")
    print()

    # CSV for downstream tools / plotting. One row per margin so it's
    # easy to plot accuracy-vs-overhead curves: x = margin, y = pct.
    with VALIDATION_FILE.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["margin", "base_measure_mean_ns", "base_measure_stdev_ns",
                    "phasebound_sum_ns", "phasebound_n_rows",
                    "difference_ns", "difference_pct"])
        for margin in margin_order:
            total = totals[margin]["sum"]
            n_rows = totals[margin]["n"]
            diff = total - base_mean
            pct = (diff / base_mean) * 100.0
            w.writerow([
                margin,
                f"{base_mean:.0f}",
                f"{base_stdev:.0f}" if base_stdev is not None else "",
                f"{total:.0f}",
                n_rows,
                f"{diff:.0f}",
                f"{pct:.4f}",
            ])
    print(f"  -> {VALIDATION_FILE.relative_to(PROJECT_ROOT)}")


# ----------------------------------------------------------------------------
# Dispatch
# ----------------------------------------------------------------------------

# Ordered: this is the canonical pipeline order, also used to populate the
# --stage argparse choices and the default "run them all" behaviour. Adding
# a new stage means appending a (name, func) tuple here.
STAGES = [
    ("base", stage_base),
    ("analysis", stage_analysis),
    ("markers", stage_markers),
    ("phasebound", stage_phasebound),
    ("baseline", stage_baseline),
    ("validate", stage_validate),
]


def main() -> None:
    p = argparse.ArgumentParser(
        description=__doc__,
        # Preserve the docstring's formatting (the stage table etc.)
        # instead of letting argparse re-wrap it.
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--stage",
                   choices=[name for name, _ in STAGES],
                   help="Run only this stage. Default: run all stages in order.")
    p.add_argument("--workload", default="experiment/FePt",
                   help="Workload directory relative to project root. "
                        "Default: experiment/FePt.")
    p.add_argument("--input", default="i_lsms_express_gpu",
                   help="Workload input file (argv[1] of every binary). "
                        "Default: i_lsms_express_gpu (matches run.sh).")
    p.add_argument("--core", type=int, default=8,
                   help="CPU core to pin runs to via taskset. Default: 8.")
    p.add_argument("--trials", type=int, default=10,
                   help="Trials per measurement stage. Default: 10.")
    p.add_argument("--ids", default="",
                   help="Comma-separated nugget ids to run in the phasebound "
                        "stage (e.g. region_34). Default: all discovered.")
    p.add_argument("--marker-margins", default="100",
                   help="Comma-separated integer percents in (0, 100] for "
                        "end-marker selection (e.g. '100,99,95'). For each "
                        "margin, the markers stage picks per-region end BBs "
                        "from those whose csv stamp is >= margin%% of max, "
                        "favouring the smallest bbv (lowest hook overhead). "
                        "All margins' rows go into one combined "
                        "phasebound-markers.csv (tagged via a margin column) "
                        "and the phase-bound build produces one binary per "
                        "(margin, region) pair in the same build dir. "
                        "Default '100' = single sweep, original behaviour.")
    p.add_argument("--timeout", type=float, default=None,
                   help="Per-binary wall-clock timeout in seconds. Default: none.")
    args = p.parse_args()

    # Quick guard-rail checks so we fail at startup rather than midway
    # through a stage when we discover something is missing.
    if args.trials < 1:
        sys.exit("--trials must be >= 1")
    # Parse --marker-margins into a deduplicated, sorted list of ints.
    # Sorting is descending so 100 (current behaviour) shows first in
    # the output CSVs, which matches how users typically eyeball the
    # accuracy/overhead tradeoff (tightest first, loosest last).
    try:
        margins = sorted(
            {int(x.strip()) for x in args.marker_margins.split(",") if x.strip()},
            reverse=True,
        )
    except ValueError:
        sys.exit("--marker-margins must be integers (e.g. '100,99,95')")
    if not margins:
        sys.exit("--marker-margins is empty")
    for m in margins:
        if not (0 < m <= 100):
            sys.exit(f"--marker-margins value {m} out of range (must be in (0, 100])")
    args.marker_margins_list = margins
    if shutil.which("taskset") is None:
        sys.exit("taskset not found in PATH; install util-linux")
    if shutil.which("cmake") is None:
        sys.exit("cmake not found in PATH")

    # Make sure the CSV destination exists before any stage tries to
    # write to it. Cheap and idempotent.
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    # If --stage is set, run only that one; otherwise walk the full
    # pipeline. The choices= constraint on argparse ensures we can't get
    # an unknown name here.
    if args.stage:
        stages_to_run = [(n, f) for n, f in STAGES if n == args.stage]
    else:
        stages_to_run = STAGES

    for name, func in stages_to_run:
        func(args)

    print("\nDone.")


if __name__ == "__main__":
    main()
