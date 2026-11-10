# PLAN.md — defects, edge cases, limitations, and guideline deviations

Status: open backlog. Twenty-two items were fixed on 2026-11-09, thirty-four on
2026-11-10, and five more were closed that day because they were already done — the
option chosen for each, its commit and its verification are in §13–§27. Two sources: a read-through
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

- **CI-7 — no dependency caching.** Both jobs clone every upstream repo and re-fetch
  toolchains each run. Options: (a) `actions/cache` keyed by project+commit; (b) reuse
  the `zig fetch` package cache; (c) shallow clones (`--depth 1`) plus
  `git fetch --depth 1 <sha>`. Verify: compare run times.

---

## 2. Protocol / MCP surface

---

## 3. Server runtime

No open items.

---

## 4. Indexer

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

- **REL-6 — remote indexes have no status sidecar,** so degraded-file data is
  invisible. Options: (a) fetch `<url>.status.json`; (b) embed status as an index
  header record; (c) accept. Verify: `doc_import_status` on a URL index.

---

## 6. Guideline deviations

Rules being broken are in `AGENTS.md` §5, §11, §12 (code/corpus conventions) and D8
(table-driven capabilities).

No open items. GUIDE-8 is resolved in §19.

---

## 7. Test coverage gaps

No open items: every gap this section listed now has its test. The last two are
`PROTO-2: doc_import_status rejects unknown arguments` and `PROTO-1: every listed
resource can be read`, both in `src/regressions_test.zig` (recorded in §16).

---

## 8. Documentation and packaging

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
|CI-7|—|timing only|
|REL-1|—|local HTTP server counting requests|
|REL-2|—|black-hole address plus quit; timing-based|
|REL-6|—|integration: URL index with no sidecar|
|DOC-4|—|`inspect_pe_resources` on a `ReleaseSafe` artifact (packaging smoke test)|

Every item above that names a handler can use the `Harness` in
`src/regressions_test.zig` — it builds a real corpus and an empty index, so a new
test is a few lines.

## 11. Suggested order

The first three steps of the original order — the pipeline, the cheap client-visible
fixes and the data-plane trust items — are done (§13, §14, §15). What remains, in
order:

1. Remaining limitations by demand: REL-1.
2. Contract and packaging gaps: DOC-4, CI-9.
3. Everything else in §1–§6 by demand.

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

## 17. Resolved on 2026-11-10, third chunk

Thirteen items, one commit (`e9624fb`): the protocol surface, the input bounds, the
reload predicates and the index ceiling all landed in the same tree — their tests and
their `PLAN.md` deletions overlap, so they share a commit.

|Id|Option|Commit|Verification|
|---|---|---|---|
|PROTO-3|(b) `-32601` plus `data.supportedVersions`|`e9624fb`|protocol test: `initialize` on the current revision names `server/discover` and both supported versions|
|PROTO-4|(a) implement the notification stream|`e9624fb`|protocol tests: an unknown `logLevel` is `-32602`; a reload failure reaches the client that asked for logs as `notifications/message`|
|PROTO-5|(a) fold constraint text into the signal tokens|`e9624fb`|regression test: a constraint naming the bottleneck matches R03 while the echoed `signals` stay exactly what the caller sent|
|PROTO-7|(a) return `match_count` and `truncated`|`e9624fb`|`advice_lookup` reports both in every result; the truncation marker names the hidden count|
|PROTO-8|(b) keep rejecting and document|`e9624fb`|protocol test: an array envelope → `-32600` with a null id; MCP has no batching|
|PROTO-10|(b) cap and append a truncation marker|`e9624fb`|unit test: `appendIndexListing` with a cap of 2 renders two lines plus `truncated: 1 more records`; the policy constant is 5 000|
|SRV-2|(a) refuse a non-object result with `-32603`|`e9624fb`|unit test in `src/protocol/response.zig`: a string result is `NonObjectResult` instead of an unchecked `.object`|
|SRV-3|(a) reply `-32603` when the failure is OOM|`e9624fb`|unit test on `errors.outOfMemory`; the serve loop answers `-32603` from a fresh pool instead of dropping the request|
|SRV-7|(a) cap the query and return `-32602`|`e9624fb`|regression + protocol tests: a 60 KiB query and a 65-token query are both `-32602`|
|GUIDE-4|(a) cap at 4 KiB and return `-32602`|`e9624fb`|`registry.zig` test: 4 KiB accepted, 4 KiB + 1 rejected, 64 array items accepted, 65 rejected, 4 nesting levels accepted, 5 rejected|
|REL-3|(a) strip `file://` into a path|`e9624fb`|unit test: `file:///tmp/i.jsonl` → `/tmp/i.jsonl`, `file:///C:/x` → `C:/x`, neither is a URL|
|REL-5|(a) a `--max-index-bytes` flag|`e9624fb`|unit test: `an artifact larger than the ceiling is rejected` (the golden index, 10-byte limit); CLI accepts the flag|
|REL-7|(b) also compare the metadata-change time|`e9624fb`|the watcher compares `ctime` as well as size and `mtime`, so an equal-size, equal-mtime rewrite is still detected|

