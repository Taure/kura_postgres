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
            {"a COMMIT that gets no answer raises as unknown", fun unanswered_commit_raises/0},
            {"a COMMIT the server ends the session on raises as unknown",
                fun ended_commit_raises_unknown/0}
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
            {"a raise two levels down undoes only the innermost work", fun doubly_nested_raise/0},
            {"a nested transaction that raised leaves no savepoint behind",
                fun raised_nested_releases_savepoint/0},
            {"a RELEASE the server refuses raises", fun refused_release_raises/0},
            {"a cleanup that raises keeps the original exception",
                fun raised_cleanup_keeps_original/0},
            {"a SAVEPOINT that raises is named like a refused one",
                fun raised_savepoint_is_named/0},
            {"a COMMIT in a transaction raises and keeps the work before it", fun() ->
                ended_by(~"COMMIT", [1])
            end},
            {"an END in a transaction raises and keeps the work before it", fun() ->
                ended_by(~"END", [1])
            end},
            {"a ROLLBACK in a transaction raises and keeps nothing", fun() ->
                ended_by(~"ROLLBACK", [])
            end},
            {"a COMMIT in a nested transaction raises and keeps the work before it", fun() ->
                nested_ended_by(~"COMMIT", [1, 2])
            end},
            {"an END in a nested transaction raises and keeps the work before it", fun() ->
                nested_ended_by(~"END", [1, 2])
            end},
            {"a ROLLBACK in a nested transaction raises and keeps nothing", fun() ->
                nested_ended_by(~"ROLLBACK", [])
            end},
            {"a ROLLBACK after a failed statement raises", fun rollback_after_failure_raises/0},
            {"a function that catches the end runs nothing more in autocommit",
                fun caught_end_runs_nothing_more/0},
            {"a nested transaction after a caught end does not start",
                fun caught_end_starts_no_savepoint/0}
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
        ?assertEqual(
            [code, constraint, severity, severity_non_localised], lists:sort(maps:keys(Fields))
        ),
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

raised_nested_releases_savepoint() ->
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
        #{rows := [#{n := Held}]} = query(
            ~"SELECT count(*)::integer AS n FROM pg_locks WHERE pid = pg_backend_pid() AND locktype = 'transactionid'",
            []
        ),
        ?assertEqual(1, Held)
    end).

