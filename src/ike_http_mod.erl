%% Moderation: what an account in a role may do, each a plain form with
%% the session's token and a reason. To anyone else none of it is there.
%% Everything done here goes through ike_writer:moderate/1, which writes
%% it to the log in the same transaction or does not do it.
-module(ike_http_mod).
-behaviour(cowboy_handler).

-export([init/2]).

-type what() :: front | post | board | account | report | booru | meta.
-type who() :: {ike_id:actor(), Csrf :: binary(), ike_role:role()}.

-spec init(cowboy_req:req(), what()) -> {ok, cowboy_req:req(), what()}.
init(Req, What) ->
    Reply =
        case ike_http_login:session(Req) of
            {ok, _Id, #{actor := Actor, csrf := Csrf, role := Role}} when
                Role =:= admin; Role =:= moderator; element(1, Role) =:= janitor
            ->
                Who = {Actor, Csrf, Role},
                case {What, cowboy_req:method(Req)} of
                    {front, <<"GET">>} -> front(Who, Req);
                    {post, <<"GET">>} -> look(Who, Req);
                    {front, _} -> ike_http:reply(405, Req);
                    {report, <<"POST">>} -> dismiss(Who, Req);
                    {booru, <<"GET">>} -> look_entry(Who, Req);
                    {meta, <<"GET">>} -> look_meta(Who, Req);
                    {_, <<"POST">>} -> submit(What, Who, Req);
                    _ -> ike_http:reply(405, Req)
                end;
            _ ->
                ike_http:not_found(Req)
        end,
    {ok, Reply, What}.

-spec front(who(), cowboy_req:req()) -> cowboy_req:req().
front({_, Csrf, Role}, Req) ->
    %% the form that asks for a post by number lands here
    Asked =
        try cowboy_req:match_qs([{post, int, none}], Req) of
            #{post := N} when is_integer(N), N > 0 -> N;
            _ -> none
        catch
            _:_ -> none
        end,
    case Asked of
        none ->
            Down = [
                D
             || {_, Board, _} = D <- ike_reader:out_of_sight(),
                ike_role:permits(Role, unhide, #{
                    board => Board, self => false, account => 0, undo => 0
                })
            ],
            Reports = [
                R
             || {_, _, Board, _} = R <- ike_reader:reports(),
                ike_role:permits(Role, hide, #{
                    board => Board, self => false, account => 0, undo => 0
                })
            ],
            Html = ike_view:moderation(
                {Csrf, Role}, ike_reader:boards(), ike_reader:suspended(), Down, Reports
            ),
            ike_http:page(200, Html, Req);
        Post ->
            ike_http:see_other(<<"/mod/post/", (integer_to_binary(Post))/binary>>, Req)
    end.

-spec look(who(), cowboy_req:req()) -> cowboy_req:req().
look({Actor, Csrf, Role}, Req) ->
    case cowboy_req:binding(post, Req) of
        N when is_integer(N), N > 0 ->
            case ike_reader:post(N) of
                {ok, Post} ->
                    Kinds = kinds(Post, Role, ike_id:to_integer(Actor)),
                    ike_http:page(200, ike_view:moderated({Csrf, Role}, Post, Kinds), Req);
                none ->
                    ike_http:not_found(Req)
            end;
        _ ->
            ike_http:not_found(Req)
    end.

%% what this role can do to a post as it now is, and to each of its
%% images: the forms that would go through, and no others
-spec kinds(ike_view:held(), ike_role:role(), integer()) ->
    {[ike_role:kind()], [{non_neg_integer(), shown | blocked | gone, [ike_role:kind()]}]}.
