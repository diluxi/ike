%% Posting: the forms, made per request because they carry the session's
%% csrf token, and what they submit. A new thread at /board/B/new, a reply
%% at /board/B/N/reply. An account may post anywhere; nobody may post
%% where the board is not locked, as often as the limiter lets them.
-module(ike_http_post).
-behaviour(cowboy_handler).

-export([init/2]).

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
                    Who = {csrf, Csrf, Name, Staged},
                    ike_http:page(200, ike_view:post_form(action(Place), Who), Req);
                error ->
                    case ike_reader:board(Board) of
                        open ->
                            {Token, Req1} = form_token(Req),
                            Html = ike_view:post_form(action(Place), {nobody, Token}),
                            ike_http:page(200, Html, Req1);
                        _ ->
                            ike_http:page(200, ike_view:post_form(action(Place), locked), Req)
                    end
            end;
        false ->
            ike_http:not_found(Req)
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
            case {ike_http_login:cookie(?FORM, Req0), ike_http:form(Req0)} of
                {{ok, Cookie}, {ok, #{<<"csrf">> := Token} = Form, Req}} when
                    byte_size(Cookie) =:= 43
                ->
                    case
                        byte_size(Token) =:= byte_size(Cookie) andalso
                            crypto:hash_equals(Token, Cookie)
                    of
                        true ->
                            case exists(Place) of
                                true -> unhurried(Place, maps:get(<<"body">>, Form, <<>>), Req);
                                false -> ike_http:not_found(Req)
                            end;
                        false ->
                            ike_http:forbidden(Req)
                    end;
                {_, {error, Status, Req}} ->
                    ike_http:reply(Status, Req);
                {_, {ok, _, Req}} ->
                    ike_http:forbidden(Req)
            end;
        _ ->
            ike_http:forbidden(Req0)
    end.

%% the board's own pace, counted only for posts that would go through
-spec unhurried(place(), binary(), cowboy_req:req()) -> cowboy_req:req().
unhurried({Board, _} = Place, Body, Req) ->
    case ike_limit:board(Board) of
        ok ->
            write(Place, ike_id:anonymous(), Body, #{}, Req);
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
            case ike_http:form(Req0) of
                {ok, #{<<"csrf">> := Token} = Form, Req} ->
                    case
                        byte_size(Token) =:= byte_size(Csrf) andalso crypto:hash_equals(Token, Csrf)
                    of
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
                            Upload =
                                case string:to_integer(maps:get(<<"upload">>, Form, <<>>)) of
                                    {U, <<>>} when is_integer(U), U > 0 ->
                                        #{upload => {Account, U}};
                                    _ ->
                                        #{}
                                end,
                            case exists(Place) of
                                true ->
                                    write(
                                        Place, Actor, maps:get(<<"body">>, Form, <<>>), Upload, Req
                                    );
                                false ->
                                    ike_http:not_found(Req)
                            end;
                        false ->
                            ike_http:forbidden(Req)
                    end;
                {ok, _, Req} ->
                    ike_http:forbidden(Req);
                {error, Status, Req} ->
                    ike_http:reply(Status, Req)
            end;
        error ->
            nobody(Place, Req0)
    end.

-spec write(
    place(),
    ike_id:actor(),
    binary(),
    #{upload => {ike_id:actor(), pos_integer()}},
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

%% a board or a thread on it exists when its page does
-spec exists(place()) -> boolean().
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
