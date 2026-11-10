# AGENTS.md — <project>

This file is the **spec of record and rulebook** for AI agents working in this repo.
It contains rules, decision triggers, and API facts verified on the pinned toolchain —
never an inventory of files, never a commit hash.

**Provenance.** Distilled from the first 109 commits of ZigMCP's history: 28 `fix`,
3 `test`, 11 `docs(agents)` repairs to that project's own rulebook — line pins replaced
by symbol citations (twice), a branch/remote claim, a present-today inventory, a drifted
surface table — and 30 `docs(plan)` bookkeeping records its backlog rule mandates.

The 11 are the design rule below: a file that records *state* rots within a day. The 30
point the other way — not decay but cost: bookkeeping a backlog *rule* asks for, batched
one commit per chunk of fixes. Count the two separately, or you will read a deliberate
process as rot. Record what does not change; put what does change behind a command.

**Using this file.** Copy it into the new repo as `AGENTS.md` — agents auto-load that
name (plus tool-specific variants), not `AGENTS-2.md`. Fill §1 and the first two rows
of §3 before the first commit; everything else is already true of any Zig 0.17.1 tree.
Human-facing install/run docs belong in `readme.md`; a user-visible change updates both,
in the same commit.

**Read order:** §1 → §2 → §3 → §5 → §9.

Section numbers are stable. Source comments cite `AGENTS.md §N` and decisions cite `Dn`;
renumbering a section means updating every citation (`grep "AGENTS.md §"`).

---

## 1. Project identity

Every unspecified line here is a coin flip an agent will make for you. Fill it in.

- **What it is** (one sentence): `<…>`
- **Who runs it, and how often**: `<…>`
- **Input it accepts** and the size ceiling on each input: `<…>`, `<…>`
- **Output it produces**: `<…>`
- **The one thing that must never happen**: `<e.g. serve a partially written artifact,
  lose a committed record, emit two responses for one request>`
- **Non-goals** (things reviewers should reject a PR for adding): `<…>`

### Goals

| # | Goal | Acceptance signal — a command or an observable output |
|---|---|---|
| G1 | `<…>` | `<command>` exits 0 |
| G2 | `<…>` | `<predicate over the produced artifact>` |
| G3 | `<…>` | `<measured distribution, not a deadline>` |

A goal with no executable acceptance signal is a wish. Write the command.

### Shape

The shape decides most of the invariants below. Pick one and delete the others.

| Shape | Binding constraint | Consequence |
|---|---|---|
| Library | The API surface is the product | Every public symbol needs a test that a consumer would write |
| CLI / batch | Determinism and exit codes | Same input ⇒ byte-identical output; diagnostics on stderr; non-zero exit on failure |
| Long-lived service | The process outlives its inputs | Bounded memory, atomic artifact swap, flush before blocking, clean shutdown |

---

## 2. Invariants

Numbered so code can cite them. Breaking one is a bug, not a style debate.

| ID | Invariant |
|---|---|
| I1 | Every claim about behaviour is a command that was run. Anything unrun is labelled `[INFERENCE]`. |
| I2 | `zig build test` is the authority. "Should work" is not a state. |
| I3 | Never weaken a test to match the code. Fix the code, or file the defect and say so. |
| I4 | Every input is bounded: reads, counts, loops, recursion, query length, output size. |
| I5 | stdout carries the product's data only. Diagnostics go to stderr, one line, with the cause. |
| I6 | Parse once at the boundary; serve from flat read-only memory. Nothing is re-parsed per unit of work. |
| I7 | Generated artifacts are never hand-edited. Regenerate them, or fail. |
| I8 | Publish atomically: validate the whole artifact, then swap. A failed load leaves the previous one serving. |
| I9 | Fail closed on data, fail open on work: reject a corrupt artifact whole; skip one broken unit and continue. |
| I10 | Nothing is echoed to a consumer without validation. A missing field is better than a wrong one. |
| I11 | One logical change per commit. A doc statement this change falsifies is fixed or deleted in the same commit. |
| I12 | No new runtime dependency without a `D` entry the human approved. |

---

## 3. Decisions

A decision is load-bearing. Changing one requires the human's explicit approval and an
edit to this table in the same commit. Keep rejected alternatives — they are the part a
future reader needs, and the part that stops the same argument twice.

