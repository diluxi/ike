%% /mod/themes: the site's looks, which any moderator changes (lux,
%% 2026-11-19). No stylesheet is static: each is a theme, its text
%% edited here whole, one of them the site's. The pages take theirs from
%% the media origin (invariant 5). A theme's page wears that theme, to
%% be tried before it is the site's. Janitors and everyone else find
%% nothing here.
-module(ike_http_theme).
-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), What) -> {ok, cowboy_req:req(), What} when What :: index | theme.
init(Req, What) ->
    Reply =
        case ike_http_login:session(Req) of
            {ok, _, #{actor := Actor, csrf := Csrf, role := Role}} when
                Role =:= admin; Role =:= moderator
            ->
                case {What, cowboy_req:method(Req)} of
                    {index, <<"GET">>} -> listed(Csrf, Req);
                    {index, <<"POST">>} -> acted(Actor, Csrf, Req);
                    {theme, <<"GET">>} -> shown(Csrf, Req);
                    {theme, <<"POST">>} -> saved(Actor, Csrf, Req);
                    _ -> ike_http:reply(405, Req)
                end;
            _ ->
                ike_http:not_found(Req)
        end,
    {ok, Reply, What}.

-spec listed(binary(), cowboy_req:req()) -> cowboy_req:req().
listed(Csrf, Req) ->
    ike_http:page(200, ike_view:themes(Csrf, ike_reader:themes()), Req).

-spec shown(binary(), cowboy_req:req()) -> cowboy_req:req().
shown(Csrf, Req) ->
    case name(Req) of
        {ok, Name} ->
            case ike_reader:theme(Name) of
                {ok, Css, Active} ->
                    ike_http:page(200, ike_view:theme(Csrf, Name, Css, Active), Req);
                none ->
                    ike_http:not_found(Req)
            end;
        error ->
            ike_http:not_found(Req)
    end.

%% a theme's stylesheet saved whole
-spec saved(ike_id:actor(), binary(), cowboy_req:req()) -> cowboy_req:req().
saved(Actor, Csrf, Req0) ->
    case {name(Req0), ike_http:form(Req0)} of
        {{ok, Name}, {ok, #{<<"csrf">> := Token, <<"css">> := Css}, Req}} ->
            case fair(Token, Csrf) andalso ike_reader:theme(Name) =/= none of
                true -> done(ike_writer:theme(Name, Css, Actor), here(Name), Req);
                false -> ike_http:forbidden(Req)
            end;
        {_, {ok, _, Req}} ->
            ike_http:reply(400, Req);
        {_, {error, Status, Req}} ->
            ike_http:reply(Status, Req)
    end.

%% a theme made (from another's stylesheet), made the site's, or dropped
-spec acted(ike_id:actor(), binary(), cowboy_req:req()) -> cowboy_req:req().
acted(Actor, Csrf, Req0) ->
    case ike_http:form(Req0) of
        {ok, #{<<"csrf">> := Token, <<"name">> := Name} = Form, Req} ->
            case {fair(Token, Csrf), Form} of
                {false, _} ->
                    ike_http:forbidden(Req);
                {true, #{<<"do">> := <<"use">>}} ->
                    done(ike_writer:use_theme(Name, Actor), <<"/mod/themes">>, Req);
                {true, #{<<"do">> := <<"drop">>}} ->
                    done(ike_writer:drop_theme(Name, Actor), <<"/mod/themes">>, Req);
                {true, #{<<"do">> := <<"new">>, <<"from">> := From}} ->
                    case {ike_reader:theme(Name), ike_reader:theme(From)} of
                        {none, {ok, Css, _}} ->
                            done(ike_writer:theme(Name, Css, Actor), here(Name), Req);
                        {{ok, _, _}, _} ->
                            refused(409, <<"there is a theme by that name already.">>, Req);
                        {_, none} ->
                            ike_http:reply(400, Req)
                    end;
                _ ->
                    ike_http:reply(400, Req)
            end;
        {ok, _, Req} ->
            ike_http:reply(400, Req);
        {error, Status, Req} ->
            ike_http:reply(Status, Req)
    end.

-spec done(ok | {error, term()}, binary(), cowboy_req:req()) -> cowboy_req:req().
done(ok, Back, Req) ->
    ike_http:see_other(Back, Req);
done({error, bad_name}, _Back, Req) ->
    refused(400, <<"a theme's name is up to 32 of a to z, 0 to 9 and -.">>, Req);
done({error, bad_css}, _Back, Req) ->
    refused(400, <<"a stylesheet is text: up to 256 KiB, no control characters.">>, Req);
done({error, in_use}, _Back, Req) ->
    refused(409, <<"the site's theme is not dropped; make another the site's first.">>, Req);
done({error, no_such_theme}, _Back, Req) ->
    ike_http:not_found(Req);
done({error, _}, _Back, Req) ->
    ike_http:reply(500, Req).

-spec refused(cowboy:http_status(), binary(), cowboy_req:req()) -> cowboy_req:req().
refused(Status, Why, Req) ->
    ike_http:page(Status, ike_view:message(<<"not saved">>, Why), Req).

-spec here(binary()) -> binary().
here(Name) -> <<"/mod/themes/", Name/binary>>.

-spec name(cowboy_req:req()) -> {ok, binary()} | error.
name(Req) ->
    case cowboy_req:binding(theme, Req) of
        Name when is_binary(Name) ->
            case ike_media:theme_name(Name) of
                true -> {ok, Name};
                false -> error
            end;
        _ ->
            error
    end.

-spec fair(binary(), binary()) -> boolean().
fair(Token, Csrf) ->
    byte_size(Token) =:= byte_size(Csrf) andalso crypto:hash_equals(Token, Csrf).
