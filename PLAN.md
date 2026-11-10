# PLAN.md — defects, edge cases, limitations, and guideline deviations

Status: open backlog. Twenty-two items were fixed on 2026-11-09, seven on 2026-11-10,
and five more were closed that day because they were already done — the option chosen
for each, its commit and its verification are in §13–§16. Two sources: a read-through
of the tree on 2026-11-09, and a breakage campaign the same day that fuzzed the
stdio surface and the indexer, profiled the hot paths, and inspected a `ReleaseSafe`
PE with REA — method, measurements and negative results in §12.
`AGENTS.md` remains the spec of record for behaviour; the accepted gaps are summarised
in its §14, which this file expands.

IDs are stable — reference them in commits (`fix(ci): CI-1`). Each item is one
sentence of problem plus 2–3 options; "Verify" is the cheapest check that the fix
worked. §10 maps every id to a regression test, or says which layer must own it.

---

## 0. How to verify

### Gates (run after every change)

| Command | Proves |
|---|---|
| `zig build test` | unit, property, integration, golden and protocol layers compile and pass |
| `zig build check` | the advice corpus is schema-valid: 12 patterns, 12 rules, ids and `Sxx` refs resolve |
| `zig fmt --check . --exclude tests/fixtures` | formatting |
| `zig build bench` | the server starts, answers every tool, and prints latencies |
| `zig build test-protocol` | protocol layer alone (fastest signal for wire changes) |

All gates run on this machine (Zig 0.17.1, Windows, 2026-11-09): `test` green,
`check` green, `workflows` green, `bench` prints startup 18.2 ms, peak RSS 7.6 MB,
0 tool errors. `test-regressions` is **green**: the red-by-design suite is gone, its
pure-function tests moved into `registry.zig` and `text.zig`, and the handler tests
that remain run in `zig build test` as well. See §16 for why builds previously
produced a 0-byte binary.

### Recipes

On Windows every `zig-out/bin/<tool>` below is `zig-out/bin/<tool>.exe`, and the
blocks assume a POSIX shell.

```bash
# wire format: one request per line, response on the next line
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"doc_import_status","arguments":{"bogus":1},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}' | zig-out/bin/zigmcp

# index extraction: must reproduce the golden file byte for byte
zig-out/bin/indexer --out /tmp/i.jsonl --source fixture=0000000=tests/fixtures/indexer_src --include lib/std
diff /tmp/i.jsonl tests/golden/index.jsonl

# hot reload: start, rewrite the index, watch stderr
zig-out/bin/zigmcp --index /tmp/i.jsonl --advice-dir data/advice

# workflows: reproduce the trigger condition locally
gh workflow run index.yml          # manual path
git commit --allow-empty -m x && git push   # push path (CI-1)

# oversized line (SRV-1): 70 KiB of spaces then EOF — one -32700, then a clean exit
python -c "print(' '*70000)" | zig-out/bin/zigmcp; echo "exit=$?"

# nesting past the reader buffer (SRV-1; bounds depth, §16): 100k nested arrays
python -c "print('{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\",\"params\":'+'['*100000+']'*100000+'}')" | zig-out/bin/zigmcp
```

