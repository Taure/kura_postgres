-module(kura_test_capability_schema).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0]).

%% Each OS process gets its own table, so test runs sharing the database
%% cannot drop or truncate each other's.
table() ->
    iolist_to_binary([~"kura_capabilities_", os:getpid()]).

fields() ->
    [
        #kura_field{name = id, type = integer, primary_key = true, nullable = false},
        #kura_field{name = name, type = text},
        #kura_field{name = doc, type = jsonb},
        #kura_field{name = tags, type = {array, string}},
        #kura_field{name = embedding, type = {vector, 3}}
    ].
