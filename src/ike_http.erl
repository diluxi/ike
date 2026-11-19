%% The Cowboy listener: everything Caddy does not serve from disk, and
%% what every response has in common.
-module(ike_http).

-export([child_spec/0]).
-export([headers/0]).
-export([html/3, page/3, reply/2, not_found/1, forbidden/1, see_other/2, form/1, pairs/1]).
-export([same_origin/1, guarded/1, submitted/2]).

%% what a form may weigh; caddy caps bodies at the same size
-define(FORM_BYTES, 65536).

-spec child_spec() -> supervisor:child_spec().
child_spec() ->
    #{ip := Ip, port := Port} = application:get_env(ike, listen, #{}),
    ranch:child_spec(
        ?MODULE,
        ranch_tcp,
        #{socket_opts => [{ip, Ip}, {port, Port}]},
        cowboy_clear,
        #{
            env => #{dispatch => dispatch()},
            %% ike_http_anon first: nothing after it knows the peer
            stream_handlers => [ike_http_anon, cowboy_stream_h]
        }
    ).

-spec dispatch() -> cowboy_router:dispatch_rules().
dispatch() ->
    Thread = {thread, int},
    Board = {board, fun board/2},
    Kind = {kind, fun kind/2},
    %% the media origin first: what it serves, ike's own host never does
    Media = binary_to_list(ike_config:media_host()),
    cowboy_router:compile([
        {Media, [
            {"/staged/:upload/:expires/:sig/[:part]", [{upload, int}, {expires, int}],
                ike_http_media, []},
            {"/:file", ike_http_media, public},
            {'_', ike_http_media, []}
        ]},
        {'_', [
            {"/health", ike_http_health, []},
            {"/", ike_http_page, front},
            {"/ike.js", ike_http_page, script},
            {"/board", ike_http_page, boards},
            {"/booru", ike_http_page, booru},
            {"/booru/search", ike_http_search, []},
            {"/user/:name", ike_http_user, []},
            {"/trunk", ike_http_trunk, index},
            {"/trunk/:meta", [{meta, int}], ike_http_trunk, meta},
            {"/trunk/:meta/comment", [{meta, int}], ike_http_trunk, comment},
            {"/trunk/:meta/curate", [{meta, int}], ike_http_trunk, curate},
            {"/wiki", ike_http_wiki, index},
            %% kind/name: a page of a kind (lux); a name alone, whichever has it
            {"/wiki/:kind/:name", [Kind], ike_http_wiki, page},
            {"/wiki/:kind/:name/edit", [Kind], ike_http_wiki, edit},
            {"/wiki/:kind/:name/history", [Kind], ike_http_wiki, history},
            {"/wiki/:name", ike_http_wiki, page},
            {"/wiki/:name/edit", ike_http_wiki, edit},
            {"/wiki/:name/history", ike_http_wiki, history},
            {"/booru/:booru", [{booru, int}], ike_http_page, entry},
            {"/booru/:booru/tags", [{booru, int}], ike_http_tag, []},
            {"/board/:board", [Board], ike_http_page, board},
            {"/board/:board/new", [Board], ike_http_post, []},
            {"/board/:board/:thread", [Board, Thread], ike_http_page, thread},
            {"/board/:board/:thread/reply", [Board, Thread], ike_http_post, []},
            {"/p/:post", [{post, int}], ike_http_permalink, []},
            {"/act", ike_http_act, []},
            {"/preview", ike_http_preview, []},
            {"/login", ike_http_login, login},
            {"/login/callback", ike_http_login, callback},
            {"/logout", ike_http_login, logout},
            {"/upload", ike_http_upload, []},
            {"/upload/fetch", ike_http_fetch, []},
            {"/account", ike_http_account, []},
            {"/mod", ike_http_mod, front},
            {"/mod/post/:post", [{post, int}], ike_http_mod, post},
            {"/mod/board/:board", [Board], ike_http_mod, board},
            {"/mod/themes", ike_http_theme, index},
            {"/mod/themes/:theme", ike_http_theme, theme},
            {"/mod/account/:account", [{account, int}], ike_http_mod, account},
            {"/mod/report/:report", [{report, int}], ike_http_mod, report},
            {"/mod/booru/:booru", [{booru, int}], ike_http_mod, booru},
            {"/mod/meta/:meta", [{meta, int}], ike_http_mod, meta},
            %% everything else, so that a miss is answered by ike and not
            %% by cowboy's bare 404
            {'_', ike_http_page, missing}
        ]}
    ]).

%% a path names a file under the pages, so a board's name in one is only
%% ever what a board may be called
-spec board(forward | reverse | format_error, term()) -> {ok, term()} | {error, term()} | iodata().
board(format_error, _) ->
    <<"not a board's name">>;
