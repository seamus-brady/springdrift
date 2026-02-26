-module(springdrift_ffi).
-export([read_line/0, get_env/1, get_args/0, read_char/0,
         start_spinner/1, stop_spinner/0,
         generate_uuid/0, get_datetime/0, get_date/0,
         tui_run/2, throw_tui_exit/0,
         fetch_url/1, check_docker/0, docker_build/1,
         docker_run_container/3, docker_exec/2, docker_stop/1,
         docker_logs/2, docker_cp/2]).

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

%% Run LoopFun; always run CleanupFun before returning, even on exception.
tui_run(LoopFun, CleanupFun) ->
    try LoopFun()
    catch
        throw:tui_exit -> ok;
        _Class:_Reason -> ok
    after
        CleanupFun()
    end,
    nil.

%% Throw the tui_exit atom so tui_run can catch it cleanly.
throw_tui_exit() ->
    throw(tui_exit).

%% Read exactly one byte from stdin (blocking). Works after enter_raw().
read_char() ->
    case io:get_chars("", 1) of
        eof                       -> {error, nil};
        Data when is_binary(Data) -> {ok, Data};
        Data when is_list(Data)   -> {ok, list_to_binary(Data)};
        _                         -> {error, nil}
    end.

%% Fetch a URL via HTTP GET. Returns {ok, Body} or {error, Reason}.
%% Body is truncated to 50 KB to avoid flooding context.
fetch_url(Url) ->
    application:ensure_all_started(inets),
    application:ensure_all_started(ssl),
    Opts = [{timeout, 10000}],
    UrlStr = case is_binary(Url) of
        true  -> binary_to_list(Url);
        false -> Url
    end,
    case httpc:request(get, {UrlStr, []}, Opts, [{body_format, binary}]) of
        {ok, {{_, _, _}, _, Body}} ->
            Truncated = binary:part(Body, 0, min(byte_size(Body), 51200)),
            {ok, Truncated};
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Check whether Docker daemon is reachable. Returns true or false.
check_docker() ->
    case os:find_executable("docker") of
        false -> false;
        _Path ->
            Out = os:cmd("docker info 2>&1"),
            not lists:prefix("Cannot connect", Out) andalso
            not lists:prefix("Error", Out) andalso
            string:str(Out, "Server Version") > 0
    end.

%% Build the springdrift-sandbox Docker image from ContextDir.
%% Returns {ok, nil} or {error, Reason}.
docker_build(ContextDir) ->
    Dir = case is_binary(ContextDir) of
        true  -> binary_to_list(ContextDir);
        false -> ContextDir
    end,
    Cmd = "docker build -t springdrift-sandbox:latest " ++ Dir ++ " 2>&1",
    Out = os:cmd(Cmd),
    %% docker build exits 0 on success; os:cmd doesn't give exit code,
    %% so we check for known success/failure markers.
    case string:str(Out, "Successfully built") > 0 orelse
         string:str(Out, "naming to docker.io") > 0 orelse
         string:str(Out, "FINISHED") > 0 of
        true  -> {ok, nil};
        false ->
            %% Also accept if the image already exists (no rebuild needed).
            CheckCmd = "docker image inspect springdrift-sandbox:latest 2>&1",
            CheckOut = os:cmd(CheckCmd),
            case string:str(CheckOut, "\"Id\"") > 0 of
                true  -> {ok, nil};
                false -> {error, list_to_binary(Out)}
            end
    end.

%% Start a detached sandbox container with the project directory mounted.
%% Ports is a list of integers; each is exposed as -p N:N.
%% Returns {ok, ContainerId} or {error, Reason}.
docker_run_container(Image, Cwd, Ports) ->
    ImageStr = case is_binary(Image) of
        true  -> binary_to_list(Image);
        false -> Image
    end,
    CwdStr = case is_binary(Cwd) of
        true  -> binary_to_list(Cwd);
        false -> Cwd
    end,
    PortArgs = lists:foldl(fun(P, Acc) ->
        Acc ++ " -p " ++ integer_to_list(P) ++ ":" ++ integer_to_list(P)
    end, "", Ports),
    Uuid = binary_to_list(generate_uuid()),
    Name = "springdrift-sandbox-" ++ Uuid,
    Cmd = "docker run -d --name " ++ Name ++
          PortArgs ++
          " --mount type=bind,src=" ++ CwdStr ++ ",dst=/workspace,readonly" ++
          " --tmpfs /tmp:rw,size=256m,noexec" ++
          " --memory 512m --cpus 1.0" ++
          " --cap-drop ALL --security-opt no-new-privileges" ++
          " --network bridge" ++
          " " ++ ImageStr ++ " sleep infinity 2>&1",
    Out = string:trim(os:cmd(Cmd)),
    %% On success, docker run -d prints the container ID (64 hex chars)
    case length(Out) >= 12 andalso string:str(Out, " ") =:= 0 of
        true  -> {ok, list_to_binary(Out)};
        false -> {error, list_to_binary(Out)}
    end.

