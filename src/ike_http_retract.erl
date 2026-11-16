%% /p/N/retract: a poster trashes their own post (lux's retraction). By
%% the password given when posting, as vichan has it, or, for a post an
%% account signed, by being that account. The form is on pages that are
%% the same for everyone, so it carries no token: the browser's Origin
%% must be this site, and a post's password is tried only so often.
-module(ike_http_retract).
-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), State) -> {ok, cowboy_req:req(), State}.
init(Req0, State) ->
    Reply =
        case {cowboy_req:method(Req0), cowboy_req:binding(post, Req0)} of
            {<<"POST">>, N} when is_integer(N), N > 0 ->
                case ike_http:same_origin(Req0) of
                    true -> asked(N, Req0);
                    false -> ike_http:forbidden(Req0)
                end;
            {<<"POST">>, _} ->
                ike_http:not_found(Req0);
            _ ->
                ike_http:reply(405, Req0)
        end,
    {ok, Reply, State}.

-spec asked(pos_integer(), cowboy_req:req()) -> cowboy_req:req().
asked(N, Req0) ->
    case ike_http:form(Req0) of
        {ok, Form, Req} ->
            By =
                case {maps:get(<<"password">>, Form, <<>>), ike_http_login:session(Req)} of
                    {<<>>, {ok, _, #{actor := Actor}}} -> {account, Actor};
                    {<<>>, error} -> none;
                    {Password, _} -> {password, Password}
                end,
            case {By, ike_limit:retraction(N)} of
                {none, _} ->
                    refused(Req);
                {_, limited} ->
                    Html = ike_view:message(<<"slow down">>, <<"too many tries for this post.">>),
                    ike_http:page(429, Html, Req);
                {_, ok} ->
                    done(ike_writer:retract(ike_id:post(N), By), Req)
            end;
        {error, Status, Req} ->
            ike_http:reply(Status, Req)
    end.

-spec done(ok | {error, term()}, cowboy_req:req()) -> cowboy_req:req().
done(ok, Req) ->
    _ = ike_render:sync(),
    ike_http:page(200, ike_view:message(<<"retracted">>, <<"the post is gone from view.">>), Req);
done({error, not_now}, Req) ->
    ike_http:page(
        409, ike_view:message(<<"not now">>, <<"that post is not up to be retracted.">>), Req
    );
done({error, no_such_post}, Req) ->
    ike_http:not_found(Req);
done({error, not_yours}, Req) ->
    refused(Req);
done({error, _}, Req) ->
    ike_http:reply(500, Req).

%% the same for a wrong password, none, or a post not one's own
-spec refused(cowboy_req:req()) -> cowboy_req:req().
refused(Req) ->
    Html = ike_view:message(
        <<"not retracted">>, <<"that password, or that account, is not the post's.">>
    ),
    ike_http:page(403, Html, Req).
