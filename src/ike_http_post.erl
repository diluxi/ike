%% Posting: the forms, made per request because they carry the session's
%% csrf token, and what they submit. A new thread at /board/B/new, a reply
%% at /board/B/N/reply. An account may post anywhere; nobody may post
%% where the board is not locked, as often as the limiter lets them.
-module(ike_http_post).
-behaviour(cowboy_handler).

-export([init/2, kept_password/1]).

%% where a post is going: a board, and a thread on it unless it starts one
-type place() :: {Board :: binary(), new | ike_id:post()}.

-spec init(cowboy_req:req(), State) -> {ok, cowboy_req:req(), State}.
init(Req, State) ->
    Thread =
        case cowboy_req:binding(thread, Req) of
            N when is_integer(N), N > 0 -> ike_id:post(N);
            _ -> new
        end,
    Reply =
        case cowboy_req:binding(board, Req) of
            Board when is_binary(Board) ->
                Place = {Board, Thread},
                %% the log is written by ike alone
                case {ike_reader:board(Board), cowboy_req:method(Req)} of
                    {log, _} -> ike_http:not_found(Req);
                    %% a thread on the wiki is a page: started at /wiki/NAME
                    {_, _} when Board =:= <<"wiki">>, Thread =:= new -> ike_http:not_found(Req);
                    {_, <<"GET">>} -> form(Place, Req);
                    {_, <<"POST">>} -> submit(Place, Req);
                    _ -> ike_http:reply(405, Req)
                end;
            _ ->
                ike_http:not_found(Req)
        end,
    {ok, Reply, State}.

%% what ties a form sent by nobody to this site's own page: a cookie no
%% other site can set or have sent along, holding what the form holds
%% too. it is made up per browser and kept nowhere (hazard i2)
-define(FORM, <<"__Host-ike-form">>).

-spec form(place(), cowboy_req:req()) -> cowboy_req:req().
form({Board, _} = Place, Req) ->
    case exists(Place) of
        true ->
            case ike_http_login:session(Req) of
                {ok, _Id, #{actor := Actor, csrf := Csrf, name := Name}} ->
                    Staged = [
                        {U, ike_staged:url(U, thumb)}
                     || #{id := U} <- ike_reader:staged(ike_id:to_integer(Actor))
                    ],
                    {Password, Req1} = kept_password(Req),
                    Who = {csrf, Csrf, Name, Staged, Password},
                    ike_http:page(200, ike_view:post_form(action(Place), Who), Req1);
                error ->
                    case ike_reader:board(Board) of
                        open ->
                            {Token, Req1} = form_token(Req),
                            {Password, Req2} = kept_password(Req1),
                            Html = ike_view:post_form(
                                action(Place),
                                {nobody, Token, Password, ike_config:anonymous_uploads()}
                            ),
                            ike_http:page(200, Html, Req2);
                        _ ->
                            ike_http:page(200, ike_view:post_form(action(Place), locked), Req)
                    end
            end;
        false ->
            ike_http:not_found(Req)
    end.

%% the password this browser posts with, as vichan keeps one: made up
%% once, kept in a cookie, filled in on the form, and used at the foot
%% of a thread when none is typed. ike keeps none of it but each post's
%% salted hash
-define(PASSWORD, <<"__Host-ike-password">>).

-spec kept_password(cowboy_req:req()) -> {binary(), cowboy_req:req()}.
kept_password(Req) ->
    case ike_http_login:cookie(?PASSWORD, Req) of
        {ok, Kept} when byte_size(Kept) > 0, byte_size(Kept) =< 64 ->
            {Kept, Req};
        _ ->
            New = base64:encode(crypto:strong_rand_bytes(9), #{mode => urlsafe, padding => false}),
            {New,
                cowboy_req:set_resp_cookie(?PASSWORD, New, Req, #{
                    path => <<"/">>,
                    secure => true,
                    http_only => true,
                    same_site => strict,
                    max_age => 31536000
                })}
    end.

%% the browser's token, or a new one for it
-spec form_token(cowboy_req:req()) -> {binary(), cowboy_req:req()}.
form_token(Req) ->
    case ike_http_login:cookie(?FORM, Req) of
        {ok, Token} when byte_size(Token) =:= 43 ->
            {Token, Req};
        _ ->
            Token = base64:encode(crypto:strong_rand_bytes(32), #{
                mode => urlsafe, padding => false
            }),
            {Token,
                cowboy_req:set_resp_cookie(?FORM, Token, Req, #{
                    path => <<"/">>, secure => true, http_only => true, same_site => strict
                })}
    end.

