# ZigMCP — Plan

A Model Context Protocol server, written in Zig, that serves two things to an AI coding agent:

1. **The systems-programming advice** from `systems_programming_context_v1.md`, as structured, citable MCP resources/tools/prompts.
2. **Documentation imported from other Zig projects**, extracted from Zig's built-in documentation syntax (`///` declaration doc comments and `//!` container doc comments), served as searchable MCP resources.

The server binary is treated as a stable, thin host. Everything that changes — the advice corpus, the imported doc index, upstream dependency versions — is **data**, refreshed by CI/CD, and loaded at runtime rather than compiled into the binary.

---

## 1. Goals and non-goals

### Goals

| # | Goal | Acceptance signal |
|---|---|---|
| G1 | Serve the systems-programming advice with its evidence labels and source IDs intact | Every advice record exposes `evidence` (`FACT`/`RESULT`/`SYNTHESIS`/`GUIDANCE`) and `sources` (`S01`…`S24`) |
| G2 | Import docs from other Zig projects using Zig's own doc syntax | Indexer extracts `///`/`//!` comments from arbitrary upstream `.zig` trees, with symbol paths and file:line |
| G3 | Stay current without hand-edits | A scheduled CI job re-resolves every upstream project's master branch and republishes the index; no source change required |
| G4 | Protocol correctness against MCP revision `2026-07-28` | `server/discover` implemented; every request's `_meta` validated; every result carries `resultType` + `serverInfo`; every cacheable result carries `ttlMs` + `cacheScope` |
| G5 | Correct under failure and load | Verification protocol in §10 executed and reported (latency quantiles, memory, errors, prep costs) |

### Non-goals

- Not an MCP **client**; server-side only in v1.
- No Streamable HTTP transport in v1 (stdio only). Rationale: HTTP adds an auth surface (`-32020`/`-32021`) that this server has no use for, and keeps the "run as a subprocess" deployment that clients actually launch.
- No learned indexes, PGO, or learned policies. Per the source document's own SELECT rules, these require a measured baseline and representative traces that do not exist yet (§9, excluded rows).
- Not a replacement for `zig std` / the compiler's `-femit-docs` HTML site. This server is for *machine-readable, cross-project* retrieval.

---

## 2. Decisions

| ID | Decision | Rationale | Alternative rejected |
|---|---|---|---|
| D1 | Implement the MCP wire layer **in-repo** (JSON-RPC 2.0 over stdio), not as a dependency | The most complete third-party Zig MCP library (`mcp.zig`) requires Zig ≥ 0.17 for its current release, while the local toolchain is 0.16.0 and upstream master is `0.18.0-dev.935+ead8f5a7a`; a pinned dependency would break on every upstream master bump. Our surface is small: `server/discover`, `tools/list`, `tools/call`, `resources/list`, `resources/read`, `resources/templates/list`, `prompts/list`, `prompts/get` | `mcp.zig` 0.0.9 — revisit if HTTP/OAuth/tasks/MRTR become requirements |
| D2 | Advice corpus is **data** (ZON), not Zig code | Directly applies P01 (table/configuration driven) to the corpus itself; editing advice must not require touching handlers | Hardcoded Zig structs — rejected, couples content to code |
| D3 | Doc index is a **runtime-loaded artifact**, not embedded, and is **hot-reloadable** (validate-then-atomic-swap) | Satisfies G3: CI republishes the index; the binary is unchanged and the running server picks the new index up on its own | `@embedFile` of the index — forces a rebuild per upstream commit; load-only-at-startup — forces a client restart per upstream commit |
| D4 | Index canonical form is **JSONL** (one record per line), optionally `.zst`-compressed for shipping | Diffable and reviewable in PRs (bot-generated updates are auditable); `std.compress.zstd` exists in the stdlib | A custom binary blob — rejected as a review dead end |
| D5 | Doc extraction uses **`std.zig.Ast`**, not `-femit-docs` | Parsing does not require the upstream project to compile on our toolchain, which is essential when tracking a master branch that may be mid-breakage. Verified locally: `std.zig.Ast.parse` yields `.doc_comment` / `.container_doc_comment` tokens | `zig build-lib -femit-docs` — kept as an *optional* extra (§8.4), not the index source |
| D6 | Upstream sources are **hash-pinned in `build.zig.zon`**, re-pinned by a CI bump job | Reproducible builds; the bump job is what delivers G3 | Floating git refs in `build.zig.zon` — Zig's package manager resolves and freezes the commit at fetch time anyway |
| D7 | Protocol revision support: implement `2026-07-28` plus a legacy `initialize` alias | `server/discover` is mandatory in the current revision; older clients still probe with `initialize` | Only the new revision — rejects currently-deployed clients |
| D8 | Tool/resource descriptors live in a **comptime table**; JSON Schema is derived from it | One source of truth for name, description, schema, and handler; no drift between advertised and implemented capabilities | Hand-written JSON per tool — rejected as a drift source |
| D9 | **Release artifacts are built with a pinned Zig release** (the current stable, e.g. 0.16.x), never a moving master; the master-nightly CI leg is a canary that never publishes | A moving toolchain turns a green `master` build into an unreproducible release. The upstream projects whose docs we import track their master branch, but they are **never compiled into the server** — only parsed (D5) and shipped as runtime data (D3), so their churn cannot break our build | Building releases from master nightly — rejected as unreproducible |
| D10 | Legacy clients (pre-`2026-07-28`) are supported by **version inference, not a second code path**: a request whose `_meta` is absent is treated as `2025-06-18`, and the `initialize` alias returns the old-style result shape | Older clients send no `_meta` at all, so the strict `-32602` check would reject them outright. One parser with a "version inferred" flag keeps the wire layer single-path while remaining compatible | A full second protocol implementation — doubles the surface and drifts; dropping legacy support — breaks deployed clients |

### 2.1 Architectures brainstormed and rejected

The request was "easily updatable, mostly through CI/CD, tracking the master branch". Four update models were considered before choosing the CI-published-artifact model:

| Model | How updates reach the agent | Why rejected |
|---|---|---|
| **A. Embed everything in the binary** | Rebuild the binary on every upstream bump | Every upstream commit becomes our release. Rebuild latency and release churn make "mostly CI" impossible; the binary is no longer a stable thin host. Kept only for the tiny bundled fallback index |
| **B. Server clones/fetches upstream at startup** | The server pulls `master` itself and indexes on launch | The agent's query latency now depends on a network clone; the server breaks when an upstream master is mid-breakage; indexing cost is paid per launch instead of once per bump; no auditable diff of what changed. This is the model the whole plan rejects |
| **C. CI builds the index, the server downloads it at startup** | Index artifact is published by CI; server fetches it once per launch | Still requires a server restart to see a new index, so "update" means "restart the client's subprocess". Acceptable, but strictly worse than D |
| **D. CI builds the index, the server hot-reloads it (chosen)** | Index artifact is published by CI; the running server polls/watches it, validates, and atomically swaps | Chosen: the binary is stable, the update is a data swap, freshness is bounded by a short `ttlMs` and a short poll interval, and a broken upstream cannot take the server down (the last good index keeps serving) |

