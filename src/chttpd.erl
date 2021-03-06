% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(chttpd).
-include_lib("couch/include/couch_db.hrl").

-export([start_link/0, start_link/1, start_link/2,
    stop/0, handle_request/1, config_change/2,
    primary_header_value/2, header_value/2, header_value/3, qs_value/2,
    qs_value/3, qs/1, qs_json_value/3, path/1, absolute_uri/2, body_length/1,
    verify_is_server_admin/1, unquote/1, quote/1, recv/2, recv_chunked/4,
    error_info/1, parse_form/1, json_body/1, json_body_obj/1, body/1,
    doc_etag/1, make_etag/1, etag_respond/3, partition/1, serve_file/3,
    server_header/0, start_chunked_response/3,send_chunk/2,
    start_response_length/4, send/2, start_json_response/2,
    start_json_response/3, end_json_response/1, send_response/4,
    send_method_not_allowed/2, send_error/2, send_error/4, send_redirect/2,
    send_chunked_error/2, send_json/2,send_json/3,send_json/4]).

-export([start_delayed_json_response/2, start_delayed_json_response/3,
    start_delayed_json_response/4,
    start_delayed_chunked_response/3, start_delayed_chunked_response/4,
    send_delayed_chunk/2, send_delayed_last_chunk/1,
    send_delayed_error/2, end_delayed_json_response/1,
    get_delayed_req/1]).

-record(delayed_resp, {
    start_fun,
    req,
    code,
    headers,
    first_chunk,
    resp=nil
}).

start_link() ->
    start_link(http).
start_link(http) ->
    Port = couch_config:get("chttpd", "port", "5984"),
    start_link(?MODULE, [{port, Port}]);

start_link(https) ->
    Port = couch_config:get("chttps", "port", "6984"),
    CertFile = couch_config:get("chttps", "cert_file", nil),
    KeyFile = couch_config:get("chttps", "key_file", nil),
    Options = case CertFile /= nil andalso KeyFile /= nil of
        true ->
            SslOpts = [{certfile, CertFile}, {keyfile, KeyFile}],

            %% set password if one is needed for the cert
            SslOpts1 = case couch_config:get("chttps", "password", nil) of
                nil -> SslOpts;
                Password ->
                    SslOpts ++ [{password, Password}]
            end,
            % do we verify certificates ?
            FinalSslOpts = case couch_config:get("chttps",
                    "verify_ssl_certificates", "false") of
                "false" -> SslOpts1;
                "true" ->
                    case couch_config:get("chttps",
                            "cacert_file", nil) of
                        nil ->
                            io:format("Verify SSL certificate "
                                ++"enabled but file containing "
                                ++"PEM encoded CA certificates is "
                                ++"missing", []),
                            throw({error, missing_cacerts});
                        CaCertFile ->
                            Depth = list_to_integer(couch_config:get("chttps",
                                    "ssl_certificate_max_depth",
                                    "1")),
                            FinalOpts = [
                                {cacertfile, CaCertFile},
                                {depth, Depth},
                                {verify, verify_peer}],
                            % allows custom verify fun.
                            case couch_config:get("chttps",
                                    "verify_fun", nil) of
                                nil -> FinalOpts;
                                SpecStr ->
                                    FinalOpts
                                    ++ [{verify_fun, couch_httpd:make_arity_3_fun(SpecStr)}]
                            end
                    end
            end,

            [{port, Port},
                {ssl, true},
                {ssl_opts, FinalSslOpts}];
        false ->
            io:format("SSL enabled but PEM certificates are missing.", []),
            throw({error, missing_certs})
    end,
    start_link(https, Options).

start_link(Name, Options) ->
    Options1 = Options ++ [
        {loop, fun ?MODULE:handle_request/1},
        {name, Name},
        {ip, couch_config:get("chttpd", "bind_address", any)}
    ],
    ServerOptsCfg = couch_config:get("chttpd", "server_options", "[]"),
    {ok, ServerOpts} = couch_util:parse_term(ServerOptsCfg),
    Options2 = lists:keymerge(1, lists:sort(Options1), lists:sort(ServerOpts)),
    case mochiweb_http:start(Options2) of
    {ok, Pid} ->
        ok = couch_config:register(fun ?MODULE:config_change/2, Pid),
        {ok, Pid};
    {error, Reason} ->
        io:format("Failure to start Mochiweb: ~s~n", [Reason]),
        {error, Reason}
    end.

