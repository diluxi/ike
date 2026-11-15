%% Posting: the forms, made per request because they carry the session's
%% csrf token, and what they submit. A new thread at /board/B/new, a reply
%% at /board/B/N/reply. For now only an account may post.
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
                case cowboy_req:method(Req) of
                    <<"GET">> -> form(Place, Req);
                    <<"POST">> -> submit(Place, Req);
                    _ -> ike_http:reply(405, Req)
                end;
            _ ->
                ike_http:not_found(Req)
        end,
    {ok, Reply, State}.

-spec form(place(), cowboy_req:req()) -> cowboy_req:req().
form(Place, Req) ->
    case exists(Place) of
        true ->
            Session =
                case ike_http_login:session(Req) of
                    {ok, _Id, #{csrf := Csrf, name := Name}} -> {csrf, Csrf, Name};
                    error -> anonymous
                end,
            ike_http:page(200, ike_view:post_form(action(Place), Session), Req);
        false ->
            ike_http:not_found(Req)
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
                            case exists(Place) of
                                true -> write(Place, Actor, maps:get(<<"body">>, Form, <<>>), Req);
                                false -> ike_http:not_found(Req)
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
            ike_http:forbidden(Req0)
    end.

-spec write(place(), ike_id:actor(), binary(), cowboy_req:req()) -> cowboy_req:req().
write({Board, Thread} = Place, Actor, Body0, Req) ->
    %% forms send lines as crlf
    Body = trim_end(binary:replace(Body0, <<"\r\n">>, <<"\n">>, [global])),
    Home =
        case Thread of
            new -> {new, Board};
            _ -> Thread
        end,
    case ike_writer:post(#{actor => Actor, thread => Home, body => Body}) of
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
