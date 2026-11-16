%% /user/NAME: an account's own page, what it signed, newest first. Made
%% per request; lux's user boards (Q10, Q14) grow from here.
-module(ike_http_user).
-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), State) -> {ok, cowboy_req:req(), State}.
init(Req, State) ->
    Reply =
        case {cowboy_req:method(Req), cowboy_req:binding(name, Req)} of
            {<<"GET">>, Name} when is_binary(Name), byte_size(Name) =< 64 ->
                case ike_reader:signed(Name) of
                    {ok, Posts} -> ike_http:page(200, ike_view:user(Name, Posts), Req);
                    none -> ike_http:not_found(Req)
                end;
            {<<"GET">>, _} ->
                ike_http:not_found(Req);
            _ ->
                ike_http:reply(405, Req)
        end,
    {ok, Reply, State}.
