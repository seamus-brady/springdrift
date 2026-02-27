%% Custom OTP logger handler.
%%
%% Captures all BEAM-level warning/error/crash reports (including stack traces
%% from process crashes) and appends them as JSON lines to springdrift.log.
%%
%% This runs instead of the default terminal handler so that BEAM crash output
%% is captured to disk rather than corrupting the TUI's alternate screen.

-module(springdrift_beam_logger).
-export([log/2]).

%% OTP logger callback — called for every log event at or above the handler level.
log(#{level := Level, msg := Msg} = Event, _Config) ->
    Timestamp = get_timestamp(),
    LevelStr  = atom_to_list(Level),
    Meta      = maps:get(meta, Event, #{}),
    Pid       = format_pid(maps:get(pid, Meta, undefined)),
    Text      = format_msg(Msg, Meta),
    Line      = encode_line(Timestamp, LevelStr, Pid, Text),
    file:write_file("springdrift.log", [Line, <<"\n">>], [append]),
    ok.

%% ---------------------------------------------------------------------------
%% Message formatting
%% ---------------------------------------------------------------------------

format_pid(undefined)               -> "beam";
format_pid(P) when is_pid(P)        -> pid_to_list(P);
format_pid(_)                       -> "beam".

format_msg({string, S}, _Meta) when is_list(S)   -> S;
format_msg({string, S}, _Meta) when is_binary(S) -> binary_to_list(S);
format_msg({report, Report}, Meta) ->
    %% Use the report callback if available — it knows how to pretty-print
    %% crash reports, supervisor reports, etc. including stack traces.
    case maps:get(report_cb, Meta, undefined) of
        undefined ->
            io_lib:format("~p", [Report]);
        Cb when is_function(Cb, 1) ->
            try Cb(Report)
            catch _:_ -> io_lib:format("~p", [Report])
            end;
        Cb when is_function(Cb, 2) ->
            try
                {Fmt, Args} = Cb(Report, #{}),
                io_lib:format(Fmt, Args)
            catch _:_ -> io_lib:format("~p", [Report])
            end;
        _ ->
            io_lib:format("~p", [Report])
    end;
format_msg({Format, Args}, _Meta) when is_list(Format) ->
    try   io_lib:format(Format, Args)
    catch _:_ -> io_lib:format("~p ~p", [Format, Args])
    end;
format_msg(Msg, _Meta) ->
    io_lib:format("~p", [Msg]).

%% ---------------------------------------------------------------------------
%% JSON encoding
%% ---------------------------------------------------------------------------

get_timestamp() ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:local_time(),
    Pad = fun(N, W) -> string:right(integer_to_list(N), W, $0) end,
    lists:flatten([Pad(Y,4), $-, Pad(Mo,2), $-, Pad(D,2), $T,
                   Pad(H,2), $:, Pad(Mi,2), $:, Pad(S,2)]).

encode_line(Timestamp, Level, Pid, Msg) ->
    MsgBin = case unicode:characters_to_binary(lists:flatten(Msg)) of
        B when is_binary(B) -> B;
        _                   -> list_to_binary(lists:flatten(Msg))
    end,
    Escaped = json_escape(MsgBin),
    iolist_to_binary([
        <<"{\"timestamp\":\"">>, Timestamp,
        <<"\",\"level\":\"">>,   Level,
        <<"\",\"source\":\"beam\",\"event\":\"beam_report\",\"pid\":\"">>, Pid,
        <<"\",\"msg\":\"">>,     Escaped,
        <<"\"}">>
    ]).

json_escape(Bin) -> json_escape(Bin, <<>>).

json_escape(<<>>, Acc) -> Acc;
json_escape(<<$", R/binary>>,  Acc) -> json_escape(R, <<Acc/binary, $\\, $">>);
json_escape(<<$\\, R/binary>>, Acc) -> json_escape(R, <<Acc/binary, $\\, $\\>>);
json_escape(<<$\n, R/binary>>, Acc) -> json_escape(R, <<Acc/binary, $\\, $n>>);
json_escape(<<$\r, R/binary>>, Acc) -> json_escape(R, <<Acc/binary, $\\, $r>>);
json_escape(<<$\t, R/binary>>, Acc) -> json_escape(R, <<Acc/binary, $\\, $t>>);
json_escape(<<C, R/binary>>, Acc) when C < 32 ->
    Hex = io_lib:format("\\u~4.16.0b", [C]),
    json_escape(R, <<Acc/binary, (list_to_binary(Hex))/binary>>);
json_escape(<<C, R/binary>>, Acc) ->
    json_escape(R, <<Acc/binary, C>>).
