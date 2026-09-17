%% The Gleam suite, run across every core this machine has.
%%
%% gleeunit hands eunit a flat list of modules, so eunit runs them one after
%% another on one scheduler: seven minutes of the eight a check used to take,
%% while nine cores sat idle. The work is pure -- random positions, oracle
%% comparisons, seeded playouts, golden replays -- so nothing about it needs
%% to be serial.
%%
%% This runner finds the same test functions gleeunit would (any zero-arity
%% function whose name ends in `_test`, in any module under test/) and hands
%% eunit the whole list wrapped in `inparallel`, which spawns one process per
%% test. The reporting is gleeunit's own, so the output reads as it always
%% did; with tests running at once the dots arrive out of order, which is the
%% only visible difference.
-module(oskol_runner).
-export([run/0]).

run() ->
    Tests = [{M, F} || M <- modules(), F <- test_functions(M)],
    %% One worker per scheduler, each running its share in order. Handing
    %% eunit all four hundred tests at once instead starves the long ones:
    %% they share the cores with everything else and time out.
    Workers = erlang:system_info(schedulers_online),
    Groups = [{inorder, Share} || Share <- deal(Tests, Workers), Share =/= []],
    Options = [
        no_tty,
        {report, {gleeunit_progress, [{colored, true}]}},
        %% A few of these tests take minutes on purpose, and eunit's default
        %% patience is five seconds.
        {scale_timeouts, 30}
    ],
    case eunit:test({inparallel, Groups}, Options) of
        ok -> erlang:halt(0);
        _ -> erlang:halt(1)
    end.

%% Deal the tests round the workers like cards, so the slow ones land in
%% different hands rather than all in one.
deal(Tests, Workers) ->
    Indexed = lists:zip(lists:seq(0, length(Tests) - 1), Tests),
    [[T || {I, T} <- Indexed, I rem Workers =:= W] || W <- lists:seq(0, Workers - 1)].

%% Every module compiled from test/, named as Gleam names them: a directory
%% separator becomes `@`.
modules() ->
    Files = filelib:wildcard("**/*.{erl,gleam}", "test"),
    [module_name(F) || F <- Files].

module_name(Path) ->
    Base = filename:rootname(Path),
    list_to_atom(lists:flatten(string:replace(Base, "/", "@", all))).

test_functions(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            [F || {F, 0} <- Module:module_info(exports), is_test_name(F)];
        _ ->
            []
    end.

is_test_name(Name) ->
    lists:suffix("_test", atom_to_list(Name)).
