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
            {"transaction/3 rolls back on error", fun transaction_rollback/0},
            {"a COMMIT the server rejects raises", fun rejected_commit_raises/0}
        ]
    end}.

nested_test_() ->
    {setup, fun nested_setup/0, fun nested_teardown/1, fun(_) ->
        [
            {Title, fun() -> emptied(Test) end}
         || {Title, Test} <- [
                {"a raise in a nested transaction undoes only its own work",
                    fun nested_raise_undoes_only_its_work/0},
                {"rolling back the outer transaction undoes a nested one",
                    fun outer_rollback_undoes_nested/0},
                {"a nested transaction is invisible until the outer one commits",
                    fun nested_waits_for_outer_commit/0},
                {"the outer transaction carries on after a nested one",
                    fun outer_continues_after_nested/0},
                {"a nested transaction whose statement failed reports the rollback",
                    fun failed_statement_in_nested_raises/0}
            ]
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

rejected_commit_raises() ->
    ok = sql(~"DROP TABLE IF EXISTS kura_driver_deferred"),
    ok = sql(
        ~"CREATE TABLE kura_driver_deferred (id integer PRIMARY KEY, parent integer REFERENCES kura_driver_deferred (id) DEFERRABLE INITIALLY DEFERRED)"
    ),
    try
        ?assertError(
            {kura_driver_minato, {commit_failed, {pgsql_error, #{code := ~"23503"}}}},
            transaction(fun() -> sql(~"INSERT INTO kura_driver_deferred VALUES (1, 2)") end)
        ),
        ?assertEqual([], ids(~"kura_driver_deferred"))
    after
        sql(~"DROP TABLE kura_driver_deferred")
    end.

nested_raise_undoes_only_its_work() ->
    transaction(fun() ->
        ok = insert(1),
        ?assertThrow(
            inner,
            transaction(fun() ->
                ok = insert(2),
                throw(inner)
            end)
        ),
        ok = insert(3),
        ?assertEqual([], seen_elsewhere())
    end),
    ?assertEqual([1, 3], ids(~"kura_driver_nested")).

outer_rollback_undoes_nested() ->
    ?assertThrow(
        outer,
        transaction(fun() ->
            ok = insert(1),
            ok = transaction(fun() -> insert(2) end),
            throw(outer)
        end)
    ),
    ?assertEqual([], ids(~"kura_driver_nested")).

nested_waits_for_outer_commit() ->
    transaction(fun() ->
        ok = transaction(fun() -> insert(1) end),
        ?assertEqual([], seen_elsewhere())
    end),
    ?assertEqual([1], ids(~"kura_driver_nested")).

outer_continues_after_nested() ->
    ?assertThrow(
        outer,
        transaction(fun() ->
            ok = transaction(fun() -> ok end),
            ?assertNotEqual(undefined, kura_pool_minato:transaction_conn(?POOL)),
            ok = insert(1),
            throw(outer)
        end)
    ),
    ?assertEqual([], ids(~"kura_driver_nested")).

failed_statement_in_nested_raises() ->
    transaction(fun() ->
        ok = insert(1),
        ?assertError(
            transaction_rolled_back,
            transaction(fun() ->
                ok = insert(2),
                {error, _} = query(~"SELECT 1/0", []),
                ok
            end)
        ),
        ok = insert(3),
        ?assertEqual([], seen_elsewhere())
    end),
    ?assertEqual([1, 3], ids(~"kura_driver_nested")).

%%----------------------------------------------------------------------
%% helpers
%%----------------------------------------------------------------------

nested_setup() ->
    ok = setup(),
    ok = sql(~"DROP TABLE IF EXISTS kura_driver_nested"),
    sql(~"CREATE TABLE kura_driver_nested (id integer)").

nested_teardown(Arg) ->
    _ = sql(~"DROP TABLE IF EXISTS kura_driver_nested"),
    teardown(Arg).

seen_elsewhere() ->
    Self = self(),
    {Reader, Monitor} = spawn_monitor(fun() -> Self ! {seen, self(), ids(~"kura_driver_nested")} end),
    receive
        {seen, Reader, Seen} ->
            erlang:demonitor(Monitor, [flush]),
            Seen;
        {'DOWN', Monitor, process, Reader, Reason} ->
            error({reader_failed, Reason})
    after 2000 -> error(reader_never_answered)
    end.

emptied(Test) ->
    ok = sql(~"TRUNCATE kura_driver_nested"),
    Test().

transaction(Fun) ->
    kura_driver_minato:transaction(kura_pool_minato, ?POOL, Fun, #{}).

query(SQL, Params) ->
    kura_driver_minato:query(kura_pool_minato, ?POOL, SQL, Params, #{}).

sql(SQL) ->
    #{} = query(SQL, []),
    ok.

insert(Id) ->
    #{num_rows := 1} = query(~"INSERT INTO kura_driver_nested VALUES ($1)", [Id]),
    ok.

ids(Table) ->
    #{rows := Rows} = query(<<"SELECT id FROM ", Table/binary, " ORDER BY id">>, []),
    [Id || #{id := Id} <- Rows].

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