```bash
# sidecar guards (SRV-6, PROTO-11): a negative or mistyped count is dropped, never cast
printf '%s\n' '{"project":"p","commit":"c","path":"a.zig","line":1,"kind":"fn","symbol":"s","doc":"d","doc_hash":"h"}' > .probe/s.jsonl
printf '%s' '{"projects":{"p":{"files_degraded":-1}}}' > .probe/s.status.json
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"doc_import_status","arguments":{}}}' | zig-out/bin/zigmcp --index .probe/s.jsonl; echo "exit=$?"   # exit 0, no files_degraded

# indexer nesting guard (IDX-8): 2000 nested parens used to overflow the parser's stack
python -c "print('pub const v = ' + '('*2000 + '1' + ')'*2000 + ';')" > .probe/deep.zig
zig-out/bin/indexer --out .probe/deep.jsonl --source p=c=.probe --include deep.zig; echo "exit=$?"   # exit 0, degraded entry with a reason

# search amplification (SRV-7): 50k-record index, then one 60 KB query
python -c "import json;[print(json.dumps({'project':'p','commit':'c','path':'m.zig','line':i+1,'kind':'fn','symbol':'mod.fn%d'%i,'container':'mod','doc':'doc %d about memory'%i,'doc_hash':'h'})) for i in range(50000)]" > .probe/big.jsonl
python -c "import json;print(json.dumps({'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'doc_search','arguments':{'query':'xyz '*15000}}}))" | zig-out/bin/zigmcp --index .probe/big.jsonl   # ~20 s for one line, ReleaseSafe

# case-colliding projects (PROTO-13): project keys are exact
printf '%s\n' '{"project":"Fixture","commit":"c1","path":"A.zig","line":1,"kind":"fn","symbol":"a","doc":"d","doc_hash":"h"}' '{"project":"fixture","commit":"c2","path":"b.zig","line":2,"kind":"fn","symbol":"b","doc":"d","doc_hash":"h"}' > .probe/case.jsonl
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"docs://fixture/index"}}' | zig-out/bin/zigmcp --index .probe/case.jsonl   # lists one record
```

---

## 1. CI/CD

- **CI-4 — `sources.zon` scope is half-applied.** Both workflows take only the first
  `include` and ignore `exclude`. Options: (a) parse all globs in the plan step and
  pass repeated `--include`, adding `--exclude` to the indexer; (b) replace the regex
  parser with a Zig tool that uses `std.zon` and emits a plan file; (c) leave the
  scope flat and drop `exclude` from the schema. Verify: add a second include and see
  it in the emitted records.

- **CI-5 — duplicated `sources.zon` parser.** `bump-master.yml` and `index.yml` each
  carry their own regex block, and both break on formatting changes. Options: (a) one
  `tools/sources_plan.zig` (or `.py`) invoked by both; (b) a `zig build plan-sources`
  step; (c) a committed generated plan file refreshed by the bump job. Verify: run
  both workflows after reformatting `sources.zon`.

- **CI-6 — bump rerun collides with its own branch.** The branch name is
  `bump/upstream-<date>`; a second run the same day fails `git checkout -b` or the
  push. Options: (a) append the run id; (b) `git push --force-with-lease`; (c) close
  and reopen the PR. Verify: run `bump-master.yml` twice in a day.

- **CI-7 — no dependency caching.** Both jobs clone every upstream repo and re-fetch
  toolchains each run. Options: (a) `actions/cache` keyed by project+commit; (b) reuse
  the `zig fetch` package cache; (c) shallow clones (`--depth 1`) plus
  `git fetch --depth 1 <sha>`. Verify: compare run times.

- **CI-8 — `release.yml` ships no corpus.** The released binary cannot start without
  `data/advice`. Options: (a) tar `data/advice/` with the binary; (b) compile a
  fallback corpus in with `@embedFile` (data plane rule still holds for the index);
  (c) resolve the advice directory relative to the executable. Verify: unpack a
  release and run it from an empty directory.

- **CI-9 — every `uses:` runs on a deprecated node20 runtime.** `actions/checkout@v4`,
  `actions/upload-artifact@v4` and `softprops/action-gh-release@v2` are node20
  actions; actionlint ≥ 1.17 reports the deprecation for all four workflows, and the
  removal date it names has passed. Options: (a) bump to the node24 majors
  (`checkout@v5`, `upload-artifact@v5`, and whatever `action-gh-release` ships);
  (b) pin the older actionlint (v1.7.7, which `ci.yml` runs) and accept the risk;
  (c) keep and document. Verify: actionlint 1.17+ reports no `runtime "node20"`
  finding.

---

## 2. Protocol / MCP surface

- **PROTO-3 — `initialize` is `-32601` on current-revision requests.** Spec-legal,
  but clients that send `initialize` with `_meta` get an error instead of a
  discovery-shaped result. Options: (a) always answer it; (b) answer with `-32601`
  plus `data.supportedVersions`; (c) leave. Verify: send both shapes.

- **PROTO-4 — `logLevel` is parsed but nothing is emitted.** A client that opts into
  logging gets no `notifications/message` ever. Options: (a) implement the
  notification stream; (b) reject `logLevel`; (c) document it as unsupported.
  Verify: set `logLevel` and expect (or not) a notification.