| ID | Decision | Rationale | Rejected alternative |
|---|---|---|---|
| D1 | `<e.g. build the wire/format layer in-repo>` | `<…>` | `<…>` |
| D2 | `<e.g. config is data, loaded at startup>` | Editing behaviour must not require a rebuild | Hardcoded constants |
| D3 | `<…>` | `<…>` | `<…>` |

### Decision triggers

Thresholds, so an agent does not have to invent one mid-task.

- **Add a dependency** only when the alternative is security-sensitive code you would
  have to write and maintain (TLS, crypto, compression, archive formats) **and** it can
  be pinned by hash. Otherwise write the 80 lines.
- **Add a second code path** only when the two paths produce behaviour a consumer can
  observe. A different input shape is one path with a flag, not two implementations.
- **Add a background thread** only when the work can block longer than the main loop may
  stall, or is unbounded. State who owns the data and what shutdown does.
- **Add a cache or an index** only after measuring the exact baseline it replaces.
  Publish the numbers next to the code.
- **Change the on-disk format** only with a version field, a reader that rejects what it
  does not understand, and a test for each rejection.
- **Add a learned component** (PGO, learned index, learned policy) only with a measured
  exact baseline and a measurable objective. Otherwise it is unverifiable complexity.

---

## 4. Toolchain and commands

Pinned: **Zig 0.17.1**. `build.zig.zon` carries `.minimum_zig_version = "0.17.1"`, and
`zig version` is the check — not a comment, not a CI badge.

```bash
zig version                  # must print 0.17.1
zig build                    # compile everything
zig build test               # unit + integration + golden + protocol/CLI
zig build run -- <args>      # forwards args only with run_cmd.addPassthruArgs()
zig build -Doptimize=ReleaseSafe
zig fmt --check . --exclude <fixture-dir>    # --exclude takes a path, repeatable
zig build --help             # the real list of steps; trust it over any doc
```

Rules that save an afternoon:

- Re-verify every std API you are about to lean on (§5) with a throwaway probe. The
  compiler's error notes name the replacement.
- An interrupted `zig build` can orphan `zig.exe` children holding the cache lock; the
  next build then looks hung. Kill them before timing anything.
- `zig build-lib -femit-docs` writes `docs/` **and a `.lib`** into the current directory.
  It has no output-dir flag. Clean both up.
- `zig fetch --save[=<name>]` writes into the package root it **runs in**. Run it from a
  subshell inside the checkout you mean, or it edits the parent's manifest.
- Pin actions and tools to exact versions in CI and run the same pinned invocation
  locally. A lint gate that differs from CI is decoration.
- ZLS needs a matching minor version. It reports syntax errors immediately but semantic
  errors only after the next build; `zig build test` is the authority, not the editor.

---

## 5. Zig 0.17.1 API facts that bite

Verified on 0.17.1. Each line is a trap that cost a real debugging session; the citations
are by symbol, because line numbers move.

### Files and streams

- `std.fs.File` is **gone**. Use `std.Io.File.stdin()/stdout()/stderr()`;
  `file.writer(io, &buf)` returns a struct whose `.interface` is the `std.Io.Writer`.
- Writers are **buffered**: nothing is emitted until `.flush()`. Flush before blocking on
  the next read, or the consumer waits forever for bytes that are already "written".
- On a pipe, use `readerStreaming`/`writerStreaming`. Positional I/O on a pipe silently
  loses bytes.

### Entry point, arguments

- The entry point receives `std.process.Init`: `gpa`, `io`, `arena`, `environ_map`,
  `preopens`, `minimal`.
- Arguments: `std.process.Args.toSlice(args, arena)`. `Args.iterate` is a compile error
  on Windows.

### JSON

- `std.json.ObjectMap` keeps `put(gpa, k, v)` on both 0.17.1 and master.
- `std.json.Array` is **managed** on 0.17.1 (`.init(gpa)` + `append(v)`) and the
  **unmanaged** `std.ArrayList(Value)` on master (`.empty` + `append(gpa, v)`). Decide the
  shape once, at comptime, with `@hasDecl(std.json.Array, "init")`, in a single helper
  module — and route every array through it.
- `std.ArrayList(T)` is unmanaged on 0.17.1: `append(gpa, v)`, `toOwnedSlice(gpa)`.
- `std.json.Stringify.value(v, .{}, &writer)` on a `std.json.Value` uses its
  `jsonStringify`. Passing an anonymous struct serializes **the struct** — a silent wire
  bug that no type check catches.