## 18. Resolved on 2026-11-10, fourth chunk

One item, one commit: `reclaimLocked` freed an index's arena while holding the
store's spin lock, so readers spun for the whole free. The retired list is now
detached under the lock and freed after unlocking.

|Id|Option|Commit|Verification|
|---|---|---|---|
|SRV-5|(a) move the free outside the lock|`330386d`|unit test: the last release frees the retired index (the testing allocator would flag a leak) and the store's `retired` list is empty; `zig build test`, `test-regressions` and `bench` all pass|

## 19. Resolved on 2026-11-10, fifth chunk

Four documentation/packaging items, one commit (`891a0a3`): a canonical client
snippet and a canonical backlog. They share a theme — a second copy that drifts —
so they landed together, with a test per copy.

|Id|Option|Commit|Verification|
|---|---|---|---|
|DOC-1|(a) add `lsp.json` to `.paths`|`891a0a3`|`build.zig.zon` ships `lsp.json` and `client-config.json`; `zig build test` still passes|
|DOC-2|(a) one snippet in a file both read|`891a0a3`|`DOC-2: the readme embeds client-config.json verbatim` (unit test); `release.yml` cats the same file into the release body|
|DOC-3|(a) this file is canonical|`891a0a3`|covered by GUIDE-8's test; §14 and the readme's Known limitations are pointers|
|GUIDE-8|(a) this file is canonical and the others link to it|`891a0a3`|`GUIDE-8: the limitation lists live only in PLAN.md` (unit test): neither section restates the backlog|

## 20. Resolved on 2026-11-10, sixth chunk

Two CI items, one commit (`c4994bc`): the workflow-local copies of the
`data/sources.zon` parser are gone, replaced by one parser over the ZON AST, and
the indexer finally honours the `exclude` scope it was given.

|Id|Option|Commit|Verification|
|---|---|---|---|
|CI-4|(a)+(b)|`c4994bc`|indexer test `an --exclude pattern removes matching files from the index` (bare prefix vs `**`, one run per form); CLI check: the fixture's two `lib/std/nested/container.zig` records vanish under `--exclude lib/std/nested` and no other record changes|
|CI-5|(a)+(b)|`c4994bc`|`src/util/sources.zig` unit test parses a reformatted, one-line, no-scope ZON file and gets every include and exclude; `zig build plan-sources` prints both real sources; `zig build test`, `check`, `workflows`, `zig fmt` and actionlint 1.7.7 pass|

## 21. Resolved on 2026-11-10, seventh chunk

One indexer item, one commit (`fbc7026`): record line numbers no longer rescan
from byte 0. `tools/line_table.zig` records the line starts once per file and
binary-searches them, which turned a clean n² ladder into a linear one.

|Id|Option|Commit|Verification|
|---|---|---|---|
|IDX-9|(a)|`fbc7026`|`lineOf agrees with findLineColumn at every offset` (unit test); the golden index is still byte-identical, and it pins every `line`; Debug ladder 5k/10k/25k = 0.109/0.119/0.296 s (was 1.17/4.63/29.65 s), ReleaseSafe 0.035/0.033/0.071 s|

