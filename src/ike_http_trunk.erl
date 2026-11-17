%% /trunk: every asset's meta, what is known of it beyond its bytes
%% (lux, 2026-11-17). Public metas are everyone's to see; a private one is
%% its owner's and the moderators' alone (invariant 10), and its files are
%% reached only by the signed links these pages give them. Made per
%% request, since what is listed depends on who asks.
-module(ike_http_trunk).
-behaviour(cowboy_handler).

-export([init/2, viewer/1, hash/1]).

-spec init(cowboy_req:req(), State) -> {ok, cowboy_req:req(), State}.
init(Req, index = State) ->
    Reply =
        case cowboy_req:method(Req) of
            <<"GET">> ->
                {Viewer, _} = viewer(Req),
                Metas = [{M, links(M)} || M <- ike_reader:metas(Viewer)],
                ike_http:page(200, ike_view:trunk(Metas), Req);
            _ ->
                ike_http:reply(405, Req)
        end,
    {ok, Reply, State};
init(Req, meta = State) ->
    Reply =
        case {cowboy_req:method(Req), hash(cowboy_req:binding(hex, Req))} of
            {<<"GET">>, {ok, Hash}} -> shown(Hash, Req);
            {<<"POST">>, {ok, Hash}} -> privacy(Hash, Req);
            {_, error} -> ike_http:not_found(Req);
            _ -> ike_http:reply(405, Req)
        end,
    {ok, Reply, State}.

%% a meta's address is its asset's hash, in lowercase hex
-spec hash(term()) -> {ok, binary()} | error.
hash(Hex) when is_binary(Hex), byte_size(Hex) =:= 64 ->
    case re:run(Hex, "^[0-9a-f]{64}$", [{capture, none}]) of
        match -> {ok, binary:decode_hex(Hex)};
        nomatch -> error
    end;
hash(_) ->
    error.

-spec viewer(cowboy_req:req()) -> {ike_reader:viewer(), none | {ike_id:actor(), binary()}}.
viewer(Req) ->
    case ike_http_login:session(Req) of
        {ok, _, #{actor := Actor, csrf := Csrf, role := Role}} ->
            {
                #{actor => ike_id:to_integer(Actor), moderator => moderator(Role)},
                {Actor, Csrf}
            };
        error ->
            {#{actor => none, moderator => false}, none}
    end.

%% moderators and up see every meta; a janitor is not one of them
-spec moderator(term()) -> boolean().
moderator(admin) -> true;
moderator(moderator) -> true;
moderator(_) -> false.

%% where its files are: a public meta's on the media origin, as a post's
%% are; a private one's behind short-lived signed links, which only a
%% page its owner or a moderator asked for ever holds
-spec links(ike_reader:meta()) -> ike_view:image().
links(#{hash := Hash, type := Type, width := W, height := H, private := false}) ->
    Hex = binary:encode_hex(Hash, lowercase),
    #{
        file => ike_media:url(Hex, Type),
        thumb => ike_media:thumb_url(Hex),
        type => Type,
        width => W,
        height => H
    };
links(#{upload := Upload, type := Type, width := W, height := H, private := true}) ->
    #{
        file => ike_staged:url(Upload, file),
        thumb => ike_staged:url(Upload, thumb),
        type => Type,
        width => W,
        height => H
    }.

%% one meta, or the same 404 whether it is not there or not the asker's
%% to see (hazard G5)
-spec shown(binary(), cowboy_req:req()) -> cowboy_req:req().
shown(Hash, Req) ->
    {#{moderator := Moderator} = Viewer, Session} = viewer(Req),
    case ike_reader:meta(Hash, Viewer) of
        {ok, #{mine := Mine} = Meta, Posts} ->
            Csrf =
                case {Mine, Session} of
                    {true, {_, C}} -> C;
                    _ -> none
                end,
            Who = #{csrf => Csrf, moderator => Moderator},
            ike_http:page(200, ike_view:meta(Meta, links(Meta), Posts, Who), Req);
        none ->
            ike_http:not_found(Req)
    end.

%% the owner makes it private, or public again
-spec privacy(binary(), cowboy_req:req()) -> cowboy_req:req().
privacy(Hash, Req0) ->
    case {viewer(Req0), ike_http:form(Req0)} of
        {{_, {Actor, Csrf}}, {ok, #{<<"csrf">> := Token} = Form, Req}} ->
            case byte_size(Token) =:= byte_size(Csrf) andalso crypto:hash_equals(Token, Csrf) of
                true ->
                    Private = maps:get(<<"private">>, Form, <<"0">>) =:= <<"1">>,
                    case ike_writer:privacy(Hash, Actor, Private) of
                        ok ->
                            Hex = binary:encode_hex(Hash, lowercase),
                            ike_http:see_other(<<"/trunk/", Hex/binary>>, Req);
                        {error, not_yours} ->
                            ike_http:forbidden(Req);
                        {error, _} ->
                            ike_http:reply(500, Req)
                    end;
                false ->
                    ike_http:forbidden(Req)
            end;
        {_, {ok, _, Req}} ->
            ike_http:forbidden(Req);
        {_, {error, Status, Req}} ->
            ike_http:reply(Status, Req)
    end.
