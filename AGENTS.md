# Repository Guidelines

## Project Overview

**ZigMCP** is a Model Context Protocol server written in Zig. It serves two things to an AI coding agent:

1. **Systems-programming advice** — the content of `systems_programming_context_v1.md` (paradigms P01–P12, decision rules, guarantees, limits, source registry S01–S24), exposed as MCP tools/resources/prompts with evidence labels intact.
2. **Documentation imported from other Zig projects** — extracted from Zig's built-in doc syntax (`///` declaration comments, `//!` container comments) and served as searchable MCP resources.

**Current state: greenfield.** The repo contains only `PLAN.md` (the spec of record), `systems_programming_context_v1.md` (upstream reference), an empty `readme.md`, `AGENTS.md`, and a `.gitignore`. There is **no `build.zig`, `build.zig.zon`, `src/`, `tests/`, `data/`, `tools/`, `generated/`, or `.github/`** — every path below is *planned*, not present.

**The governing architectural idea:** the server binary is a stable, thin host. Everything that changes — advice corpus, doc index, upstream dependency pins — is **data**, replaced by CI, loaded at runtime. Never embed the index in the binary (PLAN D3).

## Architecture & Data Flow

### Two planes

| Plane | Contents | Rebuilt when |
|---|---|---|
| **Server plane** (`src/`) | Protocol, transport, registry, advice engine, doc index loader, search | Rarely — only when code changes |
| **Data plane** (`data/`, `generated/`) | Advice corpus (ZON), upstream source list (ZON), doc index (JSONL) | Continuously, by CI, without touching `src/` |

### Request flow (one MCP message)

```
stdin line (newline-framed JSON)
  → transport/stdio.zig       read one line; no embedded newlines
  → std.json.parseFromSlice   into std.json.Value
  → protocol/meta.zig         resolve version: params._meta absent → legacy 2025-06-18 (no _meta
                              requirements); present → validate
                              io.modelcontextprotocol/protocolVersion (required),
                              …/clientCapabilities (required), …/clientInfo (optional)
                              present-but-incomplete → -32602
                              version unsupported  → -32022 + supported list
  → protocol/json_rpc.zig     classify request vs notification
  → server/registry.zig       comptime table dispatch by method name (PLAN D8)
  → handler                   server/discover | tools/call | resources/read | prompts/get
                              handlers read ONLY pre-loaded in-memory structures
  → build result              on 2026-07-28 responses ALWAYS include resultType
                              ("complete"; "input_required" reserved) and
                              _meta["io.modelcontextprotocol/serverInfo"];
                              + cache hints (ttlMs + cacheScope) on the six
                              cacheable methods (PLAN §7.4);
                              legacy (inferred 2025-06-18) responses omit both
                              tool-level failure → isError:true inside a normal result (NOT a JSON-RPC error)
  → std.json.Stringify        into a fixed buffer
  → transport/stdio.zig       write ONE line to stdout and FLUSH it before reading the next
                              request (the stdout writer is buffered — an unflushed response
                              deadlocks a client that is blocking on it); diagnostics to stderr only
  → stdin EOF                 flush and exit 0
```

Corpora are parsed **once at startup** into flat, arena-owned structures; the hot path is read-only scan/render (PLAN §4).

### Planned module map (PLAN §5 — none of these exist yet)

