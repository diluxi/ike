%% Themes, from outside (lux, 2026-11-19): no stylesheet is static. ike
%% comes with three, plain the site's; any moderator edits each whole,
%% makes one the site's, makes a new one from another, drops one that is
%% not the site's. The pages take the site's from the media origin; a
%% theme's own page wears that theme. Nobody else finds any of it.
-module(ike_theme_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    ike_comes_with_three/1,
    a_moderator_edits_them/1,
    nobody_else_does/1,
    made_from_another/1
]).

-import(ike_browser, [login/2, login/3, request/5, query/3, cookies/1, media/2]).

all() ->
    [ike_comes_with_three, a_moderator_edits_them, nobody_else_does, made_from_another].

init_per_suite(Config) ->
    ike_browser:start(Config, []).

end_per_suite(_Config) ->
    ike_browser:stop().

moderator(Config, Name) -> login(Config, Name, #{groups => [<<"ike-moderator">>]}).

act(Config, #{csrf := Csrf} = Session, Fields) ->
    request(
        Config,
        post,
        "/mod/themes",
        cookies(Session),
        {form, uri_string:compose_query([{"csrf", Csrf} | Fields])}
    ).

save(Config, #{csrf := Csrf} = Session, Name, Css) ->
    request(
        Config,
        post,
        "/mod/themes/" ++ Name,
        cookies(Session),
        {form, uri_string:compose_query([{"csrf", Csrf}, {"css", Css}])}
    ).

sheet(Config, File) ->
    {200, Headers, Css} = media(Config, "http://media.test/" ++ File),
    "text/css" = hd(string:split(proplists:get_value("content-type", Headers), ";")),
    "no-cache" = proplists:get_value("cache-control", Headers),
    Css.

ike_comes_with_three(Config) ->
    [[<<"cream">>, 0], [<<"navy">>, 0], [<<"plain">>, 1]] = query(
        Config, "SELECT name, active FROM theme ORDER BY name", []
    ),
    Plain = sheet(Config, "style.css"),
    Plain = sheet(Config, "theme.plain.css"),
    {_, _} = binary:match(sheet(Config, "theme.cream.css"), <<"#ffffee">>),
    {_, _} = binary:match(sheet(Config, "theme.navy.css"), <<"#012e57">>),
    %% the kinds of tag, each its colour, and the booru's side
    {_, _} = binary:match(Plain, <<"a.tag-character">>),
    {_, _} = binary:match(Plain, <<"main.sided">>),
    %% every page takes it from there, the main origin has none
    {200, _, Booru} = request(Config, get, "/booru", [], none),
    {_, _} = binary:match(Booru, <<"href=\"http://media.test/style.css\"">>),
    {_, _} = binary:match(Booru, <<"<main class=\"sided booru\"><aside><form class=\"search\"">>),
    {404, _, _} = request(Config, get, "/style.css", [], none),
    {404, _, _} = media(Config, "http://media.test/theme.none.css").

a_moderator_edits_them(Config) ->
    M = moderator(Config, <<"decorator">>),
    {200, _, Mod} = request(Config, get, "/mod", cookies(M), none),
    {_, _} = binary:match(Mod, <<"href=\"/mod/themes\"">>),
    {200, _, List} = request(Config, get, "/mod/themes", cookies(M), none),
    {_, _} = binary:match(List, <<"href=\"/mod/themes/plain\">plain</a> (the site&#39;s)">>),
    %% a theme's page wears it, its sheet whole in the box
    {200, _, Page} = request(Config, get, "/mod/themes/navy", cookies(M), none),
    {_, _} = binary:match(Page, <<"href=\"http://media.test/theme.navy.css\"">>),
    {_, _} = binary:match(Page, <<"#012e57">>),
    %% saved: its file is the new sheet; not the site's, the site's stays
    {303, _, _} = save(Config, M, "navy", "body { background: #000080; }\r\n"),
    <<"body { background: #000080; }\r\n">> = sheet(Config, "theme.navy.css"),
    nomatch = binary:match(sheet(Config, "style.css"), <<"#000080">>),
    %% made the site's: the site wears it, on every page at once
    {303, _, _} = act(Config, M, [{"do", "use"}, {"name", "navy"}]),
    <<"body { background: #000080; }\r\n">> = sheet(Config, "style.css"),
    {303, _, _} = save(Config, M, "navy", "body { background: #000081; }"),
    <<"body { background: #000081; }">> = sheet(Config, "style.css"),
    %% the site's is not dropped; another is, its file with it
    {409, _, _} = act(Config, M, [{"do", "drop"}, {"name", "navy"}]),
    {303, _, _} = act(Config, M, [{"do", "drop"}, {"name", "cream"}]),
    {404, _, _} = media(Config, "http://media.test/theme.cream.css"),
    {404, _, _} = request(Config, get, "/mod/themes/cream", cookies(M), none),
    %% a sheet is text
    {400, _, _} = save(Config, M, "navy", [0]),
    {400, _, _} = save(Config, M, "navy", binary:copy(<<"a">>, 262145)),
    %% who changed what, and when, is kept
    [[N]] = query(
        Config,
        "SELECT count(*) FROM theme_change c JOIN actor a ON a.id = c.actor"
        " WHERE a.subject = 'decorator'",
        []
    ),
    4 = N,
    %% back as it was, for the suites after
    {303, _, _} = act(Config, M, [{"do", "use"}, {"name", "plain"}]).

nobody_else_does(Config) ->
    Janitor = login(Config, <<"janitor-styler">>, #{groups => [<<"ike-janitor-b">>]}),
    Account = login(Config, <<"plain-styler">>),
    lists:foreach(
        fun(Cookies) ->
            {404, _, _} = request(Config, get, "/mod/themes", Cookies, none),
            {404, _, _} = request(Config, get, "/mod/themes/plain", Cookies, none),
            {404, _, _} = request(
                Config, post, "/mod/themes/plain", Cookies, {form, "css=body%7Bcolor%3Ared%7D"}
            )
        end,
        [[], cookies(Janitor), cookies(Account)]
    ),
    %% nor does a moderator's form without its token
    M = moderator(Config, <<"tokenless">>),
    {403, _, _} = request(
        Config, post, "/mod/themes/plain", cookies(M), {form, "csrf=x&css=body%7B%7D"}
    ),
    nomatch = binary:match(sheet(Config, "style.css"), <<"color:red">>).

made_from_another(Config) ->
    M = moderator(Config, <<"copier">>),
    Plain = sheet(Config, "theme.plain.css"),
    {303, H, _} = act(Config, M, [{"do", "new"}, {"name", "mine"}, {"from", "plain"}]),
    "/mod/themes/mine" = proplists:get_value("location", H),
    Plain = sheet(Config, "theme.mine.css"),
    {409, _, _} = act(Config, M, [{"do", "new"}, {"name", "mine"}, {"from", "plain"}]),
    {400, _, _} = act(Config, M, [{"do", "new"}, {"name", "Not A Name"}, {"from", "plain"}]),
    {400, _, _} = act(Config, M, [{"do", "new"}, {"name", "other"}, {"from", "nothing"}]).
