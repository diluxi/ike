%% The Cowboy listener: everything Caddy does not serve from disk, and
%% what every response has in common.
-module(ike_http).

-export([child_spec/0]).
-export([headers/0]).
-export([html/3, page/3, reply/2, not_found/1, forbidden/1, see_other/2, form/1]).

%% what a form may weigh; caddy caps bodies at the same size
-define(FORM_BYTES, 65536).

-spec child_spec() -> supervisor:child_spec().
child_spec() ->
    #{ip := Ip, port := Port} = application:get_env(ike, listen, #{}),
    ranch:child_spec(
        ?MODULE,
        ranch_tcp,
        #{socket_opts => [{ip, Ip}, {port, Port}]},
        cowboy_clear,
        #{
            env => #{dispatch => dispatch()},
            %% ike_http_anon first: nothing after it knows the peer
            stream_handlers => [ike_http_anon, cowboy_stream_h]
        }
    ).

-spec dispatch() -> cowboy_router:dispatch_rules().
dispatch() ->
    Thread = {thread, int},
    cowboy_router:compile([
        {'_', [
            {"/health", ike_http_health, []},
            {"/", ike_http_page, []},
            {"/t/:thread", [Thread], ike_http_page, []},
            {"/new", ike_http_post, []},
            {"/t/:thread/reply", [Thread], ike_http_post, []},
            {"/login", ike_http_login, login},
            {"/login/callback", ike_http_login, callback},
            {"/logout", ike_http_login, logout},
            %% everything else, so that a miss is answered by ike and not
            %% by cowboy's bare 404
            {'_', ike_http_page, missing}
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

%% no session, or a form without its token (hazard i2)
-spec forbidden(cowboy_req:req()) -> cowboy_req:req().
forbidden(Req) ->
    Html = ike_view:message(
        <<"not allowed">>, <<"log in at /login, and send forms from this site's own pages.">>
    ),
    page(403, Html, Req).

%% a submitted form. only urlencoded ones are read at all: a multipart
%% body, which is what carries files, is refused unread (hazard a1)
-spec form(cowboy_req:req()) ->
    {ok, #{binary() => binary()}, cowboy_req:req()}
    | {error, cowboy:http_status(), cowboy_req:req()}.
form(Req0) ->
    try cowboy_req:parse_header(<<"content-type">>, Req0) of
        {<<"application">>, <<"x-www-form-urlencoded">>, _} ->
            try cowboy_req:read_urlencoded_body(Req0, #{length => ?FORM_BYTES, period => 5000}) of
                {ok, Pairs, Req} ->
                    {ok, maps:from_list([{K, V} || {K, V} <- Pairs, is_binary(V)]), Req}
            catch
                _:_ -> {error, 400, Req0}
            end;
        _ ->
            {error, 415, Req0}
    catch
        _:_ -> {error, 400, Req0}
    end.