| Path | Responsibility |
|---|---|
| `src/main.zig` | Entry: load corpora, run stdio loop |
| `src/protocol/json_rpc.zig` | Request/response/notification types |
| `src/protocol/meta.zig` | `_meta` parse + version negotiation + legacy version inference (D10) |
| `src/protocol/errors.zig` | Error codes: `-32700`, `-32600..-32603`, `-32022` (`-32020`/`-32021` are HTTP-only and reserved) |
| `src/transport/stdio.zig` | Newline framing, stdout purity, stderr logs, per-line flush before the next read |
| `src/server/registry.zig` | Comptime capability table (D8) — one source of truth for name/description/schema/handler |
| `src/server/discover.zig` | `server/discover` |
| `src/server/tools.zig` | `tools/list`, `tools/call` |
| `src/server/resources.zig` | `resources/list`, `resources/read`, `resources/templates/list` |
| `src/server/prompts.zig` | `prompts/list`, `prompts/get` |
| `src/advice/corpus.zig` | ZON schema + loader for `data/advice/*.zon` |
| `src/advice/rules.zig` | P02/P05 rule matcher over the SELECT rules |
| `src/advice/render.zig` | Record → MCP resource/prompt text |
| `src/docs/index.zig` | JSONL record schema + loader |
| `src/docs/columnar.zig` | P03 layout: offsets into one string table + parallel arrays |
| `src/docs/reload.zig` | Artifact watch + validate-then-atomic-swap (D3); the background watcher is the only writer of the active index pointer |
| `src/docs/search.zig` | Symbol/path/token queries |
| `src/util/arena_pool.zig` | Reusable buffers; no per-request allocation |

### MCP surface (PLAN §7)

- **Tools:** `advice_lookup`, `recommend_approach`, `doc_search`, `doc_get`, `doc_import_status`
- **Resources:** `advice://overview`, `advice://patterns/{P01..P12}`, `advice://rules`, `advice://guarantees`, `advice://limits`, `advice://sources`, `docs://{project}/symbols/{symbol}`, `docs://{project}/index`
- **Prompts:** `systems_review`, `approach_selection`

Protocol revision `2026-07-28`: stateless, **no `initialize` handshake** — `server/discover` is mandatory. A legacy `initialize` alias (D7) ships in M0 with the protocol core, with legacy clients handled by version inference rather than a second wire implementation (D10).

## Key Directories

Present today:

| Path | Purpose |
|---|---|
| `PLAN.md` | **Spec of record.** §2 decisions (D1–D10) + §2.1 rejected architectures, §3 evidence base, §4 architecture, §5 layout, §6 data model, §7 MCP surface, §8 doc import (+ CI mechanics), §9 pattern mapping, §10 verification, §11 milestones, §12 risks, §13 open questions |
| `AGENTS.md` | This file — repo guidelines for AI agents working in this tree |
| `systems_programming_context_v1.md` | Upstream reference, by section heading: `CONTEXT` (scope + the evidence-label legend), `CORE` (the P01–P12 concept table), `P01`–`P12` (one section per paradigm), `GUARANTEES`, `SELECT` (12 conditional rules), `VERIFY`, `LIMITS`, `SOURCES` (S01–S24) |
| `readme.md` | **Empty by design** — a known gap; PLAN.md mandates no content for it (it appears only in the §5 layout tree) |
| `.gitignore` | Excludes `zig-out/`, `.zig-cache/`, `.probe/`, `docs/`, `generated/`, and native byproducts |

Planned (PLAN §5): `build.zig`, `build.zig.zon`, `src/` (above), `data/advice/*.zon` + `data/sources.zon`, `tools/indexer.zig` + `tools/advice_check.zig`, `generated/index.jsonl` (CI-produced, never hand-edited), `.github/workflows/{ci,bump-master,index,release}.yml`.

## Development Commands

### Runnable today (no `build.zig` exists)

```bash
zig version                  # 0.16.0
zig env                      # lib_dir / std_dir / global_cache_dir
zig fmt --check .            # formatter gate over existing .zig files (also: --zon, --ast-check)
zig build --help             # shows --fetch[=needed|all]; cannot build anything
```

`zig build test`, `zig build run`, `zig build --fetch=all` **cannot work yet** — no `build.zig` (milestone M0, PLAN §11).

### Available once M0 lands

```bash
zig build                    # build + install to zig-out/
zig build test               # all test layers
zig build run                # start the stdio server
zig build -Doptimize=ReleaseSafe
zig build --fetch=all        # fetch hash-pinned upstream sources
```

### Dependency management

```bash
# Re-pin an upstream branch. Requires a build.zig.zon to write into, so run it
# in a SCRATCH checkout (zig init), then copy the resolved .url/.hash across.
zig fetch --save=zig_std "git+https://github.com/ziglang/zig.git#master"
zig fetch --save=mcp_zig "git+https://github.com/muhammad-fiaz/mcp.zig.git#main"
```

