# PLAN.md — defects, edge cases, limitations, and guideline deviations

Status: open backlog; ENV-1 is resolved, nothing else is fixed yet. Two sources: a
read-through of the tree on 2026-11-09, and a breakage campaign the same day that
fuzzed the stdio surface and the indexer, profiled the hot paths, and inspected a
`ReleaseSafe` PE with REA — method, measurements and negative results in §12.
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
`check` green, `bench` prints startup 16.1 ms, peak RSS 7.5 MB, 0 tool errors.
`test-regressions` is **red by design** — six tests, one per fixable defect — and
turns green item by item as the backlog is worked. See ENV-1 for why builds
previously produced a 0-byte binary.

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

# oversized line (SRV-1): 70 KiB of spaces then EOF
python -c "print(' '*70000)" | zig-out/bin/zigmcp; echo "exit=$?"

# deep nesting (SRV-4): 100k nested arrays
python -c "print('{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\",\"params\":'+'['*100000+']'*100000+'}')" | zig-out/bin/zigmcp
```

```bash
# sidecar panic (SRV-6) and sidecar type leak (PROTO-11)
printf '%s\n' '{"project":"p","commit":"c","path":"a.zig","line":1,"kind":"fn","symbol":"s","doc":"d","doc_hash":"h"}' > .probe/s.jsonl
printf '%s' '{"projects":{"p":{"files_degraded":-1}}}' > .probe/s.status.json
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"doc_import_status","arguments":{}}}' | zig-out/bin/zigmcp --index .probe/s.jsonl; echo "exit=$?"   # exit 3, panic

# indexer stack overflow (IDX-8): Debug dies at 2000 nested parens (~4 KB), ReleaseSafe at 10000
python -c "print('pub const v = ' + '('*2000 + '1' + ')'*2000 + ';')" > .probe/deep.zig
zig-out/bin/indexer --out .probe/deep.jsonl --source p=c=.probe --include deep.zig; echo "exit=$?"   # exit 3221225477; regenerate with 10000 for ReleaseSafe

# search amplification (SRV-7): 50k-record index, then one 60 KB query
python -c "import json;[print(json.dumps({'project':'p','commit':'c','path':'m.zig','line':i+1,'kind':'fn','symbol':'mod.fn%d'%i,'container':'mod','doc':'doc %d about memory'%i,'doc_hash':'h'})) for i in range(50000)]" > .probe/big.jsonl
python -c "import json;print(json.dumps({'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'doc_search','arguments':{'query':'xyz '*15000}}}))" | zig-out/bin/zigmcp --index .probe/big.jsonl   # ~20 s for one line, ReleaseSafe

# case-colliding projects (PROTO-13)
printf '%s\n' '{"project":"Fixture","commit":"c1","path":"A.zig","line":1,"kind":"fn","symbol":"a","doc":"d","doc_hash":"h"}' '{"project":"fixture","commit":"c2","path":"b.zig","line":2,"kind":"fn","symbol":"b","doc":"d","doc_hash":"h"}' > .probe/case.jsonl
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"docs://fixture/index"}}' | zig-out/bin/zigmcp --index .probe/case.jsonl   # lists both records
```

---

## 1. CI/CD

- **CI-1 — `index.yml` never runs on its trigger.** The job `if:` tests
  `github.event.workflow_run.conclusion`, but the triggers are `push` and
  `workflow_dispatch`; on push that expression is false, so the publish job is
  skipped. Options: (a) `if: github.event_name == 'push' || github.event_name ==
  'workflow_dispatch'`; (b) drop the `if:` entirely; (c) add a `workflow_run`
  trigger and keep the condition. Verify: push a `data/sources.zon` change and see
  the job run.

- **CI-2 — the index is never published as a release asset.** `bump-master.yml` and
  `index.yml` both download `index.jsonl` from the latest release, but `release.yml`
  attaches `generated/index.jsonl` only if it exists in the tagged checkout, and it
  is gitignored, so it never does. Options: (a) add a publish job to `index.yml` that
  uploads to a rolling `index` release (`gh release upload --clobber`); (b) have
  `release.yml` rebuild the index in-job from the pinned commits; (c) serve the index
  from a stable URL and use that as the baseline. Verify: `gh release view` lists
  `index.jsonl` after a run.

- **CI-3 — corpus validation is not in CI.** `ci.yml` runs `zig build test` and `fmt`
  but not `zig build check`, so an invalid corpus merges green. Options: (a) add a
  `zig build check` step; (b) fold `check` into `test`; (c) run it in a separate
  workflow. Measured: a corpus whose fact cites `S99` and one whose rule considers
  `P99` both start and serve normally, and a corpus with `P03` renamed to `P99` serves
  11 patterns silently — only `zig build check` rejects them, and CI never runs it.
  Verify: break an `Sxx` id and watch CI fail.

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

---

## 2. Protocol / MCP surface

- **PROTO-1 — `advice://patterns` is advertised but unreadable.** `resources/list`
  emits it; `resources/read` has no branch for it and returns `-32602`. Options:
  (a) serve the concatenated pattern list; (b) stop listing it, keep
  `advice://overview`; (c) advertise it via `resources/templates/list` only. Verify:
  read the URI and expect `contents`.

