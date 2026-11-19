%% Serves the rendered pages when no web server in front does (Caddy
%% answers these paths from the same files before a request gets here).
-module(ike_http_page).
-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), State) -> {ok, cowboy_req:req(), State}.
init(Req, missing = State) ->
    {ok, ike_http:not_found(Req), State};
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
        %% the trunk's threads are read where they belong: a meta's page or
        %% its curation's (lux: no board of their own)
        {_, <<"board/trunk">>} ->
            {ok, ike_http:see_other(<<"/trunk">>, Req), State};
        {_, <<"board/trunk/", _/binary>>} ->
            Where =
                case ike_reader:attached(cowboy_req:binding(thread, Req)) of
                    {booru, Owner} -> <<"/booru/", (integer_to_binary(Owner))/binary>>;
                    {meta, M} -> <<"/trunk/", (integer_to_binary(M))/binary>>;
                    none -> <<"/trunk">>
                end,
            {ok, ike_http:see_other(Where, Req), State};
        %% a card reached from a search: made here, its bar holding it
        {Method, <<"booru/", _/binary>>} when
            (Method =:= <<"GET">> orelse Method =:= <<"HEAD">>), State =:= entry
        ->
            case {searched(Req), cowboy_req:binding(booru, Req)} of
                {Query, Entry} when Query =/= [], is_integer(Entry), Entry > 0 ->
                    case ike_reader:entry_page(Entry, Query) of
                        {ok, Page} -> {ok, ike_http:html(200, Page, Req), State};
                        none -> {ok, ike_http:not_found(Req), State}
                    end;
                _ ->
                    {ok, from_disk(Name, Req), State}
            end;
        {Method, _} when Method =:= <<"GET">>; Method =:= <<"HEAD">> ->
            {ok, from_disk(Name, Req), State};
        _ ->
            {ok, ike_http:reply(405, Req), State}
    end.

-spec from_disk(binary(), cowboy_req:req()) -> cowboy_req:req().
from_disk(Name, Req) ->
    Path = <<(ike_config:pages_dir())/binary, "/", Name/binary, ".html">>,
    case file:read_file(Path) of
        {ok, Page} -> ike_http:html(200, Page, Req);
        {error, _} -> ike_http:not_found(Req)
    end.

%% the search a card was reached by, as the bar keeps it
-spec searched(cowboy_req:req()) -> [binary()].
searched(Req) ->
    try cowboy_req:match_qs([{tags, [], <<>>}], Req) of
        #{tags := T} when is_binary(T) -> ike_tag:said(T);
        _ -> []
    catch
        _:_ -> []
    end.

%% the script, as the renderer wrote it
-spec plain(binary(), binary(), cowboy_req:req()) -> cowboy_req:req().
plain(Name, Type, Req) ->
    case file:read_file(<<(ike_config:pages_dir())/binary, "/", Name/binary>>) of
        {ok, Bytes} ->
            cowboy_req:reply(200, (ike_http:headers())#{<<"content-type">> => Type}, Bytes, Req);
        {error, _} ->
            ike_http:not_found(Req)
    end.