**Dependency URLs never float.** `zig fetch --save` resolves the branch to a commit and writes `url = "git+https://…git?ref=<branch>#<sha>"` plus a content `hash`; the `#<sha>` freezes the commit and the `hash` is the source of truth. Tracking a branch therefore requires an explicit re-pin step — owned by the `bump-master.yml` CI job (PLAN §8.5, D6). Branch names differ per repo (`master` for zig, `main` for mcp.zig); a wrong branch fails with `error: ref not found`.

## Code Conventions & Common Patterns

### Zig (0.16) API facts that bite

These are verified against the installed toolchain; re-verify before relying on them.

- **`std.fs.File` no longer exists.** Use `std.Io.File.stdin()/stdout()/stderr()`; `file.writer(io, &buf)` returns a writer whose `.interface` is the `std.Io.Writer` (`lib/std/Io/File.zig:91,104,117,600`).
- **Entry point receives `std.process.Init`** (`lib/std/process.zig:30`): `gpa`, `io`, `arena` (`*std.heap.ArenaAllocator`), `environ_map`, `preopens`, `minimal`.
- **`std.json`**: `Value`, `ObjectMap` (= `StringArrayHashMap(Value)`), `Array`, `Stringify` (`beginObject`/`objectField`/`endObject`), `parseFromSlice` (`lib/std/json.zig:63-65,94`; `lib/std/json/static.zig:73`).
- **`std.compress.zstd`** exists (`lib/std/compress.zig:8`).
- **Doc-comment extraction** (`lib/std/zig/Ast.zig`): `parse` :145, `rootDecls` :326, `firstToken` :604, `nodeMainToken` :100, `tokenSlice` :276, `fullVarDecl` :2291, `fullContainerDecl` :2393. `///` → token tag `.doc_comment`, `//!` → `.container_doc_comment`. A declaration's doc is the contiguous run of `.doc_comment` tokens immediately **preceding** `ast.firstToken(decl)`.
  - `Ast.parse` takes a **sentinel-terminated** source (`[:0]const u8`) and **does not fail on malformed input** — diagnostics land in `tree.errors`, which mixes warnings and errors (no severity field; `Ast.Error` = `tag`, `is_note`, `token_is_prev`, `token`, `extra`).
  - `tree.tokens.items(.tag)` returns `[]Token.Tag` **directly** (no `.items` on it). `ast.tokenSlice(i)` takes a `u32` token index and returns the comment **including** its `///` prefix.
  - `fullContainerDecl` takes a `var buf: [2]Ast.Node.Index = undefined` local and returns an **optional** → `if (opt) |v| { … }` with **no** `.?` inside the capture. Members are `cd.ast.members` (**not** `cd.members`).
  - `Node.Index` is `enum(u32)` (:2930); `OptionalIndex` (:2948) exposes `.unwrap() → ?Node.Index` — use that instead of a manual `@enumFromInt(@intFromEnum(x))` on the raw enum value (a bare `@intFromEnum` is rejected by the compiler).
  - **Error-set members are not AST nodes**: an `error_set_decl` node holds only the `{`/`}` token indexes (`nodeData(node).token_and_token`); members are plain `identifier` tokens in the stream, each optionally preceded by a `.doc_comment` token.
  - **Parameter docs**: `ast.fullFnProto(&buf1, decl)` (optional) exposes `name_token`; `proto.iterate(&tree)` yields `Param{ first_doc_comment, name_token, … }`.
  - Container initializer tags: `container_decl`, `container_decl_trailing`, `container_decl_two`, `container_decl_two_trailing`, `container_decl_arg`, `container_decl_arg_trailing` (plus `tagged_union*`).
- **`std.Io.File.stdout().writer(io, &buf)` is buffered** — call `.flush()` or nothing is emitted.
- **`zig build-lib -femit-docs <file.zig>` writes `docs/` into the current working directory** (no `-femit-docs-dir` flag in 0.16).
- **Build API** (`lib/std/Build.zig`): `addExecutable` :787, `addTest` :881, `addModule` :909, `createModule` :918, `addRunArtifact` :936, `addWriteFiles` :1099, `step` :1355, `installArtifact` :1660, `addInstallDirectory` :1726, `dependency` :2055. `root_module` is a **field** in the options struct, not a function argument. `lib/std/Build/Module.zig`: `addImport` :326, `addAnonymousImport` :332, `addEmbedPath` :507. `lib/std/Build/Step/Compile.zig:889`: `getEmittedDocs`.