- **PROTO-2 — `doc_import_status` accepts unknown arguments.** It calls
  `validate(schema, null)`, so `{"bogus":1}` passes even though §5 says unknown
  arguments are invalid params. Options: (a) validate the real `arguments` value;
  (b) reject any non-empty arguments object; (c) leave and document. Verify: the
  recipe in §0 returns `-32602`.

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

- **PROTO-6 — `advice_lookup` with both `concept` and `question` picks the concept
  silently.** Options: (a) `-32602` when both are present; (b) prefer `question`;
  (c) return both results. Verify: send both.

- **PROTO-7 — question mode truncates to 5 matches with no indication.** Options:
  (a) return `match_count` and `truncated`; (b) raise the cap; (c) include scores
  and tokens used. Verify: a question matching 6+ patterns.

- **PROTO-8 — JSON-RPC batches become `-32600`.** An array of requests is not an
  object, so it is rejected with `id: null`. Options: (a) accept arrays and reply
  with an array; (b) keep rejecting and document; (c) reply `-32600` per element.
  Verify: send `[{…},{…}]`.

- **PROTO-9 — integer arguments must be JSON integers.** `limit: 20.0` parses as a
  float and is rejected. Options: (a) accept integral floats; (b) coerce numbers by
  value; (c) leave. Verify: send `20.0`.

- **PROTO-10 — `docs://{project}/index` is unbounded.** One read returns every
  symbol of a project, unbounded in size. Options: (a) add a cursor/offset argument;
  (b) cap and append a truncation marker; (c) drop the resource in favour of
  `doc_search`. Verify: read it against a full index and measure bytes.

- **PROTO-11 — `doc_import_status` echoes unvalidated sidecar values, breaking its
  own `outputSchema`.** `files_total`, `files_degraded` and `degraded` are copied
  straight from `<index>.status.json` into `structuredContent`, so a sidecar holding
  `"files_total":"oops"` or `"files_degraded":1.5` yields a result whose types
  contradict the advertised schema (`integer`) and a client that validates the
  response rejects it. Options: (a) type-check each value and omit the mismatching
  fields; (b) parse the sidecar into one typed struct so a wrong type fails the whole
  sidecar and is reported; (c) drop sidecar data from the response. Verify: the §0
  sidecar recipe with a string `files_total` returns a result with no `files_total`.

- **PROTO-12 — a "nothing matched" result carries no `structuredContent` although the
  tool declares `outputSchema`.** `doc_search`, `doc_get` and `advice_lookup` all
  advertise an `outputSchema` in `tools/list`, but the no-match path returns
  `{content, isError}` only, so a typed client cannot tell "no result" from a
  malformed one and its own schema validation fails. Options: (a) always emit
  `structuredContent` (`{query, count: 0, results: []}`, `{project, symbol: null}`)
  with `isError: true`; (b) stop advertising `outputSchema` on tools with an
  empty-result path; (c) document that `isError` overrides the schema. Verify:
  `doc_search` with `"query":"zzzz"` returns `structuredContent.count == 0`.

- **PROTO-13 — two projects differing only in case are conflated.** Project keys are
  compared with `eqlIgnoreCase` in the `doc_search` project filter, in
  `docs://{project}/index` and in `docs://{project}/symbols/{symbol}`, while
  `resources/list` and `doc_import_status` treat the keys as distinct — so an index
  holding `Fixture` and `fixture` advertises two URIs that both return the union, and
  a project-scoped search returns records from both. Options: (a) compare project
  keys exactly and keep case-insensitivity for symbols only; (b) reject an index
  whose project keys collide case-insensitively; (c) keep and document. Verify: a
  two-record index with `Fixture`/`fixture` → `docs://fixture/index` lists one record.

