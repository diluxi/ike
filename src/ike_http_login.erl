%% Login through the issuer, and logout. /login sends the browser away
%% with a state, a nonce and a pkce challenge; /login/callback takes the
%% code it comes back with; /logout is a form like any other.
-module(ike_http_login).
-behaviour(cowboy_handler).

-export([init/2]).
-export([session/1, cookie/2]).

-define(SESSION, <<"__Host-ike">>).
-define(LOGIN, <<"__Host-ike-login">>).

-spec init(cowboy_req:req(), login | callback | logout) ->
    {ok, cowboy_req:req(), login | callback | logout}.
init(Req, Action) ->
    Method = cowboy_req:method(Req),
    Reply =
        case {Action, Method} of
            {login, <<"GET">>} -> login(Req);
            {callback, <<"GET">>} -> callback(Req);
            {logout, <<"POST">>} -> logout(Req);
            _ -> ike_http:reply(405, Req)
        end,
    {ok, Reply, Action}.

%% who is asking, by their cookie
-spec session(cowboy_req:req()) -> {ok, Id :: binary(), ike_session:session()} | error.
session(Req) ->
    case cookie(?SESSION, Req) of
        {ok, Id} ->
            case ike_session:lookup(Id) of
                {ok, Session} -> {ok, Id, Session};
                error -> error
            end;
        error ->
            error
    end.

-spec login(cowboy_req:req()) -> cowboy_req:req().
login(Req) ->
    case ike_session:begin_login() of
        {ok, #{binding := Binding} = Login} ->
            case ike_oidc:authorize_url(Login) of
                {ok, Url} ->
                    ike_http:see_other(Url, set_cookie(?LOGIN, Binding, 600, Req));
                {error, not_configured} ->
                    unavailable(<<"login is not set up here.">>, Req);
                {error, _} ->
                    unavailable(<<"the login service did not answer.">>, Req)
            end;
        {error, _} ->
            unavailable(<<"too many logins under way; try again shortly.">>, Req)
    end.

-spec callback(cowboy_req:req()) -> cowboy_req:req().
callback(Req0) ->
    Req = clear_cookie(?LOGIN, Req0),
    case params(Req) of
        #{<<"state">> := State, <<"code">> := Code} ->
            case {ike_session:take_login(State), cookie(?LOGIN, Req0)} of
                {{ok, #{binding := Binding} = Login}, {ok, Cookie}} ->
                    %% the browser that comes back is the one that left
                    case same(Binding, Cookie) of
                        true -> finish(Code, Login, Req);
                        false -> refused(Req)
                    end;
                _ ->
                    refused(Req)
            end;
        _ ->
            refused(Req)
    end.

-spec finish(binary(), ike_session:login(), cowboy_req:req()) -> cowboy_req:req().
finish(Code, Login, Req) ->
    case ike_oidc:subject(Code, Login) of
        {ok, Issuer, Subject, Nick, Groups} ->
            case ike_writer:local_actor(Issuer, Subject, Nick) of
                {ok, Actor} ->
                    case ike_session:create(Actor, Nick, ike_role:of_groups(Groups)) of
                        {ok, Id, _Session} ->
                            Lifetime = ike_config:session_seconds(),
                            ike_http:see_other(
                                <<"/">>, set_cookie(?SESSION, Id, Lifetime, Req)
                            );
                        {error, _} ->
                            refused(Req)
                    end;
                {error, suspended} ->
                    Html = ike_view:message(
                        <<"suspended">>, <<"this account is suspended; see /board/mod.">>
                    ),
                    ike_http:page(403, Html, Req);
                {error, _} ->
                    refused(Req)
            end;
        {error, _} ->
            refused(Req)
    end.

-spec logout(cowboy_req:req()) -> cowboy_req:req().
logout(Req0) ->
    case session(Req0) of
        {ok, Id, #{csrf := Csrf}} ->
            case ike_http:form(Req0) of
                {ok, #{<<"csrf">> := Token}, Req} ->
                    case same(Csrf, Token) of
                        true ->
                            ok = ike_session:delete(Id),
                            ike_http:see_other(<<"/">>, clear_cookie(?SESSION, Req));
                        false ->
                            ike_http:forbidden(Req)
                    end;
                {ok, _, Req} ->
                    ike_http:forbidden(Req);
                {error, Status, Req} ->
                    ike_http:reply(Status, Req)
            end;
        error ->
            ike_http:see_other(<<"/">>, Req0)
    end.

%% one answer for every way a login can fail, so that it tells nothing
-spec refused(cowboy_req:req()) -> cowboy_req:req().
refused(Req) ->
    Html = ike_view:message(<<"login failed">>, <<"that did not work; start again from /login.">>),
    ike_http:page(400, Html, Req).

-spec unavailable(binary(), cowboy_req:req()) -> cowboy_req:req().
unavailable(Text, Req) ->
    ike_http:page(503, ike_view:message(<<"no login">>, Text), Req).

-spec same(binary(), binary()) -> boolean().
same(A, B) ->
    byte_size(A) =:= byte_size(B) andalso crypto:hash_equals(A, B).

-spec params(cowboy_req:req()) -> #{binary() => binary()}.
params(Req) ->
    try cowboy_req:parse_qs(Req) of
        Pairs -> maps:from_list([{K, V} || {K, V} <- Pairs, is_binary(V)])
    catch
        _:_ -> #{}
    end.

-spec cookie(binary(), cowboy_req:req()) -> {ok, binary()} | error.
cookie(Name, Req) ->
    try cowboy_req:parse_cookies(Req) of
        Cookies ->
            case lists:keyfind(Name, 1, Cookies) of
                {_, Value} when is_binary(Value) -> {ok, Value};
                _ -> error
            end
    catch
        _:_ -> error
    end.

%% hazard i2: never readable by a script, never sent over plain http or
%% with another site's form post; the __Host- prefix pins it to this origin
-spec set_cookie(binary(), binary(), non_neg_integer(), cowboy_req:req()) ->
    cowboy_req:req().
set_cookie(Name, Value, MaxAge, Req) ->
    cowboy_req:set_resp_cookie(Name, Value, Req, #{
        path => <<"/">>,
        secure => true,
        http_only => true,
        same_site => lax,
        max_age => MaxAge
    }).

-spec clear_cookie(binary(), cowboy_req:req()) -> cowboy_req:req().
clear_cookie(Name, Req) ->
    set_cookie(Name, <<>>, 0, Req).
