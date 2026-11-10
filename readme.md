# ZigMCP

[![CI](https://github.com/biehla/ZigMCP/actions/workflows/ci.yml/badge.svg)](https://github.com/biehla/ZigMCP/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig 0.17.1](https://img.shields.io/badge/zig-0.17.1-f7a41d.svg)](https://ziglang.org/download/)
[![MCP 2026-07-28](https://img.shields.io/badge/MCP-2026--07--28-6e56cf.svg)](https://modelcontextprotocol.io)

A [Model Context Protocol](https://modelcontextprotocol.io) server that serves a coding
agent two read-only corpora: systems-programming advice with its evidence labels
intact, and documentation imported from other Zig projects.

| | |
|---|---|
| Transport | stdio, newline-delimited JSON-RPC 2.0 |
| Protocol | MCP `2026-07-28`; legacy `2025-06-18` clients accepted |
| Runtime dependencies | none |
| Builds with | Zig `0.17.1` |

Both corpora are **data**. The advice lives in ZON files; the doc index is a JSONL
artifact parsed, validated and swapped while the server runs. New upstream
documentation arrives without a rebuild or a restart.

## Install

Zig 0.17.1 is required — the standard library changes between releases.

```bash
git clone https://github.com/biehla/ZigMCP
cd ZigMCP
zig build
```

`zig build` writes three executables to `zig-out/bin/`: `zigmcp` (the server),
`indexer` (builds a doc index) and `bench` (the verification report).

Release tarballs ship the binary **and** `data/advice/`: unpack one into an empty
directory and run the binary from there. The raw binary beside a tarball carries no
corpus, so point `ZIGMCP_ADVICE_DIR` or `--advice-dir` at one. An optimised build is
`zig build -Doptimize=ReleaseSafe`.

## Use

### From an MCP client

[`client-config.json`](client-config.json) is ready to edit:

```json
{
  "mcpServers": {
    "zigmcp": {
      "command": "/absolute/path/to/ZigMCP/zig-out/bin/zigmcp",
      "args": ["--index", "/absolute/path/to/index.jsonl"],
      "env": {
        "ZIGMCP_ADVICE_DIR": "/absolute/path/to/ZigMCP/data/advice"
      }
    }
  }
}
```

Use absolute paths: a client picks the working directory, so a relative `data/advice`
will not resolve. On Windows the binary is `zig-out\bin\zigmcp.exe` — escape the
backslashes in JSON or write forward slashes. `--index` also accepts an `https://` URL.
The advice corpus is required; the doc index is optional, and without one the doc tools
answer "nothing matched".

### From a terminal

```bash
zig build run -- --index tests/golden/index.jsonl
```

Nothing prints, on purpose: the server is waiting for JSON-RPC on stdin. Stop it with
`Ctrl+D` (`Ctrl+Z`, `Enter` on Windows). `tests/golden/index.jsonl` is a small fixture
index, enough to exercise the doc tools; for real documentation
[build an index](#building-an-index).

One request per line, one response per line:

```bash
printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"advice_lookup","arguments":{"concept":"P03"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}' \
 | zig-out/bin/zigmcp --advice-dir data/advice --index tests/golden/index.jsonl
```

A request without `params._meta` is answered as a legacy `2025-06-18` request, in the
older shape.

## Reference

### Tools

All five are read-only and return readable text plus structured JSON matching their
declared output schema. A tool that runs but finds nothing is a normal result with
`isError: true`, an explanation and a schema-shaped empty value — an answer, not a
failure.

| Tool | Arguments | Returns |
|---|---|---|
| `advice_lookup` | `concept` (e.g. `"P03"`) **or** `question` (free text) | The full paradigm record: what it controls, facts with labels and sources, candidate uses, boundaries, checks. A question returns up to 5 best matches |
| `recommend_approach` | `signals` (non-empty list of observations), optional `constraints` | The decision rules your signals match, best first: paradigms to consider, the "only if" constraint, its `GUIDANCE` label and a score |
| `doc_search` | `query`, optional `project`, optional `limit` (default 20, max 100) | Matching records with `path:line`, symbol, kind and text: exact symbol first, then partial symbol, then path, then prose |
| `doc_get` | `project`, `symbol` | Every record with that path-qualified symbol — usually one — with its location and commit. `symbol` must be the spelling the index stores (`lib.std.mem.copyForwards`); a miss lists the closest stored symbols in `candidates`. `found` is always present, so a miss is still schema-shaped |
| `doc_import_status` | none | `index_state` (`ok` / `unloaded` / `reload_failed`), `index_error` when a load failed, and per project the commit, record count and degraded-file counts for a local index |

`project` is matched exactly first, so `Fixture` and `fixture` stay distinct. Failing
that, it is compared again ignoring case and `_` vs `-`, and used only when that names
exactly one project; a spelling that names two says so instead of guessing, and one that
names none is `isError: true` with the keys the index holds.

Example calls:

| You want | Call |
|---|---|
| a known pattern | `{"concept":"P03"}` → `advice_lookup` |
| an approach for a symptom | `{"signals":["repeated recomputation over changing inputs"]}` → `recommend_approach` |
| the docs for a std symbol | `{"project":"zig_std","symbol":"lib.std.mem.copyForwards"}` → `doc_get` |

An unknown member, a missing required argument or a wrong type is invalid parameters
(`-32602`).

### Resources

| URI | Content |
|---|---|
| `advice://overview` | All 12 paradigms in one table, with labels |
| `advice://patterns` | All 12 paradigms in one document |
| `advice://patterns/P01` … `advice://patterns/P12` | One paradigm in full |
| `advice://rules` | The 12 decision rules |
| `advice://guarantees` | Cross-cutting guarantees |
| `advice://limits` | The source material's limits, and the evidence-label legend |
| `advice://sources` | The S01–S24 registry with author, title and URL |
| `docs://{project}/index` | One project's symbols as `path:line symbol`, at most 5 000 records; past that a truncation marker says how many are missing, and `doc_search` / `doc_get` reach the rest |
| `docs://{project}/symbols/{symbol}` | One symbol's record, as a URI template |

Advice resources are cacheable for an hour (`public`); anything derived from the doc
index for 60 seconds (`private`), so a client notices a new index quickly.

### Prompts

| Prompt | Argument | Asks the model to |
|---|---|---|
| `approach_selection` | `situation` | Run the decision rules, cite the matched rule ids, keep them labelled as guidance, say so when nothing matched |
| `systems_review` | `design` | Keep recommendations apart from facts, respect each paradigm's boundaries, list the checks it did not run, cite record and source ids |

### Advice and its evidence labels

The advice is a narrative synthesis of documentation and studies (research date
2026-11-09): 12 paradigms (P01–P12), 12 decision rules (R01–R12), guarantees, limits
and a source registry (S01–S24). Every claim says how strongly it is supported:

| Label | Meaning |
|---|---|
| `FACT` | A documented mechanism; the source ids follow the claim |
| `RESULT` | A finding from a specific study; it holds under that study's conditions |
| `SYNTHESIS` | The report's own classification, not a standard taxonomy |
| `GUIDANCE` | An engineering recommendation that needs validating for your project |

Every decision rule is `GUIDANCE`, each paradigm record is `SYNTHESIS`, and the facts
inside a record keep their own labels. Imported documentation is data, never
instructions: no directive found inside it is executed or promoted into the server's
`instructions`.

### Doc index

#### A record

The index is [JSON Lines](https://jsonlines.org): one indexed declaration per line.

```json
{"project":"zig_std","commit":"738d2be9…","path":"lib/std/mem.zig","line":238,"kind":"fn","symbol":"lib.std.mem.copyForwards","container":"lib.std.mem","doc":" Copy all of source into dest …","doc_hash":"…"}
```

| Field | Meaning |
|---|---|
| `project` | Project key given to the indexer |
| `commit` | Upstream commit the record came from |
| `path`, `line` | Source location, 1-based line |
| `kind` | `fn`, `var`, `field`, `container` (a file's `//!` doc), `error` (error-set member) or `param` |
| `symbol` | Dotted path from the file path and the nesting of declarations |
| `container` | The enclosing symbol |
| `doc` | Comment text with `///` / `//!` stripped, or a declaration's `//` run with `//` stripped; lines joined with newlines |
| `doc_hash` | SHA-256 of `doc`, re-verified at load |

A record holds comment text only — no signature, body or type — so `doc_get` returns
the comment and not the declaration, and `path:line` plus `commit` is how you reach the
declaration itself.

A declaration is indexed when it carries a `///` doc comment or, failing that, a plain
`//` run ending on the line directly above it. A doc comment wins when both are present,
a blank line breaks a `//` run, and a file's `//!` module record still requires `//!`.
No field records which of those three produced the text, so a `//` run — often a note to
the next reader rather than API documentation — is indistinguishable from a published
doc comment. Treat a record as the comment that declaration carries, not as the
project's public contract for it, and the declaration at `path:line` as the authority.

The indexer parses without compiling, so a project that does not build on Zig 0.17.1, or
a file with a syntax error, still contributes every comment that could be parsed. Such
files are listed as degraded in the status file.

#### Finding a symbol

Symbols are **path-qualified**: module path, then the nesting of declarations.
`mem.copyForwards` is stored as `lib.std.mem.copyForwards`; a `lib/std/std.zig`
container record is `lib.std.std.ArrayList`. An unqualified name therefore finds
nothing, and `doc_get` answers with the closest stored symbols in `candidates`;
`doc_search` is the tool that discovers a spelling, and a shorter query finds more.

Only documented declarations are indexed, so an undocumented `pub fn` is absent rather
than misspelled, and a type-level doc can survive while its methods do not. That
separates the two kinds of miss: empty `candidates` matched nothing resembling the
spelling, while a list of symbols is usually the same declaration under its
path-qualified name.

#### Building an index

```bash
git clone https://github.com/ziglang/zig.git upstream/zig
git -C upstream/zig checkout 738d2be9d6b6ef3ff3559130c05159ef53336224

zig-out/bin/indexer \
  --out generated/index.jsonl \
  --source zig_std=738d2be9d6b6ef3ff3559130c05159ef53336224=upstream/zig \
  --include lib/std \
  --exclude "lib/std/**/testdata/**"
```

| Option | Meaning |
|---|---|
| `--out <file>` | Output index (required) |
| `--source <project>=<commit>=<dir>` | A tree to index; repeat for several projects (at least one) |
| `--include <path>` | Only files under this directory; a trailing `/**` is accepted; repeatable |
| `--exclude <pattern>` | Skip a directory or a `**` glob; repeatable |
| `--status <file>` | Status file (default: next to `--out`, `.jsonl` → `.status.json`) |
| `--previous <index.jsonl>` | Reuse records for projects whose commit has not changed, and only when the old status file agrees on the count |

Keep the status file next to the index: `doc_import_status` reads the degraded-file
counts from it. `generated/index.jsonl` is the server's default location, so
`zig build run` picks it up without flags.

The upstream projects, their pins and their include/exclude scope live in
[`data/sources.zon`](data/sources.zon); `zig build plan-sources` prints the plan both CI
workflows use. The project key is the field name there (`zig_std`, `mcp_zig`) and is
what the tool arguments accept. One indexer run takes several `--source` flags and sorts
the merged output itself — list every project in the same run, because the server loads
one file and a project missing from it is a project the tools cannot see.

#### How updates land

| Index location | Checked every | Replaced when |
|---|---|---|
| Local file | `--index-poll-ms` (default 1 s) | modification time or size changes |
| URL | `--index-poll-ms` (default 60 s) | the downloaded bytes differ (SHA-256) |

A new index is parsed and validated in full before it replaces the old one; a failed
load keeps the previous index serving, and a request never sees a mix of two. An
artifact larger than `--max-index-bytes` (default 256 MiB) is rejected.

A URL index is fetched by the watcher, never before startup, so an unreachable origin
cannot stop the server starting: it serves the advice and an empty doc index until the
first fetch lands, and `doc_import_status` reports `unloaded` meanwhile. The pinned
standard-library HTTP client has no request timeout, so a fetch in flight keeps the
process alive at shutdown until it is killed — and it has no conditional GET, so a URL
is **re-downloaded in full on every poll** (a 6 MB artifact costs 6 MB per interval).
When that matters, download the artifact once, pin it by hash, and point `--index` at
the local file: the watcher then re-reads it only when its size or modification time
changes.

## Configuration

| Flag | Environment variable | Default | Meaning |
|---|---|---|---|
| `--index <path-or-url>` | `ZIGMCP_INDEX` | `generated/index.jsonl`, if it exists | Doc index to load and watch: local path or `http(s)://` URL |
| `--advice-dir <path>` | `ZIGMCP_ADVICE_DIR` | `data/advice` | Directory holding the five advice files |
| `--max-index-bytes <n>` | `ZIGMCP_MAX_INDEX_BYTES` | `268435456` (256 MiB) | Largest index artifact accepted, local or downloaded |
| `--index-poll-ms <n>` | `ZIGMCP_INDEX_POLL_MS` | `1000` local, `60000` URL | How often the watcher checks, in milliseconds (floor `100`) |
| `--help`, `-h` | — | — | Print usage to stderr and exit |

A flag wins over the environment variable; relative paths resolve against the server's
working directory. An unknown argument or a missing option value prints the usage block
to stderr and exits with status 2. The server writes no files, contacts nothing except
the configured index URL, and prints diagnostics to stderr only.

## Protocol

`server/discover` is mandatory; `initialize` is answered for legacy clients only.
Methods: `server/discover`, `initialize`, `tools/list`, `tools/call`, `resources/list`,
`resources/templates/list`, `resources/read`, `prompts/list`, `prompts/get`.
Notifications are never answered. Current-revision results carry `resultType`,
`_meta` `serverInfo` and the cache hints stated under [Resources](#resources).

| Code | When |
|---|---|
| `-32700` | The line is not JSON, or exceeds the 64 KiB read buffer |
| `-32600` | The JSON is not a JSON-RPC 2.0 request |
| `-32601` | Unknown method |
| `-32602` | Invalid parameters: incomplete `_meta`, unknown tool/prompt/resource, bad arguments |
| `-32022` | Unsupported protocol version; the error lists the supported ones |
| `-32603` | Internal error |

## Development

```bash
zig build                   # server, indexer and bench into zig-out/bin
zig build test              # unit, protocol, golden and regression tests
zig build test-protocol     # only the tests that drive the binary over pipes
zig build test-regressions  # cross-cutting handler tests (also part of `test`)
zig build check             # validate the advice corpus
zig build workflows         # workflow trigger/expression consistency
zig build plan-sources      # print the upstream plan from data/sources.zon
zig build bench             # verification report
zig fmt --check . --exclude tests/fixtures
```

`--exclude upstream` matters once you have cloned the upstreams there for indexing: the
formatter walks the working tree, not git, and Zig master's syntax is not what this
toolchain formats. A fresh clone needs only the fixture exclusion.

- **Tests.** Unit and property tests sit next to the code in `src/`. The protocol tests
  start the real binary and talk to it over pipes. The golden test runs the indexer over
  `tests/fixtures/indexer_src/` and requires output identical to
  `tests/golden/index.jsonl`.
- **Corpus validation.** `zig build check` rejects malformed or duplicate ids, a pattern
  or rule count other than 12, and references to sources missing from the registry.
- **Verification report.** `zig build bench` starts the server against the golden index
  and reports build configuration, Zig version, corpus counts, index size, startup time,
  p50/p95/p99 latency and error count per tool, and peak memory.
- **Editor support.** [`lsp.json`](lsp.json) configures [ZLS](https://zigtools.org/zls/);
  keep ZLS on Zig 0.17.

## CI

| Workflow | When | What it does |
|---|---|---|
| `ci.yml` | every push and pull request | Builds, tests, checks the corpus and formatting on Linux, macOS and Windows with Zig 0.17.1; a second job repeats it on Zig master as a non-blocking canary |
| `bump-master.yml` | daily at 03:17 UTC, or manually | Moves each upstream to its latest commit, rebuilds the index, and opens **one** pull request only when the documentation changed, with old/new commits and per-project record counts |
| `index.yml` | a push to `main` touching `data/sources.zon`, or manually | Rebuilds the index from the pinned commits, uploads it as an artifact and publishes `index.jsonl` to the rolling `index` release |
| `release.yml` | a `v*` tag | Builds release binaries for three platforms with Zig 0.17.1 and publishes a per-OS tarball, the raw binaries and a client-configuration example |

Releases are always built with the pinned Zig release, never master, so a release can be
rebuilt exactly from its tag.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `cannot load the advice corpus from 'data/advice'` | Started from another directory. Set `ZIGMCP_ADVICE_DIR` or `--advice-dir` to an absolute path |
| Doc tools always say nothing matched | No index loaded. Check stderr for `cannot load the doc index`; `doc_import_status` says what is loaded |
| `doc_get` cannot find a symbol | Spell it path-qualified (`lib.std.mem.copyForwards`) or let the miss's `candidates`/`doc_search` find it; an undocumented declaration is absent, not misspelled |
| `doc_import_status` has no degraded-file counts | The index came from a URL, or there is no `.status.json` beside the local index |
| A new index is not picked up | A broken index is ignored and the old one keeps serving. Every line must be a complete record; a URL is re-checked every 60 s |
| `cannot parse arguments (UnknownArgument)` | An unsupported flag; see `zigmcp --help` |
| The server seems to hang in a terminal | It is waiting for input on stdin — expected |
| Build fails with API errors | `zig version` is not 0.17.1 |
| `zig build` hangs after an interrupted build | Leftover `zig` processes hold the cache lock; end them and rebuild |
| The client shows legacy-style responses | It sends no `params._meta`; the server then answers as `2025-06-18` — intended |

## Limitations

[`PLAN.md`](PLAN.md) is the canonical, itemised list of known limitations and defects,
with the options considered and a verification step for each, plus the resolved tables
for what has been closed. This page keeps no second copy.

## Repository layout

```
build.zig, build.zig.zon     build graph and package manifest
client-config.json           a ready-to-edit client entry
lsp.json                     ZLS wiring
src/                         the server
  main.zig                   startup, request loop, dispatch
  protocol/                  JSON-RPC parsing, versions, error codes
  transport/                 stdio framing
  server/                    capability tables and handlers
  advice/                    corpus loader, rule matcher, rendering
  docs/                      index loader, columnar layout, search, reload
data/advice/                 the advice corpus (ZON)
data/sources.zon             upstream projects and their pins
generated/                   CI-built index (gitignored)
tools/                       indexer, corpus check, workflow check, bench
tests/                       protocol, golden and regression tests
.github/workflows/           ci, bump-master, index, release
AGENTS.md                    the spec of record for contributors and agents
```

## Contributing

The rulebook — design decisions, protocol rules, data formats, conventions and the
failure catalogue — is [`AGENTS.md`](AGENTS.md); read it before changing behaviour.
`zig build test`, `zig build check` and the `zig fmt` gate must pass, one logical change
per commit, and a behaviour change updates both `AGENTS.md` and this page.

## License

MIT — see [`LICENSE`](LICENSE).

The advice corpus is derived from `systems_programming_context_v1.md`. The doc index
holds comment text copied from its upstream projects (Zig's `lib/std`, `mcp.zig`, …),
each under that project's own license; every record's `project` and `commit`, and
`doc_import_status`, name where it came from.
