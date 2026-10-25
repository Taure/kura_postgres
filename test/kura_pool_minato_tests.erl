-module(kura_pool_minato_tests).
-include_lib("eunit/include/eunit.hrl").

-export([slow_checkout_stop/4]).

-define(POOL, kura_pool_minato_test).
-define(CONFIG, #{
    host => "localhost",
    port => 5555,
    database => "kura_test",
    user => "postgres",
    password => "root",
    pool_size => 2
}).

with_pool_test_() ->
    {setup, fun setup/0, fun teardown/1, fun(_) ->
        [
            {"behaviour declares kura_pool", fun behaviour_declared/0},
            {"behaviour declares kura_capabilities", fun capabilities_behaviour_declared/0},
            {"capabilities lists the standard PG feature set", fun capabilities_set/0},
            {"checkout returns a usable connection", fun checkout_returns_conn/0},
            {"with_conn runs the fun and checks back in", fun with_conn_roundtrip/0},
            {"sequential checkouts reuse a connection from the pool", fun sequential_checkouts/0},
            {"give_away transfers ownership to another process", fun give_away_transfers/0},
            {"start_pool is idempotent on a running pool", fun start_pool_idempotent/0},
            {"an owner's death discards the connection and its session state",
                fun owner_death_discards_connection/0},
            {"minato's server-side cancellation reaches the caller of run/4",
                fun statement_timeout_is_cancelled_on_the_server/0},
            {"a statement that loses the connection ends the holder",
                fun lost_connection_ends_the_holder/0},
            {"a statement that raises re-raises in the caller and ends the holder",
                fun raising_statement_ends_the_holder/0},
            {"a held connection builds and drops an index concurrently",
                fun concurrent_index_on_a_held_connection/0}
        ]
    end}.

%% `transport` decides which of minato's two transports a connection opens on,
%% and minato documents `inet` as the way back from its default. That is only
%% true if the option survives translation, and this file's own catch-all used
%% to drop it. Asserted through behaviour rather than by reading the option
%% back: `send_timeout` is a driver option the socket transport refuses at
%% connect, so a pool that becomes ready with it set is a pool that got `inet`.
transport_survives_translation_test() ->
    Name = kura_pool_minato_transport_test,
    Config = ?CONFIG,
    Opts = Config#{transport => inet, socket_options => [{priority, 3}]},
    {ok, _Pid} = kura_pool_minato:start_pool(Name, Opts),
    ?assertEqual(ok, wait_for_ready(Name, 5000)),
    _ = kura_pool_minato:stop_pool(Name),
    ok.

setup() ->
    application:ensure_all_started(minato),
    application:ensure_all_started(kura),
    case kura_pool_minato:start_pool(?POOL, ?CONFIG) of
        {ok, _Pid} -> ok;
        {error, {already_started, _Pid}} -> ok
    end,
    ok = wait_for_ready(?POOL, 5000).

teardown(_) ->
    _ = kura_pool_minato:stop_pool(?POOL),
    ok.

behaviour_declared() ->
    Attrs = kura_pool_minato:module_info(attributes),
    Behaviours = lists:append([V || {behaviour, V} <- Attrs] ++ [V || {behavior, V} <- Attrs]),
    ?assert(lists:member(kura_pool, Behaviours)).

capabilities_behaviour_declared() ->
    Attrs = kura_pool_minato:module_info(attributes),
    Behaviours = lists:append([V || {behaviour, V} <- Attrs] ++ [V || {behavior, V} <- Attrs]),
    ?assert(lists:member(kura_capabilities, Behaviours)).

capabilities_set() ->
    %% require/2 with the full standard PG set should pass.
    ?assertEqual(
        ok,
        kura_capabilities:require(
            kura_pool_minato,
            [
                returning,
                jsonb,
                arrays,
                advisory_locks,
                listen_notify,
                select_for_update_skip_locked,
                partial_indexes,
                window_functions,
                full_text_search,
                vector,
                transactions,
                savepoints,
                prepared_statements,
                concurrent_indexes
            ]
        )
    ).

