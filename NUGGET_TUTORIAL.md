# Nugget tutorial: per-region nuggets vs. whole-ROI baseline

This tutorial walks through the full Nugget workflow on LSMS-bench-adam, end
to end: build a labeled bitcode, profile the program into regions, generate
per-region marker definitions, build and measure one nugget per region, build
a whole-ROI baseline, and finally show that the sum of the per-region
measurements matches the baseline.

Every stage is driven by one Python script:
[nugget-pipeline.py](nugget-pipeline.py). You can run the whole thing in one
shot or run a single stage with `--stage <name>`.

For the running example we use the FePt workload (35 regions of ~100M
instructions each). The worked example at the end sweeps four marker
margins in one pass and gets per-region sums **within 0.15 %–1.56 %** of
the un-instrumented baseline depending on the margin (lower marker overhead
at tighter margins, looser regions at looser ones).

## Prerequisites and assumptions

The pipeline only works under a small set of assumptions; verify these before
running anything.

### Directory layout

Everything the pipeline generates is anchored under `experiment/`; the
project root stays focused on source/scripts/docs.

```
LSMS-bench-adam/
├── nugget-pipeline.py            # driver
├── NUGGET_TUTORIAL.md            # this file
├── CMakeLists.txt
├── nugget-function.cmake
├── toolchain/Nugget/             # .cmake toolchains + hook .c files
├── FePt/                         # canonical workload (auto-seeds experiment/FePt/)
├── build-base/                   # base bc + lsms-ir-bb.csv (stage 1 only)
├── build-cpu-exec/               # shared: analysis + phasebound + base-measure
└── experiment/
    ├── FePt/                     # working copy (auto-seeded on first run)
    │   ├── i_lsms_express_gpu    # input
    │   └── analysis-output.csv   # emitted by the analysis run
    ├── data/                     # every CSV pipeline result
    └── nugget-pipeline-logs/     # per-trial stdout+stderr
```

The driver auto-creates `experiment/data/` and `experiment/nugget-pipeline-logs/`
on first use. The workload directory (`experiment/FePt/` by default) is
**auto-seeded from a same-named directory at the repo root**: on the first
stage that needs the workload, if `experiment/FePt/` is missing the driver
runs `shutil.copytree(FePt, experiment/FePt)` and prints a one-line notice.
Subsequent runs reuse the copy in place. This keeps the canonical workload
at the repo root (the historical layout) while every pipeline artefact lives
under `experiment/`. If neither location exists, the driver bails with a
clear message.

`build-base/` is dedicated to stage 1. `build-cpu-exec/` is shared by stages
2/4/5 — each one reconfigures with its own toolchain via `cmake --fresh`,
which wipes `CMakeCache.txt` but keeps build artefacts so unchanged work is
reused.

All paths in `nugget-pipeline.py` and the toolchain `.cmake` files are
anchored at the file's own location (`Path(__file__).parent` and
`${CMAKE_CURRENT_LIST_DIR}` respectively). No project-internal absolute paths
are hardcoded — the repo can live anywhere on disk.

### Sibling repo

The Nugget LLVM passes are built in a sibling repository:

```
.../experiment/
├── LSMS-bench-adam/                       # this repo
└── Nugget-LLVM-passes/
    └── build/NuggetPasses.so              # required shared library
```

The toolchain files point at
`${CMAKE_CURRENT_LIST_DIR}/../../../Nugget-LLVM-passes/build/NuggetPasses.so`,
so this layout is required. Build that repo first if `NuggetPasses.so` is
missing.

### Software prerequisites

- LLVM-18 tools on `$PATH`: `clang`, `clang++`, `flang-new`, `llvm-link`,
`opt`, `llc`.
- MPI (`mpicxx`, `mpifort`), an OpenMP runtime (`libomp.so`),
`taskset` (from `util-linux`), and `python3 >= 3.10`.
- A workload directory either at the repo root (e.g. `FePt/`) or under
`experiment/` (e.g. `experiment/FePt/`). Default workload:
`experiment/FePt/` containing `i_lsms_express_gpu`. If only the root copy
exists, the driver seeds `experiment/<name>/` from it on first use.
- The application source already wraps its region-of-interest in
`nugget_roi_begin_()` / `nugget_roi_end_()` calls — Nugget hooks override
these symbols at link time, so the application doesn't need to know any
Nugget details.

