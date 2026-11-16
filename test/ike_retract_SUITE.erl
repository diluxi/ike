%% Retraction, from outside: a poster trashes their own post with the
%% password given when posting, or as the account that signed it. Not a
%% moderation, not in the log; kept, and seen by moderators.
-module(ike_retract_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    by_password/1,
    by_account/1,
    from_this_site_only/1,
    only_so_many_tries/1,
    the_browser_keeps_its_password/1,
    reported_and_dismissed/1,
    moderated_from_the_thread/1
]).

-import(ike_browser, [login/2, login/3, request/5, query/3, cookies/1]).

all() ->
    [
        by_password,
        by_account,
        from_this_site_only,
        only_so_many_tries,
        the_browser_keeps_its_password,
        reported_and_dismissed,
        moderated_from_the_thread
    ].

init_per_suite(Config0) ->
    Config = ike_browser:start(Config0, []),
    ok = ike_browser:unlock(Config, <<"meta">>),
    Config.

end_per_suite(_Config) ->
    ike_browser:stop().

%% the browser's word that a form is this site's
here(Config) ->
    [{"origin", ?config(base, Config)}].

%% a post by nobody on meta, with a password; its number
nobody(Config, Text, Password) ->
    {Token, Cookie, _} = ike_browser:form(Config, "/board/meta/new", []),
    Form = uri_string:compose_query([
        {<<"csrf">>, list_to_binary(Token)}, {<<"body">>, Text}, {<<"password">>, Password}
    ]),
    {303, H, _} = request(
        Config, post, "/board/meta/new", [{"cookie", "__Host-ike-form=" ++ Cookie}], {form, Form}
    ),
    "#p" ++ N = string:find(proplists:get_value("location", H), "#"),
    N.

%% the thread form's retract, for one post: what it came to, as a status
retract(Config, N, Fields, Headers) ->
    Form = uri_string:compose_query([{"post", N}, {"kind", "retract"} | Fields]),
    case request(Config, post, "/act", Headers, {form, Form}) of
        {200, _, Page} ->
            Said = [
                S
             || {Text, S} <- [
                    {<<": retracted">>, 200},
                    {<<"too many tries">>, 429},
                    {<<"already out of view">>, 409}
                ],
                binary:match(Page, Text) =/= nomatch
            ],
            case Said of
                [S | _] -> S;
                [] -> 403
            end;
        {Status, _, _} ->
            Status
    end.

