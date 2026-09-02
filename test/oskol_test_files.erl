%% File access for Gleam tests (golden fixtures). Gleam's stdlib has no file
%% IO on purpose; this is the only place tests touch the filesystem.
-module(oskol_test_files).
-export([list/1, read/1]).

list(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} -> {ok, [list_to_binary(N) || N <- lists:sort(Names)]};
        {error, Reason} -> {error, Reason}
    end.

read(Path) ->
    file:read_file(Path).