Two sub-questions the same brainstorm settled:

- **Should the indexer live in the server binary or in CI?** In CI. The indexer is a build-time tool (`tools/indexer.zig`); the server only ever *reads* the artifact. Shipping the indexer in the server would put upstream-parse failure modes in the request path.
- **Should upstream `master` be a floating dependency?** No. Zig's package manager freezes every URL to a commit at fetch time, so "tracking master" is necessarily an explicit re-pin step — that is the bump job (D6). The index, not the dependency graph, is what actually follows master.

---

## 3. Evidence base

### 3.1 Verified locally (Zig 0.16.0, `C:\Users\Sethticles\scoop\apps\zig\0.16.0`)

| Fact | How it was verified |
|---|---|
| `std.Io.File.stdin()/stdout()/stderr()` exist; `file.writer(io, &buf)` → `.interface`; `std.fs.File` **no longer exists** in 0.16 | Probe compiled and ran with `std.Io.File.stdout().writer(init.io, &buf)`; `std.fs.File` failed to compile |
| `std.process.Init` exposes `gpa`, `io`, `arena`, `environ_map` | `lib/std/process.zig:30` |
| `std.json` provides `Value`, `ObjectMap`, `Stringify` (`beginObject`/`objectField`/`endObject`) | `lib/std/json.zig:1-63` |
| `std.compress.zstd` exists | `lib/std/compress/` listing |
| `std.http.Client.fetch(client, options)` is a one-shot, threadsafe request; the body is written to a caller-supplied buffer via `FetchOptions.response_writer`, and `FetchResult` exposes only `status` (no `ETag`/conditional-GET support) | `lib/std/http/Client.zig:1801` (`fetch`), `:1754` (`FetchOptions`), `:1787` (`FetchResult`) |
| `std.zig.Ast.parse` takes a **sentinel-terminated** source (`[:0]const u8`) and **does not fail on malformed input** — syntax errors are collected in `tree.errors` (the AST is still returned) | Probe: a deliberately broken source parsed successfully with `errors.len = 1` (`expected_type_expr`) |
| `tree.tokens.items(.tag)` returns `[]Token.Tag` **directly** (not a struct with `.items`) | Probe compile error "`no member named 'items' in '[]zig.tokenizer.Token.Tag'`" |
| `ast.tokenSlice(i)` takes a `u32` `TokenIndex` and returns the **whole comment including the `///` prefix** | Probe: `tok[2] doc_comment slice=[/// Doc for Foo.]` |
| A declaration's doc is the contiguous run of `.doc_comment` tokens immediately preceding `ast.firstToken(decl)`; `firstToken` of a `pub` decl is the `pub` keyword | Probe: `pub const Foo` → `first_tok=4 tag=keyword_pub`, doc run = tokens 2..3; `pub fn topLevel` → `first_tok=35`, doc run = token 34 |
| `fullContainerDecl(&buf, node)` returns an optional; the capture payload exposes members as `cd.ast.members` (**not** `cd.members`) | Probe compile error "no field named 'members' in struct 'zig.Ast.full.ContainerDecl'" |
| `fullVarDecl(decl).?.ast.init_node` is a `Node.OptionalIndex`; `.unwrap()` yields `?Node.Index` (no manual `@enumFromInt` needed on this path) | Probe: `vd.ast.init_node.unwrap() orelse continue` compiled and returned a valid node index |
| Container initializer node tags are `container_decl`, `container_decl_trailing`, `container_decl_two`, `container_decl_two_trailing`, `container_decl_arg`, `container_decl_arg_trailing` (plus `tagged_union*` variants) — `fullContainerDecl` covers all of them | Probe: `pub const Foo = struct {…}` → init node tag `container_decl_two_trailing`, one member (`container_field_init`) with its doc found by the backwards token walk |
| **Error-set members are not AST nodes.** An `error_set_decl` node carries only `{` and `}` token indexes (`nodeData(node).token_and_token`); members are plain `identifier` tokens in the stream, each optionally preceded by a `.doc_comment` token | Probe: error set braces 23..29 → `tok[24] doc_comment [/// Error member doc.]`, `tok[25] identifier [Bad]`, `tok[26] comma`, `tok[27] identifier [Other]` |
| Function **parameter** docs are reachable: `ast.fullFnProto(&buf1, decl)` (optional) gives `name_token`, and `proto.iterate(&tree)` yields `Param{ first_doc_comment, name_token, … }` | Probe: `fn name = [doThing]`, `param src doc=[/// The source buffer.]`, `param count doc=[/// How many bytes to copy.]` |
| `std.Io.File.stdout().writer(io, &buf)` returns a **buffered** writer — output does not appear until `.flush()` | Probe printed nothing until `out.flush()` was added |
| `zig build-lib -femit-docs <file.zig>` writes `docs/{index.html,main.js,main.wasm,sources.tar}` into the **current working directory** (no `-femit-docs-dir` flag in 0.16) | Probe: `zig build-lib -femit-docs .probe/doc_fixture.zig` → `docs/` created in the repo root; `-femit-docs-dir` is "unrecognized parameter" |
| `zig fetch --save=NAME "git+https://github.com/ziglang/docgen.git#main"` resolves a branch to a commit and writes `url = "git+https://…git?ref=main#<sha>"` + content `hash` | Ran; resolved to `ff2a1ee7b9f61bb84d885dd301415277b7de5e0a` |
| A `?ref=<branch>` URL with a frozen commit does **not** float — `#master` fails when the remote lacks that branch | Ran `…#master` against docgen → `error: ref not found: master` (its default branch is `main`) |
| `zig build --fetch[=needed|all]` fetches the dependency tree; `b.dependency(name, args).module("x")` wires a dependency module | `zig build --help` output; `lib/std/Build.zig` `Dependency.module` |
| `Step.Compile.getEmittedDocs()` returns the generated docs dir; `Module.addEmbedPath`/`addAnonymousImport` exist | `lib/std/Build/Step/Compile.zig:889`, `lib/std/Build/Module.zig:507` |

### 3.2 From Context7 / upstream specs

