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
    only_so_many_tries/1
]).

-import(ike_browser, [login/2, login/3, request/5, query/3, cookies/1]).

all() -> [by_password, by_account, from_this_site_only, only_so_many_tries].

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

retract(Config, N, Fields, Headers) ->
    element(
        1,
        request(
            Config,
            post,
            "/p/" ++ N ++ "/retract",
            Headers,
            {form, uri_string:compose_query(Fields)}
        )
    ).

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
