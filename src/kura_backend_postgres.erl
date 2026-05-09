-module(kura_backend_postgres).
-moduledoc """
PostgreSQL backend aggregator. One config knob for users:

```erlang
{repo, [
    {backend, kura_backend_postgres},
    {host, "localhost"},
    {database, "myapp"},
    {pool_size, 10}
]}.
```

The aggregator wires up:

- `pool_module` -> `kura_pool_pgo`
- `driver_module` -> `kura_driver_pgo`
- `dialect` -> `kura_dialect_pg`
- `capabilities` -> declared on `kura_pool_pgo`
""".

-export([
    pool_module/0,
    driver_module/0,
    dialect/0,
    capabilities/0
]).

-spec pool_module() -> module().
pool_module() -> kura_pool_pgo.

-spec driver_module() -> module().
driver_module() -> kura_driver_pgo.

-spec dialect() -> module().
dialect() -> kura_dialect_pg.

-doc "Forwards to `kura_pool_pgo:capabilities/0`.".
-spec capabilities() -> kura_capabilities:capability_set().
capabilities() -> kura_pool_pgo:capabilities().
