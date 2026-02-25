-module(springdrift_ffi).
-export([read_line/0, get_env/1, get_args/0, read_char/0,
         start_spinner/1, stop_spinner/0,
         generate_uuid/0, get_datetime/0, get_date/0]).

%% Read one line from stdin.
%% Returns {ok, Binary} (including trailing newline) or {error, nil} on EOF.
read_line() ->
    case io:get_line("") of
        eof             -> {error, nil};
        {error, _}      -> {error, nil};
        Data when is_list(Data)   -> {ok, unicode:characters_to_binary(Data)};
        Data when is_binary(Data) -> {ok, Data}
    end.

%% Read an environment variable by name.
%% Returns {ok, Binary} if set, or {error, nil} if not set.
get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, list_to_binary(Value)}
    end.

%% Return command-line arguments passed to the application (after -- in gleam run).
%% Returns a list of binaries.
get_args() ->
    Args = init:get_plain_arguments(),
    [unicode:characters_to_binary(A) || A <- Args].

%% Spawn an animated spinner at one or more {Row, Col} positions (0-indexed).
%% Cycles braille frames every 80 ms until stop_spinner/0 is called.
start_spinner(Positions) ->
    catch unregister(springdrift_spinner),
    Frames = [<<16#280B/utf8>>, <<16#2819/utf8>>, <<16#2839/utf8>>,
              <<16#2838/utf8>>, <<16#283C/utf8>>, <<16#2834/utf8>>,
              <<16#2826/utf8>>, <<16#2827/utf8>>, <<16#2807/utf8>>,
              <<16#280F/utf8>>],
    Pid = spawn(fun() -> spinner_loop(Positions, Frames, 0) end),
    register(springdrift_spinner, Pid),
    nil.

spinner_loop(Positions, Frames, I) ->
    receive
        stop -> ok
    after 80 ->
        Frame = lists:nth((I rem length(Frames)) + 1, Frames),
        lists:foreach(fun({Row, Col}) ->
            Ansi = [<<"\e[">>, integer_to_binary(Row + 1), <<";">>,
                    integer_to_binary(Col + 1), <<"H">>, Frame],
            io:put_chars(Ansi)
        end, Positions),
        spinner_loop(Positions, Frames, I + 1)
    end.

%% Stop the spinner and block until its process has exited.
stop_spinner() ->
    case whereis(springdrift_spinner) of
        undefined -> nil;
        Pid ->
            MRef = erlang:monitor(process, Pid),
            Pid ! stop,
            receive
                {'DOWN', MRef, process, Pid, _} -> nil
            after 500 ->
                erlang:demonitor(MRef, [flush]),
                nil
            end
    end.

%% Generate a UUID v4 string, e.g. "550e8400-e29b-41d4-a716-446655440000".
generate_uuid() ->
    <<A:32, B:16, _:4, C:12, _:2, YBits:2, D:12, E:48>> = crypto:strong_rand_bytes(16),
    Y = 8 + YBits,
    Hex = fun(N, W) ->
        S = string:to_lower(integer_to_list(N, 16)),
        string:right(S, W, $0)
    end,
    iolist_to_binary([Hex(A,8), $-, Hex(B,4), $-, $4, Hex(C,3), $-, Hex(Y,1), Hex(D,3), $-, Hex(E,12)]).

%% Return ISO 8601 local datetime, e.g. "2026-02-24T14:30:00".
get_datetime() ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:local_time(),
    Pad = fun(N, W) -> string:right(integer_to_list(N), W, $0) end,
    iolist_to_binary([Pad(Y,4), $-, Pad(Mo,2), $-, Pad(D,2), $T,
                      Pad(H,2), $:, Pad(Mi,2), $:, Pad(S,2)]).

%% Return the local date as a string, e.g. "2026-02-24".
get_date() ->
    {{Y, Mo, D}, _} = calendar:local_time(),
    Pad = fun(N, W) -> string:right(integer_to_list(N), W, $0) end,
    iolist_to_binary([Pad(Y,4), $-, Pad(Mo,2), $-, Pad(D,2)]).

%% Read exactly one byte from stdin (blocking). Works after enter_raw().
read_char() ->
    case io:get_chars("", 1) of
        eof                       -> {error, nil};
        Data when is_binary(Data) -> {ok, Data};
        Data when is_list(Data)   -> {ok, list_to_binary(Data)};
        _                         -> {error, nil}
    end.
