%% Override of gleam@httpc to support a configurable HTTP timeout.
%%
%% gleam/httpc compiles to the Erlang module gleam@httpc. Its configure/0
%% hardcodes a 30-second timeout. Both anthropic_gleam and gllm call
%% gleam@httpc:send/1 internally with no way to pass a custom timeout.
%%
%% This module shadows the package by the same Erlang name (OTP prepends each
%% application's ebin to the code path in reverse dependency order, so
%% springdrift/ebin ends up before gleam_httpc/ebin, and this beam is found
%% first when the module is loaded on first reference).
%%
%% configure/0 reads the timeout from a persistent_term set at startup by
%% springdrift_ffi:set_httpc_timeout/1. Default is 300 000 ms (5 minutes).
%% Every other function is identical to the upstream gleam_httpc package.
%%
-module('gleam@httpc').
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch]).
-export([configure/0, verify_tls/2, follow_redirects/2, timeout/2,
         dispatch_bits/2, send_bits/1, dispatch/2, send/1]).
-export_type([http_error/0, connect_error/0, erl_http_option/0, body_format/0,
              erl_option/0, socket_opt/0, inet6fb4/0, erl_ssl_option/0,
              erl_verify_option/0, configuration/0]).

-type http_error() :: invalid_utf8_response |
    {failed_to_connect, connect_error(), connect_error()} |
    response_timeout.

-type connect_error() :: {posix, binary()} | {tls_alert, binary(), binary()}.

-type erl_http_option() :: {ssl, list(erl_ssl_option())} |
    {autoredirect, boolean()} |
    {timeout, integer()}.

-type body_format() :: binary.

-type erl_option() :: {body_format, body_format()} |
    {socket_opts, list(socket_opt())}.

-type socket_opt() :: {ipfamily, inet6fb4()}.

-type inet6fb4() :: inet6fb4.

-type erl_ssl_option() :: {verify, erl_verify_option()}.

-type erl_verify_option() :: verify_none.

-opaque configuration() :: {builder, boolean(), boolean(), integer()}.

%% Return a Configuration using the application-configured timeout.
%% springdrift sets this at startup via springdrift_ffi:set_httpc_timeout/1.
%% The fallback of 300 000 ms applies if it is called before that point.
-spec configure() -> configuration().
configure() ->
    T = persistent_term:get(springdrift_httpc_timeout_ms, 300_000),
    {builder, true, false, T}.

-spec verify_tls(configuration(), boolean()) -> configuration().
verify_tls(Config, Which) ->
    {builder, Which, erlang:element(3, Config), erlang:element(4, Config)}.

-spec follow_redirects(configuration(), boolean()) -> configuration().
follow_redirects(Config, Which) ->
    {builder, erlang:element(2, Config), Which, erlang:element(4, Config)}.

-spec timeout(configuration(), integer()) -> configuration().
timeout(Config, Timeout) ->
    {builder, erlang:element(2, Config), erlang:element(3, Config), Timeout}.

-spec prepare_headers_loop(
    list({binary(), binary()}),
    list({gleam@erlang@charlist:charlist(), gleam@erlang@charlist:charlist()}),
    boolean()
) -> list({gleam@erlang@charlist:charlist(), gleam@erlang@charlist:charlist()}).
prepare_headers_loop(In, Out, User_agent_set) ->
    case In of
        [] when User_agent_set ->
            Out;
        [] ->
            [gleam_httpc_ffi:default_user_agent() | Out];
        [{K, V} | In1] ->
            User_agent_set1 = User_agent_set orelse (K =:= <<"user-agent">>),
            Out1 = [{unicode:characters_to_list(K),
                     unicode:characters_to_list(V)} | Out],
            prepare_headers_loop(In1, Out1, User_agent_set1)
    end.

-spec prepare_headers(list({binary(), binary()})) ->
    list({gleam@erlang@charlist:charlist(), gleam@erlang@charlist:charlist()}).
prepare_headers(Headers) ->
    prepare_headers_loop(Headers, [], false).

-spec dispatch_bits(configuration(), gleam@http@request:request(bitstring())) ->
    {ok, gleam@http@response:response(bitstring())} | {error, http_error()}.
dispatch_bits(Config, Req) ->
    Erl_url = unicode:characters_to_list(
        gleam@uri:to_string(gleam@http@request:to_uri(Req))),
    Erl_headers = prepare_headers(erlang:element(3, Req)),
    Erl_http_options = [{autoredirect, erlang:element(3, Config)},
                        {timeout,      erlang:element(4, Config)}],
    Erl_http_options1 = case erlang:element(2, Config) of
        true  -> Erl_http_options;
        false -> [{ssl, [{verify, verify_none}]} | Erl_http_options]
    end,
    Erl_options = [{body_format, binary}, {socket_opts, [{ipfamily, inet6fb4}]}],
    Raw = case erlang:element(2, Req) of
        options ->
            httpc:request(erlang:element(2, Req),
                {Erl_url, Erl_headers},
                Erl_http_options1, Erl_options);
        head ->
            httpc:request(erlang:element(2, Req),
                {Erl_url, Erl_headers},
                Erl_http_options1, Erl_options);
        get ->
            httpc:request(erlang:element(2, Req),
                {Erl_url, Erl_headers},
                Erl_http_options1, Erl_options);
        _ ->
            Erl_content_type = unicode:characters_to_list(
                gleam@result:unwrap(
                    gleam@http@request:get_header(Req, <<"content-type">>),
                    <<"application/octet-stream">>)),
            httpc:request(erlang:element(2, Req),
                {Erl_url, Erl_headers, Erl_content_type, erlang:element(4, Req)},
                Erl_http_options1, Erl_options)
    end,
    gleam@result:'try'(
        gleam@result:map_error(Raw, fun gleam_httpc_ffi:normalise_error/1),
        fun(Response) ->
            {{_, Status, _}, Headers, Resp_body} = Response,
            {ok, {response,
                  Status,
                  gleam@list:map(Headers, fun string_header/1),
                  Resp_body}}
        end).

-spec send_bits(gleam@http@request:request(bitstring())) ->
    {ok, gleam@http@response:response(bitstring())} | {error, http_error()}.
send_bits(Req) ->
    dispatch_bits(configure(), Req).

-spec dispatch(configuration(), gleam@http@request:request(binary())) ->
    {ok, gleam@http@response:response(binary())} | {error, http_error()}.
dispatch(Config, Request) ->
    Request1 = gleam@http@request:map(Request, fun gleam_stdlib:identity/1),
    gleam@result:'try'(
        dispatch_bits(Config, Request1),
        fun(Resp) ->
            case gleam@bit_array:to_string(erlang:element(4, Resp)) of
                {ok, Body} -> {ok, gleam@http@response:set_body(Resp, Body)};
                {error, _} -> {error, invalid_utf8_response}
            end
        end).

-spec send(gleam@http@request:request(binary())) ->
    {ok, gleam@http@response:response(binary())} | {error, http_error()}.
send(Req) ->
    dispatch(configure(), Req).

string_header({K, V}) ->
    {unicode:characters_to_binary(K), unicode:characters_to_binary(V)}.