- **PROTO-5 — `recommend_approach` silently ignores `constraints`.** The argument is
  accepted and unused, so callers believe it filters. Options: (a) fold constraint
  text into the signal tokens; (b) drop it from the input schema; (c) return
  `isError: true` when it is non-empty. Verify: pass a constraint that would change
  the match.

- **PROTO-7 — question mode truncates to 5 matches with no indication.** Options:
  (a) return `match_count` and `truncated`; (b) raise the cap; (c) include scores
  and tokens used. Verify: a question matching 6+ patterns.

- **PROTO-8 — JSON-RPC batches become `-32600`.** An array of requests is not an
  object, so it is rejected with `id: null`. Options: (a) accept arrays and reply
  with an array; (b) keep rejecting and document; (c) reply `-32600` per element.
  Verify: send `[{…},{…}]`.

- **PROTO-10 — `docs://{project}/index` is unbounded.** One read returns every
  symbol of a project, unbounded in size. Options: (a) add a cursor/offset argument;
  (b) cap and append a truncation marker; (c) drop the resource in favour of
  `doc_search`. Verify: read it against a full index and measure bytes.

---

## 3. Server runtime

- **SRV-2 — `buildResponse` assumes an object result.** `result.value.object` is
  taken unchecked; a handler returning a non-object panics. Options: (a) `switch`
  with a `-32603` fallback; (b) `std.debug.assert(result.value == .object)`; (c) type
  the handler return as an object. Verify: unit test with a string result.

- **SRV-3 — OOM during a request produces no response.** `handleLine` errors are
  logged and the request is dropped, leaving the client waiting. Options: (a) reply
  `-32603` when the failure is OOM; (b) reset the pool and retry once; (c) leave.
  Verify: fault-inject an allocator failure in a test.

- **SRV-5 — index reclamation runs under the spin lock.** `reclaimLocked` frees an
  index while holding the store lock, so readers spin for the duration. Options:
  (a) move the free outside the lock into an owner thread; (b) accept it (index free
  is short); (c) use a mutex instead of spinning. Verify: bench under a reload loop.

- **SRV-7 — search cost scales with query tokens × records, so one request can hold
  the server for tens of seconds.** `docs/search.zig` walks every token of the query
  for every record, and a 60 KB line yields ~15 000 tokens. Measured on a 50 000-record
  index in ReleaseSafe: `"memory"` 0.24 s, `"xyz " * 15000` **19.70 s** for one
  request and one line (a Debug build takes 131 s). The server is single-threaded, so
  the stall is client-chosen.
  Options: (a) cap the query (e.g. 4 KiB, 32 tokens) and return `-32602`; (b) build
  the token inverted index that §9 lists as P11's precondition; (c) score only the
  first N tokens. Verify: the §0 amplification recipe answers in well under 1 s.

---

## 4. Indexer

- **IDX-5 — invalid UTF-8 in a doc comment is emitted raw.** The JSON writer assumes
  valid UTF-8, so invalid bytes can yield an index the loader rejects. Options:
  (a) validate and replace with U+FFFD; (b) drop the file, report degraded; (c)
  escape bytes as `\u00XX`. Verify: a fixture with a 0xFF byte in a comment.

- **IDX-6 — `modulePath` mangles paths above the root.** `../x.zig` becomes `x.zig`
  after leading-dot stripping, so two files can share a symbol. Options: (a) reject
  paths containing `..`; (b) prefix the project key; (c) keep. Verify: index a tree
  with a `../` relative entry.

- **IDX-7 — error-set extraction is token-scan based.** Members are identifiers
  between the braces, so a nested construct inside an error set would be
  misattributed. Options: (a) keep (error sets are flat by grammar); (b) stop at the
  first non-identifier token; (c) assert on nested tokens. Verify: a fixture with a
  nested decl inside an error set.