---

## 3. Server runtime

- **SRV-1 — an oversized input line silently ends the server.** `takeDelimiter` fails
  when a line exceeds the 64 KiB reader buffer; `main` logs "stdin read failed" and
  exits 0 without a `-32700`. Options: (a) reply `-32700` and continue; (b) grow the
  buffer dynamically up to a cap; (c) exit non-zero. Verify: the 70 KiB recipe in §0.

- **SRV-2 — `buildResponse` assumes an object result.** `result.value.object` is
  taken unchecked; a handler returning a non-object panics. Options: (a) `switch`
  with a `-32603` fallback; (b) `std.debug.assert(result.value == .object)`; (c) type
  the handler return as an object. Verify: unit test with a string result.

- **SRV-3 — OOM during a request produces no response.** `handleLine` errors are
  logged and the request is dropped, leaving the client waiting. Options: (a) reply
  `-32603` when the failure is OOM; (b) reset the pool and retry once; (c) leave.
  Verify: fault-inject an allocator failure in a test.

- **SRV-4 — deep JSON nesting is unbounded.** `std.json` recursion on 100k nested
  arrays can exhaust the stack. Measured: not reachable through stdio today — 10 000
  nested arrays answer `-32602`, and 100 000 exceed the 64 KiB reader buffer and hit
  SRV-1 first, which bounds depth to roughly 32 000. Fixing SRV-1 with option (b)
  (grow the buffer to a cap) re-opens this, so bound depth in the same change; IDX-8
  is the same recursion hazard in the indexer's parser, where it *is* reachable.
  Options: (a) pre-scan depth and reject past a limit; (b) cap line length (SRV-1)
  which bounds depth; (c) leave. Verify: the nesting recipe in §0.

- **SRV-5 — index reclamation runs under the spin lock.** `reclaimLocked` frees an
  index while holding the store lock, so readers spin for the duration. Options:
  (a) move the free outside the lock into an owner thread; (b) accept it (index free
  is short); (c) use a mutex instead of spinning. Verify: bench under a reload loop.

- **SRV-6 — a negative `files_degraded` in the status sidecar panics the server.**
  `tools.zig` does `@intCast(files_degraded.integer)`, so `<index>.status.json`
  holding `{"projects":{"p":{"files_degraded":-1}}}` aborts the process with
  `panic: integer does not fit in destination type` (exit 3 in Debug **and**
  ReleaseSafe) on the first `doc_import_status` call. The sidecar is ordinary local
  data: a hand edit or a truncated indexer run is enough. Options: (a) validate the
  sidecar once at load and reject entries that fail; (b) use
  `std.math.cast(usize, …)` and drop the count when it returns null; (c) clamp to 0.
  Verify: the §0 sidecar recipe exits 0 and omits `files_degraded`.

- **SRV-7 — search cost scales with query tokens × records, so one request can hold
  the server for tens of seconds.** `docs/search.zig` walks every token of the query
  for every record, and a 60 KB line yields ~15 000 tokens. Measured on a 50 000-record
  index in ReleaseSafe: `"memory"` 0.24 s, `"xyz " * 15000` **19.70 s** for one
  request and one line (a Debug build takes 131 s). The server is single-threaded, so
  the stall is client-chosen.
  Options: (a) cap the query (e.g. 4 KiB, 32 tokens) and return `-32602`; (b) build
  the token inverted index that §9 lists as P11's precondition; (c) score only the
  first N tokens. Verify: the §0 amplification recipe answers in well under 1 s.

- **SRV-8 — a bad command line reports a bare Zig error name, exits 1, and prints no
  usage.** `zigmcp --bogus` prints `zigmcp: cannot parse arguments (UnknownArgument)`
  then `error: UnknownArgument` (a Debug build additionally dumps a full stack trace
  with absolute source paths) and exits 1, while `indexer --bogus` prints its usage
  line and exits 2. `--help` exists but is never offered on error. Options: (a) catch
  these errors in `main`, print the usage block to stderr and exit 2; (b) print one
  line without the Zig error name; (c) keep and document the exit codes.
  Verify: `zigmcp --bogus; echo $?` prints usage and exits 2.

---

## 4. Indexer