kinds(#{state := State, account := Account, images := Images} = Post, Role, Actor) ->
    #{board := Board, author := Author, rank := Rank, undo := Undo} = Post,
    Facts = #{board => Board, self => Author =:= Actor, account => Rank, undo => Undo},
    Allowed = fun(Ks) -> [K || K <- Ks, ike_role:permits(Role, K, Facts)] end,
    {Allowed(ladder(State, Account)), [
        {Position, Image,
            Allowed(
                case Image of
                    shown -> [block, purge_image];
                    blocked -> [unblock, purge_image];
                    gone -> []
                end
            )}
     || {Position, Image} <- Images
    ]}.

-spec ladder(shown | hidden | trashed, local | suspended | none) -> [ike_role:kind()].
ladder(State, Account) ->
    Ladder =
        case State of
            shown -> [hide, trash, purge];
            hidden -> [unhide, trash, purge];
            trashed -> [restore, purge]
        end,
    case Account of
        local -> Ladder ++ [ban];
        _ -> Ladder
    end.

-spec submit(what(), who(), cowboy_req:req()) -> cowboy_req:req().
submit(What, {Actor, Csrf, Role}, Req0) ->
    case ike_http:form(Req0) of
        {ok, #{<<"csrf">> := Token, <<"kind">> := Kind0} = Form, Req} ->
            case
                {
                    byte_size(Token) =:= byte_size(Csrf) andalso crypto:hash_equals(Token, Csrf),
                    ike_role:kind(Kind0),
                    target(What, Req)
                }
            of
                {false, _, _} ->
                    ike_http:forbidden(Req);
                {true, {ok, Kind}, {ok, Target0, Back}} ->
                    %% an image's rung names which of the post's images
                    Target =
                        case {Kind, Form, cowboy_req:binding(post, Req), What} of
                            {_, #{<<"image">> := I}, N, post} when
                                (Kind =:= block orelse Kind =:= unblock orelse
                                    Kind =:= purge_image),
                                is_integer(N),
                                N > 0
                            ->
                                case position(I) of
                                    {ok, P} -> {image, ike_id:post(N), P};
                                    error -> Target0
                                end;
                            _ ->
                                Target0
                        end,
                    case fits(What, Kind) of
                        true ->
                            Reason = maps:get(<<"reason">>, Form, <<>>),
                            done(
                                ike_writer:moderate(#{
                                    by => Actor,
                                    role => Role,
                                    kind => Kind,
                                    target => Target,
                                    reason => Reason
                                }),
                                Kind,
                                Back,
                                Req
                            );
                        false ->
                            ike_http:reply(400, Req)
                    end;
                {true, error, _} ->
                    ike_http:reply(400, Req);
                {true, _, none} ->
                    ike_http:not_found(Req)
            end;
        {ok, _, Req} ->
            ike_http:forbidden(Req);
        {error, Status, Req} ->
            ike_http:reply(Status, Req)
    end.

%% what the path names, and the page to go back to
%% a report looked at, by anyone with a role; it is not a moderation
%% and goes in no log
-spec dismiss(who(), cowboy_req:req()) -> cowboy_req:req().
dismiss({_, Csrf, _}, Req0) ->
    case {ike_http:form(Req0), cowboy_req:binding(report, Req0)} of
        {{ok, #{<<"csrf">> := Token, <<"kind">> := <<"dismiss">>}, Req}, N} when
            is_integer(N), N > 0
        ->
            case byte_size(Token) =:= byte_size(Csrf) andalso crypto:hash_equals(Token, Csrf) of
                true ->
                    case ike_writer:dismiss(N) of
                        ok -> ike_http:see_other(<<"/mod">>, Req);
                        {error, no_such_report} -> ike_http:not_found(Req);
                        {error, _} -> ike_http:reply(500, Req)
                    end;
                false ->
                    ike_http:forbidden(Req)
            end;
        {{ok, _, Req}, _} ->
            ike_http:forbidden(Req);
        {{error, Status, Req}, _} ->
            ike_http:reply(Status, Req)
    end.

%% a booru entry, as a moderator sees it
-spec look_entry(who(), cowboy_req:req()) -> cowboy_req:req().
look_entry({_, Csrf, Role}, Req) ->
    case cowboy_req:binding(booru, Req) of
        N when is_integer(N), N > 0 ->
            case ike_reader:entry_state(N) of
                {ok, State} ->
                    Ladder =
                        case State of
                            shown -> [hide, trash];
                            hidden -> [unhide, trash];
                            trashed -> [restore]
                        end,
                    Facts = #{board => <<"booru">>, self => false, account => 0, undo => 0},
                    Kinds = [K || K <- Ladder, ike_role:permits(Role, K, Facts)],
                    ike_http:page(200, ike_view:moderated_entry(Csrf, N, State, Kinds), Req);
                none ->
                    ike_http:not_found(Req)
            end;
        _ ->
            ike_http:not_found(Req)
    end.

%% a meta, as a moderator sees it: its page, whatever its state, and the
%% rungs this role may take
-spec look_meta(who(), cowboy_req:req()) -> cowboy_req:req().
look_meta({Actor, Csrf, Role}, Req) ->
    case meta_hash(Req) of
        {ok, Hash} ->
            Viewer = #{actor => ike_id:to_integer(Actor), moderator => true},
            case ike_reader:meta(Hash, Viewer) of
                {ok, #{state := State}, _} ->
                    Ladder =
                        case State of
                            shown -> [hide, trash];
                            hidden -> [unhide, trash];
                            trashed -> [restore]
                        end,
                    Facts = #{board => <<"trunk">>, self => false, account => 0, undo => 0},
                    Kinds = [K || K <- Ladder, ike_role:permits(Role, K, Facts)],
                    Html = ike_view:moderated_meta(Csrf, Hash, State, Kinds),
                    ike_http:page(200, Html, Req);
                none ->
                    ike_http:not_found(Req)
            end;
        error ->
            ike_http:not_found(Req)
    end.

-spec meta_hash(cowboy_req:req()) -> {ok, binary()} | error.
meta_hash(Req) ->
    case cowboy_req:binding(hex, Req) of
        Hex when is_binary(Hex), byte_size(Hex) =:= 64 ->
            case re:run(Hex, "^[0-9a-f]{64}$", [{capture, none}]) of
                match -> {ok, binary:decode_hex(Hex)};
                nomatch -> error
            end;
        _ ->
            error
    end.

-spec target(what(), cowboy_req:req()) ->
    {ok,
        ike_id:post()
        | {entry, ike_id:booru()}
        | {meta, binary()}
        | ike_id:actor()
        | binary(),
        Back :: binary()}
    | none.
target(post, Req) ->
    case cowboy_req:binding(post, Req) of
        N when is_integer(N), N > 0 ->
            {ok, ike_id:post(N), <<"/mod/post/", (integer_to_binary(N))/binary>>};
        _ ->
            none
    end;
target(board, Req) ->
    case cowboy_req:binding(board, Req) of
        Name when is_binary(Name) -> {ok, Name, <<"/mod">>};
        _ -> none
    end;
target(account, Req) ->
    case cowboy_req:binding(account, Req) of
        N when is_integer(N), N > 0 -> {ok, ike_id:actor(N), <<"/mod">>};
        _ -> none
    end;
target(booru, Req) ->
    case cowboy_req:binding(booru, Req) of
        N when is_integer(N), N > 0 ->
            {ok, {entry, ike_id:booru(N)}, <<"/mod/booru/", (integer_to_binary(N))/binary>>};
        _ ->
            none
    end;
target(meta, Req) ->
    case meta_hash(Req) of
        {ok, Hash} ->
            {ok, {meta, Hash}, <<"/mod/meta/", (binary:encode_hex(Hash, lowercase))/binary>>};
        error ->
            none
    end;
target(_, _Req) ->
    none.

-spec position(binary()) -> {ok, non_neg_integer()} | error.
position(Bin) ->
    case string:to_integer(Bin) of
        {N, <<>>} when is_integer(N), N >= 0 -> {ok, N};
        _ -> error
    end.

-spec fits(what(), ike_role:kind()) -> boolean().
fits(post, Kind) ->
    lists:member(Kind, [hide, unhide, trash, restore, purge, ban, block, unblock, purge_image]);
fits(board, Kind) ->
    Kind =:= lock orelse Kind =:= unlock;
fits(account, Kind) ->
    Kind =:= unban;
fits(booru, Kind) ->
    lists:member(Kind, [hide, unhide, trash, restore]);
fits(meta, Kind) ->
    lists:member(Kind, [hide, unhide, trash, restore]);
fits(front, _) ->
    false.

-spec done(ok | {error, term()}, ike_role:kind(), binary(), cowboy_req:req()) -> cowboy_req:req().
done(ok, Kind, Back, Req) ->
    %% the pages say so before the browser is sent anywhere
    _ = ike_render:sync(),
    case Kind of
        %% nothing is left of it to go back to
        purge -> ike_http:see_other(<<"/mod">>, Req);
        _ -> ike_http:see_other(Back, Req)
    end;
done({error, not_allowed}, _Kind, _Back, Req) ->
    Html = ike_view:message(<<"not allowed">>, <<"your role does not do that.">>),
    ike_http:page(403, Html, Req);
done({error, bad_text}, _Kind, _Back, Req) ->
    Html = ike_view:message(
        <<"not done">>,
        <<"give a reason: text, not empty, not long, no control characters.">>
    ),
    ike_http:page(400, Html, Req);
done({error, not_now}, _Kind, _Back, Req) ->
    Html = ike_view:message(<<"not done">>, <<"it is not in a state for that; look again.">>),
    ike_http:page(409, Html, Req);
done({error, Missing}, _Kind, _Back, Req) when
    Missing =:= no_such_post;
    Missing =:= no_such_account;
    Missing =:= no_such_board;
    Missing =:= no_such_meta
->
    ike_http:not_found(Req);
done({error, _}, _Kind, _Back, Req) ->
    ike_http:reply(500, Req).
