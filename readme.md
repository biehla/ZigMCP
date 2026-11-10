# ZigMCP

A [Model Context Protocol](https://modelcontextprotocol.io) server, written in Zig,
that gives an AI coding agent two read-only knowledge sources:

1. **Systems-programming advice.** Twelve paradigms (P01–P12: table-driven
   behaviour, data-oriented design, dataflow, PGO, learned indexes, …), twelve
   conditional decision rules (R01–R12), cross-cutting guarantees, limits, and a
   24-entry source registry (S01–S24). Every claim carries an **evidence label**
   (`FACT`, `RESULT`, `SYNTHESIS`, `GUIDANCE`) and its source ids, so the agent can
   tell a documented mechanism from a recommendation.
2. **Documentation imported from other Zig projects.** A build-time indexer reads
   upstream Zig source trees (the Zig standard library and `mcp.zig` by default),
   extracts their `///` and `//!` doc comments, and the server makes them
   searchable by symbol, path or text.

The server binary is small and rarely changes. The advice corpus and the doc index
are **data files** loaded at runtime. The doc index is reloaded while the server is
running, so a newly published index is picked up without restarting your client.

- Transport: stdio (newline-delimited JSON-RPC 2.0)
- Protocol: MCP `2026-07-28`, plus legacy clients that speak `2025-06-18`
- Runtime dependencies: none

---

## Contents

- [Quick start](#quick-start)
- [Connecting an MCP client](#connecting-an-mcp-client)
- [Configuration](#configuration)
- [What the server offers](#what-the-server-offers)
- [Reading the advice: evidence labels](#reading-the-advice-evidence-labels)
- [The doc index](#the-doc-index)
- [Talking to the server by hand](#talking-to-the-server-by-hand)
- [Development](#development)
- [CI/CD](#cicd)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)
- [Repository layout](#repository-layout)

---

## Quick start

**Requirements:** [Zig 0.17.1](https://ziglang.org/download/). Newer or older
versions are not supported (`build.zig.zon` sets `minimum_zig_version = "0.17.1"`,
and the Zig standard library changes between releases).

```bash
git clone <this repository> ZigMCP
cd ZigMCP
zig build                      # builds zig-out/bin/zigmcp (+ indexer, bench)
zig build run -- --index tests/golden/index.jsonl
```

The server now waits for JSON-RPC messages on stdin. That is normal: it is meant
to be started by an MCP client, not used interactively. Press `Ctrl+D` (`Ctrl+Z`
then Enter on Windows) to end the input; the server exits cleanly.

`tests/golden/index.jsonl` is a small fixture index that is good for trying the doc
tools. For real documentation, point `--index` at a generated index (see
[The doc index](#the-doc-index)).

For an optimised binary:

```bash
zig build -Doptimize=ReleaseSafe
```

---

## Connecting an MCP client

Most clients take an `mcpServers` entry with a command, arguments and environment.
Use **absolute paths**: clients usually start servers from a working directory of
their own choosing, and the advice corpus is looked up relative to the working
directory by default.

```json
{
  "mcpServers": {
    "zigmcp": {
      "command": "/path/to/ZigMCP/zig-out/bin/zigmcp",
      "args": ["--index", "/path/to/index.jsonl"],
      "env": {
        "ZIGMCP_ADVICE_DIR": "/path/to/ZigMCP/data/advice"
      }
    }
  }
}
```

On Windows the binary is `zig-out\bin\zigmcp.exe`; in JSON, escape backslashes
(`C:\\Users\\me\\ZigMCP\\...`) or use forward slashes.

The index can also be a URL (`"args": ["--index", "https://example.org/index.jsonl"]`).

Release builds (see [CI/CD](#cicd)) ship a per-OS `zigmcp-<os>.tar.gz` that contains
the binary **and** `data/advice/`. Unpack it into an empty directory and run the
binary from there: the default `data/advice` is resolved against the server's
**working directory**, so the unpacked layout is a working install. The raw binary
attached alongside the tarball has no corpus; point `ZIGMCP_ADVICE_DIR` (or
`--advice-dir`) at one with an absolute path if you use it.

---

## Configuration

|Command-line flag|Environment variable|Default|Meaning|
|---|---|---|---|
|`--index <path-or-url>`|`ZIGMCP_INDEX`|`generated/index.jsonl`, if that file exists|Doc index to load and keep watching. A local path or an `http://` / `https://` URL|
|`--advice-dir <path>`|`ZIGMCP_ADVICE_DIR`|`data/advice`|Directory holding the five advice files|
|`--max-index-bytes <n>`|`ZIGMCP_MAX_INDEX_BYTES`|`268435456` (256 MiB)|Largest index artifact accepted, for both a local file and an HTTP download|
|`--index-poll-ms <n>`|`ZIGMCP_INDEX_POLL_MS`|`1000` local, `60000` URL|How often the watcher checks the index, in milliseconds (floor `100`). A remote index is re-fetched on every poll|
|`--help`, `-h`|—|—|Print usage to stderr and exit|

- A flag wins over the environment variable.
- Relative paths are resolved against the server's working directory.
- An unknown argument stops the server with an error.
- **The advice corpus is required.** If it cannot be loaded, the server exits with a
  message on stderr.
- **The doc index is optional.** Without one, the advice tools work normally and the
  doc tools answer "nothing matched". If a configured index cannot be loaded at
  startup, the server says so on stderr, starts anyway, and picks the index up as
  soon as a valid file appears.

### How index updates are picked up

|Index location|Checked|Changed when|
|---|---|---|
|Local file|every second|modification time or size changes|
|URL|every 60 seconds|the downloaded bytes differ (SHA-256)|

A new index is loaded and checked completely before it replaces the old one. If the
new file is broken, the server keeps serving the previous index. Requests in
progress always see one complete index, never a mix. Index files larger than
256 MiB by default — or larger than the configured `--max-index-bytes` — are
rejected.

The server only reads. It never writes files, never contacts anything except the
configured index URL, and prints diagnostics to stderr only.

---

## What the server offers

### Tools

All tools are read-only and return both readable text and structured JSON
(`structuredContent`) that matches the tool's declared output schema. When a tool
runs fine but finds nothing, the result is marked `isError: true` with an
explanation; that is an answer, not a failure.

|Tool|Arguments|Returns|
|---|---|---|
|`advice_lookup`|`concept` (e.g. `"P03"`) **or** `question` (free text)|The full advice record(s): what the paradigm controls, facts with their labels and sources, candidate uses, boundaries, checks. A question returns up to 5 best matches|
|`recommend_approach`|`signals`: list of observations about your system (required, non-empty); `constraints`: any object (optional, currently unused)|The decision rules your signals match, best first, each with the paradigms to consider, the "only if" constraint, its `GUIDANCE` label and a match score|
|`doc_search`|`query` (required); `project` (optional); `limit` (optional, default 20, max 100)|Matching doc records with `path:line`, symbol, kind and doc text. Exact symbol matches rank first, then partial symbol matches, then path matches, then matches in the doc text|
|`doc_get`|`project`, `symbol` (both required; the project key is exact, the symbol is case-insensitive)|The full documentation of **every** record with this symbol (usually one), each with its source location and upstream commit. `found` is always present, so a miss is still shaped like the tool's output schema|
|`doc_import_status`|none|What the index holds: `index_state` (`ok`, `unloaded` or `reload_failed`, with `index_error` when a load failed), and per project the upstream commit, record count and, for a local index with a status file, how many source files were only partly parseable|

Examples of arguments:

```json
{"concept": "P06"}
{"question": "how should I lay out data for cache-friendly bulk processing?"}
{"signals": ["repeated recomputation over changing inputs"]}
{"query": "allocator", "project": "zig_std", "limit": 10}
{"project": "zig_std", "symbol": "mem.copyForwards"}
```

Passing an argument that is not in the schema, leaving out a required one, or
using the wrong type is rejected as invalid parameters.

### Resources

|URI|Content|
|---|---|
|`advice://overview`|All 12 paradigms in one table, with evidence labels|
|`advice://patterns`|All 12 paradigms in one document|
|`advice://patterns/P01` … `advice://patterns/P12`|One paradigm in full|
|`advice://rules`|The 12 decision rules|
|`advice://guarantees`|Cross-cutting guarantees|
|`advice://limits`|The limits of the source material, and the evidence-label legend|
|`advice://sources`|The S01–S24 source registry with URLs|
|`docs://{project}/index`|Every documented symbol of one project, as `path:line symbol`|
|`docs://{project}/symbols/{symbol}`|One symbol's documentation (offered as a URI template)|

Advice resources are marked cacheable for an hour. Anything that depends on the
doc index is marked cacheable for 60 seconds, so clients notice a new index quickly.

### Prompts

|Prompt|Argument|What it does|
|---|---|---|
|`systems_review`|`design`|Builds a review request for your design that includes the matching advice records and tells the model to keep recommendations apart from facts, respect each paradigm's boundaries, list the checks it did not run, and cite record and source ids|
|`approach_selection`|`situation`|Runs the decision rules against your situation and asks the model to cite the matched rule ids, keep them labelled as guidance, and say so if nothing matched|

---

## Reading the advice: evidence labels

The advice comes from `systems_programming_context_v1.md`, a narrative synthesis
of documentation and studies (research date 2026-11-09). It is reference material,
not a rulebook. Each claim is labelled:

|Label|Meaning|
|---|---|
|`FACT`|A documented mechanism; the source ids follow the claim|
|`RESULT`|A finding from a specific study; it holds under that study's conditions|
|`SYNTHESIS`|The report's own classification or interpretation, not a standard taxonomy|
|`GUIDANCE`|An engineering recommendation that needs validating for your project|

Every decision rule is `GUIDANCE`. Each paradigm record is `SYNTHESIS`, while the
facts inside it keep their own labels. `advice://sources` resolves every `Sxx` id
to an author, title and URL.

---

## The doc index

### What a record looks like

The index is a [JSON Lines](https://jsonlines.org) file: one documented
declaration per line.

```json
{"project":"zig_std","commit":"738d2be9…","path":"lib/std/mem.zig","line":812,"kind":"fn","symbol":"mem.copyForwards","container":"mem","doc":" Copies …","doc_hash":"…"}
```

|Field|Meaning|
|---|---|
|`project`|Project name given to the indexer|
|`commit`|Upstream commit the record was extracted from|
|`path`, `line`|Where the declaration is (1-based line)|
|`kind`|`fn`, `var`, `field`, `container` (a file's `//!` doc), `error` (error-set member) or `param` (function parameter)|
|`symbol`|Dotted path built from the file path and the nesting of declarations|
|`container`|The enclosing symbol|
|`doc`|The comment text with `///` / `//!` removed, lines joined with newlines|
|`doc_hash`|SHA-256 of `doc`|

Only declarations that have a doc comment are indexed. The indexer reads the source
without compiling it, so a project that does not build on Zig 0.17.1, or a file with
a syntax error, still yields every doc comment that could be parsed. Such files are
listed as degraded in the status file.

### Building an index yourself

`zig build` installs the indexer as `zig-out/bin/indexer`. Given a checkout of an
upstream project:

```bash
git clone https://github.com/ziglang/zig.git upstream/zig
git -C upstream/zig checkout 738d2be9d6b6ef3ff3559130c05159ef53336224

zig-out/bin/indexer \
  --out generated/index.jsonl \
  --source zig_std=738d2be9d6b6ef3ff3559130c05159ef53336224=upstream/zig \
  --include lib/std \
  --exclude "lib/std/**/testdata/**"
```

|Option|Meaning|
|---|---|
|`--out <file>`|Output index (required)|
|`--source <project>=<commit>=<dir>`|A source tree to index; repeat for several projects (at least one)|
|`--include <subdir>`|Only index files under this directory; repeatable|
|`--exclude <pattern>`|Skip files under a directory or matching a `**` glob, e.g. `lib/std/**/testdata/**`; repeatable|
|`--status <file>`|Where to write the status file (default: next to `--out`, `.jsonl` replaced by `.status.json`)|
|`--previous <index.jsonl>`|Reuse records from an older index for every project whose commit has not changed|

The status file lists, per project, the record count, the number of files read, and
each degraded file with its parser diagnostics. Keep it next to the index: the
`doc_import_status` tool reads it from there.

`generated/index.jsonl` is the server's default location, so `zig build run` picks
it up without flags.

The upstream projects, their pinned commits and their include/exclude scope live in
`data/sources.zon`. `zig build plan-sources` prints the plan both CI workflows use.

---

## Talking to the server by hand

Each request is one line of JSON on stdin; each response is one line on stdout.
Current-revision requests carry protocol metadata in `params._meta`:

```bash
printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"advice_lookup","arguments":{"concept":"P03"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}' \
 '{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"advice://limits"}}' \
 | zig-out/bin/zigmcp
```

- Request 1 returns the supported protocol versions, the capabilities, and
  instructions for the agent.
- Request 2 returns the P03 record as text and as structured JSON.
- Request 3 has no `_meta`, so it is treated as a legacy `2025-06-18` request and
  answered in the older response shape.

Supported methods: `server/discover`, `initialize` (legacy clients only),
`tools/list`, `tools/call`, `resources/list`, `resources/templates/list`,
`resources/read`, `prompts/list`, `prompts/get`.

Errors follow JSON-RPC:

|Code|When|
|---|---|
|`-32700`|The line is not JSON|
|`-32600`|The JSON is not a JSON-RPC 2.0 request|
|`-32601`|Unknown method|
|`-32602`|Invalid parameters: incomplete `_meta`, unknown tool, prompt or resource, bad arguments|
|`-32022`|Unsupported protocol version (the error lists the supported ones)|
|`-32603`|Internal error|

---

## Development

```bash
zig build                  # server, indexer and bench into zig-out/bin
zig build test             # unit, protocol and golden tests
zig build test-protocol    # only the tests that drive the server binary over pipes
zig build test-regressions # cross-cutting handler tests (also part of `test`)
zig build check            # validate the advice corpus
zig build workflows        # workflow trigger/expression consistency
zig build bench            # verification report (see below)
zig fmt --check . --exclude tests/fixtures
```

The formatter check skips `tests/fixtures/`, which deliberately contains a file
with a syntax error.

**Tests.** Unit and property tests live next to the code in `src/`. The protocol
tests start the real binary and talk to it over pipes. The golden test runs the
indexer over `tests/fixtures/indexer_src/` and requires output identical to
`tests/golden/index.jsonl`.

**Corpus validation.** `zig build check` rejects malformed or duplicate ids, a
pattern or rule count other than 12, and references to sources that are not in the
registry. Run it after editing `data/advice/`.

**Verification report.** `zig build bench` starts the server against the golden
index and reports the build configuration, Zig version, corpus counts, index size,
startup time, p50/p95/p99 latency and error count for every tool, and peak memory.

**Editor support.** `lsp.json` configures [ZLS](https://zigtools.org/zls/). Use a
ZLS release matching Zig 0.17.

**Contributing.** Contributor and AI-agent rules — design decisions, protocol
rules, data formats, conventions — are in [`AGENTS.md`](AGENTS.md). Read it before
changing behaviour.

---

## CI/CD

|Workflow|When|What it does|
|---|---|---|
|`ci.yml`|every push and pull request|Builds, tests and checks formatting on Linux, macOS and Windows with Zig 0.17.1. A second job does the same on Zig master as an early warning; its failures never block a merge|
|`bump-master.yml`|daily, or manually|Moves each upstream project in `data/sources.zon` to its latest commit, rebuilds the index, and opens **one** pull request only if the documentation actually changed. The PR lists old and new commits and how many records changed per project; the full index diff is attached as a build artifact|
|`index.yml`|meant to run when `data/sources.zon` changes on `main`; currently runs only when started manually (see [Known limitations](#known-limitations))|Rebuilds the full index from the pinned commits and uploads it as a build artifact|
|`release.yml`|on a `v*` tag|Builds release binaries for the three platforms with Zig 0.17.1 and publishes a GitHub Release with a client configuration example|

Releases are always built with the pinned Zig release, never with master, so a
release can be rebuilt exactly from its tag.

---

## Troubleshooting

|Symptom|Cause and fix|
|---|---|
|`cannot load the advice corpus from 'data/advice'`|The server was started from another directory. Set `ZIGMCP_ADVICE_DIR` or `--advice-dir` to an absolute path|
|Doc tools always say nothing matched|No index is loaded. Check stderr for `cannot load the doc index`; call `doc_import_status` to see what is loaded|
|`doc_import_status` shows no degraded-file counts|The index was loaded from a URL, or there is no `.status.json` next to the local index|
|A new index is not picked up|A broken index is ignored and the old one keeps serving; validate the file (every line must be a complete record). URLs are re-checked only every 60 s|
|`cannot parse arguments (UnknownArgument)`|An unsupported flag was passed; see `zigmcp --help`|
|The server seems to hang when run in a terminal|It is waiting for input on stdin; that is expected|
|Build fails with API errors|You are not on Zig 0.17.1 (`zig version`)|
|`zig build` hangs after an interrupted build|Leftover `zig` compiler processes hold the cache lock; end them and rebuild|
|Your client shows legacy-style responses|It sends no `params._meta`; the server then answers as protocol `2025-06-18`. This is intended|

---

## Known limitations

[`PLAN.md`](PLAN.md) is the canonical, itemised list: every known limitation and
defect, with the options considered and a verification step for each, plus the
resolved tables for what has been closed. This page deliberately keeps no second
copy — a copy drifts.

---

## Repository layout

```
build.zig, build.zig.zon     build graph and package manifest
src/                         the server
  main.zig                   startup, request loop, dispatch
  protocol/                  JSON-RPC parsing, protocol versions, error codes
  transport/                 stdio framing
  server/                    tools, resources, prompts, discovery
  advice/                    shared corpus schema, corpus loader, rule matcher, rendering
  docs/                      index loader, in-memory layout, search, hot reload
  util/                      scratch memory, text helpers
data/advice/                 the advice corpus (ZON)
data/sources.zon             upstream projects and pinned commits
tools/                       indexer, corpus validator, verification report
tests/                       protocol and golden tests, fixtures
.github/workflows/           CI, upstream bump, index build, release
systems_programming_context_v1.md   source material of the advice corpus
AGENTS.md                    rules and reference for contributors and AI agents
```