- **IDX-9 — record line numbers rescan the file from offset 0, so the indexer is
  quadratic in declarations per file.** `lineOf` calls
  `std.zig.findLineColumn(tree.source, off)` for every record, which walks from the
  first byte of the file. Measured on the default Debug build, one file of documented
  `fn`s: 5 000 decls 1.17 s, 10 000 4.63 s, 25 000 29.65 s (4×, then 25× — clean n²),
  50 000 decls 113 s for a 1.7 MB file — while a 4 MiB file with one documented
  declaration takes 0.10 s, so the cost tracks record count × file size, not either
  alone. Options:
  (a) build a line-start table once per file and binary-search it; (b) carry the
  previous record's line and count newlines between tokens; (c) accept and budget
  declarations per file. Verify: the timing ladder stays linear (25 000 decls under
  ~2 s).

---

## 5. Index loading and hot reload

- **REL-1 — remote refresh has no conditional GET.** The whole artifact is
  re-downloaded every 60 s (`FetchResult` exposes only `status`). Options: (a) keep
  and make the interval configurable; (b) HEAD + compare `Content-Length`/`ETag`
  when the stdlib gains it; (c) accept the bandwidth. Verify: watch requests on a
  test server.

- **REL-2 — remote fetch has no timeout.** The watcher can park in a read, and
  shutdown then abandons the thread and leaks the store. Options: (a) set a client
  timeout/deadline; (b) fail the fetch after N seconds via a watchdog thread; (c)
  accept (process is exiting). Verify: point at a black-hole address and quit.

- **REL-3 — `file://` URLs are treated as relative paths.** `Source.fromString`
  classifies only `http(s)://`. Options: (a) strip `file://` into a path; (b) reject
  with a clear error; (c) document. Verify: `--index file:///tmp/i.jsonl`.

- **REL-6 — remote indexes have no status sidecar,** so degraded-file data is
  invisible. Options: (a) fetch `<url>.status.json`; (b) embed status as an index
  header record; (c) accept. Verify: `doc_import_status` on a URL index.

- **REL-7 — the local-change heuristic is mtime + size.** A rewrite that preserves
  both is missed. Options: (a) compare the content hash after each mtime change;
  (b) also compare inode/creation time; (c) always re-read on any stat change.
  Verify: rewrite with equal size and restored mtime.

---

## 6. Guideline deviations

Rules being broken are in `AGENTS.md` §5, §11, §12 (code/corpus conventions) and D8
(table-driven capabilities).

- **GUIDE-4 — input sizes are not bounded.** §12 says bound every input, but
  `question`, `query` and `symbol` accept anything the 64 KiB line allows. Options:
  (a) cap at e.g. 4 KiB and return `-32602`; (b) cap and truncate with a flag; (c)
  rely on the line cap. Verify: a 60 KiB query.

- **GUIDE-8 — limitation lists are duplicated across three files.** `AGENTS.md` §14,
  `readme.md` Known limitations and this file will drift. Options: (a) this file is
  canonical and the others link to it; (b) generate the readme section at build time;
  (c) keep a sync checklist. Verify: grep for a gap ID in all three.

---

## 7. Test coverage gaps

No open items: every gap this section listed now has its test. The last two are
`PROTO-2: doc_import_status rejects unknown arguments` and `PROTO-1: every listed
resource can be read`, both in `src/regressions_test.zig` (recorded in §16).

---

## 8. Documentation and packaging

- **DOC-1 — `build.zig.zon` `.paths` omits `lsp.json`.** The published package lacks
  the editor config. Options: (a) add it; (b) drop `lsp.json` from the repo; (c)
  accept.
- **DOC-2 — the client snippet in `release.yml` and `readme.md` differ** (`./zigmcp`
  vs an absolute path). Options: (a) one snippet in a file both read; (b) keep
  (different contexts); (c) make the release note link to the readme.
- **DOC-3 — `AGENTS.md` §14 and `readme.md` restate the same gaps** (see GUIDE-8).

- **DOC-4 — the Windows release binary carries no manifest, version resource or icon,
  and no load-config.** REA on a `ReleaseSafe` build (`inspect_pe_resources`,
  `inspect_pe_load_config`) reports `resources: []` and `load_config: null` for a
  PE32+ image importing only `ntdll.dll` (65), `KERNEL32.dll` (1) and `CRYPT32.dll`
  (9), with no delay imports: no `VERSIONINFO` (Explorer shows no product or version),
  no `asInvoker` manifest (Windows applies compatibility heuristics), no icon, and no
  CFG/GS metadata. Options: (a) add a manifest and version resource through
  `build.zig`'s Windows options; (b) ship a `.rc` and compile it with `zig rc`;
  (c) accept and note it in the release notes. Verify: `inspect_pe_resources` shows a
  manifest and a version entry.

