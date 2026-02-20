-module(springdrift_ffi).
-export([read_line/0, get_env/1, get_args/0, read_char/0,
         start_spinner/1, stop_spinner/0]).

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

%% Read exactly one byte from stdin (blocking). Works after enter_raw().
read_char() ->
    case io:get_chars("", 1) of
        eof                       -> {error, nil};
        Data when is_binary(Data) -> {ok, Data};
        Data when is_list(Data)   -> {ok, list_to_binary(Data)};
        _                         -> {error, nil}
    end.
