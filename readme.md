# ZigMCP

**Give your coding agent a systems-programming playbook, and the Zig documentation
it needs, without leaving the chat.**

ZigMCP is a small [Model Context Protocol](https://modelcontextprotocol.io) server
written in Zig. It answers two kinds of question:

- **"Which approach fits this system?"** Twelve paradigms (table-driven behaviour,
  data-oriented design, dataflow, incremental recomputation, …), twelve decision
  rules, cross-cutting guarantees and limits. Every claim carries an evidence label —
  `FACT`, `RESULT`, `SYNTHESIS` or `GUIDANCE` — plus its sources, so your agent can
  tell a documented mechanism from a recommendation.
- **"What does this Zig symbol do?"** Doc comments extracted from other Zig projects
  (the standard library and `mcp.zig` by default), searchable by symbol, path or text.

The binary is small and rarely changes. Both knowledge sources are **data files**
loaded at runtime, and the documentation index is reloaded while the server runs, so
new upstream docs arrive without a rebuild or a restart.

| | |
|---|---|
| Transport | stdio (newline-delimited JSON-RPC 2.0) |
| Protocol | MCP `2026-07-28`, plus legacy `2025-06-18` clients |
| Runtime dependencies | none |

## Contents

- [Try it in 30 seconds](#try-it-in-30-seconds)
- [Use it from your AI client](#use-it-from-your-ai-client)
- [What you can ask it](#what-you-can-ask-it)
- [Reading the advice: evidence labels](#reading-the-advice-evidence-labels)
- [The doc index](#the-doc-index)
- [Configuration](#configuration)
- [Talking to the server directly](#talking-to-the-server-directly)
- [Development](#development)
- [CI/CD](#cicd)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)
- [Repository layout](#repository-layout)

---

## Try it in 30 seconds

You need [Zig 0.17.1](https://ziglang.org/download/) — the pinned version. The Zig
standard library changes between releases, so other versions will not build.

```bash
git clone <this repository> ZigMCP
cd ZigMCP
zig build
zig build run -- --index tests/golden/index.jsonl
```

Nothing appears, and that is on purpose: the server is waiting for JSON-RPC messages
on stdin, the way an MCP client talks to it. Press `Ctrl+D` (`Ctrl+Z` then Enter on
Windows) to stop it, or open a second terminal and try the requests in
[Talking to the server directly](#talking-to-the-server-directly).

`tests/golden/index.jsonl` is a small fixture index, enough to try the doc tools.
For real documentation, [build an index](#building-one-yourself) or point `--index`
at one.

For an optimised binary: `zig build -Doptimize=ReleaseSafe`.

## Use it from your AI client

Most clients accept an `mcpServers` entry. [`client-config.json`](client-config.json)
is ready to edit:

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

Use **absolute paths** for both the binary and the corpus. Clients start servers from
a working directory of their own choosing, so a relative `data/advice` will not
resolve.

- On Windows the binary is `zig-out\bin\zigmcp.exe`; escape backslashes in JSON
  (`C:\\Users\\me\\ZigMCP\\...`) or use forward slashes.
- `--index` also accepts an `https://` URL, which the server fetches and watches.
- The advice corpus is required; the doc index is optional. Without one, the advice
  tools work normally and the doc tools answer "nothing matched".

Release tarballs ship the binary **and** `data/advice/`: unpack one into an empty
directory and run the binary from there. The raw binary attached beside the tarball
has no corpus, so point `ZIGMCP_ADVICE_DIR` or `--advice-dir` at one.

## What you can ask it

### Tools

All five tools are read-only and return readable text plus structured JSON that
matches their declared output schema. When a tool runs but finds nothing, the result
is marked `isError: true` with an explanation and an empty result shaped like the
schema — that is an answer, not a failure.

|Tool|Arguments|What you get|
|---|---|---|
|`advice_lookup`|`concept` (e.g. `"P03"`) **or** `question` (free text)|The full paradigm record: what it controls, facts with labels and sources, candidate uses, boundaries, checks. A question returns up to 5 best matches|
|`recommend_approach`|`signals` (non-empty list of observations); `constraints` (optional object, currently unused)|The decision rules your signals match, best first: paradigms to consider, the "only if" constraint, its `GUIDANCE` label and a match score|
|`doc_search`|`query`; `project` (optional); `limit` (default 20, max 100)|Matching doc records with `path:line`, symbol, kind and text. Exact symbol first, then partial symbol, then path, then text matches|
|`doc_get`|`project`, `symbol` (project exact, symbol case-insensitive)|Every record with that symbol — usually one — with its source location and upstream commit. `found` is always present, so a miss is still schema-shaped|
|`doc_import_status`|none|`index_state` (`ok`, `unloaded`, `reload_failed`), `index_error` when a load failed, and per project the commit, record count and degraded-file counts for a local index|

Questions map to tools like this:

|You ask|Call|
|---|---|
|"Show me pattern P03"|`advice_lookup` — `{"concept":"P03"}`|
|"Which approach fits repeated recomputation?"|`recommend_approach` — `{"signals":["repeated recomputation over changing inputs"]}`|
|"Find allocator docs in std"|`doc_search` — `{"query":"allocator","project":"zig_std","limit":10}`|
|"What does `mem.copyForwards` do?"|`doc_get` — `{"project":"zig_std","symbol":"mem.copyForwards"}`|
|"Is the index loaded?"|`doc_import_status` — `{}`|

An unknown member, a missing required argument or a wrong type is rejected as invalid
parameters (`-32602`).

### Prompts

|Prompt|Argument|What it does|
|---|---|---|
|`approach_selection`|`situation`|Runs the decision rules against your situation and asks the model to cite the matched rule ids, keep them labelled as guidance, and say so when nothing matched|
|`systems_review`|`design`|Builds a review request that includes the matching advice records and asks the model to keep recommendations apart from facts, respect each paradigm's boundaries, list the checks it did not run, and cite record and source ids|

### Resources

|URI|Content|
|---|---|
|`advice://overview`|All 12 paradigms in one table, with labels|
|`advice://patterns`|All 12 paradigms in one document|
|`advice://patterns/P01` … `advice://patterns/P12`|One paradigm in full|
|`advice://rules`|The 12 decision rules|
|`advice://guarantees`|Cross-cutting guarantees|
|`advice://limits`|The limits of the source material, and the evidence-label legend|
|`advice://sources`|The S01–S24 registry with author, title and URL|
|`docs://{project}/index`|Every documented symbol of one project, as `path:line symbol`|
|`docs://{project}/symbols/{symbol}`|One symbol's documentation, as a URI template|

Advice resources are cacheable for an hour; anything derived from the doc index is
cacheable for 60 seconds, so clients notice a new index quickly.

## Reading the advice: evidence labels

The advice comes from `systems_programming_context_v1.md`, a narrative synthesis of
documentation and studies (research date 2026-11-09). It is reference material, not a
rulebook, so every claim says how strongly it is supported:

|Label|Meaning|
|---|---|
|`FACT`|A documented mechanism; the source ids follow the claim|
|`RESULT`|A finding from a specific study; it holds under that study's conditions|
|`SYNTHESIS`|The report's own classification or interpretation, not a standard taxonomy|
|`GUIDANCE`|An engineering recommendation that needs validating for your project|

Every decision rule is `GUIDANCE`. Each paradigm record is `SYNTHESIS`, while the
facts inside it keep their own labels. `advice://sources` resolves every `Sxx` id to
an author, title and URL.

## The doc index

### What a record looks like

The index is [JSON Lines](https://jsonlines.org): one documented declaration per line.

```json
{"project":"zig_std","commit":"738d2be9…","path":"lib/std/mem.zig","line":812,"kind":"fn","symbol":"mem.copyForwards","container":"mem","doc":" Copies …","doc_hash":"…"}
```

|Field|Meaning|
|---|---|
|`project`|Project name given to the indexer|
|`commit`|Upstream commit the record came from|
|`path`, `line`|Source location, 1-based line|
|`kind`|`fn`, `var`, `field`, `container` (a file's `//!` doc), `error` (error-set member) or `param` (function parameter)|
|`symbol`|Dotted path built from the file path and the nesting of declarations|
|`container`|The enclosing symbol|
|`doc`|Comment text with `///` / `//!` removed, lines joined with newlines|
|`doc_hash`|SHA-256 of `doc`|

Only documented declarations are indexed. The indexer reads the source without
compiling it, so a project that does not build on Zig 0.17.1 — or a file with a syntax
error — still contributes every doc comment that could be parsed. Such files are
listed as degraded in the status file.

### Building one yourself

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
|`--source <project>=<commit>=<dir>`|A tree to index; repeat for several projects (at least one)|
|`--include <path>`|Only index files under this directory; a trailing `/**` is accepted; repeatable|
|`--exclude <pattern>`|Skip files under a directory or matching a `**` glob; repeatable|
|`--status <file>`|Where to write the status file (default: next to `--out`, `.jsonl` replaced by `.status.json`)|
|`--previous <index.jsonl>`|Reuse records from an older index for projects whose commit has not changed, and only when the old status file agrees on the record count|

The status file lists, per project, the record count, the files read, and each
degraded file with its parser diagnostics. Keep it next to the index: the
`doc_import_status` tool reads it from there.

`generated/index.jsonl` is the server's default location, so `zig build run` picks it
up without flags. The upstream projects, their pinned commits and their
include/exclude scope live in `data/sources.zon`; `zig build plan-sources` prints the
plan both CI workflows use.

### How updates land

|Index location|Checked|Replaced when|
|---|---|---|
|Local file|every `--index-poll-ms` (default 1 s)|modification time or size changes|
|URL|every `--index-poll-ms` (default 60 s)|the downloaded bytes differ (SHA-256)|

A new index is parsed and validated completely before it replaces the old one, and a
failed load keeps the previous index serving. Requests in progress always see one
complete index, never a mix. An artifact larger than `--max-index-bytes` (default
256 MiB) is rejected.

A URL index is fetched by the watcher, not before startup, so an unreachable origin
cannot stop the server from starting — it serves the advice and an empty doc index
until the first fetch lands, and `doc_import_status` reports `unloaded` meanwhile. The
HTTP client has no request timeout, so a fetch still in flight keeps the process alive
at shutdown until it is killed.

## Configuration

|Flag|Environment variable|Default|Meaning|
|---|---|---|---|
|`--index <path-or-url>`|`ZIGMCP_INDEX`|`generated/index.jsonl`, if it exists|Doc index to load and watch: a local path or an `http://` / `https://` URL|
|`--advice-dir <path>`|`ZIGMCP_ADVICE_DIR`|`data/advice`|Directory holding the five advice files|
|`--max-index-bytes <n>`|`ZIGMCP_MAX_INDEX_BYTES`|`268435456` (256 MiB)|Largest index artifact accepted, local or downloaded|
|`--index-poll-ms <n>`|`ZIGMCP_INDEX_POLL_MS`|`1000` local, `60000` URL|How often the watcher checks the index, in milliseconds (floor `100`)|
|`--help`, `-h`|—|—|Print usage to stderr and exit|

A flag wins over the environment variable, and relative paths resolve against the
server's working directory. An unknown argument prints the usage block to stderr and
exits with status 2.

The server reads only: it writes no files, contacts nothing except the configured
index URL, and prints diagnostics to stderr only.

## Talking to the server directly

One request per line on stdin, one response per line on stdout. Current-revision
requests carry protocol metadata in `params._meta`:

```bash
printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"advice_lookup","arguments":{"concept":"P03"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}' \
 | zig-out/bin/zigmcp
```

The first response carries the supported versions, the capabilities and the agent
instructions. A request with no `_meta` is treated as a legacy `2025-06-18` request and
answered in the older shape.

Methods: `server/discover`, `initialize` (legacy clients only), `tools/list`,
`tools/call`, `resources/list`, `resources/templates/list`, `resources/read`,
`prompts/list`, `prompts/get`.

|Code|When|
|---|---|
|`-32700`|The line is not JSON|
|`-32600`|The JSON is not a JSON-RPC 2.0 request|
|`-32601`|Unknown method|
|`-32602`|Invalid parameters: incomplete `_meta`, unknown tool/prompt/resource, bad arguments|
|`-32022`|Unsupported protocol version; the error lists the supported ones|
|`-32603`|Internal error|

## Development

```bash
zig build                   # server, indexer and bench into zig-out/bin
zig build test              # unit, protocol and golden tests
zig build test-protocol     # only the tests that drive the binary over pipes
zig build test-regressions  # cross-cutting handler tests (also part of `test`)
zig build check             # validate the advice corpus
zig build workflows         # workflow trigger/expression consistency
zig build bench             # verification report
zig fmt --check . --exclude tests/fixtures
```

- **Tests.** Unit and property tests live next to the code in `src/`. The protocol
  tests start the real binary and talk to it over pipes. The golden test runs the
  indexer over `tests/fixtures/indexer_src/` and requires output identical to
  `tests/golden/index.jsonl`.
- **Corpus validation.** `zig build check` rejects malformed or duplicate ids, a
  pattern or rule count other than 12, and references to sources that are not in the
  registry. Run it after editing `data/advice/`.
- **Verification report.** `zig build bench` starts the server against the golden
  index and reports the build configuration, Zig version, corpus counts, index size,
  startup time, p50/p95/p99 latency and error count per tool, and peak memory.
- **Editor support.** `lsp.json` configures [ZLS](https://zigtools.org/zls/). Use a
  ZLS release matching Zig 0.17.

Contributor and AI-agent rules — design decisions, protocol rules, data formats,
conventions — are in [`AGENTS.md`](AGENTS.md). Read it before changing behaviour.

## CI/CD

|Workflow|When|What it does|
|---|---|---|
|`ci.yml`|every push and pull request|Builds, tests and checks formatting on Linux, macOS and Windows with Zig 0.17.1. A second job does the same on Zig master as an early warning; its failures never block a merge|
|`bump-master.yml`|daily at 03:17 UTC, or manually|Moves each upstream project to its latest commit, rebuilds the index, and opens **one** pull request only when the documentation actually changed. The PR lists old and new commits and per-project record changes; the full index diff is attached as an artifact|
|`index.yml`|a push to `main` that touches `data/sources.zon`, or manually|Rebuilds the full index from the pinned commits, uploads it as an artifact, and publishes `index.jsonl` to the rolling `index` release|
|`release.yml`|a `v*` tag|Builds release binaries for three platforms with Zig 0.17.1 and publishes a GitHub Release with a per-OS tarball, the raw binaries and a client configuration example|

Releases are always built with the pinned Zig release, never with master, so a release
can be rebuilt exactly from its tag.

## Troubleshooting

|Symptom|Cause and fix|
|---|---|
|`cannot load the advice corpus from 'data/advice'`|Started from another directory. Set `ZIGMCP_ADVICE_DIR` or `--advice-dir` to an absolute path|
|Doc tools always say nothing matched|No index is loaded. Check stderr for `cannot load the doc index`; call `doc_import_status` to see what is loaded|
|`doc_import_status` has no degraded-file counts|The index came from a URL, or there is no `.status.json` beside the local index|
|A new index is not picked up|A broken index is ignored and the old one keeps serving. Every line must be a complete record; a URL is re-checked every 60 s|
|`cannot parse arguments (UnknownArgument)`|An unsupported flag; see `zigmcp --help`|
|The server seems to hang in a terminal|It is waiting for input on stdin — expected|
|Build fails with API errors|`zig version` is not 0.17.1|
|`zig build` hangs after an interrupted build|Leftover `zig` processes hold the cache lock; end them and rebuild|
|The client shows legacy-style responses|It sends no `params._meta`; the server then answers as `2025-06-18` — intended|

## Known limitations

[`PLAN.md`](PLAN.md) is the canonical, itemised list: every known limitation and
defect, with the options considered and a verification step for each, plus the resolved
tables for what has been closed. This page deliberately keeps no second copy.

## Repository layout

```
build.zig, build.zig.zon     build graph and package manifest
client-config.json           a ready-to-edit client entry
src/                         the server
  main.zig                   startup, request loop, dispatch
  protocol/                  JSON-RPC parsing, protocol versions, error codes
  transport/                 stdio framing
  server/                    tools, resources, prompts, discovery
  advice/                    corpus schema, loader, rule matcher, rendering
  docs/                      index loader, in-memory layout, search, hot reload
  util/                      scratch memory, text helpers
data/advice/                 the advice corpus (ZON)
data/sources.zon             upstream projects and pinned commits
tools/                       indexer, corpus validator, workflow check, verification report
tests/                       protocol and golden tests, fixtures
res/                         Windows manifest and version resource
.github/workflows/           CI, upstream bump, index build, release
systems_programming_context_v1.md   source material of the advice corpus
AGENTS.md                    rules and reference for contributors and AI agents
AGENTS-2.md                  starter rulebook for a new Zig project
PLAN.md                      the open backlog and the resolved tables
```