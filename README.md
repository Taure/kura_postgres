# kura_postgres

PostgreSQL backend for [kura](https://github.com/Taure/kura). Provides
`kura_pool_minato`, `kura_driver_minato`, and `kura_backend_postgres` on top
of the [minato](https://hex.pm/packages/minato) client. The shared SQL emitter
(`kura_dialect_pg`) lives in kura core.

## Use

```erlang
{deps, [
    {kura, "~> 2.4"},
    {kura_postgres, "~> 0.4"}
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

## Transactions

`kura_driver_minato:transaction/4` runs a nested call under a `SAVEPOINT`. A
`COMMIT`, `END` or `ROLLBACK` run as a query inside a transaction, at any
depth, raises `error({kura_driver_minato, transaction_ended_by_statement})`.
The driver reads the transaction status the server reports after every
statement, so whatever the statement committed stays committed and nothing
after it runs in autocommit. See the `kura_driver_minato` module docs for every
error `transaction/4` can raise.

## Capabilities

`kura_pool_minato:capabilities/0`:

```
[returning, jsonb, arrays, advisory_locks, listen_notify,
 select_for_update_skip_locked, partial_indexes, window_functions,
 full_text_search, vector, transactions, savepoints,
 prepared_statements, concurrent_indexes]
```

## License

MIT.
