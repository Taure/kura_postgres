-module(kura_postgres_constraint_tests).
-moduledoc """
The field a constraint PostgreSQL refuses a row on is reported on, through
`kura_repo_worker:insert/2`, for the names the server generates.
""".
-include_lib("eunit/include/eunit.hrl").
-include_lib("kura/include/kura.hrl").

-export([told/4]).

-define(REPO, kura_postgres_test_repo).
-define(SCHEMA, kura_test_order_line_schema).

%% kura 2.30 neither writes a renamed column nor resolves a constraint by its
%% column, so these run on the releases after it. kura_capabilities:check/2
%% arrived with them.
constraint_field_test_() ->
    case lists:member({check, 2}, kura_capabilities:module_info(exports)) of
        true ->
            {setup, fun setup/0, fun teardown/1, fun(_) ->
                {foreach, fun emptied/0, fun(_) -> ok end, [
                    {"a renamed column is read into its field", fun renamed_column_is_read/0},
                    {"a unique violation on a renamed column", fun unique_on_a_renamed_column/0},
                    {"a duplicate key", fun duplicate_key/0},
                    {"a missing value in a renamed column", fun not_null_on_a_renamed_column/0},
                    {"a check violation", fun check_on_a_column/0},
                    {"a foreign key violation on a renamed column",
                        fun foreign_key_on_a_renamed_column/0},
                    {"a constraint with a name of its own", fun named_constraint/0},
                    {"telemetry is told the error's code and names, not its detail",
                        fun telemetry_keeps_the_names/0}
                ]}
            end};
        false ->
            []
    end.

%% No atom is named after the column: the driver hands the row over keyed by
%% the column's name as a binary, and the field is the schema's to find.
renamed_column_is_read() ->
    ?assertMatch({ok, #{id := 1, title := ~"a"}}, inserted(#{id => 1, title => ~"a"})).

unique_on_a_renamed_column() ->
    {ok, _} = inserted(#{id => 1, title => ~"a"}),
    ?assertEqual([{title, ~"has already been taken"}], refused(#{id => 2, title => ~"a"})).

duplicate_key() ->
    {ok, _} = inserted(#{id => 1, title => ~"a"}),
    ?assertEqual([{id, ~"has already been taken"}], refused(#{id => 1, title => ~"b"})).

not_null_on_a_renamed_column() ->
    ?assertEqual([{title, ~"can't be blank"}], refused(#{id => 1})).

check_on_a_column() ->
    ?assertEqual([{quantity, ~"is invalid"}], refused(#{id => 1, title => ~"a", quantity => 0})).

foreign_key_on_a_renamed_column() ->
    ?assertEqual([{parent, ~"does not exist"}], refused(#{id => 1, title => ~"a", parent => 7})).

named_constraint() ->
    {ok, _} = inserted(#{id => 1, title => ~"a", quantity => 3, parent => 1}),
    ?assertEqual(
        [{base, ~"has already been taken"}],
        refused(#{id => 2, title => ~"b", quantity => 3, parent => 1})
    ).

%% The server's detail for this error quotes the value: Key (item_title)=(a).
telemetry_keeps_the_names() ->
    {ok, _} = inserted(#{id => 1, title => ~"a"}),
    ok = telemetry:attach(?MODULE, [kura, repo, query], fun ?MODULE:told/4, self()),
    try
        _ = refused(#{id => 2, title => ~"a"})
    after
        telemetry:detach(?MODULE)
    end,
    Table = ?SCHEMA:table(),
    Constraint = <<Table/binary, "_item_title_key">>,
    receive
        {query_error, Reason} ->
            ?assertEqual(
                {pgsql_error, #{
                    code => ~"23505",
                    severity => ~"ERROR",
                    schema => ~"public",
                    table => Table,
                    constraint => Constraint
                }},
                Reason
            )
    after 1000 -> error(no_query_error_event)
    end.

told(_Event, _Measurements, #{result := error, error_reason := Reason}, Collector) ->
    Collector ! {query_error, Reason};
told(_Event, _Measurements, _Metadata, _Collector) ->
    ok.

%%----------------------------------------------------------------------
%% Fixture
%%----------------------------------------------------------------------

setup() ->
    ok = ?REPO:start(),
    Table = ?SCHEMA:table(),
    {ok, _} = kura_repo_worker:query(?REPO, [~"DROP TABLE IF EXISTS ", Table], []),
    {ok, _} = kura_repo_worker:query(
        ?REPO,
        [
            ~"CREATE TABLE ",
            Table,
            ~" (id integer PRIMARY KEY, item_title text NOT NULL UNIQUE, ",
            ~"quantity integer CHECK (quantity > 0), parent_line_id integer REFERENCES ",
            Table,
            ~" (id), CONSTRAINT one_quantity_per_parent UNIQUE (parent_line_id, quantity))"
        ],
        []
    ),
    ok.

teardown(_) ->
    {ok, _} = kura_repo_worker:query(?REPO, [~"DROP TABLE IF EXISTS ", ?SCHEMA:table()], []),
    ?REPO:stop().

emptied() ->
    {ok, _} = kura_repo_worker:query(?REPO, [~"TRUNCATE ", ?SCHEMA:table()], []),
    ok.

inserted(Params) ->
    kura_repo_worker:insert(?REPO, kura_changeset:cast(?SCHEMA, #{}, Params, maps:keys(Params))).

refused(Params) ->
    {error, #kura_changeset{errors = Errors}} = inserted(Params),
    Errors.