### Allocation discipline

Load corpora at startup into the **arena**; serve requests from flat, read-only structures; reuse a fixed response buffer per request. No per-request re-parsing of ZON or JSONL. Reloads are **atomic-replace**: parse and validate the new index fully, then swap the pointer, then drop the old one — never mutate live structures in place (PLAN §9 guarantees).

### Error handling

| Situation | Response |
|---|---|
| Malformed JSON line | JSON-RPC `-32700` |
| Malformed JSON-RPC envelope | JSON-RPC `-32600` |
| Unknown method | JSON-RPC `-32601` |
| `_meta` present but missing a required field (`protocolVersion`, `clientCapabilities`) | JSON-RPC `-32602` — the spec defines a request missing a required field as invalid **params**, not invalid request |
| `_meta` entirely absent | Not an error — version-inferred as legacy `2025-06-18` (D10) |
| Unsupported protocol version | JSON-RPC `-32022` with the supported list |
| Internal failure | JSON-RPC `-32603` |
| Tool fails at runtime | Normal result with `isError: true` — **not** a JSON-RPC error |

`-32020` / `-32021` are reserved spec codes and are **not wired in v1** (no HTTP transport, so no header/auth surface).

### Corpus conventions (the non-obvious rules)

- **Evidence labels are mandatory.** Every advice record carries exactly one of `FACT` / `RESULT` / `SYNTHESIS` / `GUIDANCE` (enum `.evidence` in ZON) plus a `sources` array of `Sxx` IDs. `tools/advice_check.zig` fails the build on a dangling `Sxx` reference or a missing label. Never present `GUIDANCE` as `FACT`.
- **The source doc's legend** (the `CONTEXT` section's "Evidence labels" list): `FACT` = documented mechanism; `RESULT` = study-specific finding, retain its conditions; `SYNTHESIS` = the report's classification, not a standard taxonomy; `GUIDANCE` = engineering recommendation needing project-specific validation. Candidate uses and checks in concept records are GUIDANCE unless labelled otherwise. **All 12 SELECT rules are GUIDANCE** — transcribe them into `rules.zon` with `.evidence = .guidance`.
- **Corpus provenance:** the advice corpus carries `version: 1` and `source_research_date: 2026-11-09` — match the source doc's frontmatter fields. Every doc-index record carries its upstream `commit`.
- **Advice corpus format: ZON** (`data/advice/patterns.zon`, `rules.zon`, `guarantees.zon`, `limits.zon`). `patterns.zon` = one record per P01–P12; `rules.zon` = the 12 SELECT rules as `(condition → consider → constraint)` rows.
- **Doc index format: JSONL**, one object per line: `project`, `commit`, `path`, `line`, `kind` (`fn`/`var`/`field`/`container`/`error`/`param`), `symbol`, `doc`, `doc_hash`. Sorted by `(project, symbol)`. JSONL is deliberate — the file must stay diffable so the bump PR's attached diff shows only genuinely changed doc text.
- **Upstream sources: ZON** (`data/sources.zon`) — `url` + `hash` + path scope, mirroring `build.zig.zon` `.dependencies`. `build.zig.zon` is the pin home; the bump PR updates both.
- **Adding a tool = adding a row to the comptime registry + a handler** (D8). Never hand-write a separate JSON Schema — derive it from the registry so advertised and implemented capabilities cannot drift.
- **Doc text is verbatim** except `///` prefix stripping and paragraph joining.
- **Doc attachment is pinned** (PLAN §8.1): a doc run attaches to the declaration whose `firstToken` immediately follows it in the token stream; a run the parser flagged `.unattached_doc_comment` is dropped. The golden fixture (§10.2) locks this rule.
- **Indexer failure policy (PLAN §8.1):** extract records from **every** parsed file regardless of `tree.errors` — the AST of a file with a syntax error is still usable for the parts that parsed, which is what preserves the "mid-breakage upstream still yields docs" property. Diagnostics are recorded and the file is reported as **degraded**. No curated fatal-tag list (the stdlib does not distinguish severity).
- **Doc run collection:** walk back from `ast.firstToken(decl) - 1` to find the run's start, then walk **forward** to collect the whole run in source order — a multi-line doc comment is multiple tokens.
- **`tools/list` is sorted by name** so clients can cache it deterministically.
- **Cache hints are mandatory (SEP-2549).** `resultType: "complete"` results of `server/discover`, `tools/list`, `prompts/list`, `resources/list`, `resources/templates/list`, and `resources/read` MUST carry `ttlMs` (≥ 0) and `cacheScope` (`"public"` | `"private"`). Advice data is stable → long TTL, `"public"`; index-derived data → short TTL (≈60 s), `"private"`.
- **Version resolution (PLAN D10):** `params._meta` **absent** ⇒ legacy `2025-06-18` request (no `_meta` requirements, no `resultType`, no cache hints; the `initialize` alias returns the old-style result). `params._meta` **present but incomplete** ⇒ `-32602`. `supportedVersions` = `["2026-07-28", "2025-06-18"]`.
- **Flush every response line** before reading the next request — `std.Io.File.stdout().writer(io, &buf)` is buffered, so an unflushed response hangs a client that is blocking on it.
- **Missing resource ⇒ `-32602`** with `data.uri`; never an empty `contents` array. The legacy `-32002` MUST NOT be emitted. Unknown tool / unknown prompt / invalid arguments / invalid cursor are also `-32602`; a malformed envelope is `-32600`.