---

## 9. Environment

No open items. The one entry this section held — a build that "succeeded" while
writing a 0-byte binary because the disk was full — was resolved on 2026-11-09 and is
recorded in §16. The symptom and its check stay in the readme troubleshooting table.

---

## 10. Test coverage map

`src/regressions_test.zig` (run as `zig build test-regressions`, and as part of
`zig build test`) holds the cross-cutting handler tests that need the real corpus
and a loaded doc index. It is no longer a red-by-design suite: the items it covered
are fixed (§13). The rows below are the items still open; each names the layer that
must own its test, because no such layer exists yet.

|Id|Regression test|If not: what must own it|
|---|---|---|
|CI-4|—|indexer CLI harness, once `--exclude` exists|
|CI-5|—|structural; testable only after the shared plan tool lands|
|CI-6|—|rerun the workflow; no local test|
|CI-7|—|timing only|
|CI-8|—|unpack a release and run it from an empty directory (CI smoke test)|
|PROTO-3|—|`tests/protocol_test.zig`: `initialize` with `_meta`|
|PROTO-4|—|protocol layer: set `logLevel`, expect a notification or `-32602`|
|PROTO-5|—|handler test on non-empty `constraints`; write once the option is chosen|
|PROTO-7|—|handler test: 6+ matching patterns, assert count/truncation|
|PROTO-8|—|`json_rpc` unit test on an array; expectation depends on the option|
|PROTO-10|—|resource test against a large index; assert a cap or cursor|
|SRV-2|—|extract `buildResponse` out of `main.zig` first; then a unit test|
|SRV-3|—|transport-level harness with an injected failing allocator|
|SRV-5|—|benchmark only, not deterministic|
|IDX-5|—|indexer CLI harness: fixture with a 0xFF byte in a comment|
|IDX-6|—|`modulePath` is private; export it for a unit test|
|IDX-7|—|fixture with a nested declaration inside an error set|
|REL-1|—|local HTTP server counting requests|
|REL-2|—|black-hole address plus quit; timing-based|
|REL-3|—|unit test: `Source.fromString("file:///x")`|
|REL-5|—|integration: sparse 257 MiB index file|
|REL-6|—|integration: URL index with no sidecar|
|REL-7|—|reload integration test: equal size, restored mtime|
|GUIDE-4|—|handler test: 60 KiB query expects `-32602`|
|GUIDE-8|—|doc lint: each gap id appears once across the tree|
|DOC-1|—|packaging assertion on `build.zig.zon` `.paths`|
|DOC-2|—|doc lint comparing the two snippets|
|DOC-3|—|same as GUIDE-8|
|SRV-7|—|timing only (`zig build bench` and the §0 recipe); needs a large fixture index|
|IDX-9|—|indexer CLI harness measuring the 5k/10k/25k ladder, or a unit test on the line table|
|CI-9|—|actionlint 1.17+ over `.github/workflows/`; no local test|
|DOC-4|—|`inspect_pe_resources` on a `ReleaseSafe` artifact (packaging smoke test)|

Every item above that names a handler can use the `Harness` in
`src/regressions_test.zig` — it builds a real corpus and an empty index, so a new
test is a few lines.

## 11. Suggested order

The first three steps of the original order — the pipeline, the cheap client-visible
fixes and the data-plane trust items — are done (§13, §14, §15). What remains, in
order:

1. Remaining limitations by demand: PROTO-10, REL-1, REL-5.
2. Measured hot spots: IDX-9 (quadratic indexer) and SRV-7 (client-chosen stall).
3. Contract and packaging gaps: DOC-4, CI-9.
4. Everything else in §1–§6 by demand.

---

## 12. Breakage campaign, 2026-11-09

Everything below was executed on this machine: Zig 0.17.1, Windows 10.0.26100, x64,
`ReleaseSafe` unless a line says otherwise.

### Method