- **MCP revision `2026-07-28`** is the current spec revision; `server/discover` is a mandatory RPC returning `supportedVersions`, `capabilities`, optional `instructions`, and `_meta["io.modelcontextprotocol/serverInfo"]`.
- **Per-request `_meta` (SEP-2575, stateless protocol).** Required: `io.modelcontextprotocol/protocolVersion`, `io.modelcontextprotocol/clientCapabilities`. Optional: `io.modelcontextprotocol/clientInfo` (clients SHOULD send it), `io.modelcontextprotocol/logLevel`, `progressToken`. **A request missing a required field is malformed ⇒ `-32602` (Invalid params), not `-32600`.** (A request with *no* `_meta` at all is a pre-`2026-07-28` client — that revision has no per-request `_meta` — so it is version-inferred rather than rejected; see D10 and §7.4.)
- Every result **MUST** carry `resultType` (`"complete"` | `"input_required"`); clients MUST read an omitted field from an earlier-protocol server as `"complete"`. Servers **SHOULD** include `_meta["io.modelcontextprotocol/serverInfo"]` on **every** result, not only on `server/discover`.
- **Caching (SEP-2549) is a MUST, not an option.** `ttlMs` (integer ≥ 0) and `cacheScope` (`"public"` | `"private"`) are **required** on `resultType: "complete"` results of `server/discover`, `tools/list`, `prompts/list`, `resources/list`, `resources/templates/list`, `resources/read`. `input_required` interim results carry no cache hints.
- Error codes: `-32700` parse error; `-32600` invalid request (malformed JSON-RPC envelope); `-32601` method not found; `-32602` invalid params (missing required `_meta`, unknown tool, unknown prompt, invalid arguments, invalid cursor, **resource not found**); `-32603` internal error. Spec-reserved: `-32020` header mismatch (HTTP only), `-32021` missing client capability, `-32022` unsupported protocol version. `-32002` (legacy resource-not-found) **MUST NOT** be emitted. New application codes go outside `-32768..-32000`.
- Tool results: `content` is required; `structuredContent` optional (must conform to `outputSchema` when one is declared); `isError: true` marks a *tool-level* failure. An unknown tool name or invalid arguments are **protocol errors** (`-32602`), not `isError` results.
- Resources: a missing resource ⇒ `-32602` with `data.uri`; servers **MUST NOT** return an empty `contents` array for a non-existent resource.
- Capabilities: `tools` / `resources` / `prompts` objects with optional `listChanged`. `resources.subscribe` and the `logging` capability are deprecated; `resources/subscribe` + `resources/unsubscribe` are replaced by `subscriptions/listen` (a long-lived notification stream; on stdio the server terminates it with `notifications/cancelled`).
- Removed in `2026-07-28`: `ping`, `logging/setLevel` (now the per-request `logLevel` `_meta` field — a server MUST NOT emit `notifications/message` for a request that did not set it), `notifications/roots/list_changed`, protocol-level sessions / `Mcp-Session-Id`, and SSE resumability.
- Cancellation: `notifications/cancelled` remains **client → server** for in-flight requests (servers SHOULD stop processing and not respond); server → client it is used only to tear down a `subscriptions/listen` stream on stdio.
- stdio transport: one JSON-RPC message per line, **no embedded newlines**; stdout carries only MCP messages; stderr is for logs; exit promptly on stdin EOF.
- The protocol is **stateless**: no `initialize` handshake in the new revision; a server MUST NOT infer capabilities from prior requests. Clients MAY use `server/discover` as a backward-compatibility probe on stdio.
- Zig build system: `build.zig.zon` dependencies are `url`+`hash` or `path`; `hash` is the source of truth; `lazy = true` avoids fetching unused deps; `zig fetch --save` writes both.
- Zig docs are generated from `///` doc comments attached to declarations; `//!` gives file-level docs; `-femit-docs` is the compiler-side generator.
- `ziglang/docgen` is the autotested-documentation package (`build.zig.zon` name `.doctest`, `minimum_zig_version 0.15.0`) — the canonical implementation lives at `tools/docgen.zig` / `tools/doctest.zig` in the compiler repo. Its README still points at Zig 0.12-era output, so it is **reference only**: the doc-import path in this plan does not depend on it (D5 uses `std.zig.Ast` directly).

---

## 4. Architecture

```mermaid
flowchart LR
    subgraph clients
        C[MCP client\nClaude/Codex/Zed]
    end

    subgraph server[ZigMCP binary — stable, rarely rebuilt]
        IO[stdio transport\nnewline-delimited JSON]
        RPC[JSON-RPC + MCP layer\n_meta validation, resultType]
        REG[Capability registry\ncomptime table: tools/resources/prompts]
        ADVICE[Advice engine\nrule matcher over ZON rules]
        DOCS[Doc index loader\nJSONL → columnar in-memory index]
        RELOAD[Index hot-reload\nwatch → validate → atomic swap]
        SEARCH[Search\ntoken + symbol-path match]
    end

    subgraph data[Data plane — replaced by CI, not by rebuilds]
        AC[advice corpus\nZON: patterns/rules/guarantees/limits]
        DI[doc index\nindex.jsonl(.zst)]
    end

    C -- JSON-RPC lines --> IO --> RPC
    RPC --> REG
    REG --> ADVICE
    REG --> DOCS
    DOCS --> SEARCH
    ADVICE -- reads --> AC
    DOCS -- reads --> DI
    RELOAD -- watches --> DI
    RELOAD -- swaps in --> DOCS

    subgraph ci[CI/CD]
        BUMP[bump job\nre-resolve upstream master]
        IDX[index job\nrun indexer over upstream trees]
        REL[release job\nbinaries + index artifacts]
    end
    BUMP --> IDX --> REL
    REL -- publishes --> DI
    REL -- publishes --> AC
```

Runtime data flow per request: line → parse JSON → resolve protocol version (present `_meta` ⇒ validate; absent `_meta` ⇒ legacy inference, D10) → dispatch by method name through the capability registry → handler reads from the in-memory advice/doc structures → build result with `resultType` + `serverInfo` (+ cache hints where the spec requires them) → serialize → write one line to stdout **and flush it**. No per-request allocation of the corpus: both corpora are parsed once at startup into flat, arena-owned structures, and a republished index is swapped in wholesale rather than re-parsed per request (D3).

---

## 5. Repository layout

