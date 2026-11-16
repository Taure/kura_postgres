-module(kura_postgres_test_repo).
-moduledoc """
A repo on the test database, configured under this application through the
backend aggregator, for the tests that go through kura's own API.
""".
-behaviour(kura_repo).

-export([otp_app/0, start/0, stop/0]).

otp_app() -> kura_postgres.

start() ->
    {ok, _} = application:ensure_all_started(minato),
    {ok, _} = application:ensure_all_started(kura),
    ok = application:set_env(kura_postgres, ?MODULE, #{
        pool => ?MODULE,
        pool_module => kura_backend_postgres:pool_module(),
        driver_module => kura_backend_postgres:driver_module(),
        dialect => kura_backend_postgres:dialect(),
        host => "localhost",
        port => 5555,
        database => "kura_test",
        user => "postgres",
        password => "root",
        pool_size => 3
    }),
    ok = kura_repo_worker:start(?MODULE).

stop() ->
    kura_db:stop_pool(?MODULE).