- **IDX-1 — one unreadable or oversized file aborts the whole run.** `readFileAlloc`
  is `try`-ed, so a 64 MiB+ file or an I/O error kills the run, contradicting
  degrade-don't-skip. Options: (a) skip the file and record it as degraded with a
  reason; (b) raise the per-file cap and stream; (c) fail only that project. Verify:
  add a 70 MiB `.zig` to a fixture tree.

- **IDX-2 — `--include` is a path prefix, not a glob.** `lib/std/**` matches nothing;
  only `lib/std` works. Options: (a) strip a trailing `/**` in the indexer; (b)
  implement glob matching; (c) document prefix semantics only. Verify: run with
  `--include 'lib/std/**'`.

- **IDX-3 — `--previous` trusts a single matching record.** A project is skipped when
  *any* previous record has the same `(project, commit)`, so a partial previous
  index is reused as if complete. Options: (a) compare record count and file count
  from the status sidecar; (b) key the skip on the commit plus a manifest hash;
  (c) drop incremental mode. Verify: truncate `--previous`, re-run, count records.

- **IDX-4 — duplicate symbols collide.** Overloads or a `fn` and a `var` with the same
  name produce several records; `doc_get` returns the first. Options: (a) return all
  matches; (b) add `kind` to the lookup; (c) append a disambiguator to `symbol`.
  Verify: `doc_get` on a duplicated name.

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

- **IDX-8 — deeply nested source overflows the stack inside `std.zig.Ast.parse` and
  kills the whole run.** A file of nested parens is enough: the Debug `indexer` dies
  at 2 000 (4 KB) and the **ReleaseSafe** binary survives 5 000 but dies at 10 000
  (20 KB); nested blocks, nested anonymous structs and nested container declarations
  all reproduce at 20 000. The death is `Stack overflow (no address available)` with
  exit status 3221225477 (0xC0000005), writing neither records nor a status sidecar,
  so one pathological upstream file aborts every project in that invocation — the same
  abort class as IDX-1, different cause, and the failure "degrade, never skip"
  forbids. Attribution: a probe that only calls `Ast.parse` on the same bytes crashes
  identically, so the walker is not the cause; `gdb -batch` shows a SIGSEGV whose
  frames repeat address-for-address (`#1` and `#11` are the same function), i.e.
  unbounded recursion.
  Options: (a) pre-scan each file for bracket depth (a byte counter over `{([`) and
  mark it degraded above a limit; (b) run the parse on a thread with an explicit
  `stack_size`; (c) parse one file per child process. Verify: the §0 nesting recipe
  exits 0 and records a degraded entry.

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

- **REL-4 — one bad line rejects the whole artifact.** By design, but the only signal
  is a stderr line; the previous index keeps serving with no client-visible marker.
  Options: (a) expose load status in `doc_import_status`; (b) add a
  `notifications/message` on failure; (c) accept. Verify: truncate the index and read
  `doc_import_status`.

- **REL-5 — the 256 MiB ceiling is hard-coded.** A larger corpus is rejected with only
  a stderr message. Options: (a) a `--max-index-bytes` flag; (b) stream the load;
  (c) keep and document. Verify: `--index` a sparse 257 MiB file.

- **REL-6 — remote indexes have no status sidecar,** so degraded-file data is
  invisible. Options: (a) fetch `<url>.status.json`; (b) embed status as an index
  header record; (c) accept. Verify: `doc_import_status` on a URL index.

- **REL-7 — the local-change heuristic is mtime + size.** A rewrite that preserves
  both is missed. Options: (a) compare the content hash after each mtime change;
  (b) also compare inode/creation time; (c) always re-read on any stat change.
  Verify: rewrite with equal size and restored mtime.

- **REL-8 — every index-loading failure is reported as `MalformedRecord`.**
  `index.zig`'s `loadFile` maps all I/O errors (`FileNotFound`, `AccessDenied`, a
  directory, `StreamTooLong` past the 256 MiB cap) onto `MalformedRecord`, so
  `--index missing.jsonl`, `--index .` and a 300 MiB artifact all log "cannot load …
  (MalformedRecord)". An operator cannot tell a missing file from a corrupt one, nor a
  size rejection from a syntax error. Options: (a) propagate the underlying error and
  print `@errorName`; (b) map the known I/O failures to distinct messages; (c) keep
  and document the collapse. Verify: `--index missing.jsonl` and `--index <257 MiB
  file>` produce different log lines.