```
ZigMCP/
├─ build.zig                     # modules, exe, tests, index/doc steps
├─ build.zig.zon                 # upstream sources (hash-pinned), mcp-free deps
├─ .gitignore                    # zig-out/, .zig-cache/, .probe/, docs/, generated/, native byproducts
├─ PLAN.md
├─ readme.md
├─ src/
│  ├─ main.zig                   # entry: load corpora, run stdio loop
│  ├─ protocol/
│  │  ├─ json_rpc.zig            # request/response/notification types
│  │  ├─ meta.zig                # _meta parse + version negotiation (D10 inference)
│  │  └─ errors.zig              # -32700/-32600..-32603, -32020/-32021/-32022
│  ├─ transport/
│  │  └─ stdio.zig               # newline framing, stdout purity, per-line flush
│  ├─ server/
│  │  ├─ registry.zig            # comptime capability table (D8)
│  │  ├─ discover.zig            # server/discover
│  │  ├─ tools.zig               # tools/list, tools/call
│  │  ├─ resources.zig           # resources/list, resources/read, templates
│  │  └─ prompts.zig             # prompts/list, prompts/get
│  ├─ advice/
│  │  ├─ corpus.zig              # ZON schema + loader
│  │  ├─ rules.zig               # P02/P05 rule matcher over SELECT rules
│  │  └─ render.zig              # record → MCP resource/prompt text
│  ├─ docs/
│  │  ├─ index.zig               # JSONL record schema + loader
│  │  ├─ columnar.zig            # P03 layout: offsets + string table
│  │  ├─ reload.zig              # artifact watch + validate-then-atomic-swap (D3)
│  │  └─ search.zig              # symbol/path/token queries
│  └─ util/
│     └─ arena_pool.zig          # reusable buffers, no per-request allocs
├─ data/
│  ├─ advice/
│  │  ├─ patterns.zon            # P01…P12 records
│  │  ├─ rules.zon               # 12 conditional decision rules
│  │  ├─ guarantees.zon          # cross-cutting constraints
│  │  └─ limits.zon              # LIMITS + evidence-label legend
│  └─ sources.zon                # upstream projects, branch + path scope
├─ tools/
│  ├─ indexer.zig                # upstream tree → index.jsonl (D5)
│  └─ advice_check.zig           # corpus validation (ZON schema, S-ID refs)
├─ generated/                    # CI-produced; not hand-edited
│  └─ index.jsonl
└─ .github/workflows/
   ├─ ci.yml                     # build/test/fmt matrix (pinned stable = release; master = canary)
   ├─ bump-master.yml            # scheduled: re-resolve upstream master
   ├─ index.yml                  # regenerate + publish index
   └─ release.yml                # tagged binaries + artifacts
```

---

## 6. Data model

### 6.1 Advice corpus (`data/advice/*.zon`)

`patterns.zon` — one record per concept P01…P12:

```zon
.{
    .id = "P03",
    .name = "Data-oriented design",
    .what_data_controls = "Physical representation and transformations",
    .facts = [
        .{ .text = "Fabian emphasises data, transformations, workload characteristics, and the executing machine.", .source = "S15" },
        .{ .text = "DPDK guidance includes memory pools, per-core data, alignment, and NUMA-local allocation.", .source = "S06" },
    ],
    .candidate_uses = ["Memory-intensive loops", "Bulk processing", "Repeated access to subsets of records"],
    .boundaries = ["Data-oriented layout is distinct from configuration-driven behaviour", "Does not require machine learning"],
    .checks = ["Actual field access", "Ownership", "Lifetime", "Shared writes", "Allocation", "Conversion costs", "Target hardware"],
    .evidence = .synthesis,      // FACT | RESULT | SYNTHESIS | GUIDANCE
    .sources = ["S06", "S15"],
}
```

`rules.zon` — the 12 conditional decision rules, expressed as data so the engine is a generic interpreter:

```zon
.{
    .id = "R03",
    .condition = "Measured memory/access bottleneck",
    .then = .{ .consider = ["P03"], .and_only_if = "Composition/query organisation fits" },
    .evidence = .guidance,
}
```

`guarantees.zon` — cross-cutting constraints (batching vs latency, RCU publication/reclamation, memory safety ≠ event ordering, CALM monotonicity conditions, ML system debt → version/provenance/recovery).

`limits.zon` — the LIMITS section verbatim-in-spirit plus the evidence-label legend, so the server never presents `GUIDANCE` as `FACT`.

**Fidelity rule (from the source document):** `FACT`/`RESULT`/`SYNTHESIS`/`GUIDANCE` labels and `S01`…`S24` source IDs travel with every record, and every advice resource carries a pointer to its source registry entries. The server must not launder hypotheses into facts.

### 6.2 Doc index record (JSONL, one object per line)

```json
{"project":"zig-std","commit":"ead8f5a7…","path":"lib/std/mem.zig","line":812,"kind":"fn","symbol":"mem.copyForwards","container":"mem","doc":"Copies `source` into `dest`. …","doc_hash":"…"}
```

| Field | Purpose |
|---|---|
| `project` | Upstream project key from `sources.zon` |
| `commit` | Exact upstream commit the record was extracted from (provenance) |
| `path`, `line` | Source location (1-based) |
| `kind` | `fn` / `var` / `field` / `container` / `error` / `param` |
| `symbol` | Fully qualified symbol path (`mem.copyForwards`, `ArrayList.Writer.write`) |
| `doc` | Cleaned doc text (`///` stripped, paragraphs joined) |
| `doc_hash` | Hash of `doc`, for incremental re-indexing |

`//!` container docs become `kind: "container"` records with `symbol` = module path.

### 6.3 Upstream sources (`data/sources.zon`)

```zon
.{
    .zig_std = .{
        .url = "git+https://github.com/ziglang/zig.git?ref=master#<sha>",
        .hash = "…",
        .scope = .{ .include = ["lib/std/**"], .exclude = ["lib/std/**/testdata/**"] },
    },
    .mcp_zig = .{
        .url = "git+https://github.com/muhammad-fiaz/mcp.zig.git?ref=main#<sha>",
        .hash = "…",
        .scope = .{ .include = ["src/**"] },
    },
}
```

---

## 7. MCP surface

### 7.1 Tools

| Tool | Input | Output | Why it exists |
|---|---|---|---|
| `advice_lookup` | `{ "concept": "P03" }` or `{ "question": "…" }` | The advice record: controls, facts, candidate uses, boundaries, checks, evidence label, sources | Primary advice access; question mode does token matching over records |
| `recommend_approach` | `{ "signals": ["repeated recomputation over changing inputs"], "constraints": {...} }` | Ranked candidate approaches with the matched rule IDs and their evidence labels | Applies the SELECT rules as an interpreter (P05), keeps rule provenance visible |
| `doc_search` | `{ "query": "arena allocator", "project": "zig-std", "limit": 20 }` | Matching index records with `path:line` and doc excerpts | Cross-project doc retrieval |
| `doc_get` | `{ "project": "zig-std", "symbol": "mem.copyForwards" }` | Full doc text, source location, upstream commit | Precise retrieval for a known symbol |
| `doc_import_status` | `{}` | Per-project: pinned commit, index record count, index freshness vs upstream master, and the count + diagnostic tags of degraded files | Makes G3 observable to the agent instead of mysterious, and surfaces upstream breakage instead of hiding it |