refused_release_raises() ->
    with_fake_holder(fun refuses_release/1, fun() ->
        ?assertError(
            {kura_driver_minato, {release_failed, {pgsql_error, #{code := ~"XX000"}}}},
            transaction(fun() -> ok end)
        )
    end).

ended_by(Statement, Kept) ->
    ?assertError(
        {kura_driver_minato, transaction_ended_by_statement},
        transaction(fun() ->
            ok = insert(1),
            ok = sql(Statement),
            insert(2)
        end)
    ),
    ?assertEqual(Kept, ids(nested_table())),
    ?assertEqual(undefined, kura_pool_minato:transaction_conn(?POOL)).

nested_ended_by(Statement, Kept) ->
    ?assertError(
        {kura_driver_minato, transaction_ended_by_statement},
        transaction(fun() ->
            ok = insert(1),
            ok = transaction(fun() ->
                ok = insert(2),
                ok = sql(Statement),
                insert(3)
            end),
            insert(4)
        end)
    ),
    ?assertEqual(Kept, ids(nested_table())).

rollback_after_failure_raises() ->
    ?assertError(
        {kura_driver_minato, transaction_ended_by_statement},
        transaction(fun() ->
            ok = insert(1),
            {error, {pgsql_error, _}} = query(~"SELECT 1 / 0", []),
            ok = sql(~"ROLLBACK"),
            insert(2)
        end)
    ),
    ?assertEqual([], ids(nested_table())).

caught_end_runs_nothing_more() ->
    ?assertError(
        {kura_driver_minato, transaction_ended_by_statement},
        transaction(fun() ->
            ok = insert(1),
            ?assertError(
                {kura_driver_minato, transaction_ended_by_statement}, sql(~"COMMIT")
            ),
            ?assertError({kura_driver_minato, transaction_ended_by_statement}, insert(2)),
            ok
        end)
    ),
    ?assertEqual([1], ids(nested_table())).

caught_end_starts_no_savepoint() ->
    Self = self(),
    ?assertError(
        {kura_driver_minato, transaction_ended_by_statement},
        transaction(fun() ->
            ?assertError(
                {kura_driver_minato, transaction_ended_by_statement}, sql(~"ROLLBACK")
            ),
            transaction(fun() -> Self ! nested_ran end)
        end)
    ),
    receive
        nested_ran -> error(nested_function_ran)
    after 0 -> ok
    end.

ended_commit_raises_unknown() ->
    Table = table(~"kura_driver_ended"),
    ok = sql([~"DROP TABLE IF EXISTS ", Table]),
    ok = sql([~"CREATE TABLE ", Table, ~" (id integer)"]),
    ok = sql([
        ~"CREATE OR REPLACE FUNCTION ",
        Table,
        ~"() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_terminate_backend(pg_backend_pid()); PERFORM pg_sleep(1); RETURN NULL; END $$"
    ]),
    ok = sql([
        ~"CREATE CONSTRAINT TRIGGER ",
        Table,
        ~" AFTER INSERT ON ",
        Table,
        ~" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ",
        Table,
        ~"()"
    ]),
    try
        ?assertError(
            {kura_driver_minato, {commit_unknown, _}},
            transaction(fun() -> sql([~"INSERT INTO ", Table, ~" VALUES (1)"]) end)
        ),
        ?assertEqual(ok, wait_for_ready(?POOL, 5000))
    after
        _ = query([~"DROP TABLE IF EXISTS ", Table], []),
        _ = query([~"DROP FUNCTION IF EXISTS ", Table, ~"()"], [])
    end.

raised_cleanup_keeps_original() ->
    with_fake_holder(fun fails_after_savepoint/1, fun() ->
        ?assertThrow(original, transaction(fun() -> throw(original) end))
    end).

raised_savepoint_is_named() ->
    with_fake_holder(fun fails_always/1, fun() ->
        ?assertError(
            {kura_driver_minato, {savepoint_failed, {raised, error}}},
            transaction(fun() -> ok end)
        )
    end).

fails_after_savepoint(<<"SAVEPOINT ", _/binary>>) -> #{command => savepoint};
fails_after_savepoint(_Cleanup) -> {raised, error, lost, []}.

fails_always(_SQL) -> {raised, error, lost, []}.

refuses_release(<<"SAVEPOINT ", _/binary>>) -> #{command => savepoint};
refuses_release(_Release) -> {error, {pgsql_error, #{code => ~"XX000"}}}.

%% Stands in for the transaction's holder, answering every statement with Answer.
with_fake_holder(Answer, Test) ->
    transaction(fun() ->
        Holder = held(),
        Fake = spawn_link(fun() -> answering(Answer) end),
        ok = kura_pool_minato:in_transaction(?POOL, Fake),
        try
            Test()
        after
            ok = kura_pool_minato:in_transaction(?POOL, Holder),
            unlink(Fake),
            exit(Fake, kill)
        end
    end).

answering(Answer) ->
    receive
        {call, Alias, {run, SQL, _Params, _Opts}} ->
            Alias ! {Alias, Answer(iolist_to_binary(SQL))},
            answering(Answer);
        {call, Alias, {run_in_transaction, SQL, _Params, _Opts}} ->
            Alias ! {Alias, reported(Answer(iolist_to_binary(SQL)))},
            answering(Answer)
    end.

reported({raised, _Class, _Reason, _Stack} = Raised) -> Raised;
reported(Answer) -> {reported, Answer, transaction}.

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
