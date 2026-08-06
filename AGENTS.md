# AGENTS.md

Working agreement for agents and contributors on **kura_postgres** - the
PostgreSQL backend adapter for the [kura](https://github.com/Taure/kura) data
layer. A thin OTP library: it implements kura's driver/pool/backend behaviours
on top of the [minato](https://hex.pm/packages/minato) client and nothing more.

## What this is

kura v2 is multi-backend: **kura** (core, backend-agnostic) + **kura_postgres**
(this repo) + **kura_sqlite** (+ future kura_mysql). This repo ships three
modules and their behaviour implementations:

- `kura_backend_postgres` - the aggregator. One config knob
  (`{backend, kura_backend_postgres}`) resolves `pool_module => kura_pool_minato`,
  `driver_module => kura_driver_minato`, `dialect => kura_dialect_pg`.
- `kura_pool_minato` - the `kura_pool` + `kura_capabilities` implementation.
  A checkout spawns a holder process that owns the connection, because a minato
  connection belongs to the process that borrowed it; `give_away/3` moves the
  watch rather than the socket, for sandbox test fixtures.
- `kura_driver_minato` - the `kura_driver` implementation. Wraps minato `query`/
  `transaction`, plus optional `ensure_database/1` and `probe_pool/1` callbacks.

The SQL emitter (`kura_dialect_pg`) lives in **kura core**, NOT here (it was
duplicated in 2.0-2.2 and moved back to core in 2.3 so SQLite-only installs
stop hitting `undef`). This repo only carries `kura_dialect_pg_tests` to
exercise that shared emitter against real Postgres.

## Scope - what belongs here

- **In:** the minato-backed pool, driver, and backend aggregator; the
  transaction/checkout conventions; `ensure_database`/`probe_pool`; the
  capability set; type/UUID round-trip config that is client-specific.
- **Out:** the query AST, compiler, changeset, migrator, repo, types, and the
  `kura_dialect_pg` emitter - all core. Any generic data-layer primitive
  belongs upstream in kura, not in one backend adapter.
- **Out forever:** anything that warps this into more than a driver shim, or
  any feature driven by a single consumer (asobi, shigoto, Trana, an app). If
  a change is not specific to this client, it belongs in kura core.

The driver-agnostic backend boundary is load-bearing. Any change to a behaviour
callback, the pool/driver API, the capability set, or the minato dep goes past the
**`kura-architecture-guardian`** (it covers the whole kura ecosystem). Its first
question on a driver swap is "show me the bench" - minato was measured against
pgo, epgsql and two JavaScript clients before it replaced them here; do not
propose a swap without a comparable benchmark.

## Commands

```bash
docker compose up -d        # Postgres 16 on host port 5555 (db kura_test)
rebar3 compile
rebar3 eunit                # driver + pool + dialect tests need the DB up
rebar3 fmt                  # erlfmt (write); CI runs fmt --check
rebar3 lint                 # rebar3_lint (elvis)
rebar3 hank                 # dead-code check
rebar3 xref
rebar3 dialyzer
rebar3 ex_doc               # fix every new warning
```

## Pre-push checklist

Run before every push, all green:

`rebar3 fmt` -> `rebar3 xref` -> `rebar3 dialyzer` -> `rebar3 lint` ->
`rebar3 hank` -> `rebar3 eunit` -> `rebar3 ct` -> `rebar3 ex_doc` ->
`rebar3 fmt --check`. Bring the Docker Postgres up first or the driver/pool
suites cannot run.

CI (Taure/erlang-ci) additionally runs coverage + sbom; eqwalize/mutate are
disabled here.

## Conventions

- OTP 28 (`.tool-versions`: erlang 28.4.1, rebar 3.26.0). The `~"..."` sigil for
  binaries, never `<<"...">>`.
- No `lists:foldl/foldr` - list comprehensions + `maps:from_list`, or explicit
  named recursion.
- Logging: `?LOG_*` macros with `#{...}` map reports, never `logger:info/error`
  format strings.
- JSON (if ever needed): OTP `json` module, never thoas/jiffy.
- Docs: OTP `-moduledoc` / `-doc` (already the house style in `src/`).
- `{vsn, "git"}` in `.app.src` - version derives from git tags, never
  hand-edited. Never publish to Hex (the user does that manually).

## Architecture

```
kura core (backend-agnostic)
  kura_pool / kura_driver / kura_dialect / kura_capabilities behaviours
  kura_dialect_pg (shared SQL emitter)  <-- lives in CORE, not here
        |
        | this repo implements:
        v
  kura_backend_postgres   aggregator -> pool/driver/dialect
  kura_pool_minato        kura_pool + kura_capabilities  -> minato_pool (holder proc)
  kura_driver_minato      kura_driver                    -> minato_query/minato_txn
```

Hot path: a caller leases a conn via `kura_pool:with_conn/3` and drives
`minato_query` itself (caller-driven socket I/O, no pool gen_server hop). Inside
a transaction, `kura_driver_minato:query/5` finds the transaction's holder in the
process dictionary and routes to it instead.

### Pool boot order (the #1 gotcha)

kura starts its pool **at kura-app boot** from config, before the consuming
app starts. An app that does `application:set_env(kura, host, ...)` in its own
`start/2` sets it too late - the pool already dialed the boot-time host and does
not move. Symptom: the pool loops on `econnrefused`/`nxdomain` and
`kura_migrator:migrate` returns `{error, none_available}`, so migrations fail
silently. Fix: the real DB host must be in kura's config at boot (use
`RELX_REPLACE_OS_VARS` on `sys.config.src` in prod; keep `{port, 5432}` static).

## Gotchas

- **Backend key required.** The legacy flat single-repo config must set
  `{backend, kura_backend_postgres}`, else kura never sets `pool_module` and
  startup crashes with `{no_pool_module_configured, Repo}`. Prefer the v2
  `{repos, #{Name => #{backend => kura_backend_postgres, ...}}}` map form. CI
  only boots dev config, so prod-config drift ships silently - verify BOTH.
- **Config keys are `host`/`user`, not `hostname`/`username`.** The repo map is
  passed verbatim to the client, which ignores unknown keys and silently
  defaults `host` to localhost. Symptom: pool stuck `none_available`, migration
  bails before any DDL. Grep any kura app for `hostname =>`/`username =>`.
- **`string` = VARCHAR(255), `text` = unbounded.** Picking `string` for
  arbitrary-length data crashes inserts with `value too long for type character
  varying(255)`. Use `text` for anything unbounded.
- **UUID format.** minato decodes a `uuid` to its string form by default, so
  nothing needs configuring. A repo that wants the raw 16 bytes passes
  `uuid_format => binary` in its query options.

## Tests

`test/` runs against a real Postgres (host port **5555**, db `kura_test`, user
`postgres`, password `root`; see `docker-compose.yml`). Suites:
`kura_driver_minato_tests`, `kura_pool_minato_tests` (pool + capability set), and
`kura_dialect_pg_tests` (the shared core emitter). `kura_test_schema` /
`kura_test_post_schema` are fixtures. CI brings up `docker-compose.ci.yml`
(tmpfs Postgres) via `extra-services-compose`.

## CI

CI calls `Taure/erlang-ci` (pinned exact version). Enabled: ct, ex_doc, hank,
coverage, sbom, sbom-scan, dependency-submission, elp-lint, summary. Currently
off: eqwalize, mutate, audit, sheldon. Do not float the erlang-ci pin.

## Git and PRs

- Conventional commits (`feat:`, `fix:`, `chore:`, `docs:`, `test:`,
  `refactor:`). No `Co-Authored-By` trailer, no "Generated with" footer.
- Always branch and open a PR - never push to `main`. Pull `main` and read the
  current state before branching. Every merge to `main` tags a release, so keep
  each PR coherent.
- Bump downstream pins (asobi, shigoto, Trana, bunko, ...) after a change lands
  here; downstreams pin kura_postgres by tag/sha.