All five tools are read-only: the registry sets `annotations.readOnlyHint = true`, `destructiveHint = false`, `idempotentHint = true`, `openWorldHint = false` (they read only local in-memory data), and each declares an `outputSchema` so results also ship as `structuredContent` matching that schema.

`limit` is clamped (default 20, max 100). A query that matches nothing returns a normal result with `isError: true` and an explanatory message — never a JSON-RPC error, because the call itself succeeded.

### 7.2 Resources

| URI | Content |
|---|---|
| `advice://overview` | The 12 patterns as a compact table (id, name, controls, evidence label) |
| `advice://patterns/{P01..P12}` | One pattern record, full text |
| `advice://rules` | The 12 conditional decision rules |
| `advice://guarantees` | Cross-cutting guarantees |
| `advice://limits` | Limits + evidence-label legend |
| `advice://sources` | S01…S24 registry with URLs |
| `docs://{project}/symbols/{symbol}` | One index record, rendered |
| `docs://{project}/index` | Project-level symbol listing (paginated by the client) |

`docs://{project}/symbols/{symbol}` is exposed as a **resource template** (`resources/templates/list`), not as a literal resource — the symbol space is unbounded, so listing every instance would be meaningless. `advice://patterns/{P01..P12}` *is* enumerable (12 fixed IDs) and is listed literally.

### 7.3 Prompts

| Prompt | Arguments | Content |
|---|---|---|
| `systems_review` | `{ "design": "…" }` | A review prompt that pulls the matching advice records, their checks, and their boundaries, and explicitly asks the model to keep `GUIDANCE` separate from `FACT` and to state which checks were not run |
| `approach_selection` | `{ "situation": "…" }` | Applies `recommend_approach` and asks for the matched rule IDs to be cited in the answer |

### 7.4 Protocol handling rules

- **Version resolution (D10 carve-out).** A request whose `params._meta` is **entirely absent** is a **legacy** request: it is treated as protocol version `2025-06-18`, the `_meta` requirements below do not apply to it, and its response omits `resultType` and the cache hints (that revision has no such fields). The legacy `initialize` alias still returns the old-style result (`protocolVersion`, `capabilities`, `serverInfo`). A request whose `_meta` **is present but missing a required field** is malformed ⇒ `-32602` (`Invalid params`). `clientInfo` is optional in both revisions (accepted and ignored beyond logging). `supportedVersions` lists `["2026-07-28", "2025-06-18"]`.
- A `2026-07-28` request must carry `_meta["io.modelcontextprotocol/protocolVersion"]` and `_meta["io.modelcontextprotocol/clientCapabilities"]`.
- Version not in `supportedVersions` ⇒ `-32022` with the supported list.
- Every result object carries `resultType` (`"complete"` for now; `"input_required"` reserved) and `_meta["io.modelcontextprotocol/serverInfo"]` = `{ name, version }` — on `2026-07-28` responses.
- **Cache hints are mandatory** on `resultType: "complete"` results of `server/discover`, `tools/list`, `prompts/list`, `resources/list`, `resources/templates/list`, `resources/read`: `ttlMs` (≥ 0) and `cacheScope` (`"public"` | `"private"`). Policy: static advice resources get a long TTL (`"public"`); anything derived from the current index gets a short TTL (e.g. 60 s, `"private"`) so a freshly republished index is picked up quickly.
- `tools/list` ordering is deterministic (sorted by name) so clients can cache it.
- Unknown tool, unknown prompt, invalid arguments, invalid cursor, unknown resource URI ⇒ `-32602`. A malformed JSON-RPC envelope ⇒ `-32600`; unparseable line ⇒ `-32700`; unknown method ⇒ `-32601`.
- Application-level failures inside a tool (e.g. "no advice matched") are returned as tool results with `isError: true`, not JSON-RPC errors. Tool *dispatch* failures (unknown name, bad arguments) are `-32602`.
- Logging is opt-in per request via `_meta["io.modelcontextprotocol/logLevel"]`; without it the server MUST NOT emit `notifications/message`. Diagnostics still go to stderr.
- stdout carries MCP messages only; all diagnostics go to stderr.
- **Every response line is flushed before the next request is read.** `std.Io.File.stdout().writer(io, &buf)` is buffered (verified: nothing appeared until `.flush()`), so the transport writes the line and flushes it immediately — otherwise a client waiting on the response deadlocks while the bytes sit in the buffer.
- On stdin EOF, flush and exit 0.

---

## 8. Doc import pipeline

### 8.1 Indexer (`tools/indexer.zig`)

Input: one or more source trees (from the package cache after `zig build --fetch`, or a CI clone) plus a `sources.zon` scope. Output: `generated/index.jsonl`.

Algorithm per `.zig` file:

1. Read the file and NUL-terminate it (`[:0]const u8`) — `std.zig.Ast.parse` requires a sentinel-terminated source.
2. `std.zig.Ast.parse(gpa, source, .zig)`. **A malformed file does not throw**: the AST is returned with diagnostics in `tree.errors` (Zig stores warnings and errors in the same list — there is no severity field; `Ast.Error` carries `tag`, `is_note`, `token`, `extra`). **Policy: extract records from every parsed file regardless of diagnostics.** The AST of a file with a syntax error is still usable for the parts that parsed, and D5's whole point is that a mid-breakage upstream master still yields docs. Each file's diagnostics (tag + line) are recorded in the status output, and a file with any diagnostic is marked **degraded** there. There is no curated "fatal tag" list — that would be maintenance debt against a stdlib that does not distinguish severity, and it would discard good docs over one bad line.
   The one quality gate is the attachment rule below: a doc run the parser flagged `.unattached_doc_comment` is dropped, because it has no declaration to attach to.
3. Collect `//!` container docs: the leading run of `.container_doc_comment` tokens → one `kind: "container"` record (module path from the file path). Verified: these are tokens 0..n at the head of the file.
4. Walk declarations recursively:
   - `ast.rootDecls()` for top level.
   - For a `var`/`const` whose initializer is a container (`container_decl*` / `tagged_union*` tags), recurse into `ast.fullContainerDecl(&buf2, init_node)` and iterate `cd.ast.members`, prefixing the symbol path. `fullContainerDecl` returns an optional; the capture payload is the unwrapped value.
   - For a `fn_decl`, take the name from `ast.fullFnProto(&buf1, decl).?.name_token`, then iterate `proto.iterate(&tree)` to emit a `kind: "param"` record for every parameter that has a `first_doc_comment`.
   - For a `container_field_init`, take the field name token.
   - **Error sets are not AST nodes.** An `error_set_decl` node carries only the `{` and `}` token indexes (`nodeData(node).token_and_token`); members are plain `identifier` tokens. So error-set members are extracted by **scanning the token range between the braces**: for each `identifier` token, look backwards for a contiguous `.doc_comment` run → one `kind: "error"` record per documented member.
