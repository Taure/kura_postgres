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

- `pool_module` -> `kura_pool_minato`
- `driver_module` -> `kura_driver_minato`
- `dialect` -> `kura_dialect_pg`
- `capabilities` -> declared on `kura_pool_minato`

A repo that wants something else says so with `pool_module` and `driver_module`
of its own; nothing here stops it.
""".

-export([
    pool_module/0,
    driver_module/0,
    dialect/0,
    capabilities/0
]).

-spec pool_module() -> module().
pool_module() -> kura_pool_minato.

-spec driver_module() -> module().
driver_module() -> kura_driver_minato.

-spec dialect() -> module().
dialect() -> kura_dialect_pg.

-doc "Forwards to `kura_pool_minato:capabilities/0`.".
-spec capabilities() -> kura_capabilities:capability_set().
capabilities() -> kura_pool_minato:capabilities().
