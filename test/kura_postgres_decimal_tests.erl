-module(kura_postgres_decimal_tests).
-moduledoc """
What a `numeric` column is read as: a float through a schema, the exact text
when the caller of the driver asks for it.
""".
-include_lib("eunit/include/eunit.hrl").

-define(REPO, kura_postgres_test_repo).
-define(SCHEMA, kura_test_price_schema).
-define(LONG, ~"12345678901234567.89").

decimal_test_() ->
    {setup, fun setup/0, fun teardown/1, fun(_) ->
        {foreach, fun emptied/0, fun(_) -> ok end, [
            {"a decimal written through a schema is read back as it was written",
                fun written_and_read/0},
            {"a schema reads a decimal as a float, which rounds a long one",
                fun a_long_one_is_rounded/0},
            {"the driver hands a numeric over as exact text when asked", fun exact_when_asked/0},
            {"an aggregate over a decimal is a float", fun aggregate_is_a_float/0}
            | kept_by_kura()
        ]}
    end}.

%% kura 2.30 turns numeric text into a float in kura_types:load/2. The
%% releases after it keep it, and kura_capabilities:check/2 arrived with them.
kept_by_kura() ->
    case lists:member({check, 2}, kura_capabilities:module_info(exports)) of
        true -> [{"kura keeps the exact text of a decimal", fun kura_keeps_the_text/0}];
        false -> []
    end.

written_and_read() ->
    Params = #{id => 1, amount => 1.25},
    ?assertMatch(
        {ok, #{amount := 1.25}},
        kura_repo_worker:insert(
            ?REPO, kura_changeset:cast(?SCHEMA, #{}, Params, maps:keys(Params))
        )
    ),
    ?assertMatch({ok, #{amount := 1.25}}, kura_repo_worker:get(?REPO, ?SCHEMA, 1)).

a_long_one_is_rounded() ->
    stored(?LONG),
    {ok, #{amount := Amount}} = kura_repo_worker:get(?REPO, ?SCHEMA, 1),
    ?assertEqual(binary_to_float(?LONG), Amount),
    ?assertNotEqual(?LONG, float_to_binary(Amount, [{decimals, 2}])).

exact_when_asked() ->
    stored(?LONG),
    ?assertEqual(?LONG, asked_for_as_text()).

aggregate_is_a_float() ->
    stored(~"1.25"),
    {ok, [#{avg := Average}]} = kura_repo_worker:query(
        ?REPO, [~"SELECT avg(amount) AS avg FROM ", ?SCHEMA:table()], []
    ),
    ?assertEqual(1.25, Average).

kura_keeps_the_text() ->
    stored(?LONG),
    ?assertEqual({ok, ?LONG}, kura_types:load(decimal, asked_for_as_text())).

%%----------------------------------------------------------------------
%% Fixture
%%----------------------------------------------------------------------

setup() ->
    ok = ?REPO:start(),
    Table = ?SCHEMA:table(),
    {ok, _} = kura_repo_worker:query(?REPO, [~"DROP TABLE IF EXISTS ", Table], []),
    {ok, _} = kura_repo_worker:query(
        ?REPO, [~"CREATE TABLE ", Table, ~" (id integer PRIMARY KEY, amount numeric)"], []
    ),
    ok.

teardown(_) ->
    {ok, _} = kura_repo_worker:query(?REPO, [~"DROP TABLE IF EXISTS ", ?SCHEMA:table()], []),
    ?REPO:stop().

emptied() ->
    {ok, _} = kura_repo_worker:query(?REPO, [~"TRUNCATE ", ?SCHEMA:table()], []),
    ok.

stored(Text) ->
    {ok, _} = kura_repo_worker:query(
        ?REPO, [~"INSERT INTO ", ?SCHEMA:table(), ~" (id, amount) VALUES (1, ", Text, ~")"], []
    ),
    ok.

asked_for_as_text() ->
    #{rows := [#{amount := Amount}]} = kura_driver_minato:query(
        kura_pool_minato,
        ?REPO,
        [~"SELECT amount FROM ", ?SCHEMA:table()],
        [],
        #{numeric_format => binary}
    ),
    Amount.
