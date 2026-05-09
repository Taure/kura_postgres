# kura_postgres

PostgreSQL backend for [kura](https://github.com/Taure/kura).

Provides `kura_pool_pgo`, `kura_driver_pgo`, `kura_dialect_pg`, and
`kura_backend_postgres` so kura applications can target PostgreSQL via
the [pgo](https://hex.pm/packages/pgo) driver.

## Use

Add `kura` and `kura_postgres` to your `rebar.config`:

```erlang
{deps, [
    {kura, "~> 2.0"},
    {kura_postgres, "~> 0.1"}
]}.
```

Configure your repo to use the PostgreSQL backend:

```erlang
{my_app, [
    {repo, [
        {backend, kura_backend_postgres},
        {host, "localhost"},
        {database, "myapp"},
        {user, "postgres"},
        {pool_size, 10}
    ]}
]}.
```

## Status

The PostgreSQL surface kura has always supported (SELECT / INSERT /
UPDATE / DELETE / WHERE / ORDER / LIMIT / RETURNING / ON CONFLICT /
JOIN / CTE / UNION / advisory locks / LISTEN/NOTIFY) lives here.

Capability set declared by `kura_pool_pgo`:

```
[returning, jsonb, arrays, advisory_locks, listen_notify,
 select_for_update_skip_locked, partial_indexes, transactions,
 savepoints, prepared_statements]
```

Until kura 2.0 ships with the PG modules removed, these same modules
are also present in the kura repo. The package split is formalized at
the 2.0 cut.

## License

MIT.