-spec nobody(place(), cowboy_req:req()) -> cowboy_req:req().
nobody({Board, _} = Place, Req0) ->
    case ike_reader:board(Board) of
        open ->
            Cookie =
                case ike_http_login:cookie(?FORM, Req0) of
                    {ok, C} when byte_size(C) =:= 43 -> C;
                    _ -> none
                end,
            case ike_http:submitted(Req0, Cookie) of
                {ok, Pairs, Files, Req} ->
                    Form = maps:from_list(Pairs),
                    Matches = Cookie =/= none andalso same(field(<<"csrf">>, Pairs), Cookie),
                    case {Matches, exists(Place), Files, ike_config:anonymous_uploads()} of
                        {false, _, _, _} ->
                            ike_http:forbidden(Req);
                        {true, false, _, _} ->
                            ike_http:not_found(Req);
                        {true, true, [], _} ->
                            unhurried(Place, Form, #{}, Req);
                        {true, true, [_ | _], false} ->
                            Html = ike_view:message(
                                <<"not posted">>, <<"posting files here needs an account.">>
                            ),
                            ike_http:page(403, Html, Req);
                        {true, true, [_ | _], true} ->
                            %% nobody's files are still images only (lux), and
                            %% posted at once: nothing of nobody's is staged
                            case kept({ike_id:anonymous(), false}, Files, still) of
                                {ok, Ids} ->
                                    unhurried(
                                        Place, Form, #{upload => {ike_id:anonymous(), Ids}}, Req
                                    );
                                {refused, Lines} ->
                                    refused(Lines, Req)
                            end
                    end;
                {error, 403, Req} ->
                    ike_http:forbidden(Req);
                {error, Status, Req} ->
                    ike_http:reply(Status, Req)
            end;
        _ ->
            ike_http:forbidden(Req0)
    end.

%% the board's own pace, counted only for posts that would go through
-spec unhurried(
    place(),
    #{binary() => binary()},
    #{upload => {ike_id:actor(), [pos_integer(), ...]}},
    cowboy_req:req()
) -> cowboy_req:req().
unhurried({Board, _} = Place, Form, Upload, Req) ->
    Body = maps:get(<<"body">>, Form, <<>>),
    case ike_limit:board(Board) of
        ok ->
            write(Place, ike_id:anonymous(), Body, maps:merge(Upload, password(Form)), Req);
        limited ->
            Html = ike_view:message(
                <<"slow down">>,
                <<"this board is taking posts without an account only so fast. try again in a while.">>
            ),
            ike_http:page(429, Html, Req)
    end.

-spec submit(place(), cowboy_req:req()) -> cowboy_req:req().
submit(Place, Req0) ->
    case ike_http_login:session(Req0) of
        {ok, _Id, #{actor := Account, csrf := Csrf, name := Name}} ->
            case ike_http:submitted(Req0, Csrf) of
                {ok, Pairs, [], Req} ->
                    signed_in(Place, {Account, Csrf, Name}, Pairs, Req);
                {ok, Pairs, Files, Req} ->
                    %% the files first, as uploads of the account's; the
                    %% post then shows them after any ticked
                    %% signed as the post is: the uploads' metas bear the
                    %% name only if the post does
                    Signed =
                        is_binary(Name) andalso
                            lists:member({<<"signed">>, <<"1">>}, Pairs),
                    case kept({Account, Signed}, Files, any) of
                        {ok, Ids} ->
                            signed_in(
                                Place,
                                {Account, Csrf, Name},
                                Pairs ++ [{<<"upload">>, integer_to_binary(I)} || I <- Ids],
                                Req
                            );
                        {refused, Lines} ->
                            refused(Lines, Req)
                    end;
                {error, 403, Req} ->
                    ike_http:forbidden(Req);
                {error, Status, Req} ->
                    ike_http:reply(Status, Req)
            end;
        error ->
            nobody(Place, Req0)
    end.

%% a form from a session: its token, the text, whether to sign, and the
%% uploads ticked, as many as the form repeats
-spec signed_in(
    place(), {ike_id:actor(), binary(), binary() | none}, [{binary(), binary()}], cowboy_req:req()
) -> cowboy_req:req().
signed_in(Place, {Account, Csrf, Name}, Pairs, Req) ->
    case maps:from_list(Pairs) of
        #{<<"csrf">> := Token} = Form ->
            case byte_size(Token) =:= byte_size(Csrf) andalso crypto:hash_equals(Token, Csrf) of
                true ->
                    %% a post is its account's only when the account
                    %% asks for that and has a name to put on it.
                    %% otherwise it is nobody's, and nothing ties
                    %% the two together
                    Actor =
                        case Form of
                            #{<<"signed">> := <<"1">>} when is_binary(Name) -> Account;
                            _ -> ike_id:anonymous()
                        end,
                    Picked = [
                        U
                     || {<<"upload">>, V} <- Pairs,
                        {U, <<>>} <- [string:to_integer(V)],
                        is_integer(U),
                        U > 0
                    ],
                    Upload =
                        case Picked of
                            [] -> #{};
                            _ -> #{upload => {Account, Picked}}
                        end,
                    case {exists(Place), length(Picked) =< ike_config:images()} of
                        {true, true} ->
                            write(
                                Place,
                                Actor,
                                maps:get(<<"body">>, Form, <<>>),
                                maps:merge(Upload, password(Form)),
                                Req
                            );
                        {true, false} ->
                            Html = ike_view:message(
                                <<"not posted">>, <<"that is more images than one post takes.">>
                            ),
                            ike_http:page(400, Html, Req);
                        {false, _} ->
                            ike_http:not_found(Req)
                    end;
                false ->
                    ike_http:forbidden(Req)
            end;
        _ ->
            ike_http:forbidden(Req)
    end.

%% files sent with a post, each stripped and kept as an upload of Actor's;
%% all of them, or none and why. still: images that do not move only
-spec kept({ike_id:actor(), Signed :: boolean()}, [binary()], any | still) ->
    {ok, [pos_integer()]} | {refused, [binary()]}.
kept(Actor, Files, Which) ->
    Results = numbered(Actor, Files, Which, 1),
    case [L || {refused, L} <- Results] of
        [] -> {ok, [I || {ok, I} <- Results]};
        Lines -> {refused, Lines}
    end.

-spec one({ike_id:actor(), boolean()}, pos_integer(), binary(), any | still) ->
    {ok, pos_integer()} | {refused, binary()}.
one({Actor, Signed}, N, Bytes, Which) ->
    Which0 = <<"file ", (integer_to_binary(N))/binary, ": ">>,
    case ike_strip:run(Bytes) of
        {ok, #{type := Type, stored := Stored} = Stripped} ->
            Still =
                lists:member(Type, [jpeg, png, webp]) andalso
                    binary:match(Stored, <<"acTL">>) =:= nomatch,
            case Which =:= any orelse Still of
                true ->
                    case
                        ike_writer:upload(#{
                            actor => Actor,
                            original => Bytes,
                            stripped => Stripped,
                            signed => Signed
                        })
                    of
                        {ok, Id} -> {ok, Id};
                        {error, refused} -> {refused, <<Which0/binary, "not taken">>};
                        {error, _} -> {refused, <<Which0/binary, "not kept, try again">>}
                    end;
                false ->
                    {refused, <<Which0/binary, "not taken">>}
            end;
        {no, _} ->
            {refused, <<Which0/binary, "not taken">>};
        {error, unavailable} ->
            {refused, <<Which0/binary, "not kept, try again">>}
    end.

-spec refused([binary()], cowboy_req:req()) -> cowboy_req:req().
refused(Lines, Req) ->
    Html = ike_view:message(<<"not posted">>, joined(Lines)),
    ike_http:page(422, Html, Req).

-spec numbered({ike_id:actor(), boolean()}, [binary()], any | still, pos_integer()) ->
    [{ok, pos_integer()} | {refused, binary()}].
numbered(Actor, [Bytes | Rest], Which, N) ->
    [one(Actor, N, Bytes, Which) | numbered(Actor, Rest, Which, N + 1)];
numbered(_Actor, [], _Which, _N) ->
    [].

-spec joined([binary()]) -> binary().
joined([L]) -> L;
joined([L | Ls]) -> <<L/binary, "; ", (joined(Ls))/binary>>;
joined([]) -> <<>>.

-spec field(binary(), [{binary(), binary()}]) -> binary().
field(Name, [{Name, Value} | _]) -> Value;
field(Name, [_ | Rest]) -> field(Name, Rest);
field(_Name, []) -> <<>>.

-spec same(binary(), binary()) -> boolean().
same(A, B) ->
    byte_size(A) =:= byte_size(B) andalso crypto:hash_equals(A, B).

%% a password to retract the post with later, if one was given, and a
%% title, if one was
-spec password(#{binary() => binary()}) -> #{password => binary(), title => binary()}.
password(Form) ->
    maps:merge(
        case Form of
            #{<<"password">> := P} when byte_size(P) > 0, byte_size(P) =< 256 -> #{password => P};
            _ -> #{}
        end,
        case Form of
            #{<<"title">> := T} when byte_size(T) > 0 -> #{title => T};
            _ -> #{}
        end
    ).

-spec write(
    place(),
    ike_id:actor(),
    binary(),
    #{upload => {ike_id:actor(), [pos_integer(), ...]}, password => binary(), title => binary()},
    cowboy_req:req()
) -> cowboy_req:req().
write({Board, Thread} = Place, Actor, Body0, Upload, Req) ->
    %% forms send lines as crlf
    Body = trim_end(binary:replace(Body0, <<"\r\n">>, <<"\n">>, [global])),
    Home =
        case Thread of
            new -> {new, Board};
            _ -> Thread
        end,
    case ike_writer:post(Upload#{actor => Actor, thread => Home, body => Body}) of
        {ok, Post} ->
            %% the page is there before the browser is sent to it
            _ = ike_render:sync(),
            N = integer_to_binary(ike_id:to_integer(Post)),
            Page =
                case Thread of
                    new -> page({Board, Post});
                    _ -> page(Place)
                end,
            ike_http:see_other(<<Page/binary, "#p", N/binary>>, Req);
        {error, bad_text} ->
            Html = ike_view:message(
                <<"not posted">>,
                <<"a post is text: not empty, not too long, no control characters.">>
            ),
            ike_http:page(400, Html, Req);
        {error, no_such_upload} ->
            Html = ike_view:message(
                <<"not posted">>, <<"that upload is not one of yours waiting to be posted.">>
            ),
            ike_http:page(400, Html, Req);
        {error, Missing} when Missing =:= no_such_thread; Missing =:= no_such_board ->
            ike_http:not_found(Req);
        {error, _} ->
            ike_http:reply(500, Req)
    end.

-spec page(place()) -> binary().
page({Board, new}) ->
    <<"/board/", Board/binary>>;
page({Board, Thread}) ->
    <<"/board/", Board/binary, "/", (integer_to_binary(ike_id:to_integer(Thread)))/binary>>.

-spec action(place()) -> binary().
action({_, new} = Place) -> <<(page(Place))/binary, "/new">>;
action(Place) -> <<(page(Place))/binary, "/reply">>.

%% a board or a thread on it exists when its page does; the trunk has no
%% pages, and no new threads: one of its threads exists when it belongs
%% to a curation or a meta (the writer takes no post for one not shown)
-spec exists(place()) -> boolean().
exists({<<"trunk">>, new}) ->
    false;
exists({<<"trunk">>, Thread}) when Thread =/= new ->
    ike_reader:attached(ike_id:to_integer(Thread)) =/= none;
exists(Place) ->
    filelib:is_regular(<<(ike_config:pages_dir())/binary, (page(Place))/binary, ".html">>).

-spec trim_end(binary()) -> binary().
trim_end(Bin) ->
    case byte_size(Bin) of
        0 ->
            Bin;
        Size ->
            case binary:last(Bin) of
                C when C =:= $\n; C =:= $\s; C =:= $\t -> trim_end(binary:part(Bin, 0, Size - 1));
                _ -> Bin
            end
    end.
