# CI Failure Fix Plan

Date: 2026-11-10. Source: `logs_115810236654/`.

## Verified baseline

- `zig build test` exits 0 locally (79/79 tests) and in every CI `Build and test`
  step in the logs. The line `failed command: ... test.exe ... --listen=-` is
  emitted by Zig's build runner when it reaps a killed child process; it is not
  a failing test and it does not fail the step.
- The actual failing steps are the canary fetch step and the three OS-specific
  `Lint the workflows` actionlint runs.

## Bug inventory

| ID | Job / step | Log evidence | Root cause |
|---|---|---|---|
| CI-FETCH | Canary (Zig master) / Fetch dependencies | `error: unrecognized argument: --fetch=all` | `ci.yml` runs `zig build --fetch=all` unconditionally; Zig master 0.18.0-dev no longer accepts it. |
| CI-GLOB | Windows release / Lint the workflows | `could not read ".github/workflows/*.yml": ... syntax is incorrect` | PowerShell does not expand the shell glob; actionlint receives the literal pattern. |
| CI-GO | macOS release / Lint the workflows | `go: command not found` | The macOS runner has no Go; the step assumes it is preinstalled. |
| CI-SC2034 | Ubuntu release / Lint the workflows | `SC2034: branch/include/repo/old_commit appears unused` | Five `while ... read` loops declare fields their bodies never use; actionlint invokes shellcheck and exits 1. |

## Tests to add first (all run by `zig build test`)

The logic lives in `src/util/workflow.zig`, which `src/root.zig` already imports
into the unit suite. Each test reads the real workflow files and asserts the
property that currently fails.

### T-FETCH: canary fetch step is master-safe

Function: `collectUnsupportedFetchFindings(gpa, text, findings)`.

- Parse each job block (2-space job headers under `jobs:`).
- A job whose text contains `version: master` must not contain a non-comment
  line with `zig build --fetch=all`, unless that step also has
  `continue-on-error: true`.
- Test cases: current `ci.yml` (must report the canary fetch step); a pinned
  `version: 0.17.1` job (no finding); a commented `# zig build --fetch=all`
  (no finding); a `run: |` block containing the command (finding); a step with
  `continue-on-error: true` (no finding).

### T-GLOB: lint command is shell-portable

Function: `collectGlobFindings(gpa, text, findings)`.

- Any non-comment line containing `go run` and a `*.yml` or `*.yaml` token is a
  finding: PowerShell passes the literal pattern, so the command is not
  portable.
- Test cases: current `ci.yml` (finding); `actionlint` with no file arguments
  (no finding); quoted `"*.yml"` (finding); a comment (no finding); a
  `run: |` multi-line block (finding).

### T-GO: every `go run` step has a preceding `actions/setup-go`

Function: `collectMissingGoSetupFindings(gpa, text, findings)`.

- Per job block, a `go run` line before any `actions/setup-go` line is a
  finding.
- Test cases: current `ci.yml` (finding in both jobs); a job with
  `actions/setup-go` before the lint step (no finding); setup after the lint
  step (finding); a commented `go run` (no finding); a `run: |` block with
  `go run` (finding).

### T-UNUSED: `read` loops do not declare unused variables

Function: `collectUnusedReadFindings(gpa, text, findings)`.

- Find `while ... read -r v1 v2 ...` headers, scan to the matching `done`, and
  report each variable not referenced as `$var` or `${var}` in the body and not
  prefixed with `_`.
- Skip single-variable `read -r line` (the rest-of-line capture cannot be
  proven unused) and document that nested loops are out of scope.
- Test cases: current `bump-master.yml` and `index.yml` (the five SC2034
  findings); a body that uses `$branch` (no finding); `_branch` (no finding);
  single-variable read (no finding); a comment mentioning `$branch` (still a
  finding unless used in code).

## Fixes after the tests fail

1. `ci.yml` canary job: remove the `Fetch dependencies` step, or mark it
   `continue-on-error: true`. The repository has no runtime dependencies (D1),
   so removal is the clean cutover. Keep `zig build test` as the next step.
2. `ci.yml` both jobs: add `actions/setup-go@v5` with
   `go-version: '1.23'` before the lint step.
3. `ci.yml` both jobs: run `go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.7`
   with no file arguments. actionlint then discovers `.github/workflows`
   itself, avoiding the glob on every shell.
4. `bump-master.yml`: rename unused loop variables to `_branch`, `_include`,
   `_repo`, `_old_commit` in the three loops.
5. `index.yml`: rename unused `include` and `repo` to `_include`, `_repo` in
   the two loops.

## Verification

- `zig build test` exits 0 (now includes T-FETCH, T-GLOB, T-GO, T-UNUSED).
- `zig build workflows` exits 0.
- `zig fmt --check . --exclude tests/fixtures` exits 0.
- `go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.7` exits 0 locally
  (Go 1.27.1 is available). shellcheck is absent locally, so T-UNUSED is the
  deterministic stand-in for the SC2034 gate; CI supplies the real shellcheck.
- Re-read the canary log shape: no `--fetch=all` error; the canary may still
  fail on a genuine master incompatibility, which its `continue-on-error`
  already treats as non-blocking.

## Boundaries

Only `src/`, `.github/`, `tests/`, and relevant `.md` files are modified. No
changes to `data/`, `tools/`, `build.zig`, or runtime dependencies. No change to
AGENTS.md decisions D1-D10.

## Result (2026-11-10)

- Added eight tests in `src/util/workflow.zig`; the four real-workflow tests
  failed before the fixes and pass after.
- Applied all five fixes.
- `zig build test` exits 0; 80/80 unit tests pass. `zig build workflows`,
  `zig fmt --check . --exclude tests/fixtures`, and actionlint (no arguments)
  exit 0 locally. shellcheck is not installed locally; the SC2034 cases are
  pinned by T-UNUSED.