### ZON

- `std.zon.parse.fromSlice(T, .{ .gpa, .arena, .source, .diagnostics })`; `source` must be
  `[:0]const u8`; `Diagnostics = { errors: []const Error }`.
- `fromSliceAlloc`/`free` are gone.
- When comments, line breaks and whitespace must not change behaviour, parse the **ZON
  AST** (`std.zig.Ast` with `.mode = .zon`) instead of regexing the text.

### Allocators

- `ArenaAllocator.allocator()` is **self-referential** — the `ptr` *is* the arena. A copy
  by value points at the dead original. Heap-allocate it (`gpa.create`), keep the pointer,
  never store an arena by value in a struct you copy.
- `Allocator.dupeZ` is gone → `dupeSentinel(allocator, T, bytes, sentinel)`.

### Concurrency and time

- `std.Io.Mutex` needs an `Io` (`lock(io)`). For tiny critical sections prefer a spin lock
  over `std.atomic.Value(bool)` — and free retired memory **outside** the lock, not in a
  `defer` that runs after the unlock.
- `std.Thread.sleep` is gone. `std.Io.sleep(io, duration, .awake)`.
- A background thread must not sleep on the process's `Io`: the timer belongs to that
  `Io`'s event loop and can outlive the caller. Use a plain OS delay or give the thread
  its own `Io`.

### HTTP

- `std.http.Client.fetch(options)` writes the body to `options.response_writer`;
  `FetchResult` exposes only `status`.
- There is **no conditional GET, no ETag, and no request timeout**. Therefore: never
  fetch on the startup path — a black-holed origin blocks startup. Fetch from a worker,
  cap the bytes, and compare by hash.

### `std.zig.Ast`

- `Ast.parse(gpa, source, .{ .mode = .zig })` never fails on malformed input; diagnostics
  land in `tree.errors`, which mixes warnings and errors and carries **no severity field**.
- `///` → `.doc_comment`; `//!` → `.container_doc_comment`.
  `tree.tokens.items(.tag)` is already a slice. `tokenSlice(i)` takes a `u32` and keeps
  the `///` prefix.
- `firstToken` of a `pub` declaration is the `pub` keyword, not the name.
- `fullContainerDecl(&buf, node)` (buf: `[2]Ast.Node.Index`) covers
  `container_decl*`/`tagged_union*`; members are `cd.ast.members`.
- `Node.Index` is `enum(u32)`; use `OptionalIndex.unwrap()`, never a manual
  `@enumFromInt`.
- Error-set members are **not nodes**: they are `identifier` tokens between the braces.
- `fullFnProto` gives `name_token`; `proto.iterate(&tree)` yields
  `Param{ first_doc_comment, name_token, … }`.
- `Ast.parse` recurses once per nesting level: a hostile file overflows the stack long
  before the bytes run out. Count depth first and refuse above ~256.

### Comptime

- **Peer-type narrowing**: `@min(runtime_u64, 1)` resolves to a `u20`-width result, and a
  multiplication of it inherits that width — an overflow at runtime that no annotation on
  the *literal* prevents. Give every stored computation an explicit type
  (`@as(u64, …)`) and annotate the local, not the operand.
- `orelse … catch` needs parentheses when combined: `(a orelse b) catch c`. Master
  rejects the ungrouped form.
- `@hasDecl(T, "name")` is the supported way to select a shape across toolchain versions.

### Build graph

- `root_module` is a **field of the options struct**
  (`b.addExecutable(.{ .name, .root_module = b.createModule(...) })`). There is no
  `root_source_file` field at the top level any more.
- `b.addOptions()` + `addOptionPath` is how a test binary receives a built artifact's
  path.
- `zig build run -- <args>` forwards arguments only after `run_cmd.addPassthruArgs()`.
- Windows binaries get a manifest and version resource with
  `root_module.addWin32ResourceFile(...)`, guarded by `target.result.os.tag == .windows`,
  and the `.rc`/`.manifest` must be listed in `build.zig.zon`'s `paths` or a package
  build loses them.

### Probe recipe

```bash
mkdir -p .probe && cd .probe
printf '%s\n' 'const std = @import("std");' 'pub fn main() !void { /* the API in question */ }' > probe.zig
zig build-exe probe.zig --cache-dir .cache
```

Read the notes, then delete `.probe/`. It is scratch, gitignored, and never committed.

