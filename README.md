# kura_postgres

PostgreSQL backend for [kura](https://github.com/Taure/kura). Provides
`kura_pool_minato`, `kura_driver_minato`, and `kura_backend_postgres` on top
of the [minato](https://hex.pm/packages/minato) client. The shared SQL emitter
(`kura_dialect_pg`) lives in kura core.

## Use

```erlang
{deps, [
    {kura, "~> 2.28"},
    {kura_postgres, "~> 1.1"}
]}.
```

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

`ssl => true` and `ssl_options` in a repo's configuration apply to its pool and
to the connection that creates a missing database.

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
`kura_stream` for `cursors`. kura releases after 2.30 read it; an older kura
does not call it.

Each is run against PostgreSQL 16 in `kura_postgres_capabilities_tests`. The
list is the same for every database: `vector` is declared whether or not the
[pgvector](https://github.com/pgvector/pgvector) extension is installed, and a
distance query fails on the server without it.

## License

MIT.
