%% /trunk: every asset's meta, what is known of it beyond its bytes
%% (lux, 2026-11-17). Public metas are everyone's to see; a private one is
%% its owner's and the moderators' alone (invariant 10), and its files are
%% reached only by the signed links these pages give them. Made per
%% request, since what is listed depends on who asks.
-module(ike_http_trunk).
-behaviour(cowboy_handler).

-export([init/2, viewer/1]).

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
        case {cowboy_req:method(Req), cowboy_req:binding(meta, Req)} of
            {<<"GET">>, N} when is_integer(N), N > 0 -> shown(N, Req);
            {<<"POST">>, N} when is_integer(N), N > 0 -> owned(N, Req);
            {_, N} when is_integer(N) -> ike_http:reply(405, Req);
            _ -> ike_http:not_found(Req)
        end,
    {ok, Reply, State}.

-spec viewer(cowboy_req:req()) ->
    {ike_reader:viewer(), none | {ike_id:actor(), binary(), binary() | none}}.
viewer(Req) ->
    case ike_http_login:session(Req) of
        {ok, _, #{actor := Actor, csrf := Csrf, role := Role, name := Name}} ->
            {
                #{actor => ike_id:to_integer(Actor), moderator => moderator(Role)},
                {Actor, Csrf, Name}
            };
        error ->
            {#{actor => none, moderator => false}, none}
    end.

%% moderators and up see every meta; a janitor is not one of them
-spec moderator(term()) -> boolean().
moderator(admin) -> true;
moderator(moderator) -> true;
moderator(_) -> false.

%% where its files are: a public, shown meta's on the media origin, as a
%% post's are; any other's behind short-lived signed links, which only a
%% page its owner or a moderator asked for ever holds
-spec links(ike_reader:meta()) -> ike_view:image().
links(#{hash := Hash, type := Type, width := W, height := H, private := false, state := shown}) ->
    Hex = binary:encode_hex(Hash, lowercase),
    #{
        file => ike_media:url(Hex, Type),
        thumb => ike_media:thumb_url(Hex),
        type => Type,
        width => W,
        height => H
    };
links(#{upload := Upload, type := Type, width := W, height := H}) ->
    #{
        file => ike_staged:url(Upload, file),
        thumb => ike_staged:url(Upload, thumb),
        type => Type,
        width => W,
        height => H
    }.

%% one meta, or the same 404 whether it is not there or not the asker's
%% to see (hazard G5)
-spec shown(pos_integer(), cowboy_req:req()) -> cowboy_req:req().
shown(Id, Req) ->
    {#{moderator := Moderator} = Viewer, Session} = viewer(Req),
    case ike_reader:meta(Id, Viewer) of
        {ok, #{mine := Mine} = Meta, Posts} ->
            {Csrf, Name} =
                case {Mine, Session} of
                    {true, {_, C, N}} -> {C, N};
                    _ -> {none, none}
                end,
            Who = #{csrf => Csrf, moderator => Moderator, name => Name},
            ike_http:page(200, ike_view:meta(Meta, links(Meta), Posts, Who), Req);
        none ->
            ike_http:not_found(Req)
    end.

%% the owner makes it private, or public (unless the bytes have a public
%% meta already: then they are sent to it), or puts their name on it
-spec owned(pos_integer(), cowboy_req:req()) -> cowboy_req:req().
owned(Id, Req0) ->
    Here = <<"/trunk/", (integer_to_binary(Id))/binary>>,
    case {viewer(Req0), ike_http:form(Req0)} of
        {{_, {Actor, Csrf, _}}, {ok, #{<<"csrf">> := Token} = Form, Req}} ->
            case byte_size(Token) =:= byte_size(Csrf) andalso crypto:hash_equals(Token, Csrf) of
                true ->
                    Done =
                        case Form of
                            #{<<"sign">> := <<"1">>} ->
                                ike_writer:sign_meta(Id, Actor);
                            #{<<"private">> := P} ->
                                ike_writer:privacy(Id, Actor, P =:= <<"1">>);
                            _ ->
                                {error, bad_request}
                        end,
                    case Done of
                        ok ->
                            ike_http:see_other(Here, Req);
                        {error, {taken, Other}} when is_integer(Other) ->
                            ike_http:see_other(
                                <<"/trunk/", (integer_to_binary(Other))/binary>>, Req
                            );
                        {error, not_yours} ->
                            ike_http:forbidden(Req);
                        {error, bad_request} ->
                            ike_http:reply(400, Req);
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