- **REL-9 — `doc_hash` is neither verified nor shape-checked on load.** The indexer
  writes a lowercase-hex SHA-256 of `doc` and `doc_get` returns it, but nothing
  recomputes or validates it and any string is accepted, so a hand-edited or partially
  corrupted artifact serves changed documentation under a plausible-looking hash —
  defeating the provenance the field exists for. Options: (a) verify each record at
  load (one SHA-256 per record; measure against the 256 MiB ceiling); (b) verify
  lazily in `doc_get`/`doc_search` output; (c) at minimum require 64 hex characters
  and document the value as unverified. Verify: change one `doc` byte, keep the hash,
  and expect the load to fail (or the tool to flag it).

- **REL-10 — the canonical record order is not enforced on load.** §7 pins records to
  `(project, symbol)` then `(path, line)`, but `Columnar.finish` and `load` accept any
  order, so a reordered artifact silently changes `docs://{project}/index`, the order
  of equal scores in search, and which record `doc_get` returns for a duplicated
  symbol (IDX-4). Options: (a) verify the order in `load` and reject an unsorted
  artifact;
  (b) sort at load (one sort of the span table); (c) document that only the indexer's
  output is canonical. Verify: reverse the two lines of a two-record index and expect
  `load` to fail.

---

## 6. Guideline deviations

Rules being broken are in `AGENTS.md` §5, §11, §12 (code/corpus conventions) and D8
(table-driven capabilities).

- **GUIDE-1 — two tools lack the mandatory `//!` header.** `tools/indexer.zig` and
  `tools/advice_check.zig` start at `const std`. Options: (a) add headers; (b) relax
  the rule to `src/` only; (c) generate headers from a template. Verify: grep for
  files whose first line is not `//!` under `src/` and `tools/`.

- **GUIDE-2 — prompts and resources dispatch by `if`/`else` chains.** D8/P01 says a
  capability is a table row plus a handler, but `prompts.get` compares names and
  `resources.read` compares URIs, so adding one means editing the chain. Options:
  (a) put a handler pointer in `PromptSpec`/`ResourceSpec`; (b) a comptime switch by
  name; (c) accept and document. Verify: add a prompt without touching `get`.

- **GUIDE-3 — the ZON schema is declared three times.** `src/advice/corpus.zig`,
  `tools/advice_check.zig` and `tools/bench.zig` each define `Pattern`/`Rule`/…, so a
  schema change needs three edits. Options: (a) one shared `src/advice/schema.zig`
  imported by all three; (b) generate the tool copies at build time; (c) keep with a
  checklist (current). Verify: add a field and compile all targets.

- **GUIDE-4 — input sizes are not bounded.** §12 says bound every input, but
  `question`, `query` and `symbol` accept anything the 64 KiB line allows. Options:
  (a) cap at e.g. 4 KiB and return `-32602`; (b) cap and truncate with a flag; (c)
  rely on the line cap. Verify: a 60 KiB query.

- **GUIDE-5 — `registry.validate(null, …)` skips required checks.** A missing
  `arguments` member bypasses the schema, so every handler must re-check; only
  `doc_import_status` fails to (PROTO-2). Options: (a) treat missing arguments as
  `{}` and enforce required fields; (b) keep and require handler checks; (c) make
  handlers declare required args separately. Verify: `tools/call` with no arguments.

- **GUIDE-6 — the tokenizer silently truncates tokens at 128 characters.**
  `util/text.zig` guards each write with `if (length < buffer.len)`, so nothing is
  overwritten; it drops the remainder of any token longer than 128 characters
  without signalling (a 200-character identifier matches as its first 128).
  Options: (a) hash or reject long tokens; (b) grow the buffer; (c) keep with a
  comment. Verify: a token of 200 `a`s.

- **GUIDE-7 — `advice_check` is described as a layer but CI never runs it** (also
  CI-3). Options: (a) wire it into `test`; (b) its own CI step; (c) drop the claim
  from §9. Verify: see CI-3.

- **GUIDE-8 — limitation lists are duplicated across three files.** `AGENTS.md` §14,
  `readme.md` Known limitations and this file will drift. Options: (a) this file is
  canonical and the others link to it; (b) generate the readme section at build time;
  (c) keep a sync checklist. Verify: grep for a gap ID in all three.

---

## 7. Test coverage gaps

