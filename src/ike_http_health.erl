%% Tells whoever asks that the release is up.
-module(ike_http_health).
-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), State) -> {ok, cowboy_req:req(), State}.
init(Req, State) ->
    Headers = #{<<"content-type">> => <<"text/plain; charset=utf-8">>},
    {ok, cowboy_req:reply(200, Headers, <<"ok\n">>, Req), State}.
