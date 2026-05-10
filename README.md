# kura_postgres

PostgreSQL backend for [kura](https://github.com/Taure/kura). Provides
`kura_pool_pgo`, `kura_driver_pgo`, and `kura_backend_postgres` on top
of the [pgo](https://hex.pm/packages/pgo) driver. The shared SQL emitter
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

`kura_app:start/2` resolves the aggregator and auto-populates `dialect`,
`pool_module`, and `driver_module`. Per-key overrides still win.

## Capabilities

`kura_pool_pgo:capabilities/0`:

```
[returning, jsonb, arrays, advisory_locks, listen_notify,
 select_for_update_skip_locked, partial_indexes, transactions,
 savepoints, prepared_statements]
```

## License

MIT.
