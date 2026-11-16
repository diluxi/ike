%% /account: who you are here, made per request, since the pages are
%% the same for everyone. The way to log out from any page.
-module(ike_http_account).
-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), State) -> {ok, cowboy_req:req(), State}.
init(Req, State) ->
    Reply =
        case {cowboy_req:method(Req), ike_http_login:session(Req)} of
            {<<"GET">>, {ok, _, #{csrf := Csrf, name := Name, role := Role}}} ->
                ike_http:page(200, ike_view:account({Csrf, Name, Role}), Req);
            {<<"GET">>, error} ->
                ike_http:page(200, ike_view:account(nobody), Req);
            _ ->
                ike_http:reply(405, Req)
        end,
    {ok, Reply, State}.
