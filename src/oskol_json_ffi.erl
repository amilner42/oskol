%% Raw JSON, for src/oskol/core/raw.gleam.
%%
%% gleam_json's Json value is iodata on the Erlang target, so a string that
%% is already valid JSON is already a Json: `raw/1` is the identity, and it
%% is only ever handed text Postgres has round-tripped through jsonb.
%% `encode/1` goes the other way, turning decoded JSON data back into text.
-module(oskol_json_ffi).

-export([raw/1, encode/1]).

raw(Text) -> Text.

encode(Value) -> iolist_to_binary(json:encode(Value)).
