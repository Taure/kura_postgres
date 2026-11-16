-module(kura_test_order_line_schema).
-moduledoc "A table whose name has several words, with two renamed columns.".
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0]).

%% Each OS process gets its own table, so test runs sharing the database
%% cannot drop or truncate each other's.
table() ->
    iolist_to_binary([~"kura_order_line_items_", os:getpid()]).

fields() ->
    [
        #kura_field{name = id, type = integer, primary_key = true, nullable = false},
        #kura_field{name = title, type = text, nullable = false, column = ~"item_title"},
        #kura_field{name = quantity, type = integer},
        #kura_field{name = parent, type = integer, column = ~"parent_line_id"}
    ].
