%% Invariant 1, at the door: the first stream handler forgets where a
%% request came from before anything else sees it. No handler, and no
%% crash report quoting a request, can then log an address it never had.
%% The rate limiter (M1) belongs here, ahead of the forgetting.
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
init(StreamID, Req, Opts) ->
    cowboy_stream:init(StreamID, forget(Req), Opts).

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
