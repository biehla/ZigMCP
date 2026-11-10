# PLAN.md — the remediation backlog

**Status:** one open item — [CI-13](#1-open-items). Every other id is closed, with the
option chosen, the commit and the check that was run, in [§4](#4-resolved-ledger);
[§5](#5-batch-log) records how the work was batched.

This is the canonical backlog. [`AGENTS.md`](AGENTS.md) §14 points here and keeps no
copy; `AGENTS.md` remains the spec of record for behaviour, so an entry is a gap between
the tree and that spec. Two sources: a read-through of the tree on 2026-11-09, and a
breakage campaign the same day that fuzzed the stdio surface and the indexer, profiled
the hot paths and inspected a `ReleaseSafe` PE with REA — method, measurements and
negative results in [§3](#3-breakage-campaign-2026-11-09).

**Ids are stable** and commits cite them (`fix(ci): CI-1`, `feat(tools): PROTO-15`). An
entry states the problem in one sentence, gives 2–3 options, and names the cheapest check
that the fix worked. [§2](#2-verification) lists the gates and the recipes that check
performs, and [§2.3](#23-where-each-check-lives) maps an id to the test layer that owns
it.

*Reorganised on 2026-11-10: the per-chunk sections that were §13–§35 are now one ledger
([§4](#4-resolved-ledger)) and one batch log ([§5](#5-batch-log)). No id changed; an old
commit that cites "PLAN §23" is citing a batch that now appears as its rows and its
batch-log line.*

---

## 1. Open items

### CI/CD

**CI-13 — `main` exists but is not the default branch, so `index.yml` ignores the line
of development.** `index.yml` triggers on `push: branches: [main]` and `bump-master.yml`
opens its PR with `--base main`; `main` was created on the remote at `1a3704e`, but the
repository's **default** branch is still
`autoresearch/data-driven-programming-best-practices-for-build-20261109`. A push to the
branch work actually lands on therefore never rebuilds the index, and `main` is a
snapshot rather than the development line the bump PR would merge into.

Options: (a) make `main` the default branch and merge the current default into it;
(b) read the branch from `${{ github.event.repository.default_branch }}` in both
workflows; (c) accept dispatch-only for the index and keep `main` as the PR target on
purpose.

Verify: `gh run list --workflow index.yml` shows a run with `event: push` after a
`data/sources.zon` change lands on the default branch.

### Closed areas

Nothing else is open. Each area this file has carried — the protocol surface, the server
runtime, the indexer, index loading and hot reload, guideline deviations, test coverage,
documentation and packaging, and the environment — is clean, and its evidence is the
ledger row in [§4](#4-resolved-ledger) rather than an empty section here. New work starts
from a fresh read-through or a breakage campaign, not from this list.

---

## 2. Verification

### 2.1 Gates

| Command | Proves |
|---|---|
| `zig build test` | unit, property, integration, golden and protocol layers compile and pass |
| `zig build check` | the advice corpus is schema-valid: 12 patterns, 12 rules, ids and `Sxx` refs resolve |
| `zig fmt --check . --exclude tests/fixtures` | formatting |
| `zig build bench` | the server starts, answers every tool, and prints latencies |
| `zig build test-protocol` | protocol layer alone (fastest signal for wire changes) |

Every gate runs on this machine (Zig 0.17.1, Windows, 2026-11-09): `test` green, `check`
green, `workflows` green, `bench` prints startup 18.2 ms, peak RSS 7.6 MB, 0 tool errors.
`test-regressions` is green: the red-by-design suite is gone, its pure-function tests
moved into `registry.zig` and `text.zig`, and the handler tests that remain run in
`zig build test` as well. ENV-1 in [§4.6](#46-tests-guidelines-docs-and-environment)
records why a build once produced a 0-byte binary.

### 2.2 Recipes

On Windows every `zig-out/bin/<tool>` below is `zig-out/bin/<tool>.exe`, and the blocks
assume a POSIX shell.

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

# nesting past the reader buffer (SRV-1; bounds depth, §3): 100k nested arrays
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

### 2.3 Where each check lives

`src/regressions_test.zig` (run as `zig build test-regressions`, and as part of
`zig build test`) holds the cross-cutting handler tests that need the real corpus and a
loaded doc index. It is no longer a red-by-design suite; every closed id has the test its
layer owns, named in its [ledger](#4-resolved-ledger) row. CI-13 has no test layer at
all: its check is a live dispatch, as its entry says.

A new handler test can use the `Harness` in `src/regressions_test.zig` — it builds a real
corpus and an empty index, so the test is a few lines.

---

## 3. Breakage campaign, 2026-11-09

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
  exception is the known PROTO-2 hole, which answers a successful result. Notifications
  never produced a reply, and no case crashed: the only process exits were SRV-1's clean
  stdin failure on lines of 65 536 bytes or more.
- **Index encoding.** A `doc` holding a raw `0xFF`, a truncated `0xC3` or a `\ud800`
  escape is rejected by the loader, so invalid UTF-8 never reaches the wire; records
  carrying U+0000 and U+001F escapes load and still produce a valid JSON response.
- **No format-string path.** `docs://{s}/index`, `docs://%/symbols/%s`, a 60 KB URI and
  an empty URI all return `-32602` and no crash.
- **SRV-4 is unreachable behind SRV-1.** 10 000 nested arrays answer `-32602`; 100 000
  exceed the reader buffer and hit SRV-1 first, which bounds JSON depth.
- **Reload is leak-free.** Twelve swaps alternating 5 000/5 200 records held RSS at
  7.2–7.8 MB, and a truncated write left the previous index serving (5 200 records, old
  commit) — REL-4's degradation works.
- **Indexer resilience.** 4 MiB doc comments, NUL-only files, empty files and unclosed
  error sets are all handled; only nesting depth (IDX-8) and declaration count (IDX-9)
  hurt.
- **Release dependencies.** `ntdll.dll` (65), `KERNEL32.dll` (1), `CRYPT32.dll` (9), no
  delay imports — no third-party runtime dependency (D1).
- **Corpus loading is fail-fast, not fail-open.** A truncated or empty `patterns.zon`,
  an unknown `.evidence` tag and a missing `rules.zon` each stop start-up with exit 1 and
  a `file:line` diagnostic, and no handler is ever reached with a broken tree.
  Parseable-but-invalid corpora are the opposite problem: they serve silently (CI-3).
- **Corpus not embedded.** A pattern name from `patterns.zon` does not appear in the
  binary, confirming CI-8: a release needs `data/advice` beside it.

The drivers and fixture trees lived in `.probe/` (gitignored). The crash and timing items
have recipes in [§2.2](#22-recipes); the rest carry a `Verify:` line naming the exact
command or tool, and REL-9/REL-10 are single-record edits over the PROTO-13 fixture.

---

## 4. Resolved ledger

How to read a row: **Option** is the letter from the item's own list with the decision it
chose in a phrase, or the decision alone where the item had no list; **Commit** is the
commit that carries the change, `—` where the entry was closed without one; **Verification**
is what was actually run, not what was inspected. A `—` commit means the entry was already
done when the backlog was re-read, and its Verification column is the evidence that closed
it.

### 4.1 Protocol and the MCP surface

|Id|Option|Commit|Verification|
|---|---|---|---|
|PROTO-1|(a) serve the list|`9381888`|handler test: every listed resource reads|
|PROTO-2|(a) validate the real arguments|`e152999`|handler test: `{"bogus":1}` → `-32602`|
|PROTO-3|(b) `-32601` plus `data.supportedVersions`|`e9624fb`|protocol test: `initialize` on the current revision names `server/discover` and both supported versions|
|PROTO-4|(a) implement the notification stream|`e9624fb`|protocol tests: an unknown `logLevel` is `-32602`; a reload failure reaches the client that asked for logs as `notifications/message`|
|PROTO-5|(a) fold constraint text into the signal tokens|`e9624fb`|regression test: a constraint naming the bottleneck matches R03 while the echoed `signals` stay exactly what the caller sent|
|PROTO-6|(a) `-32602` when both are present|`6871df4`|handler test|
|PROTO-7|(a) return `match_count` and `truncated`|`e9624fb`|`advice_lookup` reports both in every result; the truncation marker names the hidden count|
|PROTO-8|(b) keep rejecting and document|`e9624fb`|protocol test: an array envelope → `-32600` with a null id; MCP has no batching|
|PROTO-9|(a) accept integral floats|`5c5ccdd`|`registry.zig` test: `20.0` accepted, `20.5` and `1e300` rejected|
|PROTO-10|(b) cap and append a truncation marker|`e9624fb`|unit test: `appendIndexListing` with a cap of 2 renders two lines plus `truncated: 1 more records`; the policy constant is 5 000|
|PROTO-11|(a) type-check each echoed value|`5cf1b72`|[§2.2](#22-recipes) mistyped sidecar → all three members absent; unit test|
|PROTO-12|(a) always emit `structuredContent`|`74691aa`|protocol test: no-match `doc_search`, `doc_get` and `advice_lookup` all carry it|
|PROTO-13|(a) exact project keys|`e29796a`|[§2.2](#22-recipes) case-colliding index → one record per URI; handler test|
|PROTO-14|(a) resolve the argument exactly first, then ignoring case and `_` vs `-`, and only when that names one project|`f2e3844`|handler tests: `project: "zig-std"` reaches the `zig_std` records and `doc_get` echoes `ZIG_STD` back; `FIXTURE` over `Fixture`+`fixture` is `isError` with both keys named and no merging; `nope` lists `Known projects: mcp_zig, zig_std`; the PROTO-13 test still passes|
|PROTO-15|the miss reports the closest stored symbols in the message and a `candidates` array|`8a33da8`|regression tests `PROTO-15: a miss names the stored path-qualified symbols` (`ArrayList.append` → `candidates[0] == "lib.std.std.ArrayList"`, and a nonsense spelling → an empty list) and `PROTO-16`'s; protocol test: `fixture`/`comments.plain.line` → `candidates` names `lib.std.comments.plain`|
|PROTO-16|a **dotted tail** resolves when exactly one stored symbol ends with it; `resolved_from` echoes the argument as sent, and two symbols sharing the tail stay a miss|`a6f48b3`|regression test `PROTO-16: a unique dotted tail reaches the stored symbol`: `mem.copyForwards` → `lib.std.mem.copyForwards` with `resolved_from`, `em.copyForwards` a miss on the `.` boundary, `.dup` shared by two symbols a miss; protocol test: `comments.plain` resolves to `lib.std.comments.plain`|

### 4.2 Server runtime and the wire

|Id|Option|Commit|Verification|
|---|---|---|---|
|SRV-1|(a) `-32700`, discard, continue|`8d7cc1d`|protocol test: 70 KiB line → `-32700`, next request answered, exit 0|
|SRV-2|(a) refuse a non-object result with `-32603`|`e9624fb`|unit test in `src/protocol/response.zig`: a string result is `NonObjectResult` instead of an unchecked `.object`|
|SRV-3|(a) reply `-32603` when the failure is OOM|`e9624fb`|unit test on `errors.outOfMemory`; the serve loop answers `-32603` from a fresh pool instead of dropping the request|
|SRV-4|closed as unreachable: the 64 KiB reader cap bounds JSON nesting, and the indexer's own recursion hazard was IDX-8 (`6836304`)|—|the [§2.2](#22-recipes) nesting recipe at the maximum depth a 64 KiB line allows — 32 726 nested arrays in 65 499 bytes — answers `-32602` and exits 0; 10 000 nested arrays do the same|
|SRV-5|(a) move the free outside the lock|`330386d`|unit test: the last release frees the retired index (the testing allocator would flag a leak) and the store's `retired` list is empty; `zig build test`, `test-regressions` and `bench` all pass|
|SRV-6|(b) `std.math.cast`, drop the count|`bf0bdf0`|[§2.2](#22-recipes) sidecar recipe exits 0 with no `files_degraded`; unit test|
|SRV-7|(a) cap the query and return `-32602`|`e9624fb`|regression + protocol tests: a 60 KiB query and a 65-token query are both `-32602`|
|SRV-8|(a) usage block, exit 2|`173e11a`|protocol test: `--bogus` → exit 2, `Usage: zigmcp`, no Zig error name|

### 4.3 Indexer

|Id|Option|Commit|Verification|
|---|---|---|---|
|IDX-1|(a) degrade with a reason|`61d0865`|indexer test: 65 MiB file → rc 0, `files_degraded: 1`, other records intact|
|IDX-2|(a) strip a trailing `/**` in `matchesInclude`|`aa7021b`|indexer test: `--include 'lib/std/**'` and `--include lib/std` produce identical, non-empty output|
|IDX-3|(a) cross-check the sidecar count|`6be0038`|indexer test: sidecar 5 vs 2 records → re-indexed; 2 vs 2 → carried over|
|IDX-4|(a) `doc_get` returns every match|`aa7021b`|regression test: two records sharing `mod.dup` → `matches.len == 2` in `(path, line)` order|
|IDX-5|(a) replace an invalid byte with U+FFFD before hashing|`feba2d2`|indexer test `invalid UTF-8 in a doc comment is replaced, not emitted as a byte array`: a temp file with 0xFF; the output is valid UTF-8, `doc` is a string with U+FFFD, and `doc_hash` is the SHA-256 of the sanitized text|
|IDX-6|(a) reject a parent escape, keep a dotfile|`1d0a99a`|indexer unit test `modulePath keeps dotfiles distinct and rejects a parent escape`: `x.zig`/`./x.zig` → `x`, `.hidden.zig` → `.hidden`, `lib/std/mem.zig` → `lib.std.mem`, `../x.zig` and `lib/../x.zig` → `error.PathEscapesRoot`; the golden index is unchanged|
|IDX-7|(a) keep: error sets are flat by grammar, so a nested declaration is invalid Zig and degrades the file|`4d33172`|indexer test `a nested declaration in an error set degrades the file instead of inventing a member`: exit 0, no `kind:error` record for the nested name, `bad.zig` listed as degraded; the `if`/`struct`/`@import`/string variants were probed too (all exit 0, no records, never a misattributed member)|
|IDX-8|(a) depth pre-scan, limit 256|`6836304`|indexer test: 2 000 nested parens → rc 0 + degraded reason|
|IDX-9|(a) a line-start table, binary-searched|`fbc7026`|`lineOf agrees with findLineColumn at every offset` (unit test); the golden index is still byte-identical, and it pins every `line`; Debug ladder 5k/10k/25k = 0.109/0.119/0.296 s (was 1.17/4.63/29.65 s), ReleaseSafe 0.035/0.033/0.071 s|
|IDX-10|the walk counts every site that can carry a record — fn/var/field, named parameter, error-set member, a file's `//!` run — so `records / declarations` never exceeds 1; an incremental run carries the count from the previous sidecar, and omits the member when that sidecar has none|`15cfd60`, `4931082`|the fixture tree reports `records: 33, declarations: 42`; `tests/golden/index.status.json` pins it and the JSONL stayed byte-identical; protocol test `doc_import_status reports the declaration yield from the sidecar` reads both members from a live server; indexer tests `an incremental run keeps the declaration count it did not walk` (carried, never `0`) and `a carried-over project with no known site count omits the member`|
|DOC-10|declined: a `source` field on the record would let a client tell `///` from `//!` from a `//` run, but it changes the artifact format for a distinction the readme already states, and `path:line` answers the question directly|—|readme "A record does not say which of those three produced its text" and `AGENTS.md` §7's `doc` row (`10ad271`)|

### 4.4 Index loading and hot reload

|Id|Option|Commit|Verification|
|---|---|---|---|
|REL-1|(a) make the poll interval a server option|`4ea4509`|`REL-1: the poll interval is configurable and clamped` (unit test): defaults 1000/60000, an explicit 250 wins for both source kinds, 0 clamps to 100; `zig build test`, `check`, `workflows` and `zig fmt --check` pass|
|REL-2|(c), plus removing the startup block|`9b19761`|protocol test `REL-2: a black-holed index URL does not block startup`: with `--index http://10.255.255.1/...` the server answers `server/discover`; before the fix the same probe hung (reproduced: still running 3 s after EOF). `zig build test`, `check`, `workflows` and `zig fmt --check` pass|
|REL-3|(a) strip `file://` into a path|`e9624fb`|unit test: `file:///tmp/i.jsonl` → `/tmp/i.jsonl`, `file:///C:/x` → `C:/x`, neither is a URL|
|REL-4|(a) expose the load state|`e6e2009`|protocol test: `--index missing.jsonl` → `reload_failed` + `FileNotFound`|
|REL-5|(a) a `--max-index-bytes` flag|`e9624fb`|unit test: `an artifact larger than the ceiling is rejected` (the golden index, 10-byte limit); CLI accepts the flag|
|REL-6|(c) local-only sidecar rule, stated in AGENTS.md §5|`8e047c1`|unit test `REL-6: a URL index has no local status sidecar`: `http(s)` paths are remote, a relative path and `file://` are not; `zig build test` passes|
|REL-7|(b) also compare the metadata-change time|`e9624fb`|the watcher compares `ctime` as well as size and `mtime`, so an equal-size, equal-mtime rewrite is still detected|
|REL-8|(a) propagate the underlying error|`6eaa06e`|`--index missing.jsonl` → `FileNotFound`, `--index tests` → `IsDir`|
|REL-9|(a) verify at load|`977695b`|tampered `doc` → `MalformedRecord`; the golden index still loads 25 records|
|REL-10|(a) reject out-of-order artifacts|`8b965e4`|swapped golden lines → `MalformedRecord`; unit test|
|REL-11|declined: publishing and fetching `index.status.json` beside a URL index would report another run's health unless its `commit` were checked against the loaded index, and it doubles the poll cost for counts that describe the publisher, not the served artifact|—|`REL-6`'s unit test names `http(s)` as remote; `AGENTS.md` §5 states the local-only rule and the readme's troubleshooting row says why the counts are absent|

### 4.5 CI/CD, docs and packaging

|Id|Option|Commit|Verification|
|---|---|---|---|
|CI-1|(b) drop the `if:`|`f2cf5ec`|`zig build workflows` fails on the pre-fix file (`index.yml:25`) and passes now; actionlint clean|
|CI-2|(a) rolling `index` release|`80171d2`|`zig build workflows` + actionlint; `gh release view index` after a run (no remote here)|
|CI-3|(a) add `zig build check`|`b33cb93`|`tests/advice_check_test.zig` (the validator fails closed) plus the `ci.yml` step|
|CI-4|(a)+(b) one parser over the ZON AST, and honour `exclude`|`c4994bc`|indexer test `an --exclude pattern removes matching files from the index` (bare prefix vs `**`, one run per form); CLI check: the fixture's two `lib/std/nested/container.zig` records vanish under `--exclude lib/std/nested` and no other record changes|
|CI-5|(a)+(b) emit every include and exclude from `data/sources.zon`|`c4994bc`|`src/util/sources.zig` unit test parses a reformatted, one-line, no-scope ZON file and gets every include and exclude; `zig build plan-sources` prints both real sources; `zig build test`, `check`, `workflows`, `zig fmt` and actionlint 1.7.7 pass|
|CI-6|(a) put the run id in the branch name|`a02c46b`|branch is `bump/upstream-<date>-${GITHUB_RUN_ID}`, unique per run; `zig build workflows` and the pinned actionlint pass. The live twice-a-day rerun is a CI-only check (the layer [§2.3](#23-where-each-check-lives) names)|
|CI-7|(c) fetch exactly the pinned commit|`93c6094`|the form `git init` + `remote add` + `fetch --depth 1 origin <sha>` + `checkout --detach FETCH_HEAD` was run against GitHub and resolved `FETCH_HEAD` to the pinned SHA; `zig build workflows` and the pinned actionlint pass. A before/after run-time comparison is a CI-only check|
|CI-8|(a) ship the corpus in the tarball|`7db2cee`|local smoke: tar the ReleaseSafe binary + `data/advice`, unpack into an empty directory, run with EOF → exit 0 with all five corpus files present; `zig build workflows`, `zig fmt` and actionlint 1.7.7 pass|
|CI-9|(a) node24 majors, plus (c) for `setup-zig`|`f7fb720`|each action.yml declares `runs.using`: `checkout@v5`, `upload-artifact@v6`, `setup-go@v6`, `action-gh-release@v3` = node24; `setup-zig@v2` = node20 (upstream, no v3). `zig build workflows`, `zig fmt --check` and actionlint 1.7.7 pass|
|CI-10|(a) stop pre-seeding `generated/`|`e9dabc4`|`index.yml` "Build the index" → "Merge and sort" → "Merge the status sidecars": pre-fix aborts with `JSONDecodeError` on the empty `index.status.json` (run `42801043827`'s exact failure), post-fix exits 0 with two projects and two records|
|CI-11|(a) run `zig fetch --save` inside `scratch`|`e9dabc4`|`bump-master.yml` "Re-resolve the tracked branches": pre-fix aborts with `no dependency block` (run `42800551557`'s exact failure), post-fix writes both pins with the resolved commit and `scratch/build.zig.zon` carries the dependency|
|CI-12|(a) `# shellcheck disable=SC2016`, the backticks being literal markdown|`e9dabc4`|`actionlint -shellcheck shellcheck 0.11.0`: pre-fix reports the same three `SC2016` findings on `release.yml:51` and exits 1, post-fix exits 0; the generated `release-notes.md` is byte-identical before and after|
|DOC-1|(a) add `lsp.json` to `.paths`|`891a0a3`|`build.zig.zon` ships `lsp.json` and `client-config.json`; `zig build test` still passes|
|DOC-2|(a) one snippet in a file both read|`891a0a3`|`DOC-2: the readme embeds client-config.json verbatim` (unit test); `release.yml` cats the same file into the release body|
|DOC-3|(a) this file is canonical|`891a0a3`|covered by GUIDE-8's test; §14 of `AGENTS.md` and the readme's Known limitations are pointers|
|DOC-4|(b) manifest plus version resource|`e9c8057`|pefile on the Debug and ReleaseSafe images: resource types `RT_MANIFEST` + `RT_VERSION`, with `CompanyName`/`FileDescription`/`FileVersion`/`ProductName`/`ProductVersion` = ZigMCP / ZigMCP MCP server / 0.1.0 / ZigMCP / 0.1.0; `zig build test` passes|
|DOC-5|(a) state "documentation comments only" in the tool descriptions and the readme|`f2e3844`|`tools/list` description text from a live server; readme "The doc index" paragraph|
|DOC-6|add `LICENSE` (MIT), `build.zig.zon` `paths`, and the release tarball copy|`f2e3844`|`head -1 LICENSE`; the `paths` entry in `build.zig.zon`; the packaging step copies it into `dist/pkg`|
|DOC-7|examples and descriptions use the stored spelling|`85d4871`|readme `doc_get` example and record example carry `lib.std.mem.copyForwards`; `tools/list` descriptions name `///`, `//!` and plain `//`; `server/discover` instructions state the rule|
|DOC-8|document the per-poll re-download|`85d4871`|readme "How updates land" names the full re-download and the local-file alternative|
|DOC-9|state that every answer is retrieval|`61ff0f1`|`server/discover`'s instructions from a live server name the two corpora and say the server does not generate code or claim anything was compiled; readme Tools says the same|

The last check for CI-10, CI-11 and CI-12 is a live dispatch after the push: the replica
proves the shell logic, not GitHub's environment.

### 4.6 Tests, guidelines, docs and environment

|Id|Option|Commit|Verification|
|---|---|---|---|
|GUIDE-1|(a) add the `//!` headers|`20784b3`|`src/root.zig` lint test names every headerless `src/**`/`tools/**` file (both tools before the fix) and passes after|
|GUIDE-2|(a) a `handler` in `PromptSpec`/`ResourceSpec` (and `cache` in resources)|`20784b3`|regression tests: every prompt spec dispatches through its handler, both resource families read through the table|
|GUIDE-3|(a) one shared `src/advice/schema.zig` imported as the `advice_schema` module|`20784b3`|`zig build check` + `zig build bench` compile both tools against it; one `const Pattern = struct` left in `src` and `tools`; `corpus.zig` pins type identity at comptime|
|GUIDE-4|(a) cap at 4 KiB and return `-32602`|`e9624fb`|`registry.zig` test: 4 KiB accepted, 4 KiB + 1 rejected, 64 array items accepted, 65 rejected, 4 nesting levels accepted, 5 rejected|
|GUIDE-5|(a) `null` means `{}`|`b0eb235`|`registry.zig` test: a required field is rejected for absent arguments|
|GUIDE-6|(b) growable token buffer|`94b0dd3`|`text.zig` test: a 200-character token is kept whole|
|GUIDE-7|closed: CI-3 wired `zig build check` in, so the validator runs where the claim says it does|—|`.github/workflows/ci.yml`: `- name: Validate the advice corpus` → `run: zig build check`, in both the blocking and the canary job|
|GUIDE-8|(a) this file is canonical and the others link to it|`891a0a3`|`GUIDE-8: the limitation lists live only in PLAN.md` (unit test): neither section restates the backlog|
|TEST-1|dropped as stale: already covered|—|`tests/protocol_test.zig`: `an oversized line is a parse error and the server keeps serving`|
|TEST-2|closed by IDX-4|`aa7021b`|`IDX-4: doc_get returns every record sharing a symbol`|
|TEST-3|closed: the test exists|—|`src/regressions_test.zig`: `PROTO-2: doc_import_status rejects unknown arguments`|
|TEST-4|closed: the test exists|—|`src/regressions_test.zig`: `PROTO-1: every listed resource can be read`|
|TEST-5|dropped as stale: already covered|—|`ci.yml` runs `zig build workflows` and `go run …/actionlint@v1.7.7` in both jobs|
|TEST-6|the `--include` half; `--previous`/`--status` were already covered|`aa7021b`|`an --include glob selects the same files as its directory prefix`; `a truncated --previous index is not reused` already asserts `skipped` and the derived `.status.json`|
|ENV-1|resolved on 2026-11-09 — the disk was full, not the toolchain|—|`zig build test` exits 0 and `zig-out/bin/zigmcp.exe` is non-zero; the symptom and its check live in the readme troubleshooting table|

Two entries changed shape while being fixed, both recorded in `AGENTS.md`:

- **PROTO-12** adds `found` to `doc_get`'s output schema and makes the record fields
  optional. A no-match result cannot satisfy a schema whose every member is required, so
  the alternative was to stop advertising the schema.
- **REL-10**'s test exposed a pre-existing leak: `load`'s error path destroyed the
  `ArenaAllocator` struct without freeing its pages, so every rejected artifact leaked
  its partial index. Fixed in the same commit.

**CI-9** was added during the first pass, not found by it: the scoop-installed actionlint
(1.17.1) reports that every `uses:` in the tree runs on a deprecated node20 runtime, and
`ci.yml` pins the older v1.7.7, which does not report it. The gate stays green while the
deprecation is tracked rather than silently ignored.

### 4.7 Retrieval performance

The decision trigger in `AGENTS.md` §3 asks for a measured exact baseline before a cache
or an index is added. The baseline now exists, so an inverted index is a decision with
numbers behind it rather than a preference.

|Id|Option|Commit|Verification|
|---|---|---|---|
|PERF-1|declined an inverted or trigram index: at the current corpus a linear scan answers in ~10 ms, and a call-graph corpus would be a new decision rather than a faster scan|—|`zig build -Doptimize=ReleaseSafe`, then `zig-out/bin/bench --server zig-out/bin/zigmcp --index generated/index.jsonl --iterations 40` over 13 482 records / 5 736 450 bytes: `doc_search` p50/p95/p99 = 9.035/10.168/10.234 ms, `doc_get` = 0.185/0.302/0.377 ms, `doc_import_status` = 0.944/1.231/1.300 ms, `advice_lookup` = 0.040/0.058/0.125 ms, 0 errors, startup 84.1 ms, peak RSS 27 766 784 bytes|

Re-measure before changing the retrieval path: the same command, the same index, in
`ReleaseSafe`. A second corpus (callers, call paths) is a new indexer pass and a new
decision, not an optimisation of this one.

---

## 5. Batch log

A batch is a commit (or a pair) that closed several ids at once, and a sync commit that
moved the resolved tables. Each row says what it carried and why those items shared a
commit; the ids themselves are in [§4](#4-resolved-ledger), with their commits.

|Date|Commit(s)|What it carried, and why together|
|---|---|---|
|2026-11-09|22 commits|The first pass, one commit per item: each fix's test and its pending deletion were reviewable on their own|
|2026-11-09|—|Five entries were already done when the backlog was re-read; deleted rather than left as phantom tasks (§4 rows with no commit)|
|2026-11-10|`20784b3`|Schema module, table dispatch and module headers: three items touch the same three tools and the same two docs, so splitting would have meant staging halves of one file|
|2026-11-10|`aa7021b`|The `--include` glob and `doc_get`'s duplicate handling are independent defects, but their tests, their doc rows and their deletions overlap|
|2026-11-10|`e9624fb`|Thirteen items: the protocol surface, the input bounds, the reload predicates and the index ceiling all landed in the same tree, with overlapping tests and deletions|
|2026-11-10|`330386d`|`reclaimLocked` freed an index's arena while holding the lock, so readers spun for the whole free; the retired list is now detached under the lock and freed after unlocking|
|2026-11-10|`891a0a3`|Four documentation/packaging items sharing one theme — a second copy that drifts — each with a test per copy|
|2026-11-10|`c4994bc`|The workflow-local copies of the `data/sources.zon` parser, replaced by one parser over the ZON AST, and the `exclude` scope the indexer ignored|
|2026-11-10|`fbc7026`|Record line numbers no longer rescan from byte 0; `tools/line_table.zig` records the line starts once per file and binary-searches them|
|2026-11-10|`feba2d2`|Invalid UTF-8 in a doc comment no longer turns `doc` into a byte array the loader rejects|
|2026-11-10|`1d0a99a`|`modulePath` no longer strips every leading dot, so a parent path cannot collapse onto a sibling's symbol and a dotfile keeps its name|
|2026-11-10|`4d33172`|An error set was kept as option (a) rather than made tolerant: no error member is invented for a nested declaration|
|2026-11-10|`7db2cee`|The release tarball gained the advice corpus, and the raw-binary name stopped depending on the Unix binary having an extension|
|2026-11-10|`f7fb720`|The actions moved to their node24 majors; `mlugg/setup-zig@v2` stays on node20 because upstream has no release for it|
|2026-11-10|`a02c46b`|The bump branch carries the run id, so a second run the same day cannot collide; the diff gate still runs before the branch|
|2026-11-10|`4ea4509`|A remote index is still re-fetched on every poll, but the cadence became a server option instead of a constant|
|2026-11-10|`9b19761`|A remote index is no longer fetched before startup: the watcher owns the fetch and polls immediately, since the stdlib client has no request timeout|
|2026-11-10|`e9c8057`|The Windows binary carries a manifest (asInvoker, supported OS) and a version resource, so Windows applies no compatibility heuristics|
|2026-11-10|`8e047c1`|A remote index has no sidecar and none is fetched: the local-only rule is stated in `AGENTS.md` §5 rather than worked around|
|2026-11-10|`93c6094`|Both workflows fetch exactly the pinned commit instead of cloning the branch and checking the pin out|
|2026-11-10|`e9dabc4`|Three CI defects found by the first dispatches of workflows that had never run: each was reproduced by extracting the failing step's `run:` body and executing it in a replica tree with stub binaries|
|2026-11-10|`f2e3844`|An external review of the published repository: a project spelling that differed by case or `_` vs `-`, tool text that promised a signature the index never holds, and a missing `LICENSE`|
|2026-11-10|`8a33da8`, `85d4871`|An evaluation asking `doc_get` for the readme's own unqualified spelling: the miss now names the closest stored symbols, and every example uses the spelling the indexer produces|
|2026-11-10|`61ff0f1`, `a6f48b3`, `15cfd60`|The rest of `TODO.md`: the retrieval-only statement, dotted-tail resolution, the declaration yield, and a measured retrieval baseline — plus the items that measurement and the artifact-format rule let us decline (DOC-10, REL-11, PERF-1)|