config_change("chttpd", "bind_address") ->
    ?MODULE:stop();
config_change("chttpd", "port") ->
    ?MODULE:stop();
config_change("chttpd", "backlog") ->
    ?MODULE:stop();
config_change("chttpd", "server_options") ->
    ?MODULE:stop().

stop() ->
    catch mochiweb_http:stop(https),
    mochiweb_http:stop(?MODULE).

handle_request(MochiReq) ->
    Begin = now(),

    case couch_config:get("chttpd", "socket_options") of
    undefined ->
        ok;
    SocketOptsCfg ->
        {ok, SocketOpts} = couch_util:parse_term(SocketOptsCfg),
        ok = mochiweb_socket:setopts(MochiReq:get(socket), SocketOpts)
    end,

    AuthenticationFuns = [
        fun couch_httpd_auth:cookie_authentication_handler/1,
        fun couch_httpd_auth:default_authentication_handler/1
    ],

    % for the path, use the raw path with the query string and fragment
    % removed, but URL quoting left intact
    RawUri = MochiReq:get(raw_path),
    {"/" ++ Path, _, _} = mochiweb_util:urlsplit_path(RawUri),
    {HandlerKey, _, _} = mochiweb_util:partition(Path, "/"),

    Peer = MochiReq:get(peer),
    LogForClosedSocket = io_lib:format("mochiweb_recv_error for ~s - ~p ~s", [
        Peer,
        MochiReq:get(method),
        RawUri
    ]),

    Method1 =
    case MochiReq:get(method) of
        % already an atom
        Meth when is_atom(Meth) -> Meth;

        % Non standard HTTP verbs aren't atoms (COPY, MOVE etc) so convert when
        % possible (if any module references the atom, then it's existing).
        Meth -> couch_util:to_existing_atom(Meth)
    end,
    increment_method_stats(Method1),

    % allow broken HTTP clients to fake a full method vocabulary with an X-HTTP-METHOD-OVERRIDE header
    MethodOverride = MochiReq:get_primary_header_value("X-HTTP-Method-Override"),
    Method2 = case lists:member(MethodOverride, ["GET", "HEAD", "POST", "PUT", "DELETE", "TRACE", "CONNECT", "COPY"]) of
    true ->
        ?LOG_INFO("MethodOverride: ~s (real method was ~s)", [MethodOverride, Method1]),
        case Method1 of
        'POST' -> couch_util:to_existing_atom(MethodOverride);
        _ ->
            % Ignore X-HTTP-Method-Override when the original verb isn't POST.
            % I'd like to send a 406 error to the client, but that'd require a nasty refactor.
            % throw({not_acceptable, <<"X-HTTP-Method-Override may only be used with POST requests.">>})
            Method1
        end;
    _ -> Method1
    end,

    % alias HEAD to GET as mochiweb takes care of stripping the body
    Method = case Method2 of
        'HEAD' -> 'GET';
        Other -> Other
    end,

    HttpReq = #httpd{
        mochi_req = MochiReq,
        method = Method,
        path_parts = [list_to_binary(chttpd:unquote(Part))
                || Part <- string:tokens(Path, "/")],
        db_url_handlers = db_url_handlers(),
        design_url_handlers = design_url_handlers()
    },

    % put small token on heap to keep requests synced to backend calls
    erlang:put(nonce, couch_util:to_hex(crypto:rand_bytes(4))),

    Result =
    try
        case authenticate_request(HttpReq, AuthenticationFuns) of
        #httpd{} = Req ->
            HandlerFun = url_handler(HandlerKey),
            HandlerFun(possibly_hack(Req));
        Response ->
            Response
        end
    catch
        throw:{http_head_abort, Resp0} ->
            {ok, Resp0};
        throw:{http_abort, Resp0, Reason0} ->
            {aborted, Resp0, Reason0};
        throw:{invalid_json, S} ->
            ?LOG_ERROR("attempted upload of invalid JSON ~s", [S]),
            send_error(HttpReq, {bad_request, "invalid UTF-8 JSON"});
        exit:{mochiweb_recv_error, E} ->
            ?LOG_INFO(LogForClosedSocket ++ " - ~p", [E]),
            exit(normal);
        throw:Error ->
            send_error(HttpReq, Error);
        error:database_does_not_exist ->
            send_error(HttpReq, database_does_not_exist);
        Tag:Error ->
            Stack = erlang:get_stacktrace(),
            ?LOG_ERROR("Uncaught error in HTTP request: ~p",[{Tag, Error}]),
            ?LOG_INFO("Stacktrace: ~p",[Stack]),
            send_error(HttpReq, {Error, nil, Stack})
    end,

    RequestTime = timer:now_diff(now(), Begin)/1000,
    {Status, Code} = case Result of
    {ok, #delayed_resp{resp=Resp}} ->
        {ok, Resp:get(code)};
    {ok, Resp} ->
        {ok, Resp:get(code)};
    {aborted, Resp, _} ->
        {aborted, Resp:get(code)}
    end,
    Host = MochiReq:get_header_value("Host"),
    ?LOG_INFO("~s ~s ~s ~s ~B ~p ~B", [Peer, Host,
        atom_to_list(Method1), RawUri, Code, Status, round(RequestTime)]),
    couch_stats_collector:record({couchdb, request_time}, RequestTime),
    case Result of
    {ok, _} ->
        couch_stats_collector:increment({httpd, requests}),
        {ok, Resp};
    {aborted, _, Reason} ->
        couch_stats_collector:increment({httpd, aborted_requests}),
        ?LOG_ERROR("Response abnormally terminated: ~p", [Reason]),
        exit(normal)
    end.

%% HACK: replication currently handles two forms of input, #db{} style
%% and #http_db style. We need a third that makes use of fabric. #db{}
%% works fine for replicating the dbs and nodes database because they
%% aren't sharded. So for now when a local db is specified as the source or
%% the target, it's hacked to make it a full url and treated as a remote.
possibly_hack(#httpd{path_parts=[<<"_replicate">>]}=Req) ->
    {Props0} = couch_httpd:json_body_obj(Req),
    Props1 = fix_uri(Req, Props0, <<"source">>),
    Props2 = fix_uri(Req, Props1, <<"target">>),
    put(post_body, {Props2}),
    Req;
possibly_hack(Req) ->
    Req.

fix_uri(Req, Props, Type) ->
    case is_http(replication_uri(Type, Props)) of
    true ->
        Props;
    false ->
        Uri = make_uri(Req,replication_uri(Type, Props)),
        [{Type,Uri}|proplists:delete(Type,Props)]
    end.

replication_uri(Type, PostProps) ->
    case couch_util:get_value(Type, PostProps) of
    {Props} ->
        couch_util:get_value(<<"url">>, Props);
    Else ->
        Else
    end.

is_http(<<"http://", _/binary>>) ->
    true;
is_http(<<"https://", _/binary>>) ->
    true;
is_http(_) ->
    false.

make_uri(Req, Raw) ->
    Url = list_to_binary(["http://", couch_config:get("httpd", "bind_address"),
                         ":", couch_config:get("chttpd", "port"), "/", Raw]),
    Headers = [
        {<<"authorization">>, ?l2b(header_value(Req,"authorization",""))},
        {<<"cookie">>, ?l2b(header_value(Req,"cookie",""))}
    ],
    {[{<<"url">>,Url}, {<<"headers">>,{Headers}}]}.
%%% end hack


% Try authentication handlers in order until one returns a result
authenticate_request(#httpd{user_ctx=#user_ctx{}} = Req, _AuthFuns) ->
    Req;
authenticate_request(#httpd{} = Req, [AuthFun|Rest]) ->
    authenticate_request(AuthFun(Req), Rest);
authenticate_request(#httpd{} = Req, []) ->
    case couch_config:get("chttpd", "require_valid_user", "false") of
    "true" ->
        throw({unauthorized, <<"Authentication required.">>});
    "false" ->
        case couch_config:get("admins") of
        [] ->
            Ctx = #user_ctx{roles=[<<"_reader">>, <<"_writer">>, <<"_admin">>]},
            Req#httpd{user_ctx = Ctx};
        _ ->
            Req#httpd{user_ctx=#user_ctx{}}
        end
    end;
authenticate_request(Response, _AuthFuns) ->
    Response.

increment_method_stats(Method) ->
    couch_stats_collector:increment({httpd_request_methods, Method}).

url_handler("") ->              fun chttpd_misc:handle_welcome_req/1;
url_handler("favicon.ico") ->   fun chttpd_misc:handle_favicon_req/1;
url_handler("_utils") ->        fun chttpd_misc:handle_utils_dir_req/1;
url_handler("_all_dbs") ->      fun chttpd_misc:handle_all_dbs_req/1;
url_handler("_active_tasks") -> fun chttpd_misc:handle_task_status_req/1;
url_handler("_config") ->       fun chttpd_misc:handle_config_req/1;
url_handler("_replicate") ->    fun chttpd_misc:handle_replicate_req/1;
url_handler("_uuids") ->        fun chttpd_misc:handle_uuids_req/1;
url_handler("_log") ->          fun chttpd_misc:handle_log_req/1;
url_handler("_sleep") ->        fun chttpd_misc:handle_sleep_req/1;
url_handler("_session") ->      fun couch_httpd_auth:handle_session_req/1;
url_handler("_oauth") ->        fun couch_httpd_oauth:handle_oauth_req/1;
%% showroom_http module missing in bigcouch
url_handler("_restart") ->      fun showroom_http:handle_restart_req/1;
url_handler("_membership") ->   fun mem3_httpd:handle_membership_req/1;
url_handler(_) ->               fun chttpd_db:handle_request/1.

db_url_handlers() ->
    [
        {<<"_view_cleanup">>,   fun chttpd_db:handle_view_cleanup_req/2},
        {<<"_compact">>,        fun chttpd_db:handle_compact_req/2},
        {<<"_design">>,         fun chttpd_db:handle_design_req/2},
        {<<"_temp_view">>,      fun chttpd_view:handle_temp_view_req/2},
        {<<"_changes">>,        fun chttpd_db:handle_changes_req/2},
        {<<"_search">>,         fun chttpd_external:handle_search_req/2}
    ].

design_url_handlers() ->
    [
        {<<"_view">>,           fun chttpd_view:handle_view_req/3},
        {<<"_show">>,           fun chttpd_show:handle_doc_show_req/3},
        {<<"_list">>,           fun chttpd_show:handle_view_list_req/3},
        {<<"_update">>,         fun chttpd_show:handle_doc_update_req/3},
        {<<"_info">>,           fun chttpd_db:handle_design_info_req/3},
        {<<"_rewrite">>,        fun chttpd_rewrite:handle_rewrite_req/3}
    ].

% Utilities

partition(Path) ->
    mochiweb_util:partition(Path, "/").

header_value(#httpd{mochi_req=MochiReq}, Key) ->
    MochiReq:get_header_value(Key).

header_value(#httpd{mochi_req=MochiReq}, Key, Default) ->
    case MochiReq:get_header_value(Key) of
    undefined -> Default;
    Value -> Value
    end.

primary_header_value(#httpd{mochi_req=MochiReq}, Key) ->
    MochiReq:get_primary_header_value(Key).

serve_file(#httpd{mochi_req=MochiReq}=Req, RelativePath, DocumentRoot) ->
    {ok, MochiReq:serve_file(RelativePath, DocumentRoot,
        server_header() ++ couch_httpd_auth:cookie_auth_header(Req, []))}.

qs_value(Req, Key) ->
    qs_value(Req, Key, undefined).

qs_value(Req, Key, Default) ->
    couch_util:get_value(Key, qs(Req), Default).

qs_json_value(Req, Key, Default) ->
    case qs_value(Req, Key, Default) of
        Default ->
            Default;
        Result ->
            ?JSON_DECODE(Result)
    end.

qs(#httpd{mochi_req=MochiReq}) ->
    MochiReq:parse_qs().

path(#httpd{mochi_req=MochiReq}) ->
    MochiReq:get(path).

absolute_uri(#httpd{mochi_req=MochiReq}, Path) ->
    XHost = couch_config:get("httpd", "x_forwarded_host", "X-Forwarded-Host"),
    Host = case MochiReq:get_header_value(XHost) of
        undefined ->
            case MochiReq:get_header_value("Host") of
                undefined ->
                    {ok, {Address, Port}} = inet:sockname(MochiReq:get(socket)),
                    inet_parse:ntoa(Address) ++ ":" ++ integer_to_list(Port);
                Value1 ->
                    Value1
            end;
        Value -> Value
    end,
    XSsl = couch_config:get("httpd", "x_forwarded_ssl", "X-Forwarded-Ssl"),
    Scheme = case MochiReq:get_header_value(XSsl) of
        "on" -> "https";
        _ ->
            XProto = couch_config:get("httpd", "x_forwarded_proto",
                "X-Forwarded-Proto"),
            case MochiReq:get_header_value(XProto) of
                % Restrict to "https" and "http" schemes only
                "https" -> "https";
                _ ->
                    case MochiReq:get(scheme) of
                        https ->
                            "https";
                        http ->
                            "http"
                    end
            end
    end,
    Scheme ++ "://" ++ Host ++ Path.

unquote(UrlEncodedString) ->
    mochiweb_util:unquote(UrlEncodedString).

quote(UrlDecodedString) ->
    mochiweb_util:quote_plus(UrlDecodedString).

parse_form(#httpd{mochi_req=MochiReq}) ->
    mochiweb_multipart:parse_form(MochiReq).

recv(#httpd{mochi_req=MochiReq}, Len) ->
    MochiReq:recv(Len).

recv_chunked(#httpd{mochi_req=MochiReq}, MaxChunkSize, ChunkFun, InitState) ->
    % Fun is called once with each chunk
    % Fun({Length, Binary}, State)
    % called with Length == 0 on the last time.
    MochiReq:stream_body(MaxChunkSize, ChunkFun, InitState).

body_length(Req) ->
    case header_value(Req, "Transfer-Encoding") of
        undefined ->
            case header_value(Req, "Content-Length") of
                undefined -> undefined;
                Length -> list_to_integer(Length)
            end;
        "chunked" -> chunked;
        Unknown -> {unknown_transfer_encoding, Unknown}
    end.

body(Req) ->
    couch_httpd:body(Req).

json_body(Httpd) ->
    ?JSON_DECODE(body(Httpd)).

json_body_obj(Httpd) ->
    case json_body(Httpd) of
        {Props} -> {Props};
        _Else ->
            throw({bad_request, "Request body must be a JSON object"})
    end.


doc_etag(#doc{revs={Start, [DiskRev|_]}}) ->
    "\"" ++ ?b2l(couch_doc:rev_to_str({Start, DiskRev})) ++ "\"".

make_etag(Term) ->
    <<SigInt:128/integer>> = erlang:md5(term_to_binary(Term)),
    list_to_binary(io_lib:format("\"~.36B\"",[SigInt])).

etag_match(Req, CurrentEtag) when is_binary(CurrentEtag) ->
    etag_match(Req, binary_to_list(CurrentEtag));

etag_match(Req, CurrentEtag) ->
    EtagsToMatch = string:tokens(
        chttpd:header_value(Req, "If-None-Match", ""), ", "),
    lists:member(CurrentEtag, EtagsToMatch).

etag_respond(Req, CurrentEtag, RespFun) ->
    case etag_match(Req, CurrentEtag) of
    true ->
        % the client has this in their cache.
        chttpd:send_response(Req, 304, [{"Etag", CurrentEtag}], <<>>);
    false ->
        % Run the function.
        RespFun()
    end.

verify_is_server_admin(#httpd{user_ctx=#user_ctx{roles=Roles}}) ->
    case lists:member(<<"_admin">>, Roles) of
    true -> ok;
    false -> throw({unauthorized, <<"You are not a server admin.">>})
    end.

start_response_length(#httpd{mochi_req=MochiReq}=Req, Code, Headers, Length) ->
    couch_stats_collector:increment({httpd_status_codes, Code}),
    Resp = MochiReq:start_response_length({Code, Headers ++ server_header() ++
        couch_httpd_auth:cookie_auth_header(Req, Headers), Length}),
    case MochiReq:get(method) of
    'HEAD' -> throw({http_head_abort, Resp});
    _ -> ok
    end,
    {ok, Resp}.

send(Resp, Data) ->
    Resp:send(Data),
    {ok, Resp}.

start_chunked_response(#httpd{mochi_req=MochiReq}=Req, Code, Headers) ->
    couch_stats_collector:increment({httpd_status_codes, Code}),
    Resp = MochiReq:respond({Code, Headers ++ server_header() ++
        couch_httpd_auth:cookie_auth_header(Req, Headers), chunked}),
    case MochiReq:get(method) of
    'HEAD' -> throw({http_head_abort, Resp});
    _ -> ok
    end,
    {ok, Resp}.

send_chunk(Resp, Data) ->
    Resp:write_chunk(Data),
    {ok, Resp}.

send_response(#httpd{mochi_req=MochiReq}=Req, Code, Headers, Body) ->
    couch_stats_collector:increment({httpd_status_codes, Code}),
    if Code >= 400 ->
        ?LOG_DEBUG("httpd ~p error response:~n ~s", [Code, Body]);
    true -> ok
    end,
    {ok, MochiReq:respond({Code, Headers ++ server_header() ++
        couch_httpd_auth:cookie_auth_header(Req, Headers), Body})}.

send_method_not_allowed(Req, Methods) ->
    send_error(Req, 405, [{"Allow", Methods}], <<"method_not_allowed">>,
        ?l2b("Only " ++ Methods ++ " allowed"), []).

send_json(Req, Value) ->
    send_json(Req, 200, Value).

send_json(Req, Code, Value) ->
    send_json(Req, Code, [], Value).

send_json(Req, Code, Headers, Value) ->
    couch_httpd:send_json(Req, Code, [reqid() | Headers], Value).

start_json_response(Req, Code) ->
    start_json_response(Req, Code, []).

start_json_response(Req, Code, Headers) ->
    couch_httpd:start_json_response(Req, Code, [reqid() | Headers]).

end_json_response(Resp) ->
    couch_httpd:end_json_response(Resp).

start_delayed_json_response(Req, Code) ->
    start_delayed_json_response(Req, Code, []).

start_delayed_json_response(Req, Code, Headers) ->
    start_delayed_json_response(Req, Code, Headers, "").

start_delayed_json_response(Req, Code, Headers, FirstChunk) ->
    {ok, #delayed_resp{
        start_fun = fun start_json_response/3,
        req = Req,
        code = Code,
        headers = Headers,
        first_chunk = FirstChunk}}.

start_delayed_chunked_response(Req, Code, Headers) ->
    start_delayed_chunked_response(Req, Code, Headers, "").

start_delayed_chunked_response(Req, Code, Headers, FirstChunk) ->
    {ok, #delayed_resp{
        start_fun = fun start_chunked_response/3,
        req = Req,
        code = Code,
        headers = Headers,
        first_chunk = FirstChunk}}.

send_delayed_chunk(#delayed_resp{}=DelayedResp, Chunk) ->
    {ok, #delayed_resp{resp=Resp}=DelayedResp1} =
        start_delayed_response(DelayedResp),
    {ok, Resp} = send_chunk(Resp, Chunk),
    {ok, DelayedResp1}.

send_delayed_last_chunk(Req) ->
    send_delayed_chunk(Req, []).

send_delayed_error(#delayed_resp{req=Req,resp=nil}, Reason) ->
    {Code, ErrorStr, ReasonStr} = error_info(Reason),
    send_error(Req, Code, ErrorStr, ReasonStr);
send_delayed_error(#delayed_resp{resp=Resp}, Reason) ->
    throw({http_abort, Resp, Reason}).

end_delayed_json_response(#delayed_resp{}=DelayedResp) ->
    {ok, #delayed_resp{resp=Resp}} =
        start_delayed_response(DelayedResp),
    end_json_response(Resp).

get_delayed_req(#delayed_resp{req=#httpd{mochi_req=MochiReq}}) ->
    MochiReq;
get_delayed_req(Resp) ->
    Resp:get(request).

start_delayed_response(#delayed_resp{resp=nil}=DelayedResp) ->
    #delayed_resp{
        start_fun=StartFun,
        req=Req,
        code=Code,
        headers=Headers,
        first_chunk=FirstChunk
    }=DelayedResp,
    {ok, Resp} = StartFun(Req, Code, Headers),
    case FirstChunk of
        "" -> ok;
        _ -> {ok, Resp} = send_chunk(Resp, FirstChunk)
    end,
    {ok, DelayedResp#delayed_resp{resp=Resp}};
start_delayed_response(#delayed_resp{}=DelayedResp) ->
    {ok, DelayedResp}.

error_info({Error, Reason}) when is_list(Reason) ->
    error_info({Error, couch_util:to_binary(Reason)});
error_info(bad_request) ->
    {400, <<"bad_request">>, <<>>};
error_info({bad_request, Reason}) ->
    {400, <<"bad_request">>, Reason};
error_info({query_parse_error, Reason}) ->
    {400, <<"query_parse_error">>, Reason};
error_info(database_does_not_exist) ->
    {404, <<"not_found">>, <<"Database does not exist.">>};
error_info(not_found) ->
    {404, <<"not_found">>, <<"missing">>};
error_info({not_found, Reason}) ->
    {404, <<"not_found">>, Reason};
error_info({not_acceptable, Reason}) ->
    {406, <<"not_acceptable">>, Reason};
error_info(conflict) ->
    {409, <<"conflict">>, <<"Document update conflict.">>};
error_info({conflict, _}) ->
    {409, <<"conflict">>, <<"Document update conflict.">>};
error_info({forbidden, Msg}) ->
    {403, <<"forbidden">>, Msg};
error_info({forbidden, Error, Msg}) ->
    {403, Error, Msg};
error_info({unauthorized, Msg}) ->
    {401, <<"unauthorized">>, Msg};
error_info(file_exists) ->
    {412, <<"file_exists">>, <<"The database could not be "
        "created, the file already exists.">>};
error_info({r_quorum_not_met, Reason}) ->
    {412, <<"read_quorum_not_met">>, Reason};
error_info({w_quorum_not_met, Reason}) ->
    {500, <<"write_quorum_not_met">>, Reason};
error_info({bad_ctype, Reason}) ->
    {415, <<"bad_content_type">>, Reason};
error_info(requested_range_not_satisfiable) ->
    {416, <<"requested_range_not_satisfiable">>, <<"Requested range not satisfiable">>};
error_info({error, illegal_database_name}) ->
    {400, <<"illegal_database_name">>, <<"Only lowercase characters (a-z), "
        "digits (0-9), and any of the characters _, $, (, ), +, -, and / "
        "are allowed">>};
error_info({missing_stub, Reason}) ->
    {412, <<"missing_stub">>, Reason};
error_info(not_implemented) ->
    {501, <<"not_implemented">>, <<"this feature is not yet implemented">>};
error_info({Error, null}) ->
    {500, couch_util:to_binary(Error), null};
error_info({Error, Reason}) ->
    {500, couch_util:to_binary(Error), couch_util:to_binary(Reason)};
error_info({Error, nil, _Stack}) ->
    error_info(Error);
error_info({Error, Reason, _Stack}) ->
    error_info({Error, Reason});
error_info(Error) ->
    {500, couch_util:to_binary(Error), null}.

error_headers(#httpd{mochi_req=MochiReq}=Req, 401=Code, ErrorStr, ReasonStr) ->
    % this is where the basic auth popup is triggered
    case MochiReq:get_header_value("X-CouchDB-WWW-Authenticate") of
    undefined ->
        case couch_config:get("httpd", "WWW-Authenticate", nil) of
        nil ->
            % If the client is a browser and the basic auth popup isn't turned on
            % redirect to the session page.
            case ErrorStr of
            <<"unauthorized">> ->
                case couch_config:get("couch_httpd_auth", "authentication_redirect", nil) of
                nil -> {Code, []};
                AuthRedirect ->
                    case couch_config:get("couch_httpd_auth", "require_valid_user", "false") of
                    "true" ->
                        % send the browser popup header no matter what if we are require_valid_user
                        {Code, [{"WWW-Authenticate", "Basic realm=\"server\""}]};
                    _False ->
                        % if the accept header matches html, then do the redirect. else proceed as usual.
                        Accepts = case MochiReq:get_header_value("Accept") of
                        undefined ->
                           % According to the HTTP 1.1 spec, if the Accept
                           % header is missing, it means the client accepts
                           % all media types.
                           "html";
                        Else ->
                            Else
                        end,
                        case re:run(Accepts, "\\bhtml\\b",
                                [{capture, none}, caseless]) of
                        nomatch ->
                            {Code, []};
                        match ->
                            AuthRedirectBin = ?l2b(AuthRedirect),
                            % Redirect to the path the user requested, not
                            % the one that is used internally.
                            UrlReturnRaw = case MochiReq:get_header_value("x-couchdb-vhost-path") of
                                undefined -> MochiReq:get(path);
                                VHostPath -> VHostPath
                            end,
                            UrlReturn = ?l2b(couch_util:url_encode(UrlReturnRaw)),
                            UrlReason = ?l2b(couch_util:url_encode(ReasonStr)),
                            {302, [{"Location", couch_httpd:absolute_uri(Req, <<AuthRedirectBin/binary,"?return=",UrlReturn/binary,"&reason=",UrlReason/binary>>)}]}
                        end
                    end
                end;
            _Else ->
                {Code, []}
            end;
        Type ->
            {Code, [{"WWW-Authenticate", Type}]}
        end;
    Type ->
       {Code, [{"WWW-Authenticate", Type}]}
    end;
error_headers(_, Code, _, _) ->
    {Code, []}.

send_error(_Req, {already_sent, Resp, _Error}) ->
    {ok, Resp};

send_error(Req, Error) ->
    {Code, ErrorStr, ReasonStr} = error_info(Error),
    {Code1, Headers} = error_headers(Req, Code, ErrorStr, ReasonStr),
    send_error(Req, Code1, Headers, ErrorStr, ReasonStr, json_stack(Error)).

send_error(Req, Code, ErrorStr, ReasonStr) ->
    send_error(Req, Code, [], ErrorStr, ReasonStr, []).

send_error(Req, Code, Headers, ErrorStr, ReasonStr, Stack) ->
    send_json(Req, Code, Headers,
        {[{<<"error">>,  ErrorStr},
        {<<"reason">>, ReasonStr} |
        case Stack of [] -> []; _ -> [{stack, Stack}] end
    ]}).

% give the option for list functions to output html or other raw errors
send_chunked_error(Resp, {_Error, {[{<<"body">>, Reason}]}}) ->
    send_chunk(Resp, Reason),
    send_chunk(Resp, []);

send_chunked_error(Resp, Error) ->
    {Code, ErrorStr, ReasonStr} = error_info(Error),
    JsonError = {[{<<"code">>, Code},
        {<<"error">>,  ErrorStr},
        {<<"reason">>, ReasonStr} |
        case json_stack(Error) of [] -> []; Stack -> [{stack, Stack}] end
    ]},
    send_chunk(Resp, ?l2b([$\n,?JSON_ENCODE(JsonError),$\n])),
    send_chunk(Resp, []).

send_redirect(Req, Path) ->
     Headers = [{"Location", chttpd:absolute_uri(Req, Path)}],
     send_response(Req, 301, Headers, <<>>).

server_header() ->
    couch_httpd:server_header().

reqid() ->
    {"X-Couch-Request-ID", get(nonce)}.

json_stack({_Error, _Reason, Stack}) ->
    lists:map(fun json_stack_item/1, Stack);
json_stack(_) ->
    [].

json_stack_item({M,F,A}) ->
    list_to_binary(io_lib:format("~s:~s/~B", [M, F, json_stack_arity(A)]));
json_stack_item({M,F,A,L}) ->
    case proplists:get_value(line, L) of
    undefined -> json_stack_item({M,F,A});
    Line -> list_to_binary(io_lib:format("~s:~s/~B L~B",
        [M, F, json_stack_arity(A), Line]))
    end;
json_stack_item(_) ->
    <<"bad entry in stacktrace">>.

json_stack_arity(A) ->
    if is_integer(A) -> A; is_list(A) -> length(A); true -> 0 end.
