-module(kura_postgres_capabilities_tests).
-include_lib("eunit/include/eunit.hrl").

-define(POOL, kura_postgres_capabilities_test).
-define(REPO, kura_postgres_test_repo).
-define(LISTENER, kura_postgres_capabilities_listener).
-define(CONFIG, #{
    host => "localhost",
    port => 5555,
    database => "kura_test",
    user => "postgres",
    password => "root",
    pool_size => 3
}).
-define(ADVISORY_KEY, 5272178).

%% One test for each capability kura_pool_minato declares, run on the server.
%% A capability declared without a clause of runs/1 fails here. The ones kura
%% checks a query or a stream for run through kura's own API.
declared_capabilities_run_test_() ->
    {setup, fun setup/0, fun teardown/1, fun(_) ->
        [
            {atom_to_list(Capability), fun() ->
                ok = emptied(),
                runs(Capability)
            end}
         || Capability <- kura_pool_minato:capabilities()
        ]
    end}.

the_backend_declares_what_the_pool_declares_test() ->
    ?assertEqual(kura_pool_minato:capabilities(), kura_backend_postgres:capabilities()),
    ?assertEqual(kura_pool_minato:capability_model(), kura_backend_postgres:capability_model()).

%% The model number lives in kura_pool_minato alone. Whatever it is, every
%% capability kura checks a query or a stream for is declared.
the_checked_capabilities_are_declared_test() ->
    ?assert(is_integer(kura_pool_minato:capability_model())),
    ?assertEqual(
        ok,
        kura_capabilities:require(kura_pool_minato, [
            full_text_search,
            window_functions,
            vector,
            select_for_update_skip_locked,
            row_locks,
            distinct_on,
            cursors
        ])
    ).

a_capability_is_declared_once_test() ->
    Declared = kura_pool_minato:capabilities(),
    ?assertEqual(lists:usort(Declared), lists:sort(Declared)).

%% SQLite's text JSON is `json`; PostgreSQL's is declared as `jsonb`.
sqlite_only_capabilities_are_not_declared_test() ->
    ?assertNot(kura_capabilities:has(kura_pool_minato, json)).

%%----------------------------------------------------------------------
%% The capabilities
%%----------------------------------------------------------------------

runs(returning) ->
    {SQL, Params} = kura_dialect_pg:insert_all(
        rows(), [id, name], [#{id => 1, name => ~"a"}, #{id => 2, name => ~"b"}], #{
            returning => [id, name]
        }
    ),
    ?assertMatch(
        #{rows := [#{id := 1, name := ~"a"}, #{id := 2, name := ~"b"}]}, query(SQL, Params)
    );
runs(jsonb) ->
    ok = sql([
        ~"INSERT INTO ",
        table(),
        ~" (id, doc) VALUES ",
        ~"(1, '{\"kind\": \"a\", \"tags\": [\"x\"]}'), (2, '{\"kind\": \"b\", \"tags\": []}')"
    ]),
    ?assertMatch(
        #{rows := [#{id := 1, kind := ~"a"}]},
        query(
            [
                ~"SELECT id, doc ->> 'kind' AS kind FROM ",
                table(),
                ~" WHERE doc @> '{\"tags\": [\"x\"]}'"
            ],
            []
        )
    );
runs(arrays) ->
    #{num_rows := 1} = query(
        [~"INSERT INTO ", table(), ~" (id, tags) VALUES ($1, $2)"], [1, [~"a", ~"b"]]
    ),
    ?assertMatch(
        #{rows := [#{tags := [~"a", ~"b"]}]},
        query([~"SELECT tags FROM ", table(), ~" WHERE $1 = ANY (tags)"], [~"b"])
    ),
    ?assertMatch(
        #{rows := []},
        query([~"SELECT tags FROM ", table(), ~" WHERE $1 = ANY (tags)"], [~"c"])
    );