---

## 6. Conventions

- **Module header.** Every module starts with a `//!` saying what it owns and which
  section or decision it implements. A reader should not need the call graph to place it.
- **Errors name the cause.** `FileNotFound`, `IsDir`, `TooLarge`, `MalformedRecord` — not
  a generic wrapper that turns four different failures into one. An operator debugging at
  3 a.m. has only your message.
- **One source of truth per fact.** Schema in one module, tables in one array, dispatch
  through the table. If a list can drift from its handler, it will.
- **Sort at the boundary.** Every published collection gets a stable total order. That is
  what makes a golden test possible and a diff reviewable.
- **Hash what you publish**, verify at load, and reject the whole artifact on mismatch.
- **Paths**: `/`-separated, 1-based line numbers, `..` components rejected. Windows is a
  test target, not a second format.
- **Case sensitivity**: decide per key and write it down. Identifiers exact, user-facing
  lookups case-insensitive is a defensible pair — silently mixing them is not.
- **Encoding**: replace invalid UTF-8 with U+FFFD before hashing; never emit a byte array
  where a string was promised.
- **Line endings**: `.gitattributes` with `* text=auto eol=lf`. A byte-for-byte golden
  comparison is otherwise platform-dependent, and a fresh Windows clone fails first.
- **`.gitignore`**: anchor directory rules (`/docs/`, not `docs/`). An unanchored rule
  silently swallowed an entire source directory once; the repo built on the author's
  machine and nowhere else.
- **Never print to stdout** outside the product's output path.

---

## 7. Verification

| Layer | Owns | Runs under |
|---|---|---|
| Unit | pure functions, parsers, validators, boundary arithmetic | `zig build test` |
| Property | mutated, truncated and invalid input either loads whole or is rejected | `zig build test` |
| Integration | producer/consumer under concurrent swap; a torn read would mix versions | `zig build test` |
| Golden | the generator's output, byte for byte | `zig build test` |
| Protocol / CLI | the built binary over real pipes with real arguments | `zig build test` |
| End-to-end | one path through every public surface, in order | `zig build test` |
| Report | startup time, p50/p95/p99, error counts, peak RSS | `zig build bench` — a step you add when there is something to measure |

- A test earns its place by catching a **consumer-visible** defect: behaviour, boundary,
  invariant, transition, precedence, error. Delete tests that only pin wording, wiring,
  mock echoes, or source text.
- **Bound every wait.** A watchdog that turns a hang into a named failure is worth more
  than a longer timeout; one Windows pipe test parked the suite forever until it got one.
- **Teardown terminates** the child process. Never wait on an EOF you are not certain
  arrives.
- **Golden files** are regenerated deliberately and the diff reviewed. "Fixing" the golden
  to match new output without understanding why it changed is how the bug ships.
- **Canary toolchains**: one tree, comptime shape selection, no forked code paths, no
  weakened gates. Run the same gates on both versions before claiming support.
- **No deadline claims.** Report the distribution. A latency budget needs a measured
  baseline and a named machine.

---

## 8. CI and release

- **A workflow triggers exactly what it reads.** A `push`-only workflow must never read
  `github.event.pull_request.*`; a `pull_request` trigger has no secrets. This is
  checkable statically — write the checker, run it in the gate.
- **One baseline, one tag.** Publish release artifacts you intend to read back under a
  name that does not expire. Artifacts expire; releases do not.
- **Fetch exactly the commit you need**: `git init`, `remote add`, `fetch --depth 1 origin
  <sha>`, `checkout --detach FETCH_HEAD`. A `--filter=blob:none` clone still downloads the
  tree and refs.
- **A generated step never pre-seeds a file a later step parses.** Each file is written
  once, by the step that owns it. An empty placeholder that a later `json.loads` reads is
  a failed run waiting for its first dispatch.
- **Branch names carry a run identifier.** `…-<date>-<run_id>`, or the second run of the
  day fails at `checkout -b`.
- **Release artifacts contain everything the binary reads at startup.** A binary that
  loads a data directory at boot and a tarball that ships only the binary is a release
  that cannot start.
- **Lint with CI's exact toolchain.** actionlint shells out to `shellcheck` when it finds
  one on `PATH`, so a local pass without shellcheck is not a pass, and a `run:` body can
  be green on Windows and red on `ubuntu-latest` for the same bytes.