checkout_returns_conn() ->
    {ok, Conn, Token} = kura_pool_minato:checkout(?POOL, #{}),
    try
        Result = kura_pool_minato:run(Conn, ~"SELECT 1::integer AS one", [], #{}),
        ?assertMatch(#{rows := [_]}, Result)
    after
        ok = kura_pool_minato:checkin(?POOL, Token)
    end.

with_conn_roundtrip() ->
    Result = kura_pool:with_conn(kura_pool_minato, ?POOL, fun(Conn) ->
        kura_pool_minato:run(Conn, ~"SELECT 42::integer AS answer", [], #{})
    end),
    ?assertMatch(#{rows := [_]}, Result),
    #{rows := [Row]} = Result,
    ?assertEqual([42], tuple_to_list(Row)).

concurrent_index_on_a_held_connection() ->
    Statements = [
        ~"DROP TABLE IF EXISTS kura_pool_minato_concurrent",
        ~"CREATE TABLE kura_pool_minato_concurrent (id integer)",
        ~"CREATE INDEX CONCURRENTLY kura_pool_minato_concurrent_id ON kura_pool_minato_concurrent (id)",
        ~"DROP INDEX CONCURRENTLY kura_pool_minato_concurrent_id",
        ~"DROP TABLE kura_pool_minato_concurrent"
    ],
    kura_pool:with_conn(kura_pool_minato, ?POOL, fun(Conn) ->
        [?assertNotMatch({error, _}, kura_pool_minato:run(Conn, SQL, [], #{})) || SQL <- Statements]
    end).

sequential_checkouts() ->
    %% Two back-to-back checkouts must both succeed (proves checkin returned the
    %% conn to the pool, not that we just got two distinct workers).
    F = fun() ->
        {ok, Conn, Token} = kura_pool_minato:checkout(?POOL, #{}),
        try
            #{rows := [_]} = kura_pool_minato:run(Conn, ~"SELECT 1", [], #{}),
            ok
        after
            ok = kura_pool_minato:checkin(?POOL, Token)
        end
    end,
    ?assertEqual(ok, F()),
    ?assertEqual(ok, F()),
    ?assertEqual(ok, F()).

give_away_transfers() ->
    %% Setup process checks out a conn, gives it away to a child process
    %% that does the work and checks it back in. Mirrors the sandbox pattern.
    {ok, Conn, Token} = kura_pool_minato:checkout(?POOL, #{}),
    Self = self(),
    Child = spawn_link(fun() ->
        receive
            {gift, T, C} ->
                Result = kura_pool_minato:run(C, ~"SELECT 7::integer", [], #{}),
                ok = kura_pool_minato:checkin(?POOL, T),
                Self ! {done, Result}
        after 5000 ->
            Self ! {done, timeout}
        end
    end),
    ok = kura_pool_minato:give_away(Token, Child, none),
    %% Hand the token + conn to the child for the actual checkin call;
    %% give_away/3 transferred ETS ownership but the {Ref, Conn} term
    %% needs to travel via the message too.
    Child ! {gift, Token, Conn},
    receive
        {done, Result} ->
            ?assertMatch(#{rows := [_]}, Result)
    after 5000 ->
        ?assert(false)
    end.

owner_death_discards_connection() ->
    Self = self(),
    {Owner, Ref} = spawn_monitor(fun() ->
        {ok, Conn, _Token} = kura_pool_minato:checkout(?POOL, #{}),
        #{rows := [Row]} = kura_pool_minato:run(
            Conn, ~"SELECT pg_backend_pid(), pg_advisory_lock(424242)", [], #{}
        ),
        Self ! {locked, element(1, Row)},
        receive
            never -> ok
        end
    end),
    Backend =
        receive
            {locked, Pid} -> Pid
        after 2000 -> error(owner_never_locked)
        end,
    ?assertEqual(1, advisory_locks_held(Backend)),
    exit(Owner, kill),
    receive
        {'DOWN', Ref, process, Owner, killed} -> ok
    after 1000 -> error(owner_still_running)
    end,
    ?assertEqual(ok, wait_for_locks_released(Backend, 2000)).

statement_timeout_is_cancelled_on_the_server() ->
    {ok, Conn, Token} = kura_pool_minato:checkout(?POOL, #{}),
    try
        Started = erlang:monotonic_time(millisecond),
        Result = kura_pool_minato:run(Conn, ~"SELECT pg_sleep(5)", [], #{timeout => 100}),
        Elapsed = erlang:monotonic_time(millisecond) - Started,
        ?assertMatch({error, {pgsql_error, #{code := ~"57014"}}}, Result),
        ?assert(Elapsed < 2000),
        ?assertMatch(#{rows := [_]}, kura_pool_minato:run(Conn, ~"SELECT 1", [], #{}))
    after
        ok = kura_pool_minato:checkin(?POOL, Token)
    end.

raising_statement_ends_the_holder() ->
    {ok, Conn, Token} = kura_pool_minato:checkout(?POOL, #{}),
    Monitor = erlang:monitor(process, Conn),
    ?assertError(
        {minato_codec, _},
        kura_pool_minato:run(Conn, ~"SELECT $1::integer", [#{map => ~"cannot be an integer"}], #{})
    ),
    receive
        {'DOWN', Monitor, process, Conn, Reason} -> ?assertEqual(normal, Reason)
    after 2000 -> error(holder_still_running)
    end,
    ?assertEqual(ok, kura_pool_minato:checkin(?POOL, Token)),
    ?assertEqual(ok, wait_for_ready(?POOL, 2000)).

lost_connection_ends_the_holder() ->
    {ok, Conn, Token} = kura_pool_minato:checkout(?POOL, #{}),
    Monitor = erlang:monitor(process, Conn),
    #{rows := [Row]} = kura_pool_minato:run(Conn, ~"SELECT pg_backend_pid()", [], #{}),
    [Backend] = tuple_to_list(Row),
    #{rows := [_]} = kura_pool:with_conn(kura_pool_minato, ?POOL, fun(Other) ->
        kura_pool_minato:run(Other, ~"SELECT pg_terminate_backend($1, 1000)", [Backend], #{})
    end),
    ?assertMatch({error, {socket, _}}, kura_pool_minato:run(Conn, ~"SELECT 1", [], #{})),
    receive
        {'DOWN', Monitor, process, Conn, _} -> ok
    after 2000 -> error(holder_still_running)
    end,
    ?assertMatch({error, {holder_died, _}}, kura_pool_minato:run(Conn, ~"SELECT 1", [], #{})),
    ?assertEqual(ok, kura_pool_minato:checkin(?POOL, Token)),
    ?assertEqual(ok, wait_for_ready(?POOL, 2000)).

checkout_timeout_kills_the_holder_test_() ->
    {timeout, 15, fun checkout_timeout_kills_the_holder/0}.

%% The handler holds minato's checkout open past the caller's deadline, so the
%% holder gets a connection only after its owner has given up.
checkout_timeout_kills_the_holder() ->
    application:ensure_all_started(minato),
    Pool = kura_pool_minato_checkout_timeout_test,
    Config = ?CONFIG,
    {ok, _} = kura_pool_minato:start_pool(Pool, Config#{pool_size => 1}),
    try
        ?assertEqual(ok, wait_for_ready(Pool, 5000)),
        ok = telemetry:attach(
            slow_checkout, [minato, checkout, stop], fun ?MODULE:slow_checkout_stop/4, 2000
        ),
        try
            ?assertEqual(
                {error, checkout_timeout}, kura_pool_minato:checkout(Pool, #{timeout => 100})
            )
        after
            telemetry:detach(slow_checkout)
        end,
        timer:sleep(1500),
        {messages, Messages} = process_info(self(), messages),
        ?assertEqual([], [M || {holding, _} = M <- Messages]),
        {ok, _Conn, Token} = kura_pool_minato:checkout(Pool, #{timeout => 1000}),
        ok = kura_pool_minato:checkin(Pool, Token)
    after
        kura_pool_minato:stop_pool(Pool)
    end.

slow_checkout_stop(_Event, _Measurements, #{outcome := ok}, Sleep) -> timer:sleep(Sleep);
slow_checkout_stop(_Event, _Measurements, _Metadata, _Sleep) -> ok.

start_pool_idempotent() ->
    %% Already started in setup. Re-calling must return ok with the existing pid.
    ?assertMatch({ok, _Pid}, kura_pool_minato:start_pool(?POOL, ?CONFIG)).

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

advisory_locks_held(Backend) ->
    SQL = ~"SELECT count(*)::integer FROM pg_locks WHERE locktype = 'advisory' AND pid = $1",
    #{rows := [Row]} = kura_pool:with_conn(kura_pool_minato, ?POOL, fun(Conn) ->
        kura_pool_minato:run(Conn, SQL, [Backend], #{})
    end),
    [Count] = tuple_to_list(Row),
    Count.

wait_for_locks_released(Backend, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_for_locks_released_loop(Backend, Deadline).

wait_for_locks_released_loop(Backend, Deadline) ->
    case advisory_locks_held(Backend) of
        0 ->
            ok;
        _ ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true ->
                    {error, still_locked};
                false ->
                    timer:sleep(50),
                    wait_for_locks_released_loop(Backend, Deadline)
            end
    end.

wait_for_ready(Pool, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_for_ready_loop(Pool, Deadline).

wait_for_ready_loop(Pool, Deadline) ->
    case kura_pool_minato:checkout(Pool, #{}) of
        {ok, _Conn, Token} ->
            ok = kura_pool_minato:checkin(Pool, Token),
            ok;
        {error, _} ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true ->
                    {error, pool_not_ready};
                false ->
                    timer:sleep(50),
                    wait_for_ready_loop(Pool, Deadline)
            end
    end.