|Technique|Instrument|Surface|
|---|---|---|
|Wire fuzzing|`wire_once.py` — one fresh server per case, asserting exit code, line count, id and JSON validity|envelope, `_meta`, ids, params, tool arguments, resources, prompts, framing|
|Artifact fuzzing|crafted JSONL, ZON and sidecar inputs; the property tests already in `docs/index.zig`|loader, corpus, `doc_import_status`|
|Indexer fuzzing|generated `.zig` sources, one shape per directory|AST walk, line numbers, doc extraction|
|Attribution probe|`parse_probe.zig` — reads a file and calls `std.zig.Ast.parse` only|parser vs walker|
|Profiling|50 000-record synthetic index, per-request wall clock, RSS from `tasklist`|search, reload, sidecar|
|Static inspection|REA `inspect_pe_imports`, `inspect_pe_resources`, `inspect_pe_load_config`|release artifact|

### What broke

|Finding|Technique|Evidence|
|---|---|---|
|SRV-6 panics on `files_degraded: -1`|crafted sidecar|exit 3 in Debug **and** ReleaseSafe|
|PROTO-11 sidecar types reach `structuredContent`|crafted sidecar|`"files_total":"oops"`, `"files_degraded":1.5`|
|PROTO-12 no-match result lacks `structuredContent`|wire fuzzing|3 tools, each advertising `outputSchema`|
|PROTO-13 case-colliding projects merge|crafted index|both URIs return both records|
|SRV-7 60 KB query costs ~20 s|profiling|0.24 s → 19.70 s on 50 000 records (Debug 131 s)|
|SRV-8 CLI error UX|CLI probes|exit 1, no usage; Debug adds a stack trace|
|IDX-8 `Ast.parse` stack overflow|indexer fuzzing + probe + gdb|Debug dies at 4 KB, ReleaseSafe at 20 KB → exit 3221225477|
|IDX-9 quadratic line lookup|profiling|Debug: 1.17 s / 4.63 s / 29.65 s at 5k / 10k / 25k decls|
|REL-8 one error name for every I/O failure|CLI probes|missing file and a directory both `MalformedRecord`|
|REL-9 `doc_hash` unverified|source read|—|
|REL-10 canonical order unenforced|source read|—|
|DOC-4 PE has no resources or load-config|REA|`resources: []`, `load_config: null`|

### What held

- **Wire robustness.** Duplicate keys, a BOM, raw invalid UTF-8, lone surrogates, NUL
  escapes, `params` of every wrong type, `id` as float/bool/overflowing integer, and
  every wrong-typed tool argument answered `-32700`, `-32600` or `-32602` — the one
  exception is the known PROTO-2 hole, which answers a successful result.
  Notifications never produced a reply, and no case crashed: the only process exits
  were SRV-1's clean stdin failure on lines of 65 536 bytes or more.
- **Index encoding.** A `doc` holding a raw `0xFF`, a truncated `0xC3` or a `\ud800`
  escape is rejected by the loader, so invalid UTF-8 never reaches the wire; records
  carrying U+0000 and U+001F escapes load and still produce a valid JSON response.
- **No format-string path.** `docs://{s}/index`, `docs://%/symbols/%s`, a 60 KB URI and
  an empty URI all return `-32602` and no crash.
- **SRV-4 is unreachable behind SRV-1.** 10 000 nested arrays answer `-32602`;
  100 000 exceed the reader buffer and hit SRV-1 first, which bounds JSON depth.
- **Reload is leak-free.** Twelve swaps alternating 5 000/5 200 records held RSS at
  7.2–7.8 MB, and a truncated write left the previous index serving (5 200 records,
  old commit) — REL-4's degradation works.
- **Indexer resilience.** 4 MiB doc comments, NUL-only files, empty files and unclosed
  error sets are all handled; only nesting depth (IDX-8) and declaration count
  (IDX-9) hurt.
- **Release dependencies.** `ntdll.dll` (65), `KERNEL32.dll` (1), `CRYPT32.dll` (9),
  no delay imports — no third-party runtime dependency (D1).