## Passes vs. hooks

A central concept: the LLVM passes only inject *calls* to specific symbols
(`nugget_init`, `nugget_roi_begin_`, `nugget_roi_end_`, `nugget_bb_hook`,
`nugget_warmup_marker_hook`, `nugget_start_marker_hook`,
`nugget_end_marker_hook`). What those calls actually *do* — what gets timed,
what gets written to disk, when the program exits — is defined entirely by
the **hook .c files** in [toolchain/Nugget/hooks/](toolchain/Nugget/hooks/)
that link those symbols. Swapping hooks changes the output without changing
the pass.

Four hooks live in this repo, one per pipeline stage. The tutorial introduces
each one in its stage; a summary table is in the [Reference section](#reference).

## Pipeline at a glance

```
source  ->  base bc (BB-labeled)  ->  analysis bc  ->  analysis-output.csv
                                                          |
                                                          v
                                                    marker CSV
                                                          |
                                                          v
              base-measure bc (whole-ROI timer)   phase-bound bc x N (per-region timer)
                            |                                  |
                            v                                  v
                       baseline.ns                  per-region.ns (sum)
                            \________________   _________________/
                                             \ /
                                          compare
```

Six pipeline stages map onto the workflow:


| #   | `--stage`    | What it does                                           | Hook                                                    |
| --- | ------------ | ------------------------------------------------------ | ------------------------------------------------------- |
| 1   | `base`       | label every BB; emit BB-id map                         | [base.c](toolchain/Nugget/hooks/base.c)                 |
| 2   | `analysis`   | profile the program into regions of ~100M inst each    | [analysis.c](toolchain/Nugget/hooks/analysis.c)         |
| 3   | `markers`    | turn analysis output into per-region marker rows       | (script only)                                           |
| 4   | `phasebound` | build + measure one nugget per region                  | [phase-bound.c](toolchain/Nugget/hooks/phase-bound.c)   |
| 5   | `baseline`   | build + measure the un-instrumented whole-ROI baseline | [base-measure.c](toolchain/Nugget/hooks/base-measure.c) |
| 6   | `validate`   | sum per-region means; compare to baseline              | (script only)                                           |


## Running the pipeline

To run the whole pipeline in one go (this is the common case):

```bash
python3 nugget-pipeline.py
```

To run a single stage:

```bash
python3 nugget-pipeline.py --stage <base|analysis|markers|phasebound|baseline|validate>
```

Useful flags: `--workload experiment/FePt`, `--input i_lsms_express_gpu`,
`--core 8`, `--trials 10`, `--ids region_34` (phasebound-only filter, see
below), `--timeout 60`, `--marker-margins 100,99,95` (markers + phasebound,
see [Stage 3](#stage-3--generate-the-marker-csv)).

The rest of this tutorial walks through each stage.

## Stage 1 — base build (label every BB)

```bash
python3 nugget-pipeline.py --stage base
```

This configures `build-base/` with
[toolchain/Nugget/nugget-cpu-base.cmake](toolchain/Nugget/nugget-cpu-base.cmake)
and builds the `lsms_main-base-exec` target. The toolchain enables
`ir-bb-label-pass`, which attaches a `!bb.id` metadata node to every basic
block and emits a CSV mapping every BB id back to its function and source
location.

Outputs:

- `build-base/llvm-bc/lsms_main-base-bc.bc` — the labeled bitcode. Every
later stage reuses this file (the analysis / phase-bound / baseline builds
copy it into `build-cpu-exec/llvm-bc/`).
- `build-base/lsms-ir-bb.csv` —
`FunctionName,FunctionID,BasicBlockName,BasicBlockInstCount,BasicBlockID`.
The marker stage uses this to sanity-check that a chosen BB lives in a
sensible function.
- `build-base/llvm-exec/lsms_main-base-exec` — a labeled executable that
just prints `ROI begin / ROI end`.

### Hook used: [base.c](toolchain/Nugget/hooks/base.c)

Minimal. Defines `nugget_roi_begin_` and `nugget_roi_end_` as bare functions
that just print a message. The base stage isn't measuring anything; the hook
exists only so the application's existing `nugget_roi_begin_()` /
`nugget_roi_end_()` call sites resolve at link time. `ir-bb-label-pass`
itself emits its data (`lsms-ir-bb.csv`) at *compile* time, not at run time.

## Stage 2 — analysis build + run

```bash
python3 nugget-pipeline.py --stage analysis
```

Configures `build-cpu-exec/` with
[toolchain/Nugget/nugget-cpu-analysis.cmake](toolchain/Nugget/nugget-cpu-analysis.cmake)
(using `cmake --fresh` to overwrite whatever toolchain the dir was last
configured with), reuses `build-base/llvm-bc/` via `shutil.copytree`, builds
`lsms_main-analysis-exec`, then runs it once against the workload under
`taskset -c <core>` (default core 8).

Output: `<workload>/analysis-output.csv`. Row shape:

- `bbv,<region>,0,<exec-count-per-BB...>` — per-region execution count vector
(only BBs that fired in this region appear).
- `csv,<region>,0,<inst-stamp-per-BB...>` — cumulative instruction-count
stamp at which each BB was last entered in this region.
- `bb_id,<region>,0,<BB-IDs...>` — the parallel BB-id list for the two
vectors above.
- Trailing `region_inst,N/A,N/A,...` row giving total inst count per region.

Crucially, **bbv values are per-region**: each region uses a fresh
zero-initialized counter array, so a BB that fired in region 0 doesn't
inherit its count into region 1.

In our FePt run, this produced **35 regions** of ~100M instructions each.

### Hook used: [analysis.c](toolchain/Nugget/hooks/analysis.c)

This is what *writes* `analysis-output.csv`. The pass only injects the calls
— the hook decides what to do with them.

- `nugget_init(total_bb_count)` — called at the end of `nugget_roi_begin_`
(the pass injects this call). Allocates per-region BBV / csv-stamp /
counter arrays.
- `nugget_roi_begin_` — opens `analysis-output.csv` in cwd, prints "ROI begin",
arms collection (`if_start = 1`).
- `nugget_bb_hook(inst_count, bb_id, threshold)` — injected by
`phase-analysis-pass` at every BB. Increments the IR instruction counter,
records `bbv[bb_id]++` and `count_stamp[bb_id] = IR_inst_counter`. When
the inst counter crosses `threshold` (the `interval_length=100000000` pass
argument), `process_data()` swaps `bbv` and `count_stamp` to the next
fresh slot and resets the inst counter — that's why bbv is per-region.
- `nugget_roi_end_` — flushes the last partial region, writes everything to
CSV, closes the file.
- A re-entrance guard (`in_hook`) keeps the hook's own helpers (`write_down_data`,
`process_data`) from recursively retriggering `nugget_bb_hook`.

If you wanted a different analysis (e.g. logging to a perf-counter PMU
instead of writing CSV), you'd write a new `.c` file with the same symbol
names — no pass changes required.

## Stage 3 — generate the marker CSV

```bash
python3 nugget-pipeline.py --stage markers --marker-margins 100,99,95
```

Reads `<workload>/analysis-output.csv` and `build-base/lsms-ir-bb.csv`,
writes `experiment/data/phasebound-markers.csv` — one row per (margin,
region) pair. With the default `--marker-margins 100` you get exactly one
row per region (35 rows for FePt); with `--marker-margins 100,99,95` you
get 105 rows, all in the same CSV.

The algorithm:

1. **End marker for region N, given a margin M (a percent in (0, 100])**:
   - Threshold = M% × (the largest csv stamp in region N).
   - Candidates = every BB in region N whose csv stamp is ≥ threshold and
     isn't forbidden (see below).
   - Pick the candidate with the **smallest bbv** (fewest hook invocations
     → lowest measurement overhead). Ties on bbv break toward the larger
     csv stamp (closer to the true region-end ordering).

   At M=100 only the BB with the absolute largest csv stamp qualifies, so
   the behaviour collapses to "BB entered last in the region" — the
   original Nugget rule. Smaller M widens the candidate window and trades
   a tiny boundary shift for fewer marker-hook calls.
2. **Start marker for region N (N >= 1)**: the same BB as the end marker for
   region N-1 *at the same margin*. Its `start_count` is the **cumulative**
   bbv across regions 0..N-1, because the phase-bound hook's counter
   accumulates from `nugget_roi_begin_` until start fires — using a
   per-region count alone would fire start prematurely if the BB also fired
   in earlier regions.
3. **Region 0**: no previous region, so `start_count=0`. The hook
   interprets this as "fire start immediately at `nugget_roi_begin_`" and
   ignores any hits on `start_bb_id` (which is a dummy).
4. **Warmup**: `warmup_count=0` for every row. The pass skips the warmup BB
   lookup, so `warmup_bb_id` is a dummy 0.
5. **Distinct-BB constraint**: PhaseBoundPass requires the three marker BB
   ids in one row to be distinct. When the natural pick collides with the
   previous row's end (which would make `start_bb_id == end_bb_id`), the
   selector falls back to the next-best candidate, and if every candidate in
   the margin window is forbidden, walks the full csv-stamp ranking for any
   non-forbidden BB.
6. **Boundary shift is benign**: region N's chosen end marker becomes region
   N+1's start marker, so the per-region split moves but the summed runtime
   across all regions for that margin is unchanged.

The resulting CSV has 8 columns. The first column is the margin (so one
file can hold multiple sweeps); rows for one margin are contiguous:

```csv
margin,id,warmup_bb_id,warmup_count,start_bb_id,start_count,end_bb_id,end_count
100,region_00,0,0,1,0,33276,242128
100,region_01,0,0,33276,242128,33287,47301
...
99,region_00,0,0,1,0,33276,242128
99,region_01,0,0,33276,242128,33287,47301
...
95,region_31,0,0,33222,58,30045,1
...
```

Notice how at M=95 some end_count values collapse to single digits — those
are the rows where a low-bbv BB in the margin window replaces a hot-loop
BB, eliminating most of the marker-hook calls for that region.

## Stage 4 — build and measure the phase-bound nuggets

```bash
python3 nugget-pipeline.py --stage phasebound --trials 10
```

This stage does **both** the build and the measurement.

The build half configures `build-cpu-exec/` (with `cmake --fresh`) using
[toolchain/Nugget/nugget-cpu-phasebound.cmake](toolchain/Nugget/nugget-cpu-phasebound.cmake),
reuses `build-base/llvm-bc/`, and creates one binary per row in the markers
CSV. With a multi-margin CSV the CMake helper appends `-m<margin>` to the
per-row id so each (margin, region) pair maps to a distinct binary —
e.g. `lsms_main-nugget-time-region_07-m99-exec` — and all of them are
built in a single configure pass. The merged hook+base bitcode is named
on the toolchain's hook name only (`lsms_main-nugget-time-hooked-bc`), so
the bc-merge runs **once** and is reused across every per-row binary.
An aggregate `lsms_main-nugget-time-all-exec` target depends on every
per-(margin, region) exec.

The measurement half discovers every nugget binary, then runs each one
`--trials` times pinned to `--core`. The order is **trial-major**: every
trial sweeps all binaries once. That spreads system-level noise evenly
across binaries instead of letting one nugget catch all the bad luck.

Outputs (CSVs carry a `margin` column so multiple sweeps live side-by-side
in one file; log filenames encode the margin too):

- `experiment/data/phasebound-results.csv` — long-form: one row per
  measurement, columns
  `margin, id, trial, time_ns, stdev_ns, exit_code, status, wall_s, log`.
  The `stdev_ns` column is the per-(margin, id) stdev across trials,
  replicated to every raw row.
- `experiment/data/phasebound-summary.csv` — one row per (margin, id)
  pair, columns `margin, id, n_ok, mean_ns, stdev_ns, min_ns, max_ns`.
- `experiment/nugget-pipeline-logs/phasebound/<id>-m<margin>.t<NN>.log`
  — per-trial stdout + stderr from each binary.

To rerun a subset without rebuilding, use `--ids region_34`
(comma-separated for multiple). Matching is permissive: a token matches
if it equals either the full discovery id (`region_07-m99`) or just the
region part (`region_07`). So `--ids region_05` re-measures region_05
across **every** margin in the current build; `--ids region_05-m99`
picks one specific row.

### Phase-bound toolchain options

Set inside
[toolchain/Nugget/nugget-cpu-phasebound.cmake](toolchain/Nugget/nugget-cpu-phasebound.cmake);
no `-D` overrides (paths are hardcoded for reproducibility).


| Variable                         | Default                                  | Purpose                                                                                                                        |
| -------------------------------- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `NUGGET_PHASEBOUND_HOOK_NAME`    | `"time"`                                 | Becomes `<name>` in `lsms_main-nugget-<name>-<id>-exec`. Tag to distinguish builds that link different hook .c files.          |
| `NUGGET_PHASEBOUND_HOOK_SOURCE`  | `hooks/phase-bound.c`                    | The C file that defines `nugget_init`, `nugget_*_marker_hook`, `nugget_roi_begin_`, `nugget_roi_end_`.                         |
| `NUGGET_PHASEBOUND_LABEL_ONLY`   | `OFF`                                    | Global toggle. `ON` makes phase-bound-pass insert inline assembly labels (`nugget_warmup_marker:` etc.) instead of hook calls. |
| `NUGGET_PHASEBOUND_MARKERS_FILE` | `experiment/data/phasebound-markers.csv` | Hardcoded marker CSV path (anchored at the toolchain file's location via `${CMAKE_CURRENT_LIST_DIR}`).                         |


### Hook used: [phase-bound.c](toolchain/Nugget/hooks/phase-bound.c)

This hook produces both the per-region timing data and the early-exit
behavior. The pass instruments only three BBs (warmup, start, end marker);
the hook turns the three marker callbacks into a state machine plus a timer.

- `nugget_init(warmup_count, start_count, end_count)` — injected at the end
of `nugget_roi_begin_`. Stores the three thresholds and picks the initial
state:
  - `warmup==0 && start==0` -> fire `start_event()` immediately (records
  `CLOCK_MONOTONIC` start time) and arm end.
  - `warmup==0` -> arm start.
  - otherwise -> arm warmup (full warmup -> start -> end flow).
- `nugget_warmup_marker_hook` / `nugget_start_marker_hook` /
`nugget_end_marker_hook` — each one is a counter on a shared
`counter` variable. When the active phase's counter reaches its
threshold, the hook fires that phase's event and resets the counter for
the next phase.
- On end-marker fire: records the `CLOCK_MONOTONIC` end time, computes the
ns difference, prints `Time taken: <N> ns`, writes the same string to
`result.txt` in the cwd, then `exit(0)`. **That early exit is what makes
each phase-bound run finish in milliseconds instead of running the whole
program.**

Every per-region timing number in this stage is produced by this hook. A
different hook with the same symbol names could just as easily record
hardware counters, write a trace, or invoke a different timer.

## Stage 5 — build and run the whole-ROI baseline

```bash
python3 nugget-pipeline.py --stage baseline --trials 10
```

Configures `build-cpu-exec/` (with `cmake --fresh`) using
[toolchain/Nugget/nugget-cpu-base-measure.cmake](toolchain/Nugget/nugget-cpu-base-measure.cmake),
reuses `build-base/llvm-bc/`, builds `lsms_main-base-measure-exec`. **No
instrumentation pass is applied** — the bitcode goes straight to an
executable. The hook does all the work.

Outputs:

- `experiment/data/base-measure-results.csv` — one row per trial: `trial, time_ns, exit_code, status, wall_s, log`.
- `experiment/data/base-measure-summary.csv` — single data row: `n_ok, mean_ns, stdev_ns, min_ns, max_ns`.
- `experiment/nugget-pipeline-logs/baseline/t<NN>.log` — per-trial logs.

### Hook used: [base-measure.c](toolchain/Nugget/hooks/base-measure.c)

Defines `nugget_roi_begin_` to record `CLOCK_MONOTONIC` at entry, and
`nugget_roi_end_` to record `CLOCK_MONOTONIC` at exit, compute the ns
difference, print `Time taken: <N> ns`, write the same single-line
`result.txt` format the phase-bound hook uses (so downstream parsers can
read both interchangeably), then `exit(0)`.

Because no pass instruments anything between `roi_begin` and `roi_end`,
this hook measures the **un-instrumented** runtime of the application's
ROI — the cleanest baseline.

## Stage 6 — validate (sum of regions vs. baseline, per margin)

```bash
python3 nugget-pipeline.py --stage validate
```

Reads `experiment/data/phasebound-summary.csv` and
`experiment/data/base-measure-summary.csv`, **groups phasebound rows by
margin**, sums `mean_ns` within each margin, compares each sum to the
single baseline mean, prints a per-margin comparison table, and writes
`experiment/data/validation.csv` with one row per margin (columns:
`margin, base_measure_mean_ns, base_measure_stdev_ns, phasebound_sum_ns,
phasebound_n_rows, difference_ns, difference_pct`). Easy to plot
accuracy-vs-margin curves directly from that CSV.

### Worked example: FePt, 35 regions × 4 margins, 10 trials each

The numbers below come from a real run with
`--marker-margins 0,100,99,95 --trials 10 --core 8`:

```
base-measure (whole ROI):              1,505,462,107 ns = 1.505 s  (stdev 7,487,890 ns)
margin=  0%, sum (35 rows):         1,528,930,500 ns = 1.529 s   diff     +23,468,393 ns (+1.56 %)
margin=100%, sum (35 rows):         1,515,521,557 ns = 1.516 s   diff     +10,059,450 ns (+0.67 %)
margin= 95%, sum (35 rows):         1,499,890,222 ns = 1.500 s   diff      -5,571,885 ns (-0.37 %)
margin= 99%, sum (35 rows):         1,503,256,607 ns = 1.503 s   diff      -2,205,500 ns (-0.15 %)
```

Reading across the margins:

- **M=100** (original "BB entered last" rule) lands at **+0.67 %**, with
  the residual gap explained by marker-hook overhead: each phase-bound
  binary calls `nugget_init` once plus the three marker hooks (warmup,
  start, end) on every entry to their BBs. The base-measure hook has none
  of that — just two `clock_gettime` calls bracketing the entire ROI.
- **M=99 and M=95** widen the candidate window enough for the picker to
  swap hot-loop end markers for low-bbv ones (sometimes bbv=1). That
  collapses the per-row marker-hook count and the residual goes
  **negative** — the sum is now *under* the baseline by 0.15–0.37 % (well
  inside the 0.50 % single-σ noise of the 10-trial baseline). Boundaries
  shift slightly between regions but the total time is preserved.
- **M=0** lets the picker grab the absolute lowest-bbv BB anywhere in
  the region. That can land on a cold init BB at the start of the region,
  shrinking the measured "region" to almost nothing and pushing the rest
  into the next row. The sum total still captures the program time but
  per-row semantics are destroyed and the overhead bias grows
  (here, **+1.56 %**) because the chosen markers sit in cold cache lines
  that pay extra each time they're touched. Useful as a stress test;
  not as a production setting.

If you want to inspect the per-margin sums yourself:

```bash
python3 -c "import csv, collections
t = collections.defaultdict(float)
for r in csv.DictReader(open('experiment/data/phasebound-summary.csv')):
    if r['mean_ns']: t[r['margin']] += float(r['mean_ns'])
for m, s in sorted(t.items()): print(f'margin={m:>3}%  sum={s:,.0f} ns')"
```

## Reference

### Hooks at a glance


| Hook                                                    | Used by toolchain                                                               | Symbols defined                                               | Side effects                                        |
| ------------------------------------------------------- | ------------------------------------------------------------------------------- | ------------------------------------------------------------- | --------------------------------------------------- |
| [base.c](toolchain/Nugget/hooks/base.c)                 | [nugget-cpu-base.cmake](toolchain/Nugget/nugget-cpu-base.cmake)                 | `nugget_roi_begin_`, `nugget_roi_end_`                        | prints only                                         |
| [analysis.c](toolchain/Nugget/hooks/analysis.c)         | [nugget-cpu-analysis.cmake](toolchain/Nugget/nugget-cpu-analysis.cmake)         | + `nugget_init(total_bb_count)`, `nugget_bb_hook`             | writes `analysis-output.csv`                        |
| [phase-bound.c](toolchain/Nugget/hooks/phase-bound.c)   | [nugget-cpu-phasebound.cmake](toolchain/Nugget/nugget-cpu-phasebound.cmake)     | + `nugget_warmup/start/end_marker_hook` (3-arg `nugget_init`) | writes `result.txt`, `exit(0)` at end marker        |
| [base-measure.c](toolchain/Nugget/hooks/base-measure.c) | [nugget-cpu-base-measure.cmake](toolchain/Nugget/nugget-cpu-base-measure.cmake) | `nugget_roi_begin_`, `nugget_roi_end_`                        | writes `result.txt`, `exit(0)` at `nugget_roi_end_` |


### Files touched by the pipeline

- Driver: [nugget-pipeline.py](nugget-pipeline.py)
- Toolchain files: [toolchain/Nugget/](toolchain/Nugget/)
- Hook sources: [toolchain/Nugget/hooks/](toolchain/Nugget/hooks/)
- CMake helpers: [nugget-function.cmake](nugget-function.cmake)

### Adapting to a different workload

```bash
python3 nugget-pipeline.py --workload experiment/<dir> --input <input-file>
```

The workload directory should sit under `experiment/` so all run-time
artefacts stay inside that subtree. You can either put it there directly,
or place it at the repo root with the same basename (`<dir>/`) — the
driver will seed `experiment/<dir>/` from the root copy on first run
(see [Directory layout](#directory-layout)).

### Adapting to a different application

Copy the four hook files and the four toolchain `.cmake` files from
`toolchain/Nugget/` into your project, add a `NUGGET_BUILD_*` conditional
block in your top-level `CMakeLists.txt` modelled on the existing one in
this repo, then port `nugget-pipeline.py` and replace the binary-name
constants (`lsms_main-*`) with your own target names. The hook contract
(symbols defined and called by the passes) is the same regardless of host
application.

### Adding a different hook kind for the phase-bound stage

To time the same regions with a different mechanism (perf counters, a custom
trace, etc.) while keeping the existing `phasebound-markers.csv`:

1. Copy `toolchain/Nugget/hooks/phase-bound.c` to e.g.
  `hooks/phase-bound-perf.c` and reimplement the six required symbols
   (`nugget_init`, `nugget_warmup_marker_hook`, `nugget_start_marker_hook`,
   `nugget_end_marker_hook`, `nugget_roi_begin_`, `nugget_roi_end_`).
2. Copy `toolchain/Nugget/nugget-cpu-phasebound.cmake` to e.g.
  `nugget-cpu-phasebound-perf.cmake` and change:
  - `NUGGET_PHASEBOUND_HOOK_NAME` (e.g. `"perf"` — becomes `<name>` in the
  output executable name)
  - `NUGGET_PHASEBOUND_HOOK_SOURCE` (point at the new .c file)
3. Point [nugget-pipeline.py](nugget-pipeline.py) at the new toolchain by
  editing the `TOOLCHAIN_DIR / "nugget-cpu-phasebound.cmake"` path in
   `stage_phasebound` (or parameterize it if you need both at once).

The same `phasebound-markers.csv` is reused unless you change
`NUGGET_PHASEBOUND_MARKERS_FILE` in the new toolchain.