by_password(Config) ->
    A = nobody(Config, <<"mine to take back">>, <<"hunter2">>),
    B = nobody(Config, <<"also mine">>, <<"hunter2">>),
    %% one password, two posts, nothing in common kept
    [[SA]] = query(Config, "SELECT password FROM post WHERE id = ?", [list_to_integer(A)]),
    [[SB]] = query(Config, "SELECT password FROM post WHERE id = ?", [list_to_integer(B)]),
    true = SA =/= SB,
    nomatch = binary:match(SA, <<"hunter2">>),
    403 = retract(Config, A, [{"password", "wrong"}], here(Config)),
    303 = element(1, request(Config, get, "/p/" ++ A, [], none)),
    200 = retract(Config, A, [{"password", "hunter2"}], here(Config)),
    404 = element(1, request(Config, get, "/p/" ++ A, [], none)),
    [[2, 1]] = query(Config, "SELECT state, retracted FROM post WHERE id = ?", [list_to_integer(A)]),
    %% not a moderation: nothing in the log
    [[0]] = query(Config, "SELECT count(*) FROM action WHERE post = ?", [list_to_integer(A)]),
    %% twice is not twice
    409 = retract(Config, A, [{"password", "hunter2"}], here(Config)),
    %% a moderator sees it, retracted, and may put it back
    Moderator = login(Config, <<"rmod">>, #{groups => [<<"ike-moderator">>]}),
    {200, _, Look} = request(Config, get, "/mod/post/" ++ A, cookies(Moderator), none),
    {_, _} = binary:match(Look, <<"retracted by its poster">>),
    #{csrf := Csrf} = Moderator,
    {303, _, _} = request(
        Config,
        post,
        "/mod/post/" ++ A,
        cookies(Moderator),
        {form, uri_string:compose_query([{"csrf", Csrf}, {"kind", "restore"}, {"reason", "x"}])}
    ),
    [[0, 0]] = query(Config, "SELECT state, retracted FROM post WHERE id = ?", [list_to_integer(A)]),
    %% a post given no password cannot be retracted by one
    C = nobody(Config, <<"no password">>, <<>>),
    [[undefined]] = query(Config, "SELECT password FROM post WHERE id = ?", [list_to_integer(C)]),
    403 = retract(Config, C, [{"password", ""}], here(Config)),
    403 = retract(Config, C, [{"password", "anything"}], here(Config)).

by_account(Config) ->
    Session = login(Config, <<"retracter">>),
    Other = login(Config, <<"bystander">>),
    {303, H, _} = ike_browser:sign(Config, "/board/b/new", Session, <<"signed, then taken back">>),
    "#p" ++ N = string:find(proplists:get_value("location", H), "#"),
    403 = retract(Config, N, [], cookies(Other) ++ here(Config)),
    200 = retract(Config, N, [], cookies(Session) ++ here(Config)),
    [[2, 1]] = query(Config, "SELECT state, retracted FROM post WHERE id = ?", [list_to_integer(N)]),
    %% an unsigned post is nobody's: the account cannot take it back
    %% without the password it gave
    {303, H2, _} = ike_browser:post(Config, "/board/b/new", Session, <<"unsigned">>),
    "#p" ++ M = string:find(proplists:get_value("location", H2), "#"),
    403 = retract(Config, M, [], cookies(Session) ++ here(Config)).

from_this_site_only(Config) ->
    N = nobody(Config, <<"guarded">>, <<"pw">>),
    [
        403 = retract(Config, N, [{"password", "pw"}], Headers)
     || Headers <- [
            [],
            [{"origin", "null"}],
            [{"origin", "http://media.test"}],
            [{"origin", "https://elsewhere.example"}]
        ]
    ],
    303 = element(1, request(Config, get, "/p/" ++ N, [], none)).

only_so_many_tries(Config) ->
    N = nobody(Config, <<"guess me">>, <<"long and right">>),
    [403 = retract(Config, N, [{"password", "wrong"}], here(Config)) || _ <- lists:seq(1, 10)],
    429 = retract(Config, N, [{"password", "long and right"}], here(Config)),
    303 = element(1, request(Config, get, "/p/" ++ N, [], none)).

%% the post form fills in a password this browser keeps, and the thread
%% form uses it when none is typed
the_browser_keeps_its_password(Config) ->
    {200, Headers, Form} = request(Config, get, "/board/meta/new", [], none),
    Kept = ike_browser:set_cookie("__Host-ike-password", Headers),
    true = is_list(Kept) andalso length(Kept) > 8,
    {_, _} = binary:match(Form, list_to_binary("value=\"" ++ Kept ++ "\"")),
    Token = ike_browser:set_cookie("__Host-ike-form", Headers),
    {match, [Csrf]} = re:run(Form, "name=\"csrf\" value=\"([^\"]+)\"", [
        {capture, all_but_first, list}
    ]),
    Cookies = [{"cookie", "__Host-ike-form=" ++ Token ++ "; __Host-ike-password=" ++ Kept}],
    {303, H, _} = request(
        Config,
        post,
        "/board/meta/new",
        Cookies,
        {form, uri_string:compose_query([{"csrf", Csrf}, {"body", "kept"}, {"password", Kept}])}
    ),
    "#p" ++ N = string:find(proplists:get_value("location", H), "#"),
    403 = retract(Config, N, [], here(Config)),
    200 = retract(Config, N, [], [{"cookie", "__Host-ike-password=" ++ Kept} | here(Config)]).

reported_and_dismissed(Config) ->
    N = nobody(Config, <<"report me">>, <<>>),
    Report = fun(Reason) ->
        {200, _, Page} = request(
            Config,
            post,
            "/act",
            here(Config),
            {form, uri_string:compose_query([{"post", N}, {"kind", "report"}, {"reason", Reason}])}
        ),
        Page
    end,
    {_, _} = binary:match(Report(""), <<"give a reason">>),
    {_, _} = binary:match(Report("spam, says <b>me</b>"), <<": reported">>),
    %% nothing of who reported is kept
    [[<<"report">>, <<"id,post,reason,time,done">>]] = query(
        Config,
        "SELECT 'report', group_concat(name) FROM pragma_table_info('report')",
        []
    ),
    Moderator = login(Config, <<"repmod">>, #{groups => [<<"ike-moderator">>]}),
    {200, _, Mod} = request(Config, get, "/mod", cookies(Moderator), none),
    {_, _} = binary:match(Mod, <<"spam, says &lt;b&gt;me&lt;/b&gt;">>),
    [[Id]] = query(Config, "SELECT max(id) FROM report", []),
    #{csrf := Csrf} = Moderator,
    {303, _, _} = request(
        Config,
        post,
        "/mod/report/" ++ integer_to_list(Id),
        cookies(Moderator),
        {form, uri_string:compose_query([{"csrf", Csrf}, {"kind", "dismiss"}])}
    ),
    {200, _, After} = request(Config, get, "/mod", cookies(Moderator), none),
    nomatch = binary:match(After, <<"spam, says">>).

moderated_from_the_thread(Config) ->
    A = nobody(Config, <<"first">>, <<>>),
    B = nobody(Config, <<"second">>, <<>>),
    Act = fun(Who, Kind) ->
        request(
            Config,
            post,
            "/act",
            cookies(Who) ++ here(Config),
            {form,
                uri_string:compose_query([
                    {"post", A}, {"post", B}, {"kind", Kind}, {"reason", "off topic"}
                ])}
        )
    end,
    %% for anyone without a role the buttons do nothing
    Plain = login(Config, <<"plainreader">>),
    {403, _, _} = Act(Plain, "trash"),
    {403, _, _} = request(
        Config,
        post,
        "/act",
        here(Config),
        {form, uri_string:compose_query([{"post", A}, {"kind", "hide"}, {"reason", "x"}])}
    ),
    [[0], [0]] = [
        hd(query(Config, "SELECT state FROM post WHERE id = ?", [list_to_integer(P)]))
     || P <- [A, B]
    ],
    %% a moderator trashes both at once, from another site not at all
    Moderator = login(Config, <<"threadmod">>, #{groups => [<<"ike-moderator">>]}),
    {403, _, _} = request(
        Config,
        post,
        "/act",
        cookies(Moderator) ++ [{"origin", "http://media.test"}],
        {form, uri_string:compose_query([{"post", A}, {"kind", "trash"}, {"reason", "x"}])}
    ),
    {200, _, Done} = Act(Moderator, "trash"),
    {_, _} = binary:match(Done, list_to_binary("&gt;&gt;" ++ A ++ ": trash")),
    {_, _} = binary:match(Done, list_to_binary("&gt;&gt;" ++ B ++ ": trash")),
    [[2], [2]] = [
        hd(query(Config, "SELECT state FROM post WHERE id = ?", [list_to_integer(P)]))
     || P <- [A, B]
    ],
    %% and a janitor of b may not on meta
    Janitor = login(Config, <<"threadjan">>, #{groups => [<<"ike-janitor-b">>]}),
    C = nobody(Config, <<"third">>, <<>>),
    {200, _, Refused} = request(
        Config,
        post,
        "/act",
        cookies(Janitor) ++ here(Config),
        {form, uri_string:compose_query([{"post", C}, {"kind", "hide"}, {"reason", "x"}])}
    ),
    {_, _} = binary:match(Refused, <<"not your role&#39;s to do">>).