- **Corpus loading is fail-fast, not fail-open.** A truncated or empty
  `patterns.zon`, an unknown `.evidence` tag and a missing `rules.zon` each stop
  start-up with exit 1 and a `file:line` diagnostic, and no handler is ever reached
  with a broken tree. Parseable-but-invalid corpora are the opposite problem: they
  serve silently (CI-3).
- **Corpus not embedded.** A pattern name from `patterns.zon` does not appear in the
  binary, confirming CI-8: a release needs `data/advice` beside it.

The drivers and fixture trees lived in `.probe/` (gitignored). The crash and timing
items have recipes in §0; the rest carry a `Verify:` line naming the exact command or
tool, and REL-9/REL-10 are single-record edits over the PROTO-13 fixture.

---

## 13. Resolved on 2026-11-09

Twenty-two items, one commit each. "Option" is the letter from the item's own list;
"Verification" is what was actually run, not what was inspected.

|Id|Option|Commit|Verification|
|---|---|---|---|
|CI-1|(b) drop the `if:`|`f2cf5ec`|`zig build workflows` fails on the pre-fix file (`index.yml:25`) and passes now; actionlint clean|
|CI-2|(a) rolling `index` release|`80171d2`|`zig build workflows` + actionlint; `gh release view index` after a run (no remote here)|
|CI-3|(a) add `zig build check`|`b33cb93`|`tests/advice_check_test.zig` (the validator fails closed) plus the `ci.yml` step|
|PROTO-1|(a) serve the list|`9381888`|handler test: every listed resource reads|
|PROTO-2|(a) validate the real arguments|`e152999`|handler test: `{"bogus":1}` → `-32602`|
|PROTO-6|(a) `-32602` when both are present|`6871df4`|handler test|
|PROTO-9|(a) accept integral floats|`5c5ccdd`|`registry.zig` test: `20.0` accepted, `20.5` and `1e300` rejected|
|SRV-1|(a) `-32700`, discard, continue|`8d7cc1d`|protocol test: 70 KiB line → `-32700`, next request answered, exit 0|
|IDX-1|(a) degrade with a reason|`61d0865`|indexer test: 65 MiB file → rc 0, `files_degraded: 1`, other records intact|
|IDX-3|(a) cross-check the sidecar count|`6be0038`|indexer test: sidecar 5 vs 2 records → re-indexed; 2 vs 2 → carried over|
|REL-4|(a) expose the load state|`e6e2009`|protocol test: `--index missing.jsonl` → `reload_failed` + `FileNotFound`|
|SRV-6|(b) `std.math.cast`, drop the count|`bf0bdf0`|§0 sidecar recipe exits 0 with no `files_degraded`; unit test|
|SRV-8|(a) usage block, exit 2|`173e11a`|protocol test: `--bogus` → exit 2, `Usage: zigmcp`, no Zig error name|
|IDX-8|(a) depth pre-scan, limit 256|`6836304`|indexer test: 2 000 nested parens → rc 0 + degraded reason|
|PROTO-11|(a) type-check each echoed value|`5cf1b72`|§0 mistyped sidecar → all three members absent; unit test|
|PROTO-12|(a) always emit `structuredContent`|`74691aa`|protocol test: no-match `doc_search`, `doc_get` and `advice_lookup` all carry it|
|PROTO-13|(a) exact project keys|`e29796a`|§0 case-colliding index → one record per URI; handler test|
|REL-8|(a) propagate the underlying error|`6eaa06e`|`--index missing.jsonl` → `FileNotFound`, `--index tests` → `IsDir`|
|REL-9|(a) verify at load|`977695b`|tampered `doc` → `MalformedRecord`; the golden index still loads 25 records|
|REL-10|(a) reject out-of-order artifacts|`8b965e4`|swapped golden lines → `MalformedRecord`; unit test|
|GUIDE-5|(a) `null` means `{}`|`b0eb235`|`registry.zig` test: a required field is rejected for absent arguments|
|GUIDE-6|(b) growable token buffer|`94b0dd3`|`text.zig` test: a 200-character token is kept whole|

Two items changed shape while being fixed, both recorded in `AGENTS.md`:

- **PROTO-12** adds `found` to `doc_get`'s output schema and makes the record fields
  optional. A no-match result cannot satisfy a schema whose every member is required,
  so the alternative was to stop advertising the schema.
