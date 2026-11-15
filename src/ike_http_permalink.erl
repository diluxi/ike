%% /p/N: where a post is now. Pages link here rather than to a thread's
%% page, so that a post that moves needs no page made again (hazard g4).
-module(ike_http_permalink).
-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req, State) ->
    Reply =
        case {cowboy_req:method(Req), cowboy_req:binding(post, Req)} of
            {Method, Post} when
                Method =:= <<"GET">> orelse Method =:= <<"HEAD">>, is_integer(Post), Post > 0
            ->
                case ike_reader:whereabouts(Post) of
                    {ok, Board, Thread} ->
                        T = integer_to_binary(Thread),
                        P = integer_to_binary(Post),
                        ike_http:see_other(
                            <<"/board/", Board/binary, "/", T/binary, "#p", P/binary>>, Req
                        );
                    none ->
                        ike_http:not_found(Req)
                end;
            _ ->
                ike_http:not_found(Req)
        end,
    {ok, Reply, State}.
