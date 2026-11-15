%% Moderation, from outside: who may do what, what each rung of the
%% ladder looks like to a reader, suspension across a restart, locking,
%% the sweep at start, and the end of a hold. Invariant 8 (purge) is
%% ike_invariant_SUITE's.
-module(ike_mod_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    nobody_else_sees_it/1,
    a_janitor_only_hides/1,
    a_janitor_keeps_to_its_boards/1,
    nobody_bans_their_rank/1,
    nobody_undoes_a_higher_rank/1,
    a_moderator_does_not_purge/1,
    a_first_post_takes_its_thread/1,
    a_ban_outlives_a_restart/1,
    locking/1,
    the_log_takes_nothing/1,
    a_stale_page_goes_at_start/1,
    a_hold_ends/1
]).

-import(ike_browser, [login/2, login/3, post/4, sign/4, request/5, query/3, cookies/1]).

all() ->
    [
        nobody_else_sees_it,
        a_janitor_only_hides,
        a_janitor_keeps_to_its_boards,
        nobody_bans_their_rank,
        nobody_undoes_a_higher_rank,
        a_moderator_does_not_purge,
        a_first_post_takes_its_thread,
        a_ban_outlives_a_restart,
        locking,
        the_log_takes_nothing,
        a_stale_page_goes_at_start,
        %% last: it starts ike again with a short hold
        a_hold_ends
    ].

init_per_suite(Config) ->
    ike_browser:start(Config, []).

end_per_suite(_Config) ->
    ike_browser:stop().