board(_, Name) when is_binary(Name) ->
    case ike_config:board_name(Name) of
        true -> {ok, Name};
        false -> {error, not_a_board}
    end;
board(_, _) ->
    {error, not_a_board}.

%% a kind of wiki page, as its address names it
-spec kind(forward | reverse | format_error, term()) ->
    {ok, binary()} | {error, not_a_kind} | binary().
kind(format_error, _) ->
    <<"not a kind of page">>;
kind(_, Kind) when is_binary(Kind) ->
    case lists:member(Kind, ike_wiki:kinds()) of
        true -> {ok, Kind};
        false -> {error, not_a_kind}
    end;
kind(_, _) ->
    {error, not_a_kind}.

%% nothing ike sends may run a script, be framed or be sniffed into
%% another type. caddy sets the same on the pages it serves from disk
-spec headers() -> cowboy:http_headers().
headers() ->
    #{
        <<"content-security-policy">> => csp(),
        <<"x-content-type-options">> => <<"nosniff">>,
        <<"referrer-policy">> => <<"same-origin">>,
        <<"cache-control">> => <<"no-store">>
    }.

%% images, videos, fonts and the stylesheet come from the media origin,
%% and from nowhere else (the stylesheet is a moderator's: so not from
%% here, invariant 5)
-spec csp() -> binary().
csp() ->
    Media = ike_config:media_origin(),
    <<"default-src 'none'; script-src 'self'; style-src ", Media/binary, "; img-src ", Media/binary,
        "; media-src ", Media/binary, "; font-src ", Media/binary,
        "; form-action 'self'; base-uri 'none'; frame-ancestors 'none'">>.

-spec html(cowboy:http_status(), iodata(), cowboy_req:req()) -> cowboy_req:req().
html(Status, Body, Req) ->
    Headers = (headers())#{
        <<"content-type">> => <<"text/html; charset=utf-8">>
    },
    cowboy_req:reply(Status, Headers, Body, Req).

%% a page made for this request, through the same tree as the static ones
-spec page(cowboy:http_status(), ike_html:html(), cowboy_req:req()) ->
    cowboy_req:req().
page(Status, Html, Req) ->
    html(Status, ike_html:to_iodata(Html), Req).

-spec reply(cowboy:http_status(), cowboy_req:req()) -> cowboy_req:req().
reply(Status, Req) ->
    cowboy_req:reply(Status, headers(), <<>>, Req).

-spec not_found(cowboy_req:req()) -> cowboy_req:req().
not_found(Req) ->
    page(404, ike_view:message(<<"not found">>, <<"nothing here.">>), Req).