- **Reproduce the step, not the workflow.** Extract the failing `run:` block, run it in a
  throwaway tree with stubs, and show it failing before the fix and passing after. That
  evidence belongs in the commit message.

---

## 9. Working discipline for agents

- **Read before writing.** Existing patterns win over a new convention; a second
  convention is a defect with good intentions.
- **Change only what the task names.** No opportunistic refactors, no extra validation
  layers, no "while I'm here". Scope creep is indistinguishable from a regression when
  the diff is reviewed.
- **Delete what the change makes dead** — callers, aliases, re-exports, comments, docs. No
  shims, no deprecated paths, no compatibility flags nobody asked for.
- **Verify with the narrowest command** that actually exercises the change, once. Report
  only what you ran.
- **If blocked, say exactly what is missing** and what you tried. Never guess a value into
  existence, and never present a plausible subset as the delivered whole.
- **Never rewrite a published commit.** Amend or add.
- **`git log` is evidence.** Use it to see whether a rule was already tested, and to find
  the failure mode a line of code exists for. Then write the commit message that names it.
- **A doc statement that becomes false is a bug** in the same commit as the code that
  falsified it.

---

## 10. Failure catalogue

Real defect classes, in the order they were found. Each row is a checklist item for a new
parser, loader, or protocol surface.

| # | Symptom | Violated | The check to write |
|---|---|---|---|
| 1 | One unreadable file aborts a whole batch | I9 | unreadable and oversized unit → record a reason, continue, exit 0 |
| 2 | Hostile nesting overflows the stack | I4 | count depth before parsing; refuse above the ceiling |
| 3 | Corrupt or truncated artifact is served | I8, I10 | hash + record count + canonical order, verified at load; reject whole |
| 4 | A stale artifact is reused as fresh | I8 | compare the version key **and** the record count against the sidecar |
| 5 | An empty file is parsed as valid | I10 | reject empty members before feeding them to a parser |
| 6 | A pathologically long token splits into fragments | I4 | a token longer than the buffer is kept whole |
| 7 | An oversized line kills the process | I4 | answer with an error, discard the rest of the line, keep serving |
| 8 | A negative or huge counter crashes a formatter | I4 | validate every count before formatting it |
| 9 | An unvalidated field is echoed to consumers | I10 | validate type and sign; omit on mismatch |
| 10 | "Not found" is reported as a protocol error | I3 | a miss is a normal, schema-shaped result |
| 11 | A case-insensitive key collides with another | I10 | keys exact, symbols case-insensitive, both tested |
| 12 | CRLF changes a byte hash | I10 | LF policy, and strip `\r` before hashing |
| 13 | A glob include matches nothing | I4 | test `lib/**` and `lib/**/*.zig` against a real tree |
| 14 | A zero interval spins a core | I4 | clamp the configured value to a floor |
| 15 | Shutdown hangs on a network read | I8 | blocking I/O never on the startup or shutdown path |
| 16 | A long-running process never sees a new artifact | I8 | poll mtime+size, parse fully, swap the pointer only on success |
| 17 | `.gitignore` hides a source tree | I7 | anchor directory rules; `git status` on a fresh clone |
| 18 | A test hangs instead of failing | I2 | watchdog plus terminate-on-teardown |

---

## 11. Bootstrap checklist

Ordered. Each step leaves the tree green.

1. `zig init`; set `.minimum_zig_version`; commit the generated tree unchanged.
2. `.gitattributes` = `* text=auto eol=lf`; `.gitignore` with **anchored** directory rules.
3. `build.zig` with `test`, `run` and a formatter step; `zig build test` green on an empty
   tree before any product code exists.
4. One `//!`-headered module with one real test, plus a `src/root.zig` test aggregator.
5. Fill §1 (identity) and the first two rows of §3 (decisions).
6. `readme.md` with install, run, test, and the supported toolchain.
7. CI: the pinned Zig version, `zig build test`, `zig fmt --check`. Add a non-publishing
   canary leg only when a second toolchain is actually supported.
8. No dependency until §3 says yes.
9. First feature lands test-first, with the failure it prevents written in the commit
   message.
10. When a hot path exists, add the `bench` step and its tool; report p50/p95/p99, peak
    RSS and error counts — never a bare deadline. Until then §7's Report row does not
    apply.
11. Re-read this file against the tree at the first release; delete every statement that
    is no longer true rather than updating it into plausibility.