janitor(Config, Name) -> login(Config, Name, #{groups => [<<"ike-janitor-b">>]}).
moderator(Config, Name) -> login(Config, Name, #{groups => [<<"ike-moderator">>]}).
admin(Config, Name) -> login(Config, Name, #{groups => [<<"ike-admin">>]}).

%% a post's number, from where posting it sent the browser
number(Headers) ->
    "#p" ++ N = string:find(proplists:get_value("location", Headers), "#"),
    N.

page(Headers) ->
    hd(string:split(proplists:get_value("location", Headers), "#")).

thread(Config, Session, Text) ->
    {303, Headers, _} = post(Config, "/board/b/new", Session, Text),
    {page(Headers), number(Headers)}.

%% one action, as its form sends it
act(Config, #{csrf := Csrf} = Session, Path, Kind, Reason) ->
    Form = uri_string:compose_query([{"csrf", Csrf}, {"kind", Kind}, {"reason", Reason}]),
    request(Config, post, Path, cookies(Session), {form, Form}).

status(Config, Path) ->
    element(1, request(Config, get, Path, [], none)).

nobody_else_sees_it(Config) ->
    Writer = login(Config, <<"plain">>),
    {_, N} = thread(Config, Writer, <<"not to be touched">>),
    Paths = ["/mod", "/mod/post/" ++ N, "/mod/board/b", "/mod/account/1"],
    %% no role, or no session: there is nothing there
    [{404, _, _} = request(Config, get, P, cookies(Writer), none) || P <- Paths],
    [{404, _, _} = request(Config, get, P, [], none) || P <- Paths],
    [{404, _, _} = act(Config, Writer, P, "hide", "x") || P <- Paths],
    %% a role from a group the provider made up is no role
    Stranger = login(Config, <<"stranger">>, #{groups => [<<"ike-admins">>, 7, <<"wheel">>]}),
    {404, _, _} = request(Config, get, "/mod", cookies(Stranger), none),
    %% and with one, a token from elsewhere does nothing
    #{csrf := _} = Admin = admin(Config, <<"tokenless">>),
    {403, _, _} = act(Config, Admin#{csrf := "wrong"}, "/mod/post/" ++ N, "hide", "x"),
    [[0]] = query(Config, "SELECT state FROM post WHERE id = ?", [list_to_integer(N)]).

a_janitor_only_hides(Config) ->
    Writer = login(Config, <<"jwriter">>),
    {Thread, Root} = thread(Config, Writer, <<"a thread">>),
    {303, H, _} = post(Config, Thread ++ "/reply", Writer, <<"a reply to hide">>),
    N = number(H),
    Path = "/mod/post/" ++ N,
    Janitor = janitor(Config, <<"janitor">>),
    {200, _, Look} = request(Config, get, Path, cookies(Janitor), none),
    Kinds = [K || [K] <- forms(Look)],
    [<<"hide">>] = Kinds,
    [{403, _, _} = act(Config, Janitor, Path, K, "x") || K <- ["delete", "purge", "ban"]],
    {403, _, _} = act(Config, Janitor, "/mod/board/b", "unlock", "x"),
    {303, _, _} = act(Config, Janitor, Path, "hide", "off topic"),
    {200, _, Page} = request(Config, get, Thread, [], none),
    nomatch = binary:match(Page, <<"a reply to hide">>),
    {404, _, _} = request(Config, get, "/p/" ++ N, [], none),
    %% twice is not twice
    {409, _, _} = act(Config, Janitor, Path, "hide", "again"),
    {303, _, _} = act(Config, Janitor, Path, "unhide", "was fine"),
    {200, _, Again} = request(Config, get, Thread, [], none),
    {_, _} = binary:match(Again, <<"a reply to hide">>),
    %% the log says who in what role, and why, under the post's number
    [[<<"janitor">>, <<"hide">>], [<<"janitor">>, <<"unhide">>]] = query(
        Config,
        "SELECT role, kind FROM action WHERE post = ? ORDER BY entry",
        [list_to_integer(N)]
    ),
    _ = Root.

a_janitor_keeps_to_its_boards(Config) ->
    Writer = login(Config, <<"kwriter">>),
    {303, H, _} = post(Config, "/board/meta/new", Writer, <<"on meta">>),
    N = number(H),
    Path = "/mod/post/" ++ N,
    Janitor = janitor(Config, <<"kjanitor">>),
    {200, _, Look} = request(Config, get, Path, cookies(Janitor), none),
    [] = forms(Look),
    {403, _, _} = act(Config, Janitor, Path, "hide", "not my board"),
    {200, _, Mod} = request(Config, get, "/mod", cookies(Janitor), none),
    {_, _} = binary:match(Mod, <<"janitor of /b/">>),
    %% a group that names no board, or no group of the kind, is no role
    [
        {404, _, _} = request(
            Config, get, "/mod", cookies(login(Config, Name, #{groups => [Group]})), none
        )
     || {Name, Group} <- [
            {<<"k1">>, <<"ike-janitor-">>},
            {<<"k2">>, <<"ike-janitor-B!">>},
            {<<"k3">>, <<"ike-janitor">>}
        ]
    ],
    %% two groups, two boards
    Both = login(Config, <<"kboth">>, #{groups => [<<"ike-janitor-meta">>, <<"ike-janitor-b">>]}),
    {303, _, _} = act(Config, Both, Path, "hide", "now it is").

%% a post signed by the account behind Session, and its moderation page
signed(Config, Session, Text) ->
    {303, H, _} = sign(Config, "/board/b/new", Session, Text),
    "/mod/post/" ++ number(H).

nobody_bans_their_rank(Config) ->
    Moderator = moderator(Config, <<"rmoderator">>),
    Other = moderator(Config, <<"rmoderator2">>),
    Admin = admin(Config, <<"radmin">>),
    Janitor = janitor(Config, <<"rjanitor">>),
    Own = signed(Config, Moderator, <<"by a moderator">>),
    Peer = signed(Config, Other, <<"by another moderator">>),
    Above = signed(Config, Admin, <<"by an admin">>),
    Below = signed(Config, Janitor, <<"by a janitor">>),
    Offered = fun(Path) ->
        {200, _, Look} = request(Config, get, Path, cookies(Moderator), none),
        lists:member(<<"ban">>, [K || [K] <- forms(Look)])
    end,
    [false = Offered(P) || P <- [Own, Peer, Above]],
    [{403, _, _} = act(Config, Moderator, P, "ban", "x") || P <- [Own, Peer, Above]],
    true = Offered(Below),
    {303, _, _} = act(Config, Moderator, Below, "ban", "rank does not shield a janitor"),
    %% and above a moderator, an admin may
    {303, _, _} = act(Config, Admin, Peer, "ban", "rule 6"),
    %% a moderator logged in again without the group is a moderator no
    %% longer, and can be banned like anyone
    _ = login(Config, <<"rmoderator">>),
    Third = moderator(Config, <<"rmoderator3">>),
    {303, _, _} = act(Config, Third, Own, "ban", "demoted, then banned"),
    [[0]] = query(Config, "SELECT rank FROM actor WHERE subject = 'rmoderator'", []).

nobody_undoes_a_higher_rank(Config) ->
    Writer = login(Config, <<"uwriter">>),
    {303, H, _} = post(Config, "/board/b/new", Writer, <<"hidden by a moderator">>),
    Path = "/mod/post/" ++ number(H),
    Moderator = moderator(Config, <<"umoderator">>),
    Janitor = janitor(Config, <<"ujanitor">>),
    {303, _, _} = act(Config, Moderator, Path, "hide", "moderator's call"),
    {200, _, Look} = request(Config, get, Path, cookies(Janitor), none),
    [] = forms(Look),
    {403, _, _} = act(Config, Janitor, Path, "unhide", "overruled"),
    {303, _, _} = act(Config, Moderator, Path, "unhide", "my own call"),
    %% and the other way about
    {303, _, _} = act(Config, Janitor, Path, "hide", "janitor's call"),
    {303, _, _} = act(Config, Moderator, Path, "unhide", "overruled").

%% the kinds a moderator's page offers, in order
forms(Html) ->
    case
        re:run(Html, "name=\"kind\" value=\"([a-z]+)\"", [global, {capture, all_but_first, binary}])
    of
        {match, Kinds} -> Kinds;
        nomatch -> []
    end.

a_moderator_does_not_purge(Config) ->
    Writer = login(Config, <<"mwriter">>),
    {Thread, _} = thread(Config, Writer, <<"a thread">>),
    {303, H, _} = post(Config, Thread ++ "/reply", Writer, <<"a reply to delete">>),
    N = number(H),
    Path = "/mod/post/" ++ N,
    Moderator = moderator(Config, <<"moderator">>),
    {200, _, Look} = request(Config, get, Path, cookies(Moderator), none),
    %% an unsigned post leads to no account: nothing to ban
    [<<"hide">>, <<"delete">>] = [K || [K] <- forms(Look)],
    {403, _, _} = act(Config, Moderator, Path, "purge", "x"),
    {303, _, _} = act(Config, Moderator, Path, "delete", "rule 3"),
    {404, _, _} = request(Config, get, "/p/" ++ N, [], none),
    [[2, Until]] = query(
        Config, "SELECT state, purge_at FROM post WHERE id = ?", [list_to_integer(N)]
    ),
    true = Until > erlang:system_time(second) + 86400,
    {200, _, Deleted} = request(Config, get, Path, cookies(Moderator), none),
    [<<"restore">>] = [K || [K] <- forms(Deleted)],
    {303, _, _} = act(Config, Moderator, Path, "restore", "on appeal"),
    {303, _, _} = request(Config, get, "/p/" ++ N, [], none),
    [[0, undefined]] = query(
        Config, "SELECT state, purge_at FROM post WHERE id = ?", [list_to_integer(N)]
    ),
    %% a reason is text
    {400, _, _} = act(Config, Moderator, Path, "hide", ""),
    {400, _, _} = act(Config, Moderator, Path, "hide", "a\x{7}bell"),
    {400, _, _} = act(Config, Moderator, Path, "sing", "x"),
    {404, _, _} = act(Config, Moderator, "/mod/post/999999", "hide", "x").

a_first_post_takes_its_thread(Config) ->
    Writer = login(Config, <<"twriter">>),
    {Thread, Root} = thread(Config, Writer, <<"the root">>),
    {303, H, _} = post(Config, Thread ++ "/reply", Writer, <<"a reply under it">>),
    Reply = number(H),
    {Other, _} = thread(Config, Writer, list_to_binary("see >>" ++ Root)),
    Moderator = moderator(Config, <<"tmoderator">>),
    Path = "/mod/post/" ++ Root,
    {303, _, _} = act(Config, Moderator, Path, "hide", "the whole thread"),
    [404 = status(Config, P) || P <- [Thread, "/p/" ++ Root, "/p/" ++ Reply]],
    {404, _, _} = request(Config, get, Thread ++ "/reply", cookies(Writer), none),
    {404, _, _} = post(Config, Thread ++ "/reply", Writer, <<"into a hidden thread">>),
    {200, _, Index} = request(Config, get, "/board/b", [], none),
    nomatch = binary:match(Index, list_to_binary("href=\"" ++ Thread ++ "\"")),
    {200, _, Quoting} = request(Config, get, Other, [], none),
    {_, _} = binary:match(Quoting, list_to_binary("<span class=\"gone\">&gt;&gt;" ++ Root)),
    %% the reply is still a post, only not shown
    [[0]] = query(Config, "SELECT state FROM post WHERE id = ?", [list_to_integer(Reply)]),
    {303, _, _} = act(Config, Moderator, Path, "unhide", "was fine"),
    [200 = status(Config, P) || P <- [Thread, Other]],
    303 = status(Config, "/p/" ++ Reply),
    {200, _, Back} = request(Config, get, Other, [], none),
    {_, _} = binary:match(Back, list_to_binary("href=\"/p/" ++ Root ++ "\"")),
    {200, _, Index2} = request(Config, get, "/board/b", [], none),
    {_, _} = binary:match(Index2, list_to_binary("href=\"" ++ Thread ++ "\"")).

a_ban_outlives_a_restart(Config) ->
    Subject = <<"banned">>,
    Writer = login(Config, Subject),
    {303, H, _} = sign(Config, "/board/b/new", Writer, <<"signed, and against the rules">>),
    N = number(H),
    Moderator = moderator(Config, <<"bmoderator">>),
    {200, _, Look} = request(Config, get, "/mod/post/" ++ N, cookies(Moderator), none),
    [<<"hide">>, <<"delete">>, <<"ban">>] = [K || [K] <- forms(Look)],
    {303, _, _} = act(Config, Moderator, "/mod/post/" ++ N, "ban", "rule 4"),
    {409, _, _} = act(Config, Moderator, "/mod/post/" ++ N, "ban", "again"),
    %% the session is gone at once, and no new one is given
    {200, _, Form} = request(Config, get, "/board/b/new", cookies(Writer), none),
    nomatch = binary:match(Form, <<"/logout">>),
    suspended(Config, Subject),
    ok = ike_browser:restart(),
    suspended(Config, Subject),
    %% the post stays: a ban is of the account, not of what it said
    303 = status(Config, "/p/" ++ N),
    {200, _, Mod} = request(Config, get, "/mod", cookies(Moderator), none),
    {_, _} = binary:match(Mod, <<"banned: suspended">>),
    [[Account]] = query(Config, "SELECT id FROM actor WHERE subject = ?", [Subject]),
    Path = "/mod/account/" ++ integer_to_list(Account),
    {303, _, _} = act(Config, Moderator, Path, "unban", "served its time"),
    {409, _, _} = act(Config, Moderator, Path, "unban", "again"),
    {404, _, _} = act(Config, Moderator, "/mod/account/999999", "unban", "x"),
    #{csrf := _} = login(Config, Subject).

%% a login that the provider lets through and ike does not
suspended(Config, Subject) ->
    Login = ike_browser:begin_login(Config),
    Code = "code-again-" ++ binary_to_list(Subject),
    ok = ike_browser:expect(Login, Code, fun(Nonce) ->
        ike_browser:id_token(Config, Nonce, Subject, #{})
    end),
    {403, Headers, Page} = ike_browser:callback(Config, Login, Code),
    {_, _} = binary:match(Page, <<"suspended">>),
    none = ike_browser:set_cookie("__Host-ike", Headers).

locking(Config) ->
    Moderator = moderator(Config, <<"lmoderator">>),
    {200, _, Before} = request(Config, get, "/board/meta/new", [], none),
    {_, _} = binary:match(Before, <<"href=\"/login\"">>),
    {409, _, _} = act(Config, Moderator, "/mod/board/meta", "lock", "already"),
    {303, _, _} = act(Config, Moderator, "/mod/board/meta", "unlock", "open for a while"),
    {303, _, _} = ike_browser:anonymous(Config, "/board/meta/new", [], <<"from nobody">>),
    {303, _, _} = act(Config, Moderator, "/mod/board/meta", "lock", "closed again"),
    %% locked: nobody's post is refused before its token is looked at
    {403, _, _} = request(Config, post, "/board/meta/new", [], {form, "body=too+late"}),
    {404, _, _} = act(Config, Moderator, "/mod/board/nope", "lock", "x"),
    {404, _, _} = act(Config, Moderator, "/mod/board/mod", "unlock", "x"),
    {400, _, _} = act(Config, Moderator, "/mod/board/meta", "hide", "x"),
    [[<<"lock /meta/\nclosed again">>]] = query(
        Config,
        "SELECT p.body FROM action a JOIN post p ON p.id = a.entry"
        " WHERE a.kind = 'lock' ORDER BY a.entry DESC LIMIT 1",
        []
    ).

the_log_takes_nothing(Config) ->
    Writer = login(Config, <<"lwriter">>),
    {200, _, Log} = request(Config, get, "/board/mod", [], none),
    nomatch = binary:match(Log, <<"/board/mod/new">>),
    [[Root]] = query(
        Config,
        "SELECT t.root FROM thread t JOIN board b ON b.id = t.board"
        " WHERE b.name = 'mod' ORDER BY t.root LIMIT 1",
        []
    ),
    Thread = "/board/mod/" ++ integer_to_list(Root),
    {200, _, Page} = request(Config, get, Thread, [], none),
    nomatch = binary:match(Page, <<"/reply">>),
    {404, _, _} = request(Config, get, "/board/mod/new", cookies(Writer), none),
    {404, _, _} = post(Config, "/board/mod/new", Writer, <<"into the log">>),
    {404, _, _} = post(Config, Thread ++ "/reply", Writer, <<"into the log">>),
    Admin = admin(Config, <<"ladmin">>),
    Path = "/mod/post/" ++ integer_to_list(Root),
    {404, _, _} = request(Config, get, Path, cookies(Admin), none),
    {404, _, _} = act(Config, Admin, Path, "purge", "the log itself").

a_stale_page_goes_at_start(Config) ->
    Writer = login(Config, <<"swriter">>),
    {Thread, Root} = thread(Config, Writer, <<"to be hidden">>),
    {Kept, KeptRoot} = thread(Config, Writer, <<"to be kept">>),
    Moderator = moderator(Config, <<"smoderator">>),
    {303, _, _} = act(Config, Moderator, "/mod/post/" ++ Root, "hide", "x"),
    File = ike_browser:page_file(Config, list_to_integer(Root)),
    false = filelib:is_regular(File),
    %% what a stop between the commit and the unlink would leave
    ok = file:write_file(File, <<"stale">>),
    ok = ike_browser:restart(),
    false = filelib:is_regular(File),
    true = filelib:is_regular(ike_browser:page_file(Config, list_to_integer(KeptRoot))),
    404 = status(Config, Thread),
    200 = status(Config, Kept).

a_hold_ends(Config0) ->
    ike_browser:stop(),
    Config = ike_browser:start(Config0, [{hold_seconds, 1}]),
    Writer = login(Config, <<"hwriter">>),
    {_, Root} = thread(Config, Writer, <<"held, then gone">>),
    N = list_to_integer(Root),
    Moderator = moderator(Config, <<"hmoderator">>),
    {303, _, _} = act(Config, Moderator, "/mod/post/" ++ Root, "delete", "rule 5"),
    [] = wait(fun() -> query(Config, "SELECT id FROM post WHERE id = ?", [N]) end, 50),
    %% ike did it, and says so: no account, the role system
    [[<<"system">>, undefined, Entry]] = query(
        Config, "SELECT role, actor, entry FROM action WHERE kind = 'purge' AND post = ?", [N]
    ),
    {303, H, _} = request(Config, get, "/p/" ++ integer_to_list(Entry), [], none),
    {200, _, Log} = request(Config, get, page(H), [], none),
    {_, _} = binary:match(Log, <<"<span class=\"name role\">system</span>">>),
    {_, _} = binary:match(Log, <<"<span class=\"name role\">moderator</span>">>).

wait(Fun, 0) ->
    Fun();
wait(Fun, N) ->
    case Fun() of
        [] ->
            [];
        _ ->
            timer:sleep(200),
            wait(Fun, N - 1)
    end.