## Important Files

| File | Role |
|---|---|
| `PLAN.md` | The spec. Read §2 before proposing any architectural change; §9 explains which systems-programming patterns apply and which are deliberately excluded (P04, P08, P10, P11, P12). |
| `systems_programming_context_v1.md` | Upstream source for the advice corpus. Its `SOURCES` registry defines S01–S24; the evidence-label legend lives in `CONTEXT` (`FACT` / `RESULT` / `SYNTHESIS` / `GUIDANCE`), while `LIMITS` is the "preserve when summarising or recommending" section. Reference material — do not edit to change project behavior. |
| `readme.md` | Empty by design. Listed in the planned layout; PLAN.md mandates no specific content for it. |

## Runtime & Tooling Preferences

- **Toolchain: Zig 0.16.0**, installed at `C:\Users\Sethticles\scoop\apps\zig\0.16.0`. `zig env` gives `std_dir`; global package cache is `C:\Users\Sethticles\AppData\Local\zig`.
- **`.minimum_zig_version = "0.16.0"`** — the release floor is the pinned stable.
- **Release artifacts are built with a pinned stable Zig, never master** (D9). The `master` nightly CI leg is a **non-publishing canary** that only surfaces breakage early. Upstream projects are *parsed*, never compiled into the server, so their churn cannot break our build.
- **Zero third-party runtime dependencies in the server** (D1). The MCP wire layer is implemented in-repo; `mcp.zig` requires Zig ≥ 0.17 and would couple releases to upstream release cadence. Streamable HTTP transport is out of scope for v1 — that is the capability that would trigger revisiting D1 in favor of `mcp.zig`.
- **Verify before you rely on it.** Zig's stdlib moves fast (`std.fs.File` was removed in 0.16; `std.process.Init` was reshaped). Write a throwaway probe under `.probe/`, compile it, read the compiler's "parameter type declared here" notes, then delete the probe. The procedure is captured in the `zig-std-api-verification` skill.
- **Bash is available for real binaries and short fact pipelines only.** `cat`/`head`/`tail`/`sed`/`awk`, `grep`-via-bash, and `echo`/`printf` redirection are blocked — use `read`, `grep`, `edit`, `write`.
- **Git:** branches `main` and `autoresearch/data-driven-programming-best-practices-for-build-20261109`; **no remote configured**; branch history starts at `50bf5cd "first"` — see `git log` for the current commits. Each edit to `PLAN.md` is its own commit; amend or add a commit, never rewrite a published one. A `.gitignore` excludes `zig-out/`, `.zig-cache/`, `.probe/`, `docs/`, `generated/`, and native byproducts (`*.lib`, `*.a`, `*.o`). Note `zig build-lib -femit-docs` writes `docs/` **and** a `.lib` into the repo root, so a stray doc-generation run leaves untracked files behind — clean them up before committing.

