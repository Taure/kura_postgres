-module(kura_pool_minato_tests).
-include_lib("eunit/include/eunit.hrl").

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
            {"start_pool is idempotent on a running pool", fun start_pool_idempotent/0}
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
    Opts = Config#{transport => inet, socket_options => [{send_timeout, 5000}]},
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
                prepared_statements
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

start_pool_idempotent() ->
    %% Already started in setup. Re-calling must return ok with the existing pid.
    ?assertMatch({ok, _Pid}, kura_pool_minato:start_pool(?POOL, ?CONFIG)).

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

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
