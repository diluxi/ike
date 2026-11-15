%% The Cowboy listener: everything Caddy does not serve from disk, and
%% what every response has in common.
-module(ike_http).

-export([child_spec/0]).
-export([html/3, page/3, reply/2, not_found/1, see_other/2]).

-spec child_spec() -> supervisor:child_spec().
child_spec() ->
    #{ip := Ip, port := Port} = application:get_env(ike, listen, #{}),
    ranch:child_spec(
        ?MODULE,
        ranch_tcp,
        #{socket_opts => [{ip, Ip}, {port, Port}]},
        cowboy_clear,
        #{env => #{dispatch => dispatch()}}
    ).

-spec dispatch() -> cowboy_router:dispatch_rules().
dispatch() ->
    Thread = {thread, int},
    cowboy_router:compile([
        {'_', [
            {"/health", ike_http_health, []},
            {"/", ike_http_page, []},
            {"/t/:thread", [Thread], ike_http_page, []}
        ]}
    ]).

%% nothing ike sends may run a script, be framed or be sniffed into
%% another type. caddy sets the same on the pages it serves from disk
-spec headers() -> cowboy:http_headers().
headers() ->
    #{
        <<"content-security-policy">> =>
            <<"default-src 'none'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'">>,
        <<"x-content-type-options">> => <<"nosniff">>,
        <<"referrer-policy">> => <<"same-origin">>,
        <<"cache-control">> => <<"no-store">>
    }.

-spec html(cowboy:http_status(), iodata(), cowboy_req:req()) -> cowboy_req:req().
html(Status, Body, Req) ->
    Headers = (headers())#{
        <<"content-type">> => <<"text/html; charset=utf-8">>
    },
    cowboy_req:reply(Status, Headers, Body, Req).

%% a page made for this request, through the same tree as the static ones
-spec page(cowboy:http_status(), ike_html:html(), cowboy_req:req()) ->
    cowboy_req:req().
page(Status, Html, Req) ->
    html(Status, ike_html:to_iodata(Html), Req).

-spec reply(cowboy:http_status(), cowboy_req:req()) -> cowboy_req:req().
reply(Status, Req) ->
    cowboy_req:reply(Status, headers(), <<>>, Req).

-spec not_found(cowboy_req:req()) -> cowboy_req:req().
not_found(Req) ->
    page(404, ike_view:message(<<"not found">>, <<"nothing here.">>), Req).

-spec see_other(Location :: binary(), cowboy_req:req()) -> cowboy_req:req().
see_other(Location, Req) ->
    cowboy_req:reply(303, (headers())#{<<"location">> => Location}, <<>>, Req).
