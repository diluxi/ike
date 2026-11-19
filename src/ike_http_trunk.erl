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
    {ok, Reply, State};
%% a comment on a meta, or the meta curated: by an account that may see
%% it, with the session's token
init(Req, What) when What =:= comment; What =:= curate ->
    Reply =
        case {cowboy_req:method(Req), cowboy_req:binding(meta, Req)} of
            {<<"POST">>, N} when is_integer(N), N > 0, What =:= comment -> acted(comment, N, Req);
            {<<"POST">>, N} when is_integer(N), N > 0 -> acted(curate, N, Req);
            {<<"POST">>, _} -> ike_http:not_found(Req);
            _ -> ike_http:reply(405, Req)
        end,
    {ok, Reply, What}.

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
shown(Id, Req0) ->
    {#{moderator := Moderator} = Viewer, Session} = viewer(Req0),
    %% the password this browser comments with, as on the boards
    {Password, Req} = ike_http_post:kept_password(Req0),
    case ike_reader:meta(Id, Viewer) of
        %% curated: what is known of it is the curation's now (lux)
        {ok, #{curation := Entry}, _} when is_integer(Entry) ->
            ike_http:see_other(<<"/booru/", (integer_to_binary(Entry))/binary>>, Req);
        {ok, #{mine := Mine, thread := Thread} = Meta, Posts} ->
            {Csrf, Name} =
                case {Mine, Session} of
                    {true, {_, C, N}} -> {C, N};
                    _ -> {none, none}
                end,
            Account =
                case Session of
                    {_, C1, N1} -> {C1, N1};
                    none -> none
                end,
            Comments =
                case Thread of
                    _ when is_integer(Thread) -> ike_reader:comments(Thread);
                    none -> []
                end,
            #{private := Private, state := State} = Meta,
            Who = #{
                csrf => Csrf,
                moderator => Moderator,
                name => Name,
                account => Account,
                comments => Comments,
                password => Password,
                open =>
                    not Private andalso State =:= shown andalso
                    ike_reader:board(<<"trunk">>) =:= open
            },
            ike_http:page(200, ike_view:meta(Meta, links(Meta), Posts, Who), Req);
        none ->
            ike_http:not_found(Req)
    end.

%% a comment, signed if asked and the account has a name, or the meta
%% curated with the tags given; only by an account that may see it
-spec acted(comment | curate, pos_integer(), cowboy_req:req()) -> cowboy_req:req().
acted(What, Id, Req0) ->
    Here = <<"/trunk/", (integer_to_binary(Id))/binary>>,
    case {viewer(Req0), ike_http:form(Req0)} of
        {{Viewer, {Actor, Csrf, Name}}, {ok, #{<<"csrf">> := Token} = Form, Req}} ->
            Fair = byte_size(Token) =:= byte_size(Csrf) andalso crypto:hash_equals(Token, Csrf),
            Signed = is_binary(Name) andalso maps:get(<<"signed">>, Form, <<>>) =:= <<"1">>,
            case {Fair, ike_reader:meta(Id, Viewer)} of
                {false, _} ->
                    ike_http:forbidden(Req);
                {true, none} ->
                    ike_http:not_found(Req);
                {true, {ok, _, _}} when What =:= comment ->
                    By =
                        case Signed of
                            true -> Actor;
                            false -> ike_id:anonymous()
                        end,
                    case
                        ike_writer:comment(
                            Id, By, maps:get(<<"body">>, Form, <<>>), password(Form)
                        )
                    of
                        {ok, Post} ->
                            _ = ike_render:sync(),
                            P = integer_to_binary(ike_id:to_integer(Post)),
                            ike_http:see_other(<<Here/binary, "#p", P/binary>>, Req);
                        {error, bad_text} ->
                            ike_http:page(
                                400,
                                ike_view:message(
                                    <<"not posted">>,
                                    <<"a comment is text: not empty, not too long, no control characters.">>
                                ),
                                Req
                            );
                        {error, _} ->
                            ike_http:reply(500, Req)
                    end;
                {true, {ok, _, _}} ->
                    {Box, _} = ike_tag:layout(maps:get(<<"tags">>, Form, <<>>)),
                    case ike_writer:curate(Id, Actor, Signed, Box) of
                        {ok, Entry} ->
                            _ = ike_render:sync(),
                            ike_http:see_other(
                                <<"/booru/", (integer_to_binary(Entry))/binary>>, Req
                            );
                        {error, {curated, Entry}} when is_integer(Entry) ->
                            ike_http:see_other(
                                <<"/booru/", (integer_to_binary(Entry))/binary>>, Req
                            );
                        {error, not_public} ->
                            ike_http:page(
                                409,
                                ike_view:message(
                                    <<"not curated">>,
                                    <<"only a public meta goes to the booru, for now.">>
                                ),
                                Req
                            );
                        {error, no_such_meta} ->
                            ike_http:not_found(Req);
                        {error, {ambiguous, Name1, Words}} when is_binary(Name1), is_list(Words) ->
                            Html = ike_view:ambiguous(Name1, [W || W <- Words, is_binary(W)]),
                            ike_http:page(422, Html, Req);
                        {error, _} ->
                            ike_http:reply(500, Req)
                    end
            end;
        %% nobody comments on a public meta, once an admin has opened the
        %% trunk (lux): from this site, at the trunk's pace, as nobody
        {{Viewer, none}, {ok, Form, Req}} when What =:= comment ->
            case
                {
                    ike_reader:board(<<"trunk">>),
                    ike_http:guarded(Req0),
                    ike_reader:meta(Id, Viewer)
                }
            of
                {open, true, {ok, _, _}} ->
                    case ike_limit:board(<<"trunk">>) of
                        ok ->
                            Body = maps:get(<<"body">>, Form, <<>>),
                            case ike_writer:comment(Id, ike_id:anonymous(), Body, password(Form)) of
                                {ok, Post} ->
                                    _ = ike_render:sync(),
                                    P = integer_to_binary(ike_id:to_integer(Post)),
                                    ike_http:see_other(<<Here/binary, "#p", P/binary>>, Req);
                                {error, bad_text} ->
                                    ike_http:page(
                                        400,
                                        ike_view:message(
                                            <<"not posted">>,
                                            <<"a comment is text: not empty, not too long, no control characters.">>
                                        ),
                                        Req
                                    );
                                {error, _} ->
                                    ike_http:reply(500, Req)
                            end;
                        limited ->
                            ike_http:page(
                                429,
                                ike_view:message(
                                    <<"slow down">>,
                                    <<"comments without an account come only so fast. try again in a while.">>
                                ),
                                Req
                            )
                    end;
                {_, _, none} ->
                    ike_http:not_found(Req);
                _ ->
                    ike_http:forbidden(Req)
            end;
        {_, {ok, _, Req}} ->
            ike_http:forbidden(Req);
        {_, {error, Status, Req}} ->
            ike_http:reply(Status, Req)
    end.

%% the password a comment is retracted with, if one was given
-spec password(#{binary() => binary()}) -> binary() | none.
password(#{<<"password">> := P}) when byte_size(P) > 0, byte_size(P) =< 256 -> P;
password(_) -> none.

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
