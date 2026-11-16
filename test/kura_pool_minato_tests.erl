-module(kura_pool_minato_tests).
-include_lib("eunit/include/eunit.hrl").

-export([slow_checkout_stop/4, log/2]).

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
            {"start_pool reports a running pool as already started",
                fun start_pool_reports_already_started/0},
            {"a second start with other options leaves the running pool as it is",
                fun second_start_keeps_the_running_pool/0},
            {"an owner's death discards the connection and its session state",
                fun owner_death_discards_connection/0},
            {"minato's server-side cancellation reaches the caller of run/4",
                fun statement_timeout_is_cancelled_on_the_server/0},
            {"a statement that loses the connection ends the holder",
                fun lost_connection_ends_the_holder/0},
            {"a statement that raises re-raises in the caller and ends the holder",
                fun raising_statement_ends_the_holder/0},
            {"a held connection builds and drops an index concurrently",
                fun concurrent_index_on_a_held_connection/0},
            {"run_in_transaction/4 reports the transaction status after a statement",
                fun run_in_transaction_reports_status/0},
            {"run_in_transaction/4 runs nothing outside a transaction",
                fun run_in_transaction_refuses_outside/0},
            {"run_in_transaction/4 runs nothing after a COMMIT AND CHAIN",
                fun run_in_transaction_refuses_after_chain/0},
            {"run_in_transaction/4 stays refused after a new BEGIN",
                fun run_in_transaction_stays_refused/0},
            {"run_in_transaction/4 tells a chained rollback from a savepoint rollback",
                fun run_in_transaction_tells_rollbacks_apart/0},
            {"open_transaction/1 answers the error of a BEGIN the server refuses",
                fun refused_open_transaction/0},
            {"open_transaction/1 that loses the connection ends the holder",
                fun lost_open_transaction_ends_the_holder/0},
            {"run_in_transaction/4 that loses the connection answers unknown and ends the holder",
                fun lost_run_in_transaction_ends_the_holder/0},
            {"a marker read the server refuses counts as an ended transaction",
                fun refused_marker_read_ends/0},
            {"a marker read that loses the connection answers the connection error",
                fun lost_marker_read_is_a_connection_error/0}
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

a_pool_without_a_user_is_refused_test() ->
    Config = maps:remove(user, ?CONFIG),
    ?assertEqual(
        {error, {missing_option, user}},
        kura_pool_minato:start_pool(kura_pool_minato_no_user_test, Config)
    ),
    ?assertEqual(undefined, whereis(kura_pool_minato_no_user_test)).

a_pool_given_username_is_started_test() ->
    Name = kura_pool_minato_username_test,
    Config = maps:remove(user, ?CONFIG),
    {ok, _Pid} = kura_pool_minato:start_pool(Name, Config#{username => ~"postgres"}),
    ?assertEqual(ok, wait_for_ready(Name, 5000)),
    _ = kura_pool_minato:stop_pool(Name),
    ok.

%% kura hands a pool module everything in the repo's config, and minato
%% refuses a key it has no option by.
what_is_not_a_connection_setting_stays_out_test() ->
    Config = ?CONFIG,
    {ok, Connection} = kura_pool_minato:connection(Config#{
        max_page_size => 100,
        log => true,
        queue_target => 50,
        queue_interval => 1000,
        ~"a key that is no atom" => 1
    }),
    ?assertEqual([database, host, password, port, user], lists:sort(maps:keys(Connection))).

a_name_minato_keeps_for_itself_starts_no_pool_test_() ->
    [
        {atom_to_list(Name), fun() ->
            {ok, _} = application:ensure_all_started(minato),
            Running = whereis(Name),
            ?assertEqual(
                {error, {reserved_name, Name}}, kura_pool_minato:start_pool(Name, ?CONFIG)
            ),
            ?assertEqual(ok, kura_pool_minato:stop_pool(Name)),
            ?assert(is_pid(Running)),
            ?assertEqual(Running, whereis(Name))
        end}
     || Name <- [minato_sup, minato_overdue]
    ].