- **TEST-1 — no test for an oversized input line (SRV-1).** Options: (a) protocol
  test with a 70 KiB line expecting `-32700`; (b) a unit test on the transport; (c)
  accept.
- **TEST-2 — no test for duplicate symbols in `doc_get` (IDX-4).**
- **TEST-3 — no test for `doc_import_status` argument rejection (PROTO-2).**
- **TEST-4 — no test that every listed resource is readable (PROTO-1).** A loop over
  `resources/list` → `resources/read` would have caught it.
- **TEST-5 — workflows are not linted.** No `actionlint`/`yamllint`, which is why
  CI-1 shipped. Options: (a) add `actionlint` to CI; (b) a shell test asserting the
  `if:` shape; (c) accept.
- **TEST-6 — CLI edge cases are untested.** `--include` globs, `--previous` partial
  reuse, `--status` derivation. Options: (a) extend the indexer test layer; (b) a
  small `tests/indexer_cli_test.zig`; (c) accept.

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

- **ENV-1 — RESOLVED: the disk was full, not the toolchain.** `zigmcp.exe` was
  0 bytes and `install` failed with `FileNotFound` because `C:` had ~1 MB free on a
  223 GB volume (100 % used). The giveaway came from a test link:
  `LLVM ERROR: IO failure on output stream: No space left on device`. Small outputs
  (hello-world, `advice_check`) still fit; the ~15 MB server did not, and the `.pdb`
  was written before the write ran out, which is why the pair looked like an AV
  quarantine. After deleting `.zig-cache/`, `zig-out/` and `.probe/` (1.7 GB free),
  `zig build test`, `check`, `bench` and `test-regressions` all run.
  Options: (a) nothing in code — keep ≥2 GB free and check `df` first when a build
  "succeeds" with an empty output; (b) fail the build early with a free-space check
  and a clear message; (c) keep the symptom in the readme troubleshooting table
  (already there). Verify: `zig build test` exits 0 and `zig-out/bin/zigmcp.exe` is
  non-zero.

---

## 10. Test coverage map

`src/regressions_test.zig` (run as `zig build test-regressions`) asserts the
behaviour the plan wants, so each test fails today and goes green when its item is
fixed. It is kept out of `zig build test` on purpose: the main suite stays green
while the backlog is open. Six items are covered; the rest need a layer that does
not exist yet, and this table says which.

