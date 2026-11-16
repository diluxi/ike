%% Moderation: what an account in a role may do, each a plain form with
%% the session's token and a reason. To anyone else none of it is there.
%% Everything done here goes through ike_writer:moderate/1, which writes
%% it to the log in the same transaction or does not do it.
-module(ike_http_mod).
-behaviour(cowboy_handler).

-export([init/2]).

-type what() :: front | post | board | account.
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
            Html = ike_view:moderation({Csrf, Role}, ike_reader:boards(), ike_reader:suspended()),
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

%% what this role can do to a post as it now is: the forms that would
%% go through, and no others
-spec kinds(ike_view:held(), ike_role:role(), integer()) -> [ike_role:kind()].
kinds(#{state := State, account := Account, image := Image} = Post, Role, Actor) ->
    #{board := Board, author := Author, rank := Rank, undo := Undo} = Post,
    Facts = #{board => Board, self => Author =:= Actor, account => Rank, undo => Undo},
    Pictured =
        case Image of
            none -> [];
            shown -> [block, purge_image];
            blocked -> [unblock, purge_image]
        end,
    [K || K <- ladder(State, Account) ++ Pictured, ike_role:permits(Role, K, Facts)].

-spec ladder(shown | hidden | deleted, local | suspended | none) -> [ike_role:kind()].
ladder(State, Account) ->
    Ladder =
        case State of
            shown -> [hide, delete, purge];
            hidden -> [unhide, delete, purge];
            deleted -> [restore, purge]
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
                {true, {ok, Kind}, {ok, Target, Back}} ->
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
-spec target(what(), cowboy_req:req()) ->
    {ok, ike_id:post() | ike_id:actor() | binary(), Back :: binary()} | none.
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
target(front, _Req) ->
    none.

-spec fits(what(), ike_role:kind()) -> boolean().
fits(post, Kind) ->
    lists:member(Kind, [hide, unhide, delete, restore, purge, ban, block, unblock, purge_image]);
fits(board, Kind) ->
    Kind =:= lock orelse Kind =:= unlock;
fits(account, Kind) ->
    Kind =:= unban;
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
    Missing =:= no_such_post; Missing =:= no_such_account; Missing =:= no_such_board
->
    ike_http:not_found(Req);
done({error, _}, _Kind, _Back, Req) ->
    ike_http:reply(500, Req).