5. For each declaration, compute its doc text: walk **backwards** from `ast.firstToken(decl) - 1` to find the **start** of the contiguous run of `.doc_comment` tokens, then walk **forwards** from that start to the token immediately before the declaration to collect the whole run **in source order** (a two-line doc comment is two tokens — verified: the run for `pub const Foo` spanned tokens 2..3). Strip the `///` prefix from each token slice, join the lines with `\n`, and preserve blank lines between paragraphs. `ast.tokenSlice` returns the comment **including** its `///` prefix, so stripping is mandatory.
6. Emit a record per declaration that has a doc comment. Declarations without docs are skipped (they carry no retrieval value) but counted for the status report.
7. Hash the cleaned doc text for incremental comparison.

**Attachment rule (pinned, deterministic):** a doc run attaches to the declaration whose `firstToken` immediately follows it in the token stream — the run of `.doc_comment` tokens directly preceding `ast.firstToken(decl)`, with no intervening token. Verified behaviour: a blank line between the comment and the declaration does **not** break the association (a blank line is not a token, and the Zig parser itself reports **no** diagnostic for that case — a doc comment is only flagged `.unattached_doc_comment` when it is followed by nothing, i.e. at the end of a file or container). **Pinned rule: attach the immediately preceding contiguous `.doc_comment` run; a doc run that the parser flagged `.unattached_doc_comment` (by token index) is dropped.** The rule is fixed by the golden fixture (§10.2), so a change in Zig's attachment semantics is caught by a test rather than silently changing the index.

Robustness rules (the whole point of D5): a file with parse diagnostics must **not** fail the run and must **not** be discarded — its usable records are still extracted, and its diagnostics are recorded so `doc_import_status` can report the file as degraded. An upstream master branch that is mid-breakage still yields usable docs.

### 8.2 Symbol paths

Qualified by container nesting: `mem.copyForwards`, `ArrayList.Writer.write`, `std.debug.print`. The indexer tracks the container path syntactically (from the AST), not by semantic resolution — semantic resolution would require compiling the upstream project, which D5 rejects.

### 8.3 Incremental refresh

The index stores `doc_hash` per record and the upstream `commit` per project. On re-index, a project whose commit is unchanged is skipped entirely; a changed project is re-extracted and compared record-by-record, so the CI PR shows only genuinely changed doc text.

### 8.4 Optional compiler-side docs (`-femit-docs`)

Where an upstream project builds cleanly on our toolchain, `zig build-lib -femit-docs` (or a `Step.Compile.getEmittedDocs()` step in a dedicated build) produces a full static site with resolved types. This is **complementary**, not the index source: it is heavy, per-project, and fails when upstream master breaks. It is planned as an optional artifact attached to releases for human browsing.

### 8.5 Upstream sourcing and master tracking

- Sources are declared in `data/sources.zon` with a branch (`master`, `main`) and the resolved commit + package hash.
- The **bump job** re-resolves each branch with `zig fetch --save=NAME "git+https://host/org/repo.git#<branch>"` in a scratch checkout, producing a new pinned commit + content hash (the written URL becomes `…git?ref=<branch>#<sha>`), then opens a PR that updates `build.zig.zon` / `data/sources.zon`.
- The **index job** then re-extracts docs for changed projects and regenerates `generated/index.jsonl`.
- Publishing: the index is attached to a GitHub Release and also served from a stable URL. The server resolves its index from `ZIGMCP_INDEX` (a local path or an HTTP(S) URL) at startup, falling back to a bundled minimal index.
- **Runtime refresh without a rebuild (the point of D3):** the server watches the resolved index artifact and, when a new version appears, parses and validates it **fully** into a fresh arena before atomically swapping the active pointer. The old index is released only after the swap. A failed or partial fetch leaves the previous index serving — the server never mutates live structures in place and never starts with a half-valid index.
  - **Local path:** poll the file's mtime + size (cheap, no network stack). When either changes, re-read and re-parse.
  - **Remote URL:** `std.http.Client.fetch` (Zig 0.16, verified) is a one-shot, threadsafe request whose body is written to a caller-supplied buffer via `FetchOptions.response_writer`; `FetchResult` exposes only `status`. There is **no conditional-GET support** in that API (no `ETag`/`If-None-Match` plumbing), so v1 refreshes a remote index by re-fetching on the poll interval and comparing the **content hash** of the downloaded bytes against the active index. Conditional requests are deferred until the stdlib exposes them.
  - The watcher runs on a **background thread** and is the **only writer** of the active index pointer; request handlers only ever read it. The §10.2 integration test covers exactly this: a reload concurrent with in-flight requests must produce no torn reads.
- Client-side freshness: index-derived results carry a short `ttlMs` (≈60 s, `"private"`), so a client re-fetches after CI publishes a new index without the client needing to know anything about the pipeline.

### 8.6 CI/CD workflow mechanics

The four workflows are deliberately separated so a failure in one never blocks the others.

| Workflow | Trigger | What it does | Failure behaviour |
|---|---|---|---|
| `ci.yml` | push + PR | Build + test + `zig fmt --check` on the pinned stable Zig (release leg, 3 OS) and on `master` nightly (canary leg, non-publishing) | Canary breakage is reported but never blocks a release; stable-leg breakage blocks the merge |
| `bump-master.yml` | scheduled (daily) + manual dispatch | For each source in `data/sources.zon`, re-resolve the tracked branch in a scratch checkout with `zig fetch --save`, then run `tools/indexer.zig` over the freshly pinned trees **in that same checkout** and diff the resulting index against the last published one. Opens **at most one** PR for all projects, and only if that diff is non-empty; the PR updates the pins and carries the JSONL diff (per project: old commit → new commit, changed-record count) | A branch that no longer exists (or was renamed) fails that project only; the PR states which source failed and keeps its previous pin. If no doc text changed upstream, no PR is opened — the pins and the published index stay in agreement |
| `index.yml` | `workflow_run` after the bump PR merges + manual dispatch | Re-run `tools/indexer.zig` over the merged pinned trees, write `generated/index.jsonl` (sorted by `(project, symbol)`), and publish the artifact | A file with parse diagnostics still contributes its usable records and is reported as degraded; the run publishes the rest regardless |
| `release.yml` | tag `v*` | Build release binaries with the **pinned stable** Zig, attach the current index artifact, publish client configuration snippets | Reproducible from the pinned toolchain + pinned upstream commits (D9) |

