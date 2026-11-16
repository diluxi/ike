%% Serves the rendered pages when no web server in front does (Caddy
%% answers these paths from the same files before a request gets here).
-module(ike_http_page).
-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), State) -> {ok, cowboy_req:req(), State}.
init(Req, missing = State) ->
    {ok, ike_http:not_found(Req), State};
init(Req, style = State) ->
    {ok, plain(<<"style.css">>, <<"text/css; charset=utf-8">>, Req), State};
init(Req, script = State) ->
    {ok, plain(<<"ike.js">>, <<"text/javascript; charset=utf-8">>, Req), State};
init(Req, State) ->
    %% from what the route bound, never from the path as it was sent: the
    %% router resolves dots and escapes, a file name must not have to
    Name =
        case {cowboy_req:binding(board, Req), cowboy_req:binding(thread, Req), State} of
            {undefined, undefined, front} ->
                <<"index">>;
            {undefined, undefined, booru} ->
                <<"booru">>;
            {undefined, undefined, entry} ->
                case cowboy_req:binding(booru, Req) of
                    E when is_integer(E), E > 0 -> <<"booru/", (integer_to_binary(E))/binary>>;
                    _ -> none
                end;
            {undefined, undefined, boards} ->
                <<"board">>;
            {Board, undefined, _} when is_binary(Board) ->
                <<"board/", Board/binary>>;
            {Board, N, _} when is_binary(Board), is_integer(N), N > 0 ->
                <<"board/", Board/binary, "/", (integer_to_binary(N))/binary>>;
            _ ->
                none
        end,
    case {cowboy_req:method(Req), Name} of
        {_, none} ->
            {ok, ike_http:not_found(Req), State};
        {Method, _} when Method =:= <<"GET">>; Method =:= <<"HEAD">> ->
            Path = <<(ike_config:pages_dir())/binary, "/", Name/binary, ".html">>,
            case file:read_file(Path) of
                {ok, Page} -> {ok, ike_http:html(200, Page, Req), State};
                {error, _} -> {ok, ike_http:not_found(Req), State}
            end;
        _ ->
            {ok, ike_http:reply(405, Req), State}
    end.

%% the stylesheet or the script, as the renderer wrote them
-spec plain(binary(), binary(), cowboy_req:req()) -> cowboy_req:req().
plain(Name, Type, Req) ->
    case file:read_file(<<(ike_config:pages_dir())/binary, "/", Name/binary>>) of
        {ok, Bytes} ->
            cowboy_req:reply(200, (ike_http:headers())#{<<"content-type">> => Type}, Bytes, Req);
        {error, _} ->
            ike_http:not_found(Req)
    end.