runs(advisory_locks) ->
    {ok, Holder, HolderToken} = kura_pool_minato:checkout(?POOL, #{}),
    {ok, Other, OtherToken} = kura_pool_minato:checkout(?POOL, #{}),
    try
        ?assertMatch(#{rows := [#{locked := true}]}, try_lock(Holder)),
        ?assertMatch(#{rows := [#{locked := false}]}, try_lock(Other)),
        ?assertMatch(#{rows := [#{unlocked := true}]}, unlock(Holder)),
        ?assertMatch(#{rows := [#{locked := true}]}, try_lock(Other)),
        ?assertMatch(#{rows := [#{unlocked := true}]}, unlock(Other))
    after
        ok = kura_pool_minato:checkin(?POOL, HolderToken),
        ok = kura_pool_minato:checkin(?POOL, OtherToken)
    end;
runs(listen_notify) ->
    Channel = table(),
    {ok, _Listener} = minato:start_listener(?LISTENER, #{
        connection => #{
            host => "localhost",
            port => 5555,
            database => ~"kura_test",
            user => ~"postgres",
            password => ~"root"
        }
    }),
    try
        ok = minato:listen(?LISTENER, Channel),
        _ = query([~"NOTIFY ", Channel, ~", 'told'"], []),
        receive
            {minato_notification, Channel, Payload, _From} -> ?assertEqual(~"told", Payload)
        after 5000 -> error(not_notified)
        end
    after
        _ = minato:stop_listener(?LISTENER)
    end;
runs(select_for_update_skip_locked) ->
    ok = sql([~"INSERT INTO ", table(), ~" (id) VALUES (1), (2)"]),
    Ordered = kura_query:order_by(kura_query:from(rows()), [{id, asc}]),
    {Locking, LockingParams} = kura_dialect_pg:to_sql(
        kura_query:lock(kura_query:where(Ordered, {id, 1}), ~"FOR UPDATE")
    ),
    {Skipping, SkippingParams} = kura_dialect_pg:to_sql(
        kura_query:lock(Ordered, ~"FOR UPDATE SKIP LOCKED")
    ),
    Unlocked = transaction(fun() ->
        #{rows := [#{id := 1}]} = query(Locking, LockingParams),
        in_another_process(fun() ->
            transaction(fun() -> query(Skipping, SkippingParams) end)
        end)
    end),
    ?assertMatch(#{rows := [#{id := 2}]}, Unlocked),
    ?assertMatch(#{rows := [#{id := 1}, #{id := 2}]}, query(Skipping, SkippingParams));
runs(row_locks) ->
    ok = sql([~"INSERT INTO ", table(), ~" (id) VALUES (1), (2)"]),
    Refused = kura_repo_worker:transaction(?REPO, fun() ->
        ?assertMatch({ok, [#{id := 1}]}, kura_repo_worker:all(?REPO, locked(1, ~"FOR UPDATE"))),
        in_another_process(fun() ->
            {
                kura_repo_worker:all(?REPO, locked(1, ~"FOR SHARE NOWAIT")),
                kura_repo_worker:all(?REPO, locked(2, ~"FOR UPDATE NOWAIT"))
            }
        end)
    end),
    ?assertMatch({{error, {pgsql_error, #{code := ~"55P03"}}}, {ok, [#{id := 2}]}}, Refused),
    ?assertMatch({ok, [#{id := 1}]}, kura_repo_worker:all(?REPO, locked(1, ~"FOR SHARE NOWAIT")));
runs(distinct_on) ->
    ok = sql([
        ~"INSERT INTO ", table(), ~" (id, name) VALUES (1, 'a'), (2, 'a'), (3, 'b')"
    ]),
    Latest = kura_query:order_by(
        kura_query:distinct(kura_query:from(rows()), [name]), [{name, asc}, {id, desc}]
    ),
    ?assertMatch(
        {ok, [#{id := 2, name := ~"a"}, #{id := 3, name := ~"b"}]},
        kura_repo_worker:all(?REPO, Latest)
    );
runs(cursors) ->
    ok = sql([~"INSERT INTO ", table(), ~" (id) VALUES (1), (2), (3), (4), (5)"]),
    Collector = self(),
    Streamed = kura_stream:stream(
        ?REPO,
        kura_query:order_by(kura_query:from(rows()), [{id, asc}]),
        fun(Batch) ->
            Collector ! {batch, [Id || #{id := Id} <- Batch]},
            ok
        end,
        #{batch_size => 2}
    ),
    ?assertEqual(ok, Streamed),
    ?assertEqual([[1, 2], [3, 4], [5]], batches());
runs(partial_indexes) ->
    Index = <<(table())/binary, "_named">>,
    ok = sql([~"CREATE INDEX ", Index, ~" ON ", table(), ~" (name) WHERE name IS NOT NULL"]),
    #{rows := [#{indexdef := Definition}]} = query(
        ~"SELECT indexdef FROM pg_indexes WHERE indexname = $1", [Index]
    ),
    ok = sql([~"DROP INDEX ", Index]),
    ?assertMatch({_, _}, binary:match(Definition, ~"WHERE (name IS NOT NULL)"));
runs(window_functions) ->
    ok = sql([
        ~"INSERT INTO ", table(), ~" (id, name) VALUES (1, 'a'), (2, 'a'), (3, 'b')"
    ]),
    Numbered = kura_query:order_by(
        kura_query:select_expr(kura_query:from(rows()), [
            {id, id},
            {place,
                kura_query:over(row_number, #{partition_by => [name], order_by => [{id, desc}]})},
            {total, kura_query:over({sum, id}, #{partition_by => [name]})}
        ]),
        [{id, asc}]
    ),
    {SQL, Params} = kura_dialect_pg:to_sql(Numbered),
    ?assertMatch(
        #{
            rows := [
                #{id := 1, place := 2, total := 3},
                #{id := 2, place := 1, total := 3},
                #{id := 3, place := 1, total := 3}
            ]
        },
        query(SQL, Params)
    );
runs(full_text_search) ->
    ok = sql([
        ~"INSERT INTO ",
        table(),
        ~" (id, name) VALUES (1, 'a database written in Erlang'), (2, 'a web server')"
    ]),
    {SQL, Params} = kura_dialect_pg:to_sql(
        kura_query:where(kura_query:from(rows()), {name, matches, ~"erlang databases"})
    ),
    ?assertMatch(#{rows := [#{id := 1}]}, query(SQL, Params));
runs(vector) ->
    ok = sql([
        ~"INSERT INTO ",
        table(),
        ~" (id, embedding) VALUES (1, '[1,0,0]'), (2, '[0,1,0]'), (3, '[0.9,0.1,0]')"
    ]),
    Distance = kura_query:distance(embedding, l2, [1, 0, 0]),
    {SQL, Params} = kura_dialect_pg:to_sql(
        kura_query:order_by(
            kura_query:select(kura_query:where(kura_query:from(rows()), {Distance, '<', 1}), [id]),
            [{Distance, asc}]
        )
    ),
    ?assertMatch(#{rows := [#{id := 1}, #{id := 3}]}, query(SQL, Params));
runs(transactions) ->
    ok = transaction(fun() -> insert(1) end),
    ?assertThrow(
        undone,
        transaction(fun() ->
            ok = insert(2),
            throw(undone)
        end)
    ),
    ?assertEqual([1], ids());
runs(savepoints) ->
    ok = transaction(fun() ->
        ok = insert(1),
        ?assertThrow(
            undone,
            transaction(fun() ->
                ok = insert(2),
                throw(undone)
            end)
        ),
        insert(3)
    end),
    ?assertEqual([1, 3], ids());
runs(prepared_statements) ->
    {ok, Holder, Token} = kura_pool_minato:checkout(?POOL, #{}),
    try
        #{command := prepare} = kura_driver_minato:query_on(
            Holder, ~"PREPARE kura_capability (integer) AS SELECT $1 + 1 AS n", [], #{}
        ),
        ?assertMatch(
            #{rows := [#{n := 42}]},
            kura_driver_minato:query_on(Holder, ~"EXECUTE kura_capability (41)", [], #{})
        ),
        ?assertMatch(
            #{rows := [#{name := ~"kura_capability"}]},
            kura_driver_minato:query_on(
                Holder,
                ~"SELECT name FROM pg_prepared_statements WHERE name = $1",
                [
                    ~"kura_capability"
                ],
                #{}
            )
        ),
        #{command := deallocate} = kura_driver_minato:query_on(
            Holder, ~"DEALLOCATE kura_capability", [], #{}
        )
    after
        ok = kura_pool_minato:checkin(?POOL, Token)
    end;
runs(concurrent_indexes) ->
    Index = <<(table())/binary, "_concurrent">>,
    #{command := create} = query(
        [~"CREATE INDEX CONCURRENTLY ", Index, ~" ON ", table(), ~" (name)"], []
    ),
    ?assertMatch(
        #{rows := [#{indisvalid := true}]},
        query(~"SELECT indisvalid FROM pg_index WHERE indexrelid = $1::regclass", [Index])
    ),
    #{command := drop} = query([~"DROP INDEX CONCURRENTLY ", Index], []),
    ok.

%%----------------------------------------------------------------------
%% Fixture
%%----------------------------------------------------------------------

setup() ->
    _ = application:ensure_all_started(minato),
    case kura_pool_minato:start_pool(?POOL, ?CONFIG) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end,
    ok = wait_for_ready(?POOL, 5000),
    ok = ?REPO:start(),
    ok = sql(~"CREATE EXTENSION IF NOT EXISTS vector"),
    ok = sql([~"DROP TABLE IF EXISTS ", table()]),
    sql([
        ~"CREATE TABLE ",
        table(),
        ~" (id integer PRIMARY KEY, name text, doc jsonb, tags text[], embedding vector(3))"
    ]).

teardown(_) ->
    _ = query([~"DROP TABLE IF EXISTS ", table()], []),
    ok = ?REPO:stop(),
    _ = kura_pool_minato:stop_pool(?POOL),
    ok.

emptied() ->
    sql([~"TRUNCATE ", table()]).

table() ->
    kura_test_capability_schema:table().

rows() ->
    kura_test_capability_schema.

locked(Id, Lock) ->
    kura_query:lock(kura_query:where(kura_query:from(rows()), {id, Id}), Lock).

batches() ->
    receive
        {batch, Ids} -> [Ids | batches()]
    after 0 -> []
    end.

insert(Id) ->
    sql([~"INSERT INTO ", table(), ~" (id) VALUES (", integer_to_binary(Id), ~")"]).

ids() ->
    #{rows := Rows} = query([~"SELECT id FROM ", table(), ~" ORDER BY id"], []),
    [Id || #{id := Id} <- Rows].

try_lock(Holder) ->
    kura_driver_minato:query_on(
        Holder, ~"SELECT pg_try_advisory_lock($1) AS locked", [?ADVISORY_KEY], #{}
    ).

unlock(Holder) ->
    kura_driver_minato:query_on(
        Holder, ~"SELECT pg_advisory_unlock($1) AS unlocked", [?ADVISORY_KEY], #{}
    ).

sql(SQL) ->
    case query(SQL, []) of
        #{command := _} -> ok;
        {error, Reason} -> error({sql_failed, iolist_to_binary(SQL), Reason})
    end.

query(SQL, Params) ->
    kura_driver_minato:query(kura_pool_minato, ?POOL, SQL, Params, #{}).

transaction(Fun) ->
    kura_driver_minato:transaction(kura_pool_minato, ?POOL, Fun, #{}).

%% A process spawned inside a transaction is outside it, on a connection of
%% its own.
in_another_process(Fun) ->
    {Pid, Monitor} = spawn_monitor(fun() -> exit({answered, Fun()}) end),
    receive
        {'DOWN', Monitor, process, Pid, {answered, Answer}} -> Answer;
        {'DOWN', Monitor, process, Pid, Reason} -> error({other_process_failed, Reason})
    after 10000 ->
        exit(Pid, kill),
        error(other_process_timeout)
    end.

wait_for_ready(_Pool, Left) when Left =< 0 ->
    {error, timeout};
wait_for_ready(Pool, Left) ->
    case minato:health(Pool, 1000) of
        ok ->
            ok;
        _NotYet ->
            timer:sleep(50),
            wait_for_ready(Pool, Left - 50)
    end.