Noise control (the failure mode that kills bot-driven repos): the bump job opens a PR **only if the resulting index actually differs** — the gate is computed in the bump job's own scratch checkout, before the PR exists, so the decision never depends on a later workflow. The PR body lists, per project, the old commit, the new commit, and the count of changed doc records. The JSONL diff is attached to the PR as a workflow artifact (the index itself stays out of the repo — `generated/` is gitignored) — a reviewer reads doc text changes, not a binary blob.

Rollback: because the index is a separately published artifact and the server keeps the last good one in memory, rollback is "publish the previous index" — no binary rebuild, no client action beyond the short TTL.

---

## 9. Applying the systems-programming advice to this system

The source document is not a mandate, so each row states the concrete use in *this* codebase. Rows marked "excluded" are deliberate, with the reason the document itself gives.

| Pattern | Use in ZigMCP | Notes |
|---|---|---|
| P01 table/config driven | Advice corpus, upstream source list, and the capability registry are all tables interpreted by a small engine | Adding a tool = adding a row + handler; adding advice = editing ZON |
| P02 pattern–action | `advice_lookup` question mode and `doc_search` match input patterns to records | Explicit default behaviour on no match; multiple matches returned with scores |
| P03 data-oriented | Doc index held columnar (offsets into one string table, parallel arrays) rather than per-record heap objects | Layout chosen after measuring record count and query mix; scan-friendliness for the common "list symbols in a project" query |
| P05 declarative/relational | The 12 SELECT rules are relational data over (condition → consider → constraint); `recommend_approach` is a join over them | Fewer lines ≠ lower total cost; the join cost is measured, not assumed |
| P07 schema-driven generation | Two-stage build: upstream source → parsed IR → generated index artifact; tool version recorded in the artifact header | Binding time is explicit: parse at CI time, load at runtime, no hot-path codegen |
| P09 event/descriptor driven | stdio I/O with explicit buffer lifetimes; each response is written to a fixed buffer and **flushed before the next request is read** | Buffer ownership, the flush-before-read rule (an unflushed response hangs a blocking client), EOF handling, and shutdown are the failure surfaces |
| P04 ECS | Not used | No entity population with varying component sets here; composition is static |
| P06 dataflow/incremental | Incremental re-index keyed by `commit` + `doc_hash`; the running server re-derives its index when the artifact changes | CI-side re-index is incremental; server-side is a **whole-index swap**, not a partial mutation — incremental maintenance cost is paid once per bump, not per request |
| P08 programmable infra | Not used | The server extends nothing in the OS; it is an extension point itself |
| P10 PGO | Excluded | Needs representative deployment workloads; a stdio server has none worth profiling |
| P11 learned index | Excluded | Must beat a tuned exact baseline (B-tree/binary search over a sorted symbol table) — that baseline is not built or measured yet |
| P12 learned runtime policy | Excluded | No complex resource decision with a measurable objective exists in this workload |

Cross-cutting guarantees applied to this server:

- **Memory safety ≠ event ordering** — a request may be well-formed and still race with an index reload; the reload path is atomic-replace, never in-place mutation of live structures.
- **Publication and reclamation** — a reloaded index is fully parsed and validated before it becomes the active pointer; the old one is dropped only after the swap (reference-style publication, no torn reads).
- **Bounded timing** — request handling has an explicit size cap on inputs (query length, `limit` clamped) and on output (response bytes capped), so a hostile or accidental query cannot exhaust memory.
- **Version provenance** — every doc record carries the upstream commit it came from; the advice corpus carries its version (`version: 1`, `source_research_date`); the server's `serverInfo.version` is the build's own version. This is the document's "retain model/configuration versions, decision provenance, and a defined recovery path" applied to ourselves.

---

## 10. Verification plan

Adapted from the source document's VERIFY section, made project-specific.

### 10.1 Semantics to pin down before implementation

- Exactness: doc text is verbatim except for `///` prefix stripping and paragraph joining.
- Doc attachment: a doc run attaches to the declaration whose `firstToken` immediately follows it in the token stream; a doc run flagged `.unattached_doc_comment` by the parser is dropped (§8.1). Pinned by the golden fixture.
- Permitted order: `tools/list` sorted by name; index records sorted by `(project, symbol)`.
- Failure behaviour: a file with parse diagnostics still contributes the records that could be extracted, and is reported as **degraded** with its diagnostic tags and lines; the server never fails to start because of one bad file (§8.1).
- Memory limits: index load must stay under a stated ceiling (to be measured on first build; candidate 256 MiB RSS for the full corpus).
- Deadlines: no wall-clock deadline claim is made for stdio request handling; instead, p50/p95/p99 latency is reported.

### 10.2 Test layers

| Layer | What is tested | Rule |
|---|---|---|
| Unit | Doc-comment extraction (single/multi-line, `//!` containers, error-set members, params, nested containers), `tree.errors` handling (degraded file still yields records), rule matcher, JSONL parser, index columnar layout, symbol-path construction | Deterministic, isolated, no network |
| Property/fuzz | Malformed JSONL lines, truncated UTF-8 doc text, pathological queries, missing `Sxx` references in the corpus | Fuzz targets: JSONL loader, `_meta` parser, query parser |
| Golden | Indexer output vs. checked-in golden JSONL for a fixed upstream fixture, covering: single/multi-line `///`, multi-paragraph docs, `//!` container docs, struct fields, methods, params, error-set members, a doc separated from its declaration by a blank line, a trailing unattached doc comment, a warning-only file, and a file with a syntax error | Catches silent extractor regressions and pins the attachment rule and the degrade-not-skip policy (§8.1) |
| Protocol | `server/discover` shape, `_meta` validation (`-32602` on a present-but-incomplete `_meta`), legacy path (absent `_meta` ⇒ `2025-06-18` semantics, `initialize` alias shape), `-32022` on bad version, `resultType` + `serverInfo` present on every `2026-07-28` result, mandatory `ttlMs`/`cacheScope` on the six cacheable methods, `-32602` on unknown tool/resource, `-32600` on malformed envelope, `-32700` on unparseable line, stdout purity (no stray prints), **response flushed before the next request is read** (a client that writes one request and blocks on the response must not hang), clean exit on EOF | Drives the server as a subprocess over pipes, exactly as a client would |
| Integration | Index reload by the background watcher concurrent with in-flight requests (atomic swap, no torn reads, the watcher is the only writer), cancellation notification, resource exhaustion (oversized query, huge `limit`) | Model the P09 boundary conditions explicitly |
| End-to-end | A scripted client session: discover → list tools → call each tool → read a resource → get a prompt | On the CI matrix OS set |

