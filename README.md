# kura_postgres

PostgreSQL backend for [kura](https://github.com/Taure/kura). Provides
`kura_pool_minato`, `kura_driver_minato`, and `kura_backend_postgres` on top
of the [minato](https://hex.pm/packages/minato) client. The shared SQL emitter
(`kura_dialect_pg`) lives in kura core.

## Use

```erlang
{deps, [
    {kura, "~> 2.31"},
    {kura_postgres, "~> 1.2"}
]}.
```

kura_postgres needs kura 2.31.1 or a later 2.x and minato 1.2 or a later 1.x.
See [Upgrading](#upgrading) for what those two change for a repo.

Point kura at the backend in `sys.config`:

```erlang
[{kura, [
    {repo, my_repo},
    {backend, kura_backend_postgres},
    {host, "localhost"},
    {port, 5432},
    {database, "my_app"},
    {user, "postgres"},
    {password, "postgres"},
    {pool_size, 10}
]}].
```

On application start, Kura resolves the aggregator and auto-populates `dialect`,
`pool_module`, and `driver_module`. Per-key overrides still win.

## Connection settings

These keys of a repo's configuration are handed to minato, for the repo's
pool and for the connection that creates a missing database. Each means what
minato's
[configuration guide](https://hexdocs.pm/minato/configuration.html) says:

| key | |
| --- | --- |
| `host` (or `hostname`) | a string, a binary or an atom, an address, or `{local, Path}` |
| `port` | |
| `database` | |
| `user` (or `username`) | required for a pool |
| `password` | text, or a fun of no arguments that returns it |
| `pool_size` | minato's `size`, 10 unless set |
| `ssl`, `ssl_options` | `ssl_options` are refused without `ssl => true` |
| `channel_binding` | `prefer`, `require` or `disable` |
| `auth` | the methods a server may ask for, such as `[scram_sha_256]` |
| `prepared_statements` | how many statements a connection keeps parsed; `0` behind a pooler that does not follow named statements |
| `timeout` | the deadline of a statement that names none, 15 seconds unless set |
| `connect_timeout`, `cancel_timeout` | |
| `socket_options`, `transport` | |

For a server on a network anybody else is on, minato's
[security guide](https://github.com/Taure/minato/blob/main/guides/security.md) recommends all
three of:

```erlang
{ssl, true},
{auth, [scram_sha_256]},
{channel_binding, require}
```

A setting minato checks and does not take is refused before anything is
started or connected to. `kura_repo_worker:start/1` and `kura_db:start_pool/1` return
`{error, {invalid_option, Key}}` and kura logs that the pool did not start.
`Key` is the setting, without its value: `ssl_options` given without
`ssl => true`, a `channel_binding` that is not one of the three words, an
`auth` that is not a list of methods, a `timeout` that is `"5000"` and not
`5000`, a `pool_size` that is not a positive integer, a
`prepared_statements` that is not a whole number from 0 up. `port`,
`transport` and `socket_options` are not checked before the pool starts.

Only the keys in the table are read. A repo's configuration holds kura's own
settings too, so a key this backend does not know is passed over, not
refused: a misspelt `channel_binding` leaves the default in force.

## Transactions

`kura_driver_minato:transaction/4` runs a nested call under a `SAVEPOINT`. A
`COMMIT`, `END`, `ROLLBACK`, or any of them `AND CHAIN`, run as a query inside a
transaction that `transaction/4` opened, outermost or nested, raises
`error({kura_driver_minato, transaction_ended_by_statement})`. The driver reads
the transaction status and command tag the server reports after every
statement, so whatever the statement committed stays committed and nothing after
it runs outside the transaction. The transaction of a sandboxed test
(`kura_sandbox`) is checked the same way. See the `kura_driver_minato` module
docs for every error `transaction/4` can raise.

## Decimals

A `decimal` field read through a schema is a float, so it holds 15 to 17
significant digits. The exact text of a `numeric` is returned to a statement
run with `numeric_format => binary` in its driver options, as
`kura_db:query_on/5` takes them. See `kura_driver_minato`.

## Capabilities

`kura_pool_minato:capabilities/0`:

```
[returning, jsonb, arrays, advisory_locks, listen_notify,
 select_for_update_skip_locked, row_locks, distinct_on, cursors,
 partial_indexes, window_functions, full_text_search, vector,
 transactions, savepoints, prepared_statements, concurrent_indexes]
```

That is every standard capability of `kura_capabilities`.
`kura_pool_minato:capability_model/0` names the revision of kura's checks the
list is written against: model 1, which checks a query for full-text search,
a window function, a vector distance, a lock and `DISTINCT ON`, and
`kura_stream` for `cursors`. kura reads it from 2.31 on.

Each is run against PostgreSQL 16 in `kura_postgres_capabilities_tests`. The
list is the same for every database: `vector` is declared whether or not the
[pgvector](https://github.com/pgvector/pgvector) extension is installed, and a
distance query fails on the server without it.

## Upgrading

### From 1.1

1.1 ran on minato 1.1 and any kura from 2.28. This release needs minato 1.2
and kura 2.31.1 or a later 2.x. kura's
[upgrading guide](https://hexdocs.pm/kura/upgrading.html) says what 2.31
changes for an application, and minato's
[changelog](https://hexdocs.pm/minato/changelog.html) what 1.2 does. What
reaches a repo through this backend:

- `ssl_options` without `ssl => true` keep the pool from starting, with
  `{error, {invalid_option, ssl_options}}`. Before, they were passed over and
  the connection was opened without TLS. Add `ssl => true`, or take them out.
- `channel_binding`, `auth`, `prepared_statements` and `cancel_timeout` in a
  repo's configuration take effect. They were left out of what minato was
  given, so a repo that set one ran on minato's default.
- The connection that creates a missing database is opened with the same
  settings as the pool's, `channel_binding` and `auth` included, and a
  configuration the pool refuses is refused there too. It no longer reads
  `ssl` and `ssl_options` from the `kura` application environment: set them
  on the repo, or the database is created over a connection without TLS.
- When a configuration has both `host` and `hostname`, or both `user` and
  `username`, `host` and `user` are read. The pool used to read `hostname`
  and `username`.
- A statement's deadline covers its whole answer. A result that takes longer
  than the repo's `timeout`, 15 seconds unless set, to arrive is cancelled
  with SQLSTATE `57014`, where it used to be read to the end. Raise the
  repo's `timeout`, or read the result in parts with `kura_stream` or pages.
- A write is bounded by the repo's `timeout` as well. A single value of
  hundreds of megabytes over a slow link needs `{send_timeout, Milliseconds}`
  in `socket_options`.
- A row of a raw statement is keyed by an atom only for a column whose name
  is an atom on the node already, and by a binary for any other. Code that
  matches `#{id := Id}` is unaffected. The `command` of a result is a binary
  for a word that is not one of PostgreSQL's command tags.
- In `ssl_options`, `{server_name_indication, disable}` no longer turns the
  hostname check off; `{verify, verify_none}` does. Options that resume a TLS
  session (`reuse_sessions`, `reuse_session`, `session_tickets`,
  `use_ticket`) are refused.
- A pool whose `host` is another machine and whose configuration does not
  mention `ssl` logs one `unencrypted_connection` warning. `{ssl, false}`
  says it was meant.
- `minato_sup` and `minato_overdue` cannot name a pool:
  `{error, {reserved_name, Name}}`.

## License

MIT.