-spec see_other(Location :: binary(), cowboy_req:req()) -> cowboy_req:req().
see_other(Location, Req) ->
    cowboy_req:reply(303, (headers())#{<<"location">> => Location}, <<>>, Req).

%% no session, or a form without its token (hazard i2)
-spec forbidden(cowboy_req:req()) -> cowboy_req:req().
forbidden(Req) ->
    Html = ike_view:message(
        <<"not allowed">>, <<"log in at /login, and send forms from this site's own pages.">>
    ),
    page(403, Html, Req).

%% a post form as sent: plain, or multipart with files. Token is what the
%% form's csrf field must hold, checked against the fields read so far
%% before the first file is read, so that no file
%% from a form sent from elsewhere is ever read, let alone stripped; the
%% form puts its token first (hazard I2)
-spec submitted(cowboy_req:req(), Token :: binary() | none) ->
    {ok, [{binary(), binary()}], [binary()], cowboy_req:req()}
    | {error, cowboy:http_status(), cowboy_req:req()}.
submitted(Req0, Token) ->
    Multipart =
        try cowboy_req:parse_header(<<"content-type">>, Req0) of
            {<<"multipart">>, <<"form-data">>, _} -> true;
            _ -> false
        catch
            _:_ -> false
        end,
    case Multipart of
        false ->
            case pairs(Req0) of
                {ok, Pairs, Req} -> {ok, Pairs, [], Req};
                {error, _, _} = Error -> Error
            end;
        true ->
            #{max_bytes := Max, files := Most} = ike_config:strip(),
            parts(Req0, Token, Max, Most, [], [])
    end.

-spec parts(
    cowboy_req:req(),
    binary() | none,
    pos_integer(),
    pos_integer(),
    [{binary(), binary()}],
    [binary()]
) ->
    {ok, [{binary(), binary()}], [binary()], cowboy_req:req()}
    | {error, cowboy:http_status(), cowboy_req:req()}.
parts(Req0, Token, Max, Most, Fields, Files) ->
    Opts = #{length => ?FORM_BYTES, period => 5000},
    try cowboy_req:read_part(Req0, Opts) of
        {ok, Headers, Req1} ->
            case cow_multipart:form_data(#{K => V || K := V <- Headers, is_binary(V)}) of
                {data, Name} ->
                    case cowboy_req:read_part_body(Req1, Opts) of
                        {ok, Value, Req2} ->
                            parts(Req2, Token, Max, Most, Fields ++ [{Name, Value}], Files);
                        {more, _, Req2} ->
                            {error, 413, Req2}
                    end;
                {file, _, _, _} when length(Files) >= Most ->
                    {error, 413, Req1};
                {file, _, _, _} ->
                    case token(Token, Fields) of
                        false ->
                            {error, 403, Req1};
                        true ->
                            case file_body(Req1, Max, <<>>) of
                                {ok, <<>>, Req2} ->
                                    parts(Req2, Token, Max, Most, Fields, Files);
                                {ok, Bytes, Req2} ->
                                    parts(Req2, Token, Max, Most, Fields, Files ++ [Bytes]);
                                {too_large, Req2} ->
                                    {error, 413, Req2}
                            end
                    end
            end;
        {done, Req1} ->
            {ok, Fields, Files, Req1}
    catch
        _:_ -> {error, 400, Req0}
    end.

-spec token(binary() | none, [{binary(), binary()}]) -> boolean().
token(Token, [{<<"csrf">>, Value} | _]) when is_binary(Token) ->
    byte_size(Token) =:= byte_size(Value) andalso crypto:hash_equals(Token, Value);
token(Token, [_ | Rest]) ->
    token(Token, Rest);
token(_, _) ->
    false.

-spec file_body(cowboy_req:req(), integer(), binary()) ->
    {ok, binary(), cowboy_req:req()} | {too_large, cowboy_req:req()}.
file_body(Req0, Left, Acc) ->
    case cowboy_req:read_part_body(Req0, #{length => 1048576, period => 15000}) of
        {_, Data, Req} when byte_size(Data) > Left -> {too_large, Req};
        {ok, Data, Req} -> {ok, <<Acc/binary, Data/binary>>, Req};
        {more, Data, Req} -> file_body(Req, Left - byte_size(Data), <<Acc/binary, Data/binary>>)
    end.

%% what stands in for a session's token on the forms of pages that are
%% the same for everyone (/act, tagging): one place to change, should
%% those forms carry a token later
-spec guarded(cowboy_req:req()) -> boolean().
guarded(Req) ->
    same_origin(Req).

%% whether a form was sent from one of this site's own pages: a form on a
%% page that is the same for everyone carries no session's token, so the
%% browser's word on where it came from stands in for one. no Origin, or
%% "null", is no
-spec same_origin(cowboy_req:req()) -> boolean().
same_origin(Req) ->
    case {cowboy_req:header(<<"origin">>, Req), cowboy_req:header(<<"host">>, Req)} of
        {Origin, Host} when is_binary(Origin), is_binary(Host), Origin =/= <<"null">> ->
            case uri_string:parse(Origin) of
                #{host := H, port := P} when is_binary(H), is_integer(P) ->
                    <<H/binary, ":", (integer_to_binary(P))/binary>> =:= Host;
                #{host := H} when is_binary(H) ->
                    H =:= Host;
                _ ->
                    false
            end;
        _ ->
            false
    end.

%% a submitted form. only urlencoded ones are read at all: a multipart
%% body, which is what carries files, is refused unread (hazard a1)
-spec form(cowboy_req:req()) ->
    {ok, #{binary() => binary()}, cowboy_req:req()}
    | {error, cowboy:http_status(), cowboy_req:req()}.
form(Req0) ->
    case pairs(Req0) of
        {ok, Pairs, Req} -> {ok, maps:from_list(Pairs), Req};
        {error, _, _} = Error -> Error
    end.

%% the same, every field as sent, for a name a form repeats
-spec pairs(cowboy_req:req()) ->
    {ok, [{binary(), binary()}], cowboy_req:req()}
    | {error, cowboy:http_status(), cowboy_req:req()}.
pairs(Req0) ->
    try cowboy_req:parse_header(<<"content-type">>, Req0) of
        {<<"application">>, <<"x-www-form-urlencoded">>, _} ->
            try cowboy_req:read_urlencoded_body(Req0, #{length => ?FORM_BYTES, period => 5000}) of
                {ok, Pairs, Req} ->
                    {ok, [{K, V} || {K, V} <- Pairs, is_binary(V)], Req}
            catch
                _:_ -> {error, 400, Req0}
            end;
        _ ->
            {error, 415, Req0}
    catch
        _:_ -> {error, 400, Req0}
    end.