Permanent tests must catch consumer-visible defects (behaviour, boundaries, invariants, transitions, precedence, errors) — not wiring, not mock echoes, not source-text assertions.

### 10.3 Reporting

Per CI run, record: build config, Zig version, upstream commits, corpus record counts, index build time, index size, server startup time, per-tool p50/p95/p99 latency, peak RSS, error counts. Lifecycle accounting per the document: execution savings minus preparation, conversion, validation, update, and coordination costs — for this project, the dominant prep cost is the CI index build, which is paid once per upstream bump, not per request.

### 10.4 Baselines to compare against (for the P11 exclusion to stay honest)

Before any future claim about a smarter index, build and measure: (a) linear scan over JSONL, (b) binary search over a sorted symbol table, (c) a token inverted index. Only if a candidate beats those on the measured workload does it enter the design.

---

## 11. Milestones

| # | Milestone | Contents | Acceptance criteria |
|---|---|---|---|
| M0 | Repo scaffold + protocol core | `build.zig`, `build.zig.zon`, stdio transport, JSON-RPC types, `_meta` validation + version inference (D10), the legacy `initialize` alias (D7), `server/discover` | `server/discover` returns a spec-shaped result (`supportedVersions`, `capabilities`, `serverInfo`, `ttlMs`, `cacheScope`); malformed requests get `-32600`, present-but-incomplete `_meta` gets `-32602`; a request with no `_meta` is served with legacy semantics (no `resultType`, no cache hints) and `initialize` returns the old-style result; a response is flushed before the next request is read; stdout stays pure; exit 0 on EOF |
| M1 | Advice corpus | `data/advice/*.zon` transcribed from `systems_programming_context_v1.md` (P01…P12, 12 rules, guarantees, limits, S01…S24), loader, `advice_lookup` + `recommend_approach` tools, `advice://*` resources, `systems_review` + `approach_selection` prompts (both of §7.3) | Every record carries its evidence label and source IDs; `advice_check` tool fails the build on a dangling `Sxx` reference or a missing evidence label; both prompts return advice that keeps `GUIDANCE` separate from `FACT` and cites the matched rule IDs |
| M2 | Doc index | `tools/indexer.zig`, JSONL format, columnar loader, `doc_search` / `doc_get` / `doc_import_status` tools, `docs://*` resources | Indexer reproduces the golden fixture (fields, methods, params, error-set members, container docs, a warning-only file, a file with a syntax error); a degraded file still contributes its usable records and is reported as degraded; search returns `path:line` |
| M3 | CI/CD | `ci.yml` matrix (pinned stable = release toolchain × 3 OS; master nightly = canary, non-publishing), `bump-master.yml`, `index.yml`, `release.yml`, install/client-config docs | A scheduled run whose upstream docs actually changed opens one bump PR (pin updates + JSONL diff) and, after it merges, republishes the index **without any source change**; a run whose upstream commits changed no doc text opens no PR; release artifacts include binaries and the index; release artifacts are reproducible from the pinned stable toolchain (D9); the published index carries a short cache TTL so clients see the new index without a server rebuild |
| M4 | Hardening & polish | Fuzz targets, concurrency integration test, `docs://` pagination, `--index`/env configuration, `instructions` field on discover, optional `-femit-docs` artifact | Verification report published with each release; all §10.2 layers green on the matrix |

---

## 12. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Upstream master breaks (build or parse) | Index goes stale or degraded | Parsing does not require compilation (D5); a file with parse diagnostics still contributes its usable records and is reported as degraded; the last good index remains servable if a refresh fails outright |
| `std` API churn across Zig releases (0.16 → 0.17 → master) | Build breaks on the matrix | The release leg is pinned to a stable Zig (D9) and never breaks from upstream churn; the master-nightly leg runs as a **non-publishing canary** so breakage is seen early, and the server's use of std is confined to `Io`, `json`, `compress`, `mem` |
| Protocol revision churn | Client incompatibility | Version negotiation via `_meta` + `-32022`; `supportedVersions` is data, so adding a revision is a data change; legacy `initialize` alias (D7) |
| CI bot churn (frequent upstream commits → noisy PRs) | Review fatigue | Bump job batches (e.g. daily), groups by project, and only opens a PR when the *doc index* actually changes; index diffs are reviewable JSONL |
| Index size growth | Memory/latency | Measure RSS (§10.3); `.zst` shipping option; per-project scoping in `sources.zon`; a symbol-only index mode if the corpus outgrows the budget |
| Client caches a stale index after CI republishes | Agent reads out-of-date upstream docs | Index-derived results carry a short `ttlMs` (≈60 s) and `cacheScope: "private"`; advice resources carry a long TTL because they are stable. The server hot-reloads the artifact itself (D3), so no restart is needed either way |
| Hot reload races with in-flight requests | Torn reads, use-after-free | Parse+validate the new index into a fresh arena, then swap one pointer; the old arena is released only after the swap (§9 "publication and reclamation"). A failed reload leaves the previous index serving |
| Advice corpus drifts from the source document | Misleading advice | Corpus is generated from / checked against the source document by `advice_check`; evidence labels are mandatory fields, not optional metadata |
| Prompt injection via imported upstream docs | Agent misled by fetched text | Imported doc text is returned as *resource/tool data*, never as instructions; server responses never embed upstream text into the `instructions` field |

---

## 13. Open questions and defaults

| Question | Default (proceed without blocking) |
|---|---|
| Which upstream projects beyond `zig` std and `mcp.zig`? | Start with 3: `zig` (lib/std), `mcp.zig`, and one application project chosen to exercise non-std shapes |
| Should the index include upstream *source text* as well as docs? | No — docs only, initially; source text would multiply size and licensing exposure |
| Should `recommend_approach` rank, or only enumerate? | Enumerate with rule IDs; ranking without a measured objective would be unjustified |
| When does legacy `initialize` support land? | **M0, with the protocol core.** It is the same parser with an inferred-version flag (D10) — not a second wire implementation — and the `_meta` validation code is what forces that decision, so deferring it would only defer the flag |
| Does `resources/subscribe` matter? | No — `2026-07-28` replaced it with `subscriptions/listen`, and the index changes only when CI publishes, which the short cache TTL already reflects. `subscriptions/listen` is out of scope for v1 |
| Does the server need HTTP transport for CI integration? | No — CI drives it over stdio as a subprocess, same as any client |