## Testing & QA

`PLAN.md` §10 mandates six layers (PLAN §10.2). None exist yet.

| Layer | Scope |
|---|---|
| **Unit** | Doc-comment extraction (single/multi-line, `//!` containers, error-set members, params, nested containers), `tree.errors` handling (a degraded file still yields records), rule matcher, JSONL parser, columnar layout, symbol-path construction. Deterministic, isolated, no network |
| **Property/fuzz** | Malformed JSONL lines, truncated UTF-8 doc text, pathological queries, missing `Sxx` corpus references. Targets: JSONL loader, `_meta` parser, query parser |
| **Golden** | Indexer output vs. a checked-in golden JSONL for a fixed upstream fixture, covering single/multi-line `///`, multi-paragraph docs, `//!` container docs, struct fields, methods, params, error-set members, a doc separated from its declaration by a blank line, a trailing unattached doc comment, a warning-only file, and a file with a syntax error — pins the attachment rule and the degrade-not-skip policy (PLAN §8.1) |
| **Protocol** | `server/discover` shape, `_meta` validation (`-32602` on a present-but-incomplete `_meta`), legacy path (absent `_meta` ⇒ `2025-06-18` semantics; `initialize` alias shape), `-32022` on bad version, `resultType` + `serverInfo` on every `2026-07-28` result, mandatory `ttlMs`/`cacheScope` on the six cacheable methods, `-32602` on unknown tool/resource, `-32600` on a malformed envelope, `-32700` on an unparseable line, stdout purity (no stray prints), **response flushed before the next request is read** (a client blocking on the response must not hang), clean exit on EOF. Drives the server as a subprocess over pipes, exactly as a client would |
| **Integration** | Index reload by the background watcher concurrent with in-flight requests (atomic swap, no torn reads; the watcher is the only writer), cancellation, resource exhaustion (oversized query, huge `limit`) |
| **End-to-end** | Scripted client session: discover → list tools → call each tool → read a resource → get a prompt, on the CI matrix OS set |

**Permanent-test rule (PLAN §10.2):** tests must catch consumer-visible defects — behaviour, boundaries, invariants, transitions, precedence, errors — **not wiring, not mock echoes, not source-text assertions, not bare not-throw checks**.

**Semantics to pin down before implementing (PLAN §10.1):** exactness (doc text verbatim except `///` stripping and paragraph joining); doc attachment (the immediately preceding contiguous `.doc_comment` run, minus runs flagged `.unattached_doc_comment`); permitted order (`tools/list` sorted by name, index sorted by `(project, symbol)`); failure behaviour (a file with parse diagnostics still contributes its usable records and is reported as degraded — never a failed server start); memory limits (candidate 256 MiB RSS ceiling for the full corpus, to be measured); deadlines (no wall-clock claim — report p50/p95/p99 instead).

**Per-CI-run reporting (PLAN §10.3):** build config, Zig version, upstream commits, corpus record counts, index build time, index size, server startup time, per-tool p50/p95/p99 latency, peak RSS, error counts — plus lifecycle accounting (the dominant prep cost is the CI index build, paid once per upstream bump, not per request).

**Before any P11 learned-index claim (PLAN §10.4):** build and measure the exact baselines first — linear scan over JSONL, binary search over a sorted symbol table, token inverted index. Only a candidate that beats them on the measured workload enters the design.

**CI matrix (PLAN §11 M3):** pinned stable = release toolchain × 3 OS; master nightly = canary, non-publishing. Workflows: `ci.yml` (build/test/fmt), `bump-master.yml` (scheduled re-pin; batch, and open a PR only when the index actually changes), `index.yml` (regenerate + publish), `release.yml` (tagged binaries + index artifact).