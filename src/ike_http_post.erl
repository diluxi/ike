%% Posting: the forms, made per request because they carry the session's
%% csrf token, and what they submit. A new thread at /new, a reply at
%% /t/N/reply. In M0 only an account may post.
-module(ike_http_post).
-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), State) -> {ok, cowboy_req:req(), State}.
init(Req, State) ->
    Thread =
        case cowboy_req:binding(thread, Req) of
            N when is_integer(N), N > 0 -> ike_id:post(N);
            _ -> new
        end,
    Reply =
        case cowboy_req:method(Req) of
            <<"GET">> -> form(Thread, Req);
            <<"POST">> -> submit(Thread, Req);
            _ -> ike_http:reply(405, Req)
        end,
    {ok, Reply, State}.

-spec form(new | ike_id:post(), cowboy_req:req()) -> cowboy_req:req().
form(Thread, Req) ->
    case exists(Thread) of
        true ->
            Session =
                case ike_http_login:session(Req) of
                    {ok, _Id, #{csrf := Csrf}} -> {csrf, Csrf};
                    error -> anonymous
                end,
            ike_http:page(200, ike_view:post_form(action(Thread), Session), Req);
        false ->
            ike_http:not_found(Req)
    end.

-spec submit(new | ike_id:post(), cowboy_req:req()) -> cowboy_req:req().
submit(Thread, Req0) ->
    case ike_http_login:session(Req0) of
        {ok, _Id, #{actor := Actor, csrf := Csrf}} ->
            case ike_http:form(Req0) of
                {ok, #{<<"csrf">> := Token} = Form, Req} ->
                    case
                        byte_size(Token) =:= byte_size(Csrf) andalso crypto:hash_equals(Token, Csrf)
                    of
                        true -> write(Thread, Actor, maps:get(<<"body">>, Form, <<>>), Req);
                        false -> ike_http:forbidden(Req)
                    end;
                {ok, _, Req} ->
                    ike_http:forbidden(Req);
                {error, Status, Req} ->
                    ike_http:reply(Status, Req)
            end;
        error ->
            ike_http:forbidden(Req0)
    end.

-spec write(new | ike_id:post(), ike_id:actor(), binary(), cowboy_req:req()) ->
    cowboy_req:req().
write(Thread, Actor, Body0, Req) ->
    %% forms send lines as crlf
    Body = trim_end(binary:replace(Body0, <<"\r\n">>, <<"\n">>, [global])),
    case ike_writer:post(#{actor => Actor, thread => Thread, body => Body}) of
        {ok, Post} ->
            %% the page is there before the browser is sent to it
            _ = ike_render:sync(),
            N = integer_to_binary(ike_id:to_integer(Post)),
            Home =
                case Thread of
                    new -> N;
                    _ -> integer_to_binary(ike_id:to_integer(Thread))
                end,
            ike_http:see_other(<<"/t/", Home/binary, "#p", N/binary>>, Req);
        {error, bad_text} ->
            Html = ike_view:message(
                <<"not posted">>,
                <<"a post is text: not empty, not too long, no control characters.">>
            ),
            ike_http:page(400, Html, Req);
        {error, no_such_thread} ->
            ike_http:not_found(Req);
        {error, _} ->
            ike_http:reply(500, Req)
    end.

-spec action(new | ike_id:post()) -> binary().
action(new) -> <<"/new">>;
action(Thread) -> <<"/t/", (integer_to_binary(ike_id:to_integer(Thread)))/binary, "/reply">>.

%% a thread exists when its page does
-spec exists(new | ike_id:post()) -> boolean().
exists(new) ->
    true;
exists(Thread) ->
    N = integer_to_binary(ike_id:to_integer(Thread)),
    filelib:is_regular(<<(ike_config:pages_dir())/binary, "/t/", N/binary, ".html">>).

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
