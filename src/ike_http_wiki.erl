%% The wiki, made per request for now: /wiki lists the pages, /wiki/NAME
%% reads one (or offers to start it), /wiki/NAME/edit writes a revision
%% on the one it was opened on, /wiki/NAME/history shows each revision
%% against the one before. Accounts write; anonymous edits are proposals
%% (M4). The page's discussion is its thread on the board wiki.
-module(ike_http_wiki).
-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), What) -> {ok, cowboy_req:req(), What} when
    What :: index | page | edit | history.
init(Req, What) ->
    Reply =
        case {What, name(Req), cowboy_req:method(Req)} of
            {index, _, <<"GET">>} ->
                ike_http:page(200, ike_view:wiki_index(ike_reader:pages()), Req);
            {_, error, _} when What =/= index -> ike_http:not_found(Req);
            {page, {ok, Name}, <<"GET">>} ->
                read(Name, Req);
            {edit, {ok, Name}, <<"GET">>} ->
                editor(Name, Req);
            {edit, {ok, Name}, <<"POST">>} ->
                write(Name, Req);
            {history, {ok, Name}, <<"GET">>} ->
                history(Name, Req);
            _ ->
                ike_http:reply(405, Req)
        end,
    {ok, Reply, What}.

-spec name(cowboy_req:req()) -> {ok, binary()} | error.
name(Req) ->
    case cowboy_req:binding(name, Req) of
        Raw when is_binary(Raw) ->
            try uri_string:percent_decode(Raw) of
                Decoded when is_binary(Decoded) -> ike_wiki:name(Decoded);
                _ -> error
            catch
                _:_ -> error
            end;
        _ ->
            error
    end.

-spec read(binary(), cowboy_req:req()) -> cowboy_req:req().
read(Name, Req) ->
    case ike_reader:page(Name) of
        {ok, #{body := Body} = Page} ->
            ike_http:page(200, ike_view:wiki_page(Name, Page, ike_reader:links(Body)), Req);
        none ->
            ike_http:page(404, ike_view:wiki_missing(Name, signed_in(Req)), Req)
    end.

-spec signed_in(cowboy_req:req()) -> boolean().
signed_in(Req) ->
    case ike_http_login:session(Req) of
        {ok, _, _} -> true;
        error -> false
    end.

%% the form, with the page's text as it is now
-spec editor(binary(), cowboy_req:req()) -> cowboy_req:req().
editor(Name, Req0) ->
    case ike_http_login:session(Req0) of
        {ok, _, #{csrf := Csrf, name := Signer}} ->
            Text =
                case ike_reader:page(Name) of
                    {ok, #{body := B}} -> B;
                    none -> <<>>
                end,
            {Password, Req} = ike_http_post:kept_password(Req0),
            ike_http:page(200, ike_view:wiki_edit(Name, Csrf, Signer, Text, Password), Req);
        error ->
            ike_http:page(
                200, ike_view:post_form(<<(ike_wiki:path(Name))/binary, "/edit">>, locked), Req0
            )
    end.

-spec write(binary(), cowboy_req:req()) -> cowboy_req:req().
write(Name, Req0) ->
    case {ike_http_login:session(Req0), ike_http:form(Req0)} of
        {
            {ok, _, #{actor := Account, csrf := Csrf, name := Signer}},
            {ok, #{<<"csrf">> := Token} = Form, Req}
        } ->
            case byte_size(Token) =:= byte_size(Csrf) andalso crypto:hash_equals(Token, Csrf) of
                true ->
                    Body = trimmed(maps:get(<<"body">>, Form, <<>>)),
                    %% unsigned unless asked, as a post is
                    Actor =
                        case Form of
                            #{<<"signed">> := <<"1">>} when is_binary(Signer) -> Account;
                            _ -> ike_id:anonymous()
                        end,
                    Edit = #{name => Name, actor => Actor, body => Body},
                    Password =
                        case Form of
                            #{<<"password">> := P} when byte_size(P) > 0, byte_size(P) =< 256 ->
                                #{password => P};
                            _ ->
                                #{}
                        end,
                    case ike_writer:wiki(maps:merge(Edit, Password)) of
                        {ok, _} ->
                            _ = ike_render:sync(),
                            ike_http:see_other(ike_wiki:path(Name), Req);
                        {error, taken_down} ->
                            Html = ike_view:message(
                                <<"not saved">>,
                                <<"this page was taken down; a moderator may bring it back.">>
                            ),
                            ike_http:page(409, Html, Req);
                        {error, bad_text} ->
                            Html = ike_view:message(
                                <<"not saved">>,
                                <<"a page is text: not empty, not too long, no control characters.">>
                            ),
                            ike_http:page(400, Html, Req);
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

%% the page's thread is its history and its talk (lux): history leads
%% there, unless wiki_history asks for the separate page back
-spec history(binary(), cowboy_req:req()) -> cowboy_req:req().
history(Name, Req) ->
    case {ike_config:wiki_history(), ike_reader:page(Name)} of
        {thread, {ok, #{thread := Thread}}} ->
            ike_http:see_other(<<"/board/wiki/", (integer_to_binary(Thread))/binary>>, Req);
        {thread, none} ->
            ike_http:not_found(Req);
        {separate, _} ->
            separate(Name, Req)
    end.

-spec separate(binary(), cowboy_req:req()) -> cowboy_req:req().
separate(Name, Req) ->
    case ike_reader:revisions(Name) of
        [] ->
            ike_http:not_found(Req);
        Revisions ->
            ike_http:page(
                200, ike_view:wiki_history(Name, newest_first(pairs(<<>>, Revisions), [])), Req
            )
    end.

-spec pairs(binary(), [{pos_integer(), integer(), binary()}]) ->
    [{pos_integer(), integer(), [ike_wiki:change()]}].
pairs(Before, [{Id, Time, Body} | Rest]) ->
    [{Id, Time, ike_wiki:diff(Before, Body)} | pairs(Body, Rest)];
pairs(_Before, []) ->
    [].

-spec newest_first([{pos_integer(), integer(), [ike_wiki:change()]}], [
    {pos_integer(), integer(), [ike_wiki:change()]}
]) ->
    [{pos_integer(), integer(), [ike_wiki:change()]}].
newest_first([R | Rs], Acc) -> newest_first(Rs, [R | Acc]);
newest_first([], Acc) -> Acc.

%% lines as a form sends them, and nothing blank at the end
-spec trimmed(binary()) -> binary().
trimmed(Body) ->
    cut(binary:replace(Body, <<"\r\n">>, <<"\n">>, [global])).

-spec cut(binary()) -> binary().
cut(<<>>) ->
    <<>>;
cut(Bin) ->
    case binary:last(Bin) of
        C when C =:= $\n; C =:= $\s; C =:= $\t -> cut(binary:part(Bin, 0, byte_size(Bin) - 1));
        _ -> Bin
    end.
