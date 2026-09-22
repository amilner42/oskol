%% The one thing src/oskol/puzzles.gleam cannot do in Gleam: hash a string.
%%
%% A puzzle's key is the sha256 of its canonical question, so the same
%% position asked the same way is the same puzzle whoever reached it, and
%% its id is read off the same digest. Both are pure functions of the text.
-module(oskol_puzzles_ffi).

-export([sha256/1]).

sha256(Text) -> crypto:hash(sha256, Text).