- **REL-10**'s test exposed a pre-existing leak: `load`'s error path destroyed the
  `ArenaAllocator` struct without freeing its pages, so every rejected artifact leaked
  its partial index. Fixed in the same commit.

`CI-9` was added during the pass: the scoop-installed actionlint (1.17.1) reports that
every `uses:` in the tree runs on a deprecated node20 runtime. `ci.yml` pins the older
v1.7.7, which does not report it, so the gate stays green while the deprecation is
tracked rather than silently ignored.

## 14. Resolved on 2026-11-10

Three items, one commit (`20784b3`): the schema module, the table dispatch and the
module headers touch the same three tools and the same two docs, so splitting them
would have meant staging halves of one file.

|Id|Option|Commit|Verification|
|---|---|---|---|
|GUIDE-3|(a) one shared `src/advice/schema.zig` imported as the `advice_schema` module|`20784b3`|`zig build check` + `zig build bench` compile both tools against it; `grep -n "const Pattern = struct" src tools` prints one line; `corpus.zig` pins type identity at comptime|
|GUIDE-2|(a) a `handler` in `PromptSpec`/`ResourceSpec` (and `cache` in resources)|`20784b3`|regression tests: every prompt spec dispatches through its handler, both resource families read through the table|
|GUIDE-1|(a) add the `//!` headers|`20784b3`|`src/root.zig` lint test names every headerless `src/**`/`tools/**` file (both tools before the fix) and passes after|

## 15. Resolved on 2026-11-10, second chunk

Four items plus two stale entries, one commit (`aa7021b`): the `--include` glob and
`doc_get`'s duplicate handling are two independent defects, but their tests, their
doc rows and their `PLAN.md` deletions overlap, so they landed together.

|Id|Option|Commit|Verification|
|---|---|---|---|
|IDX-2|(a) strip a trailing `/**` in `matchesInclude`|`aa7021b`|indexer test: `--include 'lib/std/**'` and `--include lib/std` produce identical, non-empty output|
|IDX-4|(a) `doc_get` returns every match|`aa7021b`|regression test: two records sharing `mod.dup` → `matches.len == 2` in `(path, line)` order|
|TEST-2|— closed by IDX-4|`aa7021b`|`IDX-4: doc_get returns every record sharing a symbol`|
|TEST-6|`--include` half; `--previous`/`--status` were already covered|`aa7021b`|`an --include glob selects the same files as its directory prefix`; `a truncated --previous index is not reused` already asserts `skipped` and the derived `.status.json`|
|TEST-1|already covered; removed as stale|—|`tests/protocol_test.zig`: `an oversized line is a parse error and the server keeps serving`|
|TEST-5|already covered; removed as stale|—|`ci.yml` runs `zig build workflows` and `go run …/actionlint@v1.7.7` in both jobs|

## 16. Closed as already done, 2026-11-10

No code change: each item below was already finished when the backlog was re-read,
either by an earlier commit or by construction. They were deleted from §1–§10 instead
of being left as phantom tasks; the evidence is what was checked, not assumed.

|Id|Why it is no longer a task|Evidence|
|---|---|---|
|SRV-4|Not reachable: the 64 KiB reader cap bounds JSON nesting, and the indexer's own recursion hazard was IDX-8 (`6836304`)|the §0 nesting recipe at the maximum depth a 64 KiB line allows — 32 726 nested arrays in 65 499 bytes — answers `-32602` and exits 0; 10 000 nested arrays do the same|
|GUIDE-7|CI-3 wired `zig build check` in, so the validator runs where the claim in §9 says it does|`.github/workflows/ci.yml`: `- name: Validate the advice corpus` → `run: zig build check`, in both the blocking and the canary job|
|TEST-3|The test exists|`src/regressions_test.zig`: `PROTO-2: doc_import_status rejects unknown arguments`|
|TEST-4|The test exists|`src/regressions_test.zig`: `PROTO-1: every listed resource can be read`|
|ENV-1|Resolved on 2026-11-09 — the disk was full, not the toolchain; the symptom and its check live in the readme troubleshooting table|`zig build test` exits 0 and `zig-out/bin/zigmcp.exe` is non-zero|