%% Retrieve the last N lines of container logs.
%% Returns {ok, Output} or {error, Reason}. Output truncated to 8 KB.
docker_logs(ContainerId, Lines) ->
    IdStr = case is_binary(ContainerId) of
        true  -> binary_to_list(ContainerId);
        false -> ContainerId
    end,
    LinesStr = integer_to_list(Lines),
    Cmd = "docker logs --tail " ++ LinesStr ++ " " ++ IdStr ++ " 2>&1",
    RawOut = os:cmd(Cmd),
    Out = list_to_binary(RawOut),
    Truncated = binary:part(Out, 0, min(byte_size(Out), 8192)),
    case byte_size(Truncated) of
        0 -> {ok, <<"(no output)">>};
        _ -> {ok, Truncated}
    end.

%% Run a command inside the container. Returns {ok, Output} or {error, Output}.
%% Output is truncated to 16 KB.
docker_exec(ContainerId, Cmd) ->
    IdStr = case is_binary(ContainerId) of
        true  -> binary_to_list(ContainerId);
        false -> ContainerId
    end,
    CmdStr = case is_binary(Cmd) of
        true  -> binary_to_list(Cmd);
        false -> Cmd
    end,
    %% Escape single quotes in the command
    Escaped = re:replace(CmdStr, "'", "'\\\\''", [global, {return, list}]),
    FullCmd = "docker exec " ++ IdStr ++ " bash -c '" ++ Escaped ++ "' 2>&1; echo \"__EXIT:$?\"",
    RawOut = os:cmd(FullCmd),
    %% Parse exit code from sentinel
    case re:run(RawOut, "__EXIT:(\\d+)", [{capture, all_but_first, list}]) of
        {match, [CodeStr]} ->
            Code = list_to_integer(CodeStr),
            %% Strip sentinel from output
            Output0 = re:replace(RawOut, "\n?__EXIT:\\d+\n?$", "", [{return, list}]),
            Output1 = list_to_binary(Output0),
            Truncated = binary:part(Output1, 0, min(byte_size(Output1), 16384)),
            case Code of
                0 -> {ok, Truncated};
                _ -> {error, Truncated}
            end;
        nomatch ->
            Out = list_to_binary(RawOut),
            Truncated = binary:part(Out, 0, min(byte_size(Out), 16384)),
            {error, Truncated}
    end.

%% Copy files between host and container using docker cp.
%% Src and Dst use docker cp syntax: "container:path" or plain host path.
%% Returns {ok, nil} or {error, Reason}.
docker_cp(Src, Dst) ->
    SrcStr = case is_binary(Src) of true -> binary_to_list(Src); false -> Src end,
    DstStr = case is_binary(Dst) of true -> binary_to_list(Dst); false -> Dst end,
    FullCmd = "docker cp " ++ SrcStr ++ " " ++ DstStr ++ " 2>&1; echo \"__EXIT:$?\"",
    RawOut = os:cmd(FullCmd),
    case re:run(RawOut, "__EXIT:(\\d+)", [{capture, all_but_first, list}]) of
        {match, [CodeStr]} ->
            Code = list_to_integer(CodeStr),
            Output0 = re:replace(RawOut, "\n?__EXIT:\\d+\n?$", "", [{return, list}]),
            case Code of
                0 -> {ok, nil};
                _ -> {error, list_to_binary(string:trim(Output0))}
            end;
        nomatch ->
            {error, list_to_binary(string:trim(RawOut))}
    end.

%% Stop and remove the container.
docker_stop(ContainerId) ->
    IdStr = case is_binary(ContainerId) of
        true  -> binary_to_list(ContainerId);
        false -> ContainerId
    end,
    os:cmd("docker stop " ++ IdStr ++ " 2>&1"),
    os:cmd("docker rm " ++ IdStr ++ " 2>&1"),
    nil.
