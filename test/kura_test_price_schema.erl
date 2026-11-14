-module(kura_test_price_schema).
-moduledoc "A table with a `decimal` column.".
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0]).

table() ->
    iolist_to_binary([~"kura_prices_", os:getpid()]).

fields() ->
    [
        #kura_field{name = id, type = integer, primary_key = true, nullable = false},
        #kura_field{name = amount, type = decimal}
    ].