## 22. Resolved on 2026-11-10, eighth chunk

One indexer item, one commit (`feba2d2`): invalid UTF-8 in a doc comment no
longer turns `doc` into a byte array that the loader rejects.

|Id|Option|Commit|Verification|
|---|---|---|---|
|IDX-5|(a)|`feba2d2`|indexer test `invalid UTF-8 in a doc comment is replaced, not emitted as a byte array`: a temp file with 0xFF; the output is valid UTF-8, `doc` is a string with U+FFFD, and `doc_hash` is the SHA-256 of the sanitized text|

## 23. Resolved on 2026-11-10, ninth chunk

One indexer item, one commit (`1d0a99a`): `modulePath` no longer strips every
leading dot, so a parent path cannot collapse onto a sibling's symbol and a
dotfile keeps its name.

|Id|Option|Commit|Verification|
|---|---|---|---|
|IDX-6|(a)|`1d0a99a`|indexer unit test `modulePath keeps dotfiles distinct and rejects a parent escape`: `x.zig`/`./x.zig` → `x`, `.hidden.zig` → `.hidden`, `lib/std/mem.zig` → `lib.std.mem`, `../x.zig` and `lib/../x.zig` → `error.PathEscapesRoot`; the golden index is unchanged|

## 24. Resolved on 2026-11-10, tenth chunk

One indexer item, one commit (`4d33172`), resolved with option (a): error sets are
flat by grammar, so `handleErrorSet` only ever receives a valid set. A nested
declaration is invalid Zig; the parser recovers it and the file is degraded. The new
test pins that no error member is invented.

|Id|Option|Commit|Verification|
|---|---|---|---|
|IDX-7|(a) keep|`4d33172`|indexer test `a nested declaration in an error set degrades the file instead of inventing a member`: exit 0, no `kind:error` record for the nested name, `bad.zig` listed as degraded; the `if`/`struct`/`@import`/string variants were probed too (all exit 0, no records, never a misattributed member)|

## 25. Resolved on 2026-11-10, eleventh chunk

One CI item, one commit (`7db2cee`): the release tarball now contains the binary
and the advice corpus it loads at startup, and the raw-binary name no longer depends
on the Unix binary having an extension.

|Id|Option|Commit|Verification|
|---|---|---|---|
|CI-8|(a)|`7db2cee`|local smoke: tar the ReleaseSafe binary + `data/advice`, unpack into an empty directory, run with EOF → exit 0 with all five corpus files present; `zig build workflows`, `zig fmt` and actionlint 1.7.7 pass|

## 26. Resolved on 2026-11-10, twelfth chunk

One CI item, one commit (`f7fb720`): the actions moved to their node24 majors.
`mlugg/setup-zig@v2` is the one remaining node20 action — upstream's latest tag is
v2.2.1 and no node24 release exists — so it is kept and documented (option c for
that one).

|Id|Option|Commit|Verification|
|---|---|---|---|
|CI-9|(a), plus (c) for `setup-zig`|`f7fb720`|each action.yml declares `runs.using`: `checkout@v5`, `upload-artifact@v6`, `setup-go@v6`, `action-gh-release@v3` = node24; `setup-zig@v2` = node20 (upstream, no v3). `zig build workflows`, `zig fmt --check` and actionlint 1.7.7 pass|

## 27. Resolved on 2026-11-10, thirteenth chunk

One CI item, one commit (`a02c46b`): the bump branch carries the run id, so a second
run the same day cannot collide with the first run's branch. The diff gate runs
before the branch, so a no-op rerun still creates nothing.

|Id|Option|Commit|Verification|
|---|---|---|---|
|CI-6|(a)|`a02c46b`|branch is `bump/upstream-<date>-${GITHUB_RUN_ID}`, unique per run; `zig build workflows` and the pinned actionlint pass. The live twice-a-day rerun is a CI-only check (the layer §10 named)|



