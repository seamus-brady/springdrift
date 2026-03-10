-module(springdrift_test_ffi).
-export([script_new/1, script_pop/1]).

%% Create a new scripted response queue.
%% Spawns a process that holds the response list in its mailbox-free state.
%% Returns the pid which acts as a handle.
script_new(Responses) ->
    spawn(fun() -> script_loop(Responses) end).

%% Pop the next response from the queue.
%% Returns {ok, Response} or {error, nil} when exhausted.
script_pop(Pid) ->
    Ref = make_ref(),
    Pid ! {pop, self(), Ref},
    receive
        {Ref, {ok, Response}} -> {ok, Response};
        {Ref, exhausted} -> {error, nil}
    after 5000 ->
        {error, nil}
    end.

script_loop(Responses) ->
    receive
        {pop, From, Ref} ->
            case Responses of
                [H | T] ->
                    From ! {Ref, {ok, H}},
                    script_loop(T);
                [] ->
                    From ! {Ref, exhausted},
                    script_loop([])
            end
    end.
