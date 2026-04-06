%% Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
%%
%% This program is free software: you can redistribute it and/or modify
%% it under the terms of the GNU Affero General Public License as published
%% by the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.

-module(springdrift_ffi).
-export([read_line/0, get_env/1, get_args/0, read_char/0,
         start_spinner/1, stop_spinner/0,
         generate_uuid/0, get_datetime/0, get_date/0,
         tui_run/2, throw_tui_exit/0,
         fetch_url/1, http_post/3,
         rescue/1, sha256_hex/1,
         log_init/1, log_stdout_enabled/0, log_stderr/1,
         monotonic_now_ms/0, file_rename/2, sanitize_json/1,
         resolve_symlinks/1,
         file_size/1, days_ago_date/1,
         uri_encode/1, extract_ddg_results/1,
         http_get/1, http_get_with_headers/2,
         ensure_utf8/1, days_between/2,
         mailbox_size/0, add_days/2,
         ms_until_datetime/1, advance_datetime_ms/2,
         re_replace_all/3,
         re_match_caseless/2,
         re_is_valid_pattern/1,
         set_env/2,
         run_cmd/3, which/1,
         json_encode_term/1, json_decode_to_string/1,
         identity/1,
         sign_rs256/2, unix_now/0,
         ets_new/1, ets_insert/3, ets_lookup/2,
         count_lines/1]).

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
    Opts = [{timeout, 30000}],
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

%% HTTP POST with headers and JSON body via httpc.
%% Headers is a list of {Name, Value} tuples (binaries).
%% Returns {ok, {StatusCode, Body}} or {error, Reason}.
http_post(Url, Headers, Body) ->
    application:ensure_all_started(inets),
    application:ensure_all_started(ssl),
    UrlStr = case is_binary(Url) of
        true  -> binary_to_list(Url);
        false -> Url
    end,
    BodyStr = case is_binary(Body) of
        true  -> binary_to_list(Body);
        false -> Body
    end,
    %% Extract Content-Type from headers if present, default to application/json
    {ContentType, OtherHeaders} = extract_content_type(Headers),
    HeaderList = [{binary_to_list(K), binary_to_list(V)} || {K, V} <- OtherHeaders],
    Opts = [{timeout, 300000}],
    case httpc:request(post, {UrlStr, HeaderList, ContentType, BodyStr}, Opts, [{body_format, binary}]) of
        {ok, {{_, StatusCode, _}, _, RespBody}} ->
            {ok, {StatusCode, RespBody}};
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.


