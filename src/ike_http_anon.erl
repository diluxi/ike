%% Invariant 1, at the door: the first stream handler forgets where a
%% request came from before anything else sees it. No handler, and no
%% crash report quoting a request, can then log an address it never had.
%%
%% The rate limiter sits here, ahead of the forgetting, and its answer
%% is acted on here too: a request that is turned away never reaches a
%% handler, and one that is let through carries no trace of having been
%% counted.
-module(ike_http_anon).
-behaviour(cowboy_stream).

-export([init/3, data/4, info/3, terminate/3, early_error/5]).

-type next() :: {module(), term()} | undefined.

-define(NOWHERE, {{0, 0, 0, 0}, 0}).
%% what a proxy in front says about the client
-define(FORWARDING, [
    <<"forwarded">>,
    <<"x-forwarded-for">>,
    <<"x-forwarded-host">>,
    <<"x-real-ip">>,
    <<"x-client-ip">>
]).

-spec init(cowboy_stream:streamid(), cowboy_req:req(), cowboy:opts()) ->
    {cowboy_stream:commands(), next()}.
init(StreamID, Req0, Opts) ->
    Verdict = verdict(Req0),
    Req = forget(Req0),
    case Verdict of
        ok ->
            cowboy_stream:init(StreamID, Req, Opts);
        limited ->
            %% only who posts as nobody is held to it: an account can be
            %% banned, and nobody cannot
            case ike_http_login:session(Req) of
                {ok, _, _} -> cowboy_stream:init(StreamID, Req, Opts);
                error -> {[slow_down(), stop], undefined}
            end
    end.

%% every post is counted against where it came from, whoever sent it and
%% whatever becomes of it. nothing that goes wrong in the counting may
%% be reported, since a report would quote the address: it is turned
%% into the answer no instead
-spec verdict(cowboy_req:req()) -> ok | limited.
verdict(#{method := <<"POST">>, peer := {Peer, _}, headers := Headers}) ->
    try
        ike_limit:charge(Peer, maps:get(<<"x-forwarded-for">>, Headers, undefined))
    catch
        _:_ -> limited
    end;
verdict(_) ->
    ok.

-spec slow_down() -> cowboy_stream:resp_command().
slow_down() ->
    #{seconds := Seconds} = ike_config:limit(),
    Html = ike_view:message(
        <<"slow down">>, <<"too many posts from your network just now. try again in a while.">>
    ),
    Body = ike_html:to_iodata(Html),
    %% said here because nothing below this says it for us: without a
    %% length the answer ends only when the connection does, and a proxy
    %% that keeps its connections waits for that
    Headers = (ike_http:headers())#{
        <<"content-type">> => <<"text/html; charset=utf-8">>,
        <<"content-length">> => integer_to_binary(iolist_size(Body)),
        <<"retry-after">> => integer_to_binary(Seconds)
    },
    {response, 429, Headers, Body}.

-spec data(cowboy_stream:streamid(), cowboy_stream:fin(), binary(), next()) ->
    {cowboy_stream:commands(), next()}.
data(StreamID, IsFin, Data, Next) ->
    cowboy_stream:data(StreamID, IsFin, Data, Next).

-spec info(cowboy_stream:streamid(), term(), next()) ->
    {cowboy_stream:commands(), next()}.
info(StreamID, Info, Next) ->
    cowboy_stream:info(StreamID, Info, Next).

-spec terminate(cowboy_stream:streamid(), cowboy_stream:reason(), next()) -> ok.
terminate(StreamID, Reason, Next) ->
    _ = cowboy_stream:terminate(StreamID, Reason, Next),
    ok.

-spec early_error(
    cowboy_stream:streamid(),
    cowboy_stream:reason(),
    cowboy_stream:partial_req(),
    Resp,
    cowboy:opts()
) -> Resp when
    Resp :: cowboy_stream:resp_command().
early_error(StreamID, Reason, PartialReq, Resp0, Opts) ->
    %% a request too broken to route is still answered with the headers
    Resp =
        case Resp0 of
            {response, Status, Headers, Body} when is_map(Headers) ->
                {response, Status, maps:merge(ike_http:headers(), Headers), Body};
            _ ->
                Resp0
        end,
    cowboy_stream:early_error(StreamID, Reason, PartialReq, Resp, Opts).

%% the common headers ride along as the response's defaults, so that an
%% answer cowboy gives by itself carries them too
-spec forget(cowboy_req:req()) -> cowboy_req:req().
forget(#{headers := Headers} = Req) ->
    cowboy_req:set_resp_headers(
        ike_http:headers(),
        Req#{peer := ?NOWHERE, headers := maps:without(?FORWARDING, Headers)}
    ).