the_settings_minato_takes_reach_it_test() ->
    Asked = #{
        ssl => true,
        ssl_options => [{verify, verify_peer}],
        channel_binding => require,
        auth => [scram_sha_256],
        prepared_statements => 0,
        connect_timeout => 3000,
        timeout => 20000,
        cancel_timeout => 2000,
        transport => inet,
        socket_options => [{keepalive, true}]
    },
    {ok, Connection} = kura_pool_minato:connection(maps:merge(?CONFIG, Asked)),
    ?assertEqual(Asked, maps:with(maps:keys(Asked), Connection)).

%% The test server asks for SCRAM-SHA-256 and speaks no TLS, so it can be
%% bound to nothing and is refused before the password is used.
a_required_channel_binding_is_asked_of_the_server_test() ->
    Config = ?CONFIG,
    {ok, Connection} = kura_pool_minato:connection(Config#{channel_binding => require}),
    ?assertEqual(
        {error, {channel_binding_required, scram_sha_256}}, minato_conn:connect(Connection)
    ).

a_method_left_out_of_auth_is_refused_test() ->
    Config = ?CONFIG,
    {ok, Connection} = kura_pool_minato:connection(Config#{auth => [md5]}),
    ?assertEqual({error, {auth_method_refused, scram_sha_256}}, minato_conn:connect(Connection)).

a_pool_restricted_to_the_method_the_server_asks_for_logs_in_test() ->
    Name = kura_pool_minato_auth_test,
    Config = ?CONFIG,
    {ok, _Pid} = kura_pool_minato:start_pool(Name, Config#{auth => [scram_sha_256]}),
    try
        ?assertEqual(ok, wait_for_ready(Name, 5000))
    after
        kura_pool_minato:stop_pool(Name)
    end.

%% One connection, so both statements run on the same session. minato keeps a
%% statement parsed under a name unless told to keep none.
prepared_statements_test_() ->
    [
        {"a pool keeps statements parsed by default", fun() ->
            ?assertNotEqual(0, statements_kept(#{}))
        end},
        {"a pool told to keep no statements keeps none", fun() ->
            ?assertEqual(0, statements_kept(#{prepared_statements => 0}))
        end}
    ].

statements_kept(Changed) ->
    Name = kura_pool_minato_statements_test,
    {ok, _Pid} = kura_pool_minato:start_pool(Name, maps:merge(?CONFIG, Changed#{pool_size => 1})),
    try
        ok = wait_for_ready(Name, 5000),
        {ok, #{rows := [{1}]}} = minato:query(Name, ~"SELECT $1::integer", [1]),
        {ok, #{rows := [{Kept}]}} = minato:query(
            Name, ~"SELECT count(*)::integer FROM pg_prepared_statements", []
        ),
        Kept
    after
        kura_pool_minato:stop_pool(Name)
    end.

%% minato refuses each of these in the pool process it has already started,
%% which ends in a crash report. Asked first, nothing is started or logged.
a_refused_setting_starts_nothing_test_() ->
    [
        {Label, fun() -> refused_before_starting(Key, Changed) end}
     || {Label, Key, Changed} <- [
            {"TLS options without ssl", ssl_options, #{ssl_options => [{verify, verify_peer}]}},
            {"TLS options with ssl off", ssl_options, #{ssl => false, ssl_options => []}},
            {"an ssl that is not a boolean", ssl, #{ssl => ~"true"}},
            {"a timeout that is text", timeout, #{timeout => "5000"}},
            {"a connect timeout that is text", connect_timeout, #{connect_timeout => ~"5000"}},
            {"a cancel timeout that is text", cancel_timeout, #{cancel_timeout => "5000"}},
            {"a channel binding minato has no word for", channel_binding, #{
                channel_binding => required
            }},
            {"authentication methods that are not a list", auth, #{auth => scram_sha_256}},
            {"a password that is not text", password, #{password => 1234}},
            {"a host that is not a name", host, #{host => 5432}},
            {"a pool size that is text", pool_size, #{pool_size => "10"}},
            {"a pool size of none", pool_size, #{pool_size => 0}},
            {"a statement limit that is not a number", prepared_statements, #{
                prepared_statements => true
            }},
            {"a statement limit that is text", prepared_statements, #{prepared_statements => "64"}},
            {"a statement limit below none", prepared_statements, #{prepared_statements => -1}}
        ]
    ].

host_and_user_are_read_before_their_other_names_test() ->
    {ok, Connection} = kura_pool_minato:connection(#{
        host => ~"db.internal",
        hostname => ~"other.internal",
        user => ~"app",
        username => ~"other"
    }),
    ?assertMatch(#{host := "db.internal", user := ~"app"}, Connection).

hostname_and_username_are_read_when_they_stand_alone_test() ->
    {ok, Connection} = kura_pool_minato:connection(#{
        hostname => ~"other.internal", username => ~"other"
    }),
    ?assertMatch(#{host := "other.internal", user := ~"other"}, Connection).

refused_before_starting(Key, Changed) ->
    {ok, _} = application:ensure_all_started(minato),
    Name = kura_pool_minato_refused_test,
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => self(), level => error}),
    try
        ?assertEqual(
            {error, {invalid_option, Key}},
            kura_pool_minato:start_pool(Name, maps:merge(?CONFIG, Changed))
        ),
        ?assertEqual([], crash_reports()),
        ?assertEqual([], [Id || {Id, _, _, _} <- supervisor:which_children(minato_sup), Id =:= Name])
    after
        ok = logger:remove_handler(?MODULE),
        _ = kura_pool_minato:stop_pool(Name)
    end.

%% Through kura, which is how an application meets it.
a_repo_with_a_refused_setting_is_told_which_test() ->
    {ok, _} = application:ensure_all_started(kura),
    Repo = kura_postgres_test_repo,
    Config = ?CONFIG,
    ok = application:set_env(kura_postgres, Repo, Config#{
        pool => kura_pool_minato_refused_repo_test,
        pool_module => kura_backend_postgres:pool_module(),
        driver_module => kura_backend_postgres:driver_module(),
        dialect => kura_backend_postgres:dialect(),
        ssl_options => [{verify, verify_peer}]
    }),
    try
        ?assertEqual({error, {invalid_option, ssl_options}}, kura_repo_worker:start(Repo))
    after
        ok = application:unset_env(kura_postgres, Repo),
        kura_db:stop_pool(Repo)
    end.

log(#{msg := {report, #{label := {proc_lib, crash}} = Report}}, #{config := Collector}) ->
    Collector ! {crash_report, Report},
    ok;
log(_Event, _Config) ->
    ok.

crash_reports() ->
    receive
        {crash_report, Report} -> [Report | crash_reports()]
    after 100 -> []
    end.

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

%% Every standard capability in kura_capabilities' documentation, and
%% nothing else.
capabilities_set() ->
    Standard = [
        returning,
        jsonb,
        arrays,
        advisory_locks,
        listen_notify,
        select_for_update_skip_locked,
        row_locks,
        distinct_on,
        cursors,
        partial_indexes,
        concurrent_indexes,
        window_functions,
        full_text_search,
        vector,
        transactions,
        savepoints,
        prepared_statements
    ],
    ?assertEqual(ok, kura_capabilities:require(kura_pool_minato, Standard)),
    ?assertEqual(lists:sort(Standard), lists:sort(kura_pool_minato:capabilities())).

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

run_in_transaction_reports_status() ->
    {ok, Conn, Token} = kura_pool_minato:checkout(?POOL, #{}),
    try
        #{command := 'begin'} = kura_pool_minato:run(Conn, ~"BEGIN", [], #{}),
        ?assertMatch(
            {#{rows := [_]}, transaction},
            kura_pool_minato:run_in_transaction(Conn, ~"SELECT 1", [], #{})
        ),
        ?assertMatch(
            {{error, {pgsql_error, _}}, failed},
            kura_pool_minato:run_in_transaction(Conn, ~"SELECT 1 / 0", [], #{})
        ),
        ?assertMatch(
            {#{command := rollback}, ended},
            kura_pool_minato:run_in_transaction(Conn, ~"ROLLBACK", [], #{})
        )
    after
        ok = kura_pool_minato:checkin(?POOL, Token)
    end.

run_in_transaction_refuses_outside() ->
    {ok, Conn, Token} = kura_pool_minato:checkout(?POOL, #{}),
    try
        ?assertEqual(
            ended,
            kura_pool_minato:run_in_transaction(
                Conn, ~"CREATE TEMP TABLE kura_pool_minato_refused (id integer)", [], #{}
            )
        ),
        #{rows := [Row]} = kura_pool_minato:run(
            Conn, ~"SELECT to_regclass('pg_temp.kura_pool_minato_refused') IS NULL", [], #{}
        ),
        ?assertEqual([true], tuple_to_list(Row))
    after
        ok = kura_pool_minato:checkin(?POOL, Token)
    end.

run_in_transaction_refuses_after_chain() ->
    {ok, Conn, Token} = kura_pool_minato:checkout(?POOL, #{}),
    try
        #{command := 'begin'} = kura_pool_minato:run(Conn, ~"BEGIN", [], #{}),
        ?assertMatch(
            {#{command := commit}, ended},
            kura_pool_minato:run_in_transaction(Conn, ~"COMMIT AND CHAIN", [], #{})
        ),
        ?assertEqual(ended, kura_pool_minato:run_in_transaction(Conn, ~"SELECT 1", [], #{})),
        #{rows := [Row]} = kura_pool_minato:run(
            Conn, ~"SELECT now() = statement_timestamp()", [], #{}
        ),
        ?assertEqual([false], tuple_to_list(Row))
    after
        ok = kura_pool_minato:checkin(?POOL, Token)
    end.

run_in_transaction_stays_refused() ->
    {ok, Conn, Token} = kura_pool_minato:checkout(?POOL, #{}),
    try
        ?assertEqual(ended, kura_pool_minato:run_in_transaction(Conn, ~"SELECT 1", [], #{})),
        #{command := 'begin'} = kura_pool_minato:run(Conn, ~"BEGIN", [], #{}),
        ?assertEqual(ended, kura_pool_minato:run_in_transaction(Conn, ~"SELECT 1", [], #{}))
    after
        ok = kura_pool_minato:checkin(?POOL, Token)
    end.

run_in_transaction_tells_rollbacks_apart() ->
    {ok, Conn, Token} = kura_pool_minato:checkout(?POOL, #{}),
    try
        ?assertMatch(#{command := 'begin'}, kura_pool_minato:open_transaction(Conn)),
        ?assertMatch(
            {#{command := savepoint}, transaction},
            kura_pool_minato:run_in_transaction(Conn, ~"SAVEPOINT caller", [], #{})
        ),
        ?assertMatch(
            {#{command := rollback}, transaction},
            kura_pool_minato:run_in_transaction(Conn, ~"ROLLBACK TO SAVEPOINT caller", [], #{})
        ),
        ?assertMatch(
            {#{command := rollback}, ended},
            kura_pool_minato:run_in_transaction(Conn, ~"ROLLBACK AND CHAIN", [], #{})
        ),
        ?assertEqual(ended, kura_pool_minato:run_in_transaction(Conn, ~"SELECT 1", [], #{}))
    after
        ok = kura_pool_minato:checkin(?POOL, Token)
    end.

refused_open_transaction() ->
    {ok, Conn, Token} = kura_pool_minato:checkout(?POOL, #{}),
    try
        #{command := 'begin'} = kura_pool_minato:run(Conn, ~"BEGIN", [], #{}),
        {error, {pgsql_error, _}} = kura_pool_minato:run(Conn, ~"SELECT 1 / 0", [], #{}),
        ?assertMatch(
            {error, {pgsql_error, #{code := ~"25P02"}}}, kura_pool_minato:open_transaction(Conn)
        ),
        ?assertMatch(#{command := rollback}, kura_pool_minato:run(Conn, ~"ROLLBACK", [], #{}))
    after
        ok = kura_pool_minato:checkin(?POOL, Token)
    end.

lost_open_transaction_ends_the_holder() ->
    {ok, Conn, Token} = kura_pool_minato:checkout(?POOL, #{}),
    Monitor = erlang:monitor(process, Conn),
    #{rows := [Row]} = kura_pool_minato:run(Conn, ~"SELECT pg_backend_pid()", [], #{}),
    [Backend] = tuple_to_list(Row),
    #{rows := [_]} = kura_pool:with_conn(kura_pool_minato, ?POOL, fun(Other) ->
        kura_pool_minato:run(Other, ~"SELECT pg_terminate_backend($1, 1000)", [Backend], #{})
    end),
    ?assertMatch({error, {socket, _}}, kura_pool_minato:open_transaction(Conn)),
    receive
        {'DOWN', Monitor, process, Conn, _} -> ok
    after 2000 -> error(holder_still_running)
    end,
    ?assertEqual(ok, kura_pool_minato:checkin(?POOL, Token)),
    ?assertEqual(ok, wait_for_ready(?POOL, 2000)).

lost_run_in_transaction_ends_the_holder() ->
    {ok, Conn, Token} = kura_pool_minato:checkout(?POOL, #{}),
    Monitor = erlang:monitor(process, Conn),
    #{command := 'begin'} = kura_pool_minato:open_transaction(Conn),
    {#{command := savepoint}, transaction} =
        kura_pool_minato:run_in_transaction(Conn, ~"SAVEPOINT caller", [], #{}),
    #{rows := [Row]} = kura_pool_minato:run(Conn, ~"SELECT pg_backend_pid()", [], #{}),
    [Backend] = tuple_to_list(Row),
    #{rows := [_]} = kura_pool:with_conn(kura_pool_minato, ?POOL, fun(Other) ->
        kura_pool_minato:run(Other, ~"SELECT pg_terminate_backend($1, 1000)", [Backend], #{})
    end),
    ?assertMatch(
        {{error, _}, unknown},
        kura_pool_minato:run_in_transaction(Conn, ~"ROLLBACK TO SAVEPOINT caller", [], #{})
    ),
    receive
        {'DOWN', Monitor, process, Conn, _} -> ok
    after 2000 -> error(holder_still_running)
    end,
    ?assertEqual(ok, kura_pool_minato:checkin(?POOL, Token)),
    ?assertEqual(ok, wait_for_ready(?POOL, 2000)).

refused_marker_read_ends() ->
    {ok, Conn} = minato_pool:checkout(?POOL, 5000),
    {ok, _Began, Begun} = minato_query:query(Conn, ~"BEGIN", []),
    {error, {pgsql_error, _}, Failed} = minato_query:query(Begun, ~"SELECT 1 / 0", []),
    {ended, Next} = kura_pool_minato:marked(Failed, #{}),
    ok = minato_pool:discard(?POOL, Next).

lost_marker_read_is_a_connection_error() ->
    {ok, Conn} = minato_pool:checkout(?POOL, 5000),
    ok = minato_conn:close(Conn),
    ?assertMatch({lost, {error, _}}, kura_pool_minato:marked(Conn, #{})),
    ok = minato_pool:discard(?POOL, Conn).

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

start_pool_reports_already_started() ->
    Running = whereis_pool(?POOL),
    ?assertEqual(
        {error, {already_started, Running}}, kura_pool_minato:start_pool(?POOL, ?CONFIG)
    ).

%% Two repos naming one pool: the second start must not look like a pool
%% started with its own settings.
second_start_keeps_the_running_pool() ->
    Running = whereis_pool(?POOL),
    Other = ?CONFIG,
    ?assertEqual(
        {error, {already_started, Running}},
        kura_pool_minato:start_pool(?POOL, Other#{user => "someone_else", password => "other"})
    ),
    ?assertEqual(Running, whereis_pool(?POOL)),
    {ok, _Conn, Token} = kura_pool_minato:checkout(?POOL, #{timeout => 1000}),
    ok = kura_pool_minato:checkin(?POOL, Token).

whereis_pool(Name) ->
    [Pid] = [Pid || {Id, Pid, _, _} <- supervisor:which_children(minato_sup), Id =:= Name],
    Pid.

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
