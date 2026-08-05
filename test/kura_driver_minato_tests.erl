-module(kura_driver_minato_tests).
-include_lib("eunit/include/eunit.hrl").

-define(POOL, kura_driver_minato_test_pool).
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
            {"declares kura_driver behaviour", fun declares_behaviour/0},
            {"query/5 leases a conn and runs SQL", fun query_leases_and_runs/0},
            {"query_on/4 runs SQL on an explicit conn", fun query_on_explicit_conn/0},
            {"transaction/3 wraps fun and routes inner queries to tx conn",
                fun transaction_routes_inner_queries/0},
            {"transaction/3 rolls back on error", fun transaction_rollback/0}
        ]
    end}.

setup() ->
    _ = application:ensure_all_started(minato),
    case kura_pool_minato:start_pool(?POOL, ?CONFIG) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end,
    ok = wait_for_ready(?POOL, 5000).

teardown(_) ->
    _ = kura_pool_minato:stop_pool(?POOL),
    ok.

declares_behaviour() ->
    Attrs = kura_driver_minato:module_info(attributes),
    Behaviours = lists:append([V || {behaviour, V} <- Attrs] ++ [V || {behavior, V} <- Attrs]),
    ?assert(lists:member(kura_driver, Behaviours)).

query_leases_and_runs() ->
    Result = kura_driver_minato:query(kura_pool_minato, ?POOL, ~"SELECT 1::integer AS n", [], #{}),
    ?assertMatch(#{rows := [_], num_rows := 1}, Result).

query_on_explicit_conn() ->
    {ok, Conn, Token} = kura_pool_minato:checkout(?POOL, #{}),
    try
        Result = kura_driver_minato:query_on(Conn, ~"SELECT 2::integer AS n", [], #{}),
        ?assertMatch(#{rows := [_]}, Result)
    after
        ok = kura_pool_minato:checkin(?POOL, Token)
    end.

transaction_routes_inner_queries() ->
    Result = kura_driver_minato:transaction(
        kura_pool_minato,
        ?POOL,
        fun() ->
            %% Inside a transaction, query/5 routes to the held conn
            %% rather than leasing a fresh one.
            ?assertNotEqual(undefined, kura_pool_minato:transaction_conn(?POOL)),
            kura_driver_minato:query(kura_pool_minato, ?POOL, ~"SELECT 3::integer AS n", [], #{})
        end,
        #{}
    ),
    ?assertMatch(#{rows := [_]}, Result).

transaction_rollback() ->
    %% A throw rolls the transaction back and is re-raised.
    ?assertException(
        throw,
        boom,
        kura_driver_minato:transaction(
            kura_pool_minato,
            ?POOL,
            fun() -> erlang:throw(boom) end,
            #{}
        )
    ).

%%----------------------------------------------------------------------
%% helpers
%%----------------------------------------------------------------------

wait_for_ready(_Pool, T) when T =< 0 ->
    {error, timeout};
wait_for_ready(Pool, T) ->
    case minato:health(Pool, 1000) of
        ok ->
            ok;
        _NotYet ->
            timer:sleep(50),
            wait_for_ready(Pool, T - 50)
    end.
