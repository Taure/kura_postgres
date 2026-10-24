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
            {"a COMMIT the server rejects raises", fun rejected_commit_raises/0},
            {"a COMMIT that gets no answer raises as unknown", fun unanswered_commit_raises/0}
        ]
    end}.

nested_test_() ->
    {setup, fun nested_setup/0, fun nested_teardown/1, fun(_) ->
        {foreach, fun emptied/0, fun(_) -> ok end, [
            {"a raise in a nested transaction undoes only its own work",
                fun nested_raise_undoes_only_its_work/0},
            {"rolling back the outer transaction undoes a nested one",
                fun outer_rollback_undoes_nested/0},
            {"a nested transaction is invisible until the outer one commits",
                fun nested_waits_for_outer_commit/0},
            {"the outer transaction carries on after a nested one",
                fun outer_continues_after_nested/0},
            {"a nested transaction whose statement failed reports the rollback",
                fun failed_statement_in_nested_raises/0},
            {"a nested transaction in an aborted one raises before its function runs",
                fun savepoint_refused_raises/0},
            {"a raise two levels down undoes only the innermost work", fun doubly_nested_raise/0}
        ]}
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
    Table = table(~"kura_driver_deferred"),
    ok = sql([~"DROP TABLE IF EXISTS ", Table]),
    ok = sql([
        ~"CREATE TABLE ",
        Table,
        ~" (id integer PRIMARY KEY, parent integer REFERENCES ",
        Table,
        ~" (id) DEFERRABLE INITIALLY DEFERRED)"
    ]),
    try
        Raised =
            try transaction(fun() -> sql([~"INSERT INTO ", Table, ~" VALUES (1, 2)"]) end) of
                Returned -> {returned, Returned}
            catch
                error:Reason -> Reason
            end,
        ?assertMatch(
            {kura_driver_minato, {commit_failed, {pgsql_error, #{code := ~"23503"}}}}, Raised
        ),
        {kura_driver_minato, {commit_failed, {pgsql_error, Fields}}} = Raised,
        ?assertEqual([code, constraint, severity], lists:sort(maps:keys(Fields))),
        ?assertEqual([], ids(Table))
    after
        _ = query([~"DROP TABLE IF EXISTS ", Table], [])
    end.

unanswered_commit_raises() ->
    ?assertError(
        {kura_driver_minato, {commit_unknown, {holder_died, _}}},
        transaction(fun() ->
            Holder = held(),
            Monitor = erlang:monitor(process, Holder),
            exit(Holder, kill),
            receive
                {'DOWN', Monitor, process, Holder, _} -> ok
            end
        end)
    ),
    ?assertEqual(ok, wait_for_ready(?POOL, 5000)).

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
    ?assertEqual([1, 3], ids(nested_table())).

outer_rollback_undoes_nested() ->
    ?assertThrow(
        outer,
        transaction(fun() ->
            ok = insert(1),
            ok = transaction(fun() -> insert(2) end),
            throw(outer)
        end)
    ),
    ?assertEqual([], ids(nested_table())).

nested_waits_for_outer_commit() ->
    transaction(fun() ->
        ok = transaction(fun() -> insert(1) end),
        ?assertEqual([], seen_elsewhere())
    end),
    ?assertEqual([1], ids(nested_table())).

outer_continues_after_nested() ->
    ?assertThrow(
        outer,
        transaction(fun() ->
            Holder = kura_pool_minato:transaction_conn(?POOL),
            ok = transaction(fun() -> ok end),
            ?assertEqual(Holder, kura_pool_minato:transaction_conn(?POOL)),
            ok = insert(1),
            throw(outer)
        end)
    ),
    ?assertEqual([], ids(nested_table())).

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
    ?assertEqual([1, 3], ids(nested_table())).

savepoint_refused_raises() ->
    Self = self(),
    ?assertError(
        {kura_driver_minato, {savepoint_failed, {pgsql_error, #{code := ~"25P02"}}}},
        transaction(fun() ->
            {error, _} = query(~"SELECT 1/0", []),
            transaction(fun() -> Self ! nested_ran end)
        end)
    ),
    receive
        nested_ran -> error(nested_function_ran)
    after 0 -> ok
    end.

doubly_nested_raise() ->
    transaction(fun() ->
        ok = insert(1),
        ok = transaction(fun() ->
            ok = insert(2),
            ?assertThrow(
                inner,
                transaction(fun() ->
                    ok = insert(3),
                    throw(inner)
                end)
            ),
            insert(4)
        end),
        ?assertEqual([], seen_elsewhere())
    end),
    ?assertEqual([1, 2, 4], ids(nested_table())).

%%----------------------------------------------------------------------
%% helpers
%%----------------------------------------------------------------------

nested_setup() ->
    ok = setup(),
    ok = sql([~"DROP TABLE IF EXISTS ", nested_table()]),
    sql([~"CREATE TABLE ", nested_table(), ~" (id integer)"]).

nested_teardown(Arg) ->
    _ = query([~"DROP TABLE IF EXISTS ", nested_table()], []),
    teardown(Arg).

%% Each OS process gets its own tables, so test runs sharing the database
%% cannot drop or truncate each other's.
table(Base) ->
    iolist_to_binary([Base, ~"_", os:getpid()]).

nested_table() ->
    table(~"kura_driver_nested").

seen_elsewhere() ->
    Self = self(),
    {Reader, Monitor} = spawn_monitor(fun() -> Self ! {seen, self(), ids(nested_table())} end),
    receive
        {seen, Reader, Seen} ->
            erlang:demonitor(Monitor, [flush]),
            Seen;
        {'DOWN', Monitor, process, Reader, Reason} ->
            error({reader_failed, Reason})
    after 2000 ->
        exit(Reader, kill),
        error(reader_never_answered)
    end.

emptied() ->
    sql([~"TRUNCATE ", nested_table()]).

held() ->
    case kura_pool_minato:transaction_conn(?POOL) of
        Holder when is_pid(Holder) -> Holder
    end.

transaction(Fun) ->
    kura_driver_minato:transaction(kura_pool_minato, ?POOL, Fun, #{}).

query(SQL, Params) ->
    kura_driver_minato:query(kura_pool_minato, ?POOL, SQL, Params, #{}).

sql(SQL) ->
    #{} = query(SQL, []),
    ok.

insert(Id) ->
    #{num_rows := 1} = query([~"INSERT INTO ", nested_table(), ~" VALUES ($1)"], [Id]),
    ok.

ids(Table) ->
    #{rows := Rows} = query([~"SELECT id FROM ", Table, ~" ORDER BY id"], []),
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