|Id|Regression test|If not: what must own it|
|---|---|---|
|CI-1|—|workflow lint (`actionlint`, TEST-5); the job `if:` is not unit-testable|
|CI-2|—|`gh release view` after a run; publishing is external|
|CI-3|—|run `advice_check` on a broken-fixture dir; owner: a CLI harness like `tests/indexer_test.zig`|
|CI-4|—|indexer CLI harness, once `--exclude` exists|
|CI-5|—|structural; testable only after the shared plan tool lands|
|CI-6|—|rerun the workflow; no local test|
|CI-7|—|timing only|
|CI-8|—|unpack a release and run it from an empty directory (CI smoke test)|
|PROTO-1|`PROTO-1: every listed resource can be read`|—|
|PROTO-2|`PROTO-2: doc_import_status rejects unknown arguments`|—|
|PROTO-3|—|`tests/protocol_test.zig`: `initialize` with `_meta`|
|PROTO-4|—|protocol layer: set `logLevel`, expect a notification or `-32602`|
|PROTO-5|—|handler test on non-empty `constraints`; write once the option is chosen|
|PROTO-6|`PROTO-6: advice_lookup rejects concept and question together`|—|
|PROTO-7|—|handler test: 6+ matching patterns, assert count/truncation|
|PROTO-8|—|`json_rpc` unit test on an array; expectation depends on the option|
|PROTO-9|`PROTO-9: an integral float is accepted…`|—|
|PROTO-10|—|resource test against a large index; assert a cap or cursor|
|SRV-1|—|protocol layer: 70 KiB line, expect `-32700` and a live server|
|SRV-2|—|extract `buildResponse` out of `main.zig` first; then a unit test|
|SRV-3|—|transport-level harness with an injected failing allocator|
|SRV-4|—|`json_rpc` unit test with deep nesting; expectation depends on the option|
|SRV-5|—|benchmark only, not deterministic|
|IDX-1|—|indexer CLI harness: unreadable or oversized fixture file|
|IDX-2|—|indexer CLI harness: `--include 'lib/std/**'`|
|IDX-3|—|indexer CLI harness: truncated `--previous`|
|IDX-4|—|indexer CLI + `doc_get` handler test on a duplicate symbol|
|IDX-5|—|indexer CLI harness: fixture with a 0xFF byte in a comment|
|IDX-6|—|`modulePath` is private; export it for a unit test|
|IDX-7|—|fixture with a nested declaration inside an error set|
|REL-1|—|local HTTP server counting requests|
|REL-2|—|black-hole address plus quit; timing-based|
|REL-3|—|unit test: `Source.fromString("file:///x")`|
|REL-4|—|`doc_import_status` after a failed load (needs `index_path`)|
|REL-5|—|integration: sparse 257 MiB index file|
|REL-6|—|integration: URL index with no sidecar|
|REL-7|—|reload integration test: equal size, restored mtime|
|GUIDE-1|—|lint: every `src/**` and `tools/**` file starts with `//!`|
|GUIDE-2|—|structural; test that a capability is added by a table row alone|
|GUIDE-3|—|structural; compile all three targets after one schema edit|
|GUIDE-4|—|handler test: 60 KiB query expects `-32602`|
|GUIDE-5|`GUIDE-5: a missing arguments object still enforces required fields`|—|
|GUIDE-6|`GUIDE-6: a long token is not silently truncated`|—|
|GUIDE-7|—|same as CI-3|
|GUIDE-8|—|doc lint: each gap id appears once across the tree|
|TEST-1|—|is the test SRV-1 needs|
|TEST-2|—|is the test IDX-4 needs|
|TEST-3|—|done: PROTO-2|
|TEST-4|—|done: PROTO-1|
|TEST-5|—|adds `actionlint`, which is what CI-1 needs|
|TEST-6|—|is the test IDX-2/IDX-3 need|
|DOC-1|—|packaging assertion on `build.zig.zon` `.paths`|
|DOC-2|—|doc lint comparing the two snippets|
|DOC-3|—|same as GUIDE-8|
|ENV-1|—|resolved; `zig build test` exiting 0 is the check|
|PROTO-11|—|`regressions_test.zig` `Harness` + a temp index and sidecar; assert the field is absent|
|PROTO-12|—|protocol layer: the no-match path returns `structuredContent` with `count: 0`|
|PROTO-13|—|handler test with a case-colliding two-project index|
|SRV-6|—|`regressions_test.zig` + a temp sidecar with `files_degraded: -1`; assert no panic|
|SRV-7|—|timing only (`zig build bench` and the §0 recipe); needs a large fixture index|
|SRV-8|—|protocol layer: spawn the binary with `--bogus`, assert usage text and exit 2|
|IDX-8|—|indexer CLI harness with a generated deep-nesting fixture; assert rc 0 + degraded entry|
|IDX-9|—|indexer CLI harness measuring the 5k/10k/25k ladder, or a unit test on the line table|
|REL-8|—|unit test: `loadFile` on a missing path and on a directory yields distinct errors|
|REL-9|—|unit test: `load` rejects a record whose `doc_hash` is not the SHA-256 of `doc`|
|REL-10|—|unit test: `load` rejects records that are not in `(project, symbol)` order|
|DOC-4|—|`inspect_pe_resources` on a `ReleaseSafe` artifact (packaging smoke test)|

Every item above that names a handler can use the `Harness` in
`src/regressions_test.zig` — it builds a real corpus and an empty index, so a new
test is a few lines.

## 11. Suggested order

1. CI-1, CI-2, CI-3 — the pipeline currently cannot publish or validate what it
   claims.
2. PROTO-2, PROTO-1, SRV-1 — client-visible wrongness with cheap fixes.
3. IDX-1, IDX-3, REL-4 — trust in the data plane.
4. GUIDE-3, GUIDE-2, GUIDE-1 — structural debt that makes every later change
   costlier.
5. TEST-1…TEST-6 — pin each of the above so it cannot regress.
6. Remaining limitations by demand: PROTO-10, REL-1, REL-5.
7. Crash paths found by the campaign: SRV-6 (a data file panics the server) and IDX-8
   (an upstream source kills the indexer) — both are cheap to bound and both are
   reachable without a malicious peer.
8. Measured hot spots: IDX-9 (quadratic indexer) and SRV-7 (client-chosen stall).
9. Contract gaps: PROTO-11, PROTO-12, PROTO-13, REL-8, REL-9, REL-10, DOC-4.

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