%% Run a zero-arity function, catching any throw/error/exit.
%% Returns {ok, Result} or {error, Reason}.
rescue(Fun) ->
    try Fun() of
        Result -> {ok, Result}
    catch
        _Class:Reason -> {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% SHA-256 hex digest of a binary string.
sha256_hex(Input) ->
    Hash = crypto:hash(sha256, Input),
    list_to_binary(lists:flatten([io_lib:format("~2.16.0b", [B]) || <<B>> <= Hash])).

%% ---------------------------------------------------------------------------
%% Logger FFI
%% ---------------------------------------------------------------------------

%% Store whether stderr logging is enabled in persistent_term.
log_init(Enabled) ->
    persistent_term:put(springdrift_log_stdout, Enabled).

%% Read the stderr logging flag. Defaults to false if not set.
log_stdout_enabled() ->
    persistent_term:get(springdrift_log_stdout, false).

%% Write a line to stderr (avoids corrupting TUI alternate-screen output).
log_stderr(Text) ->
    io:format(standard_error, "~ts~n", [Text]).

monotonic_now_ms() ->
    erlang:system_time(millisecond).

file_rename(From, To) ->
    case file:rename(From, To) of
        ok -> true;
        {error, _} -> false
    end.

%% Resolve symlinks in a path by following links at each component.
resolve_symlinks(Path) when is_binary(Path) ->
    try
        list_to_binary(resolve_symlinks_str(binary_to_list(Path)))
    catch
        _:_ -> Path
    end.

resolve_symlinks_str(Path) ->
    case file:read_link(Path) of
        {ok, Target} ->
            Abs = case hd(Target) of
                $/ -> Target;
                _ -> filename:join(filename:dirname(Path), Target)
            end,
            resolve_symlinks_str(Abs);
        {error, _} ->
            %% Not a symlink — check if parent needs resolving
            case filename:dirname(Path) of
                Path -> Path;  %% root
                Dir ->
                    ResolvedDir = resolve_symlinks_str(Dir),
                    filename:join(ResolvedDir, filename:basename(Path))
            end
    end.

%% Sanitize JSON by escaping unescaped control characters inside string values.
%% Walks the binary tracking in-string state and escapes literal control chars
%% (newlines, tabs, etc.) that LLMs sometimes produce.
sanitize_json(Bin) when is_binary(Bin) ->
    sanitize_json(Bin, false, false, <<>>).

sanitize_json(<<>>, _InStr, _Esc, Acc) ->
    Acc;
%% Previous char was backslash inside a string — this char is already escaped
sanitize_json(<<C, Rest/binary>>, true, true, Acc) ->
    sanitize_json(Rest, true, false, <<Acc/binary, C>>);
%% Backslash inside a string — mark next char as escaped
sanitize_json(<<$\\, Rest/binary>>, true, false, Acc) ->
    sanitize_json(Rest, true, true, <<Acc/binary, $\\>>);
%% Unescaped quote inside string — end of string
sanitize_json(<<$", Rest/binary>>, true, false, Acc) ->
    sanitize_json(Rest, false, false, <<Acc/binary, $">>);
%% Control chars inside a string that need escaping
sanitize_json(<<$\n, Rest/binary>>, true, false, Acc) ->
    sanitize_json(Rest, true, false, <<Acc/binary, $\\, $n>>);
sanitize_json(<<$\r, Rest/binary>>, true, false, Acc) ->
    sanitize_json(Rest, true, false, <<Acc/binary, $\\, $r>>);
sanitize_json(<<$\t, Rest/binary>>, true, false, Acc) ->
    sanitize_json(Rest, true, false, <<Acc/binary, $\\, $t>>);
%% Other control chars (0x00-0x1F) inside a string — escape as \uXXXX
sanitize_json(<<C, Rest/binary>>, true, false, Acc) when C < 32 ->
    Hex = list_to_binary(io_lib:format("\\u~4.16.0B", [C])),
    sanitize_json(Rest, true, false, <<Acc/binary, Hex/binary>>);
%% Normal char inside a string
sanitize_json(<<C, Rest/binary>>, true, false, Acc) ->
    sanitize_json(Rest, true, false, <<Acc/binary, C>>);
%% Quote outside a string — start of string
sanitize_json(<<$", Rest/binary>>, false, _, Acc) ->
    sanitize_json(Rest, true, false, <<Acc/binary, $">>);
%% Any char outside a string — pass through
sanitize_json(<<C, Rest/binary>>, false, _, Acc) ->
    sanitize_json(Rest, false, false, <<Acc/binary, C>>).

%% Return the size of a file in bytes. Returns 0 if the file does not exist.
file_size(Path) when is_binary(Path) ->
    filelib:file_size(binary_to_list(Path)).

%% Return a date string N days ago, e.g. days_ago_date(30) -> "2026-02-05".
days_ago_date(Days) ->
    {Date, _} = calendar:local_time(),
    GregDays = calendar:date_to_gregorian_days(Date),
    AgoDate = calendar:gregorian_days_to_date(GregDays - Days),
    {Y, Mo, D} = AgoDate,
    Pad = fun(N, W) -> string:right(integer_to_list(N), W, $0) end,
    iolist_to_binary([Pad(Y,4), $-, Pad(Mo,2), $-, Pad(D,2)]).

%% URI-encode a string for use in query parameters.
uri_encode(Bin) when is_binary(Bin) ->
    uri_string:quote(Bin).

%% Extract search results from DuckDuckGo HTML response.
%% Returns a list of {search_result, Title, Url, Snippet} tuples
%% matching the Gleam SearchResult type.
extract_ddg_results(Html) when is_binary(Html) ->
    HtmlStr = binary_to_list(Html),
    %% Find all result__a links and their snippets
    Results = extract_results_loop(HtmlStr, []),
    lists:reverse(Results).

extract_results_loop(Html, Acc) ->
    %% Look for result__a class links
    case string:str(Html, "class=\"result__a\"") of
        0 -> Acc;
        Pos ->
            Rest = lists:nthtail(Pos - 1, Html),
            %% Extract href
            Url = extract_href(Rest),
            %% Extract link text (title)
            Title = extract_tag_text(Rest),
            %% Find snippet
            Snippet = extract_snippet(Rest),
            Result = {search_result,
                      to_binary(Title),
                      to_binary(clean_ddg_url(Url)),
                      to_binary(Snippet)},
            %% Move past this result
            Remaining = case string:str(Rest, "class=\"result__a\"") of
                0 -> [];
                _ ->
                    AfterTag = lists:nthtail(min(length(Rest) - 1, 50), Rest),
                    case string:str(AfterTag, "class=\"result__a\"") of
                        0 -> [];
                        NextPos -> lists:nthtail(NextPos - 1, AfterTag)
                    end
            end,
            case Remaining of
                [] -> [{search_result,
                        to_binary(Title),
                        to_binary(clean_ddg_url(Url)),
                        to_binary(Snippet)} | Acc];
                _ -> extract_results_loop(Remaining, [Result | Acc])
            end
    end.

extract_href(Html) ->
    case string:str(Html, "href=\"") of
        0 -> "";
        Pos ->
            After = lists:nthtail(Pos + 5, Html),
            case string:str(After, "\"") of
                0 -> "";
                EndPos -> lists:sublist(After, EndPos - 1)
            end
    end.

extract_tag_text(Html) ->
    case string:str(Html, ">") of
        0 -> "";
        Pos ->
            After = lists:nthtail(Pos, Html),
            case string:str(After, "<") of
                0 -> "";
                EndPos -> string:strip(lists:sublist(After, EndPos - 1))
            end
    end.

extract_snippet(Html) ->
    case string:str(Html, "class=\"result__snippet\"") of
        0 -> "";
        Pos ->
            After = lists:nthtail(Pos - 1, Html),
            case string:str(After, ">") of
                0 -> "";
                GtPos ->
                    Content = lists:nthtail(GtPos, After),
                    case string:str(Content, "</") of
                        0 -> "";
                        EndPos ->
                            Raw = lists:sublist(Content, EndPos - 1),
                            %% Strip HTML tags from snippet
                            strip_html_tags(Raw)
                    end
            end
    end.

strip_html_tags(Html) ->
    strip_html_tags(Html, [], false).

strip_html_tags([], Acc, _InTag) ->
    string:strip(lists:reverse(Acc));
strip_html_tags([$< | Rest], Acc, false) ->
    strip_html_tags(Rest, Acc, true);
strip_html_tags([$> | Rest], Acc, true) ->
    strip_html_tags(Rest, Acc, false);
strip_html_tags([_C | Rest], Acc, true) ->
    strip_html_tags(Rest, Acc, true);
strip_html_tags([C | Rest], Acc, false) ->
    strip_html_tags(Rest, [C | Acc], false).

%% HTTP GET request via httpc.
%% Returns {ok, {StatusCode, Body}} or {error, Reason}.
http_get(Url) ->
    application:ensure_all_started(inets),
    application:ensure_all_started(ssl),
    UrlStr = case is_binary(Url) of
        true  -> binary_to_list(Url);
        false -> Url
    end,
    Opts = [{timeout, 30000}],
    case httpc:request(get, {UrlStr, []}, Opts, [{body_format, binary}]) of
        {ok, {{_, StatusCode, _}, _, Body}} ->
            {ok, {StatusCode, Body}};
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% HTTP GET request with custom headers via httpc.
%% Headers is a list of {Name, Value} tuples (binaries).
%% Returns {ok, {StatusCode, Body}} or {error, Reason}.
http_get_with_headers(Url, Headers) ->
    application:ensure_all_started(inets),
    application:ensure_all_started(ssl),
    UrlStr = case is_binary(Url) of
        true  -> binary_to_list(Url);
        false -> Url
    end,
    HeaderList = [{binary_to_list(K), binary_to_list(V)} || {K, V} <- Headers],
    Opts = [{timeout, 30000}],
    case httpc:request(get, {UrlStr, HeaderList}, Opts, [{body_format, binary}]) of
        {ok, {{_, StatusCode, _}, _, Body}} ->
            {ok, {StatusCode, Body}};
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Clean DuckDuckGo redirect URLs to extract the actual URL.
%% Convert either a charlist or a binary to a binary safely.
to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_list(V) -> unicode:characters_to_binary(V);
to_binary(V) -> unicode:characters_to_binary(io_lib:format("~p", [V])).

clean_ddg_url(Url) ->
    case string:str(Url, "uddg=") of
        0 -> Url;
        Pos ->
            Encoded = lists:nthtail(Pos + 4, Url),
            case string:str(Encoded, "&") of
                0 -> uri_string:unquote(list_to_binary(Encoded));
                EndPos ->
                    Part = lists:sublist(Encoded, EndPos - 1),
                    uri_string:unquote(list_to_binary(Part))
            end
    end.

%% Ensure a binary is valid UTF-8, replacing invalid bytes with U+FFFD.
ensure_utf8(Bin) when is_binary(Bin) ->
    case unicode:characters_to_binary(Bin) of
        Result when is_binary(Result) -> Result;
        _ ->
            %% Contains invalid sequences — replace byte by byte
            ensure_utf8_loop(Bin, <<>>)
    end.

ensure_utf8_loop(<<>>, Acc) ->
    Acc;
ensure_utf8_loop(<<C/utf8, Rest/binary>>, Acc) ->
    ensure_utf8_loop(Rest, <<Acc/binary, C/utf8>>);
ensure_utf8_loop(<<_, Rest/binary>>, Acc) ->
    %% Replace invalid byte with U+FFFD (replacement character)
    ensure_utf8_loop(Rest, <<Acc/binary, 16#EF, 16#BF, 16#BD>>).

%% Compute exact number of days between two "YYYY-MM-DD" date strings.
%% Returns an integer (positive if DateB is after DateA).
days_between(DateA, DateB) ->
    {YA, MA, DA} = parse_date_bin(DateA),
    {YB, MB, DB} = parse_date_bin(DateB),
    GregA = calendar:date_to_gregorian_days({YA, MA, DA}),
    GregB = calendar:date_to_gregorian_days({YB, MB, DB}),
    GregB - GregA.

parse_date_bin(<<Y:4/binary, $-, M:2/binary, $-, D:2/binary, _/binary>>) ->
    {binary_to_integer(Y), binary_to_integer(M), binary_to_integer(D)};
parse_date_bin(_) ->
    {1970, 1, 1}.

%% Return the current process's mailbox size.
mailbox_size() ->
    {message_queue_len, Len} = erlang:process_info(self(), message_queue_len),
    Len.

%% Add N days to a "YYYY-MM-DD" date string, return new "YYYY-MM-DD" string.
add_days(DateBin, Days) ->
    {Y, M, D} = parse_date_bin(DateBin),
    Greg = calendar:date_to_gregorian_days({Y, M, D}),
    {NY, NM, ND} = calendar:gregorian_days_to_date(Greg + Days),
    iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0B", [NY, NM, ND])).

%% Milliseconds from now until an ISO 8601 local-time datetime string.
%% Returns negative if the datetime is in the past.
ms_until_datetime(IsoStr) when is_binary(IsoStr) ->
    {Y, Mo, D, H, Mi, S} = parse_datetime_bin(IsoStr),
    Target = calendar:datetime_to_gregorian_seconds({{Y,Mo,D},{H,Mi,S}}),
    Now = calendar:datetime_to_gregorian_seconds(calendar:local_time()),
    (Target - Now) * 1000.

%% Add N milliseconds to an ISO 8601 local-time datetime string.
%% Returns a new ISO 8601 datetime string.
advance_datetime_ms(IsoStr, Ms) when is_binary(IsoStr), is_integer(Ms) ->
    {Y, Mo, D, H, Mi, S} = parse_datetime_bin(IsoStr),
    Base = calendar:datetime_to_gregorian_seconds({{Y,Mo,D},{H,Mi,S}}),
    {{NY,NMo,ND},{NH,NMi,NS}} =
        calendar:gregorian_seconds_to_datetime(Base + (Ms div 1000)),
    Pad = fun(N, W) -> string:right(integer_to_list(N), W, $0) end,
    iolist_to_binary([Pad(NY,4),$-,Pad(NMo,2),$-,Pad(ND,2),$T,
                      Pad(NH,2),$:,Pad(NMi,2),$:,Pad(NS,2)]).

%% Parse an ISO 8601 datetime binary like "2026-03-17T14:30:00" into a 6-tuple.
parse_datetime_bin(Bin) ->
    BinStr = binary_to_list(Bin),
    case string:split(BinStr, "T") of
        [DatePart, TimePart] ->
            [Y, Mo, D] = [list_to_integer(X) || X <- string:split(DatePart, "-", all)],
            [H, Mi, S] = [list_to_integer(X) || X <- string:split(TimePart, ":", all)],
            {Y, Mo, D, H, Mi, S};
        _ ->
            %% Fallback: treat as date only (midnight)
            {Y, Mo, D} = parse_date_bin(Bin),
            {Y, Mo, D, 0, 0, 0}
    end.

%% Replace all matches of a regex pattern in text.
%% Subject-first convention matching existing FFI style.
re_replace_all(Text, Pattern, Replacement) when is_binary(Text), is_binary(Pattern), is_binary(Replacement) ->
    case re:compile(Pattern) of
        {ok, MP} ->
            re:replace(Text, MP, Replacement, [global, {return, binary}]);
        {error, _} ->
            Text
    end.

%% Set an environment variable (converts Gleam binaries to charlists for os:putenv).
set_env(Name, Value) when is_binary(Name), is_binary(Value) ->
    os:putenv(binary_to_list(Name), binary_to_list(Value)),
    nil.

%% Run a command with arguments and a timeout.
%% Returns {ok, {ExitCode, Stdout, Stderr}} or {error, Reason}.
%% Uses /bin/sh -c to get proper stderr separation via redirect.
run_cmd(Cmd, Args, TimeoutMs) when is_binary(Cmd), is_list(Args), is_integer(TimeoutMs) ->
    CmdStr = binary_to_list(Cmd),
    ArgsStr = [binary_to_list(A) || A <- Args],
    %% Build a shell command that captures stderr separately
    FullCmd = string:join([CmdStr | ArgsStr], " "),
    StderrFile = "/tmp/springdrift_stderr_" ++ integer_to_list(erlang:unique_integer([positive])),
    ShellCmd = FullCmd ++ " 2>" ++ StderrFile,
    try
        Port = open_port({spawn, ShellCmd},
                         [binary, exit_status, use_stdio, stderr_to_stdout, {line, 65536}]),
        Result = collect_port_output(Port, <<>>, TimeoutMs),
        Stderr = case file:read_file(StderrFile) of
            {ok, SE} -> SE;
            {error, _} -> <<>>
        end,
        file:delete(StderrFile),
        case Result of
            {ok, {ExitCode, Stdout}} ->
                {ok, {ExitCode, Stdout, Stderr}};
            {error, timeout} ->
                {error, <<"Command timed out after ", (integer_to_binary(TimeoutMs))/binary, "ms">>}
        end
    catch
        _:Reason ->
            file:delete(StderrFile),
            {error, iolist_to_binary(io_lib:format("Command failed: ~p", [Reason]))}
    end.

collect_port_output(Port, Acc, TimeoutMs) ->
    receive
        {Port, {data, {eol, Line}}} ->
            collect_port_output(Port, <<Acc/binary, Line/binary, "\n">>, TimeoutMs);
        {Port, {data, {noeol, Line}}} ->
            collect_port_output(Port, <<Acc/binary, Line/binary>>, TimeoutMs);
        {Port, {exit_status, ExitCode}} ->
            {ok, {ExitCode, Acc}}
    after TimeoutMs ->
        catch port_close(Port),
        %% Try to kill the OS process
        catch os:cmd("kill -9 $(lsof -ti :" ++ integer_to_list(erlang:port_info(Port, id)) ++ ") 2>/dev/null"),
        {error, timeout}
    end.

%% Check if a binary exists on PATH. Returns {ok, Path} or {error, nil}.
which(Name) when is_binary(Name) ->
    case os:find_executable(binary_to_list(Name)) of
        false -> {error, nil};
        Path -> {ok, list_to_binary(Path)}
    end.

%% Extract Content-Type from a headers list. Returns {ContentTypeStr, RemainingHeaders}.
extract_content_type(Headers) ->
    extract_content_type(Headers, "application/json", []).

extract_content_type([], CT, Acc) ->
    {CT, lists:reverse(Acc)};
extract_content_type([{K, V} | Rest], _CT, Acc) when is_binary(K) ->
    case string:lowercase(K) of
        <<"content-type">> ->
            extract_content_type(Rest, binary_to_list(V), Acc);
        _ ->
            extract_content_type(Rest, _CT, [{K, V} | Acc])
    end;
extract_content_type([H | Rest], CT, Acc) ->
    extract_content_type(Rest, CT, [H | Acc]).

%% Case-insensitive regex match. Returns true if the pattern matches anywhere in
%% the text, false otherwise. Returns false on invalid patterns (fail-open).
re_match_caseless(Text, Pattern) when is_binary(Text), is_binary(Pattern) ->
    case re:compile(Pattern, [caseless]) of
        {ok, MP} ->
            case re:run(Text, MP) of
                {match, _} -> true;
                nomatch -> false
            end;
        {error, _} ->
            false
    end.

%% Check if a regex pattern is valid (compiles without errors).
re_is_valid_pattern(Pattern) when is_binary(Pattern) ->
    case re:compile(Pattern) of
        {ok, _} -> true;
        {error, _} -> false
    end.

%% Encode an Erlang/Gleam term to a JSON binary string.
json_encode_term(Term) ->
    iolist_to_binary(json:encode(Term)).

%% Decode a JSON binary string into an Erlang term, then re-encode it.
json_decode_to_string(Bin) when is_binary(Bin) ->
    try json:decode(Bin) of
        Term -> {ok, iolist_to_binary(json:encode(Term))}
    catch
        _:_ -> {error, <<"invalid json">>}
    end.

%% Identity function — used for type coercion between opaque Gleam types.
identity(X) -> X.

%% Simple ETS key-value store for token caching.
ets_new(Name) when is_binary(Name) ->
    ets:new(binary_to_atom(Name, utf8), [set, public]).

ets_insert(Tab, Key, Value) when is_binary(Key), is_binary(Value) ->
    ets:insert(Tab, {Key, Value}),
    nil.

ets_lookup(Tab, Key) when is_binary(Key) ->
    case ets:lookup(Tab, Key) of
        [{_, Value}] -> {ok, Value};
        [] -> {error, nil}
    end.

%% RSA-SHA256 signing for JWT service account auth.
sign_rs256(PemBin, Message) when is_binary(PemBin), is_binary(Message) ->
    try
        Entries = public_key:pem_decode(PemBin),
        PrivKey = first_private_key(Entries),
        Signature = public_key:sign(Message, sha256, PrivKey),
        Encoded = base64url_encode_no_pad(Signature),
        {ok, Encoded}
    catch
        Class:Reason ->
            {error, iolist_to_binary(io_lib:format("~p:~p", [Class, Reason]))}
    end.

first_private_key([]) ->
    error(no_private_key_found);
first_private_key([{Type, _, not_encrypted} = Entry | Rest]) ->
    case Type of
        'RSAPrivateKey' -> public_key:pem_entry_decode(Entry);
        'PrivateKeyInfo' -> public_key:pem_entry_decode(Entry);
        _ -> first_private_key(Rest)
    end;
first_private_key([_ | Rest]) ->
    first_private_key(Rest).

base64url_encode_no_pad(Bin) ->
    B64 = base64:encode(Bin),
    binary:replace(
        binary:replace(
            binary:replace(B64, <<"+">>, <<"-">>, [global]),
            <<"/">>, <<"_">>, [global]),
        <<"=">>, <<"">>, [global]).

%% Count non-empty lines in a file (JSONL line count).
%% Returns 0 if the file does not exist or cannot be read.
count_lines(Path) when is_binary(Path) ->
    case file:open(binary_to_list(Path), [read, raw, binary]) of
        {ok, Fd} ->
            Count = count_lines_loop(Fd, 0),
            file:close(Fd),
            Count;
        {error, _} ->
            0
    end.

count_lines_loop(Fd, Acc) ->
    case file:read_line(Fd) of
        {ok, Line} ->
            case string:trim(Line) of
                <<>> -> count_lines_loop(Fd, Acc);
                _ -> count_lines_loop(Fd, Acc + 1)
            end;
        eof -> Acc;
        {error, _} -> Acc
    end.

%% Current UTC Unix timestamp in seconds.
unix_now() ->
    calendar:datetime_to_gregorian_seconds(calendar:universal_time())
    - calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}).
