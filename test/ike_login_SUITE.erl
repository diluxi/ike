%% Black-box: an OpenID provider stands beside ike, and the suite plays
%% the browser. It reads the database and the pages only as files.
-module(ike_login_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("public_key/include/public_key.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    login_sends_the_browser_away/1,
    login_then_post/1,
    reply_and_index/1,
    boards_keep_their_threads/1,
    only_boards_there_are/1,
    posting_needs_a_session/1,
    posting_needs_the_token/1,
    bad_text_is_refused/1,
    only_forms_are_read/1,
    reply_to_nothing/1,
    callback_needs_the_state/1,
    callback_needs_the_browser/1,
    state_works_once/1,
    token_must_verify/1,
    code_must_be_the_issued_one/1,
    logout/1,
    sessions_outlive_a_restart/1,
    same_subject_same_actor/1,
    a_name_is_asked_for/1,
    no_name_no_asking/1,
    only_plain_names/1,
    a_new_name_is_on_old_posts/1,
    nobody_has_many_names/1
]).

-import(ike_browser, [
    login/2,
    login/3,
    sign/4,
    begin_login/1,
    expect/3,
    callback/3,
    claims/3,
    id_token/4,
    post/4,
    cookies/1,
    request/5,
    set_cookie/2,
    cookie_attributes/2,
    query/3,
    posts/1,
    page_file/2
]).

all() ->
    [
        login_sends_the_browser_away,
        login_then_post,
        reply_and_index,
        boards_keep_their_threads,
        only_boards_there_are,
        posting_needs_a_session,
        posting_needs_the_token,
        bad_text_is_refused,
        only_forms_are_read,
        reply_to_nothing,
        callback_needs_the_state,
        callback_needs_the_browser,
        state_works_once,
        token_must_verify,
        code_must_be_the_issued_one,
        logout,
        sessions_outlive_a_restart,
        same_subject_same_actor,
        a_name_is_asked_for,
        no_name_no_asking,
        only_plain_names,
        a_new_name_is_on_old_posts,
        nobody_has_many_names
    ].

-define(CLIENT, <<"ike-test">>).

init_per_suite(Config) ->
    ike_browser:start(Config, []).

end_per_suite(_Config) ->
    ike_browser:stop().

login_sends_the_browser_away(Config) ->
    {303, Headers, _} = request(Config, get, "/login", [], none),
    Location = proplists:get_value("location", Headers),
    #{path := "/authorize", query := Query} = uri_string:parse(Location),
    Params = maps:from_list(uri_string:dissect_query(Query)),
    #{
        "response_type" := "code",
        "client_id" := "ike-test",
        "scope" := "openid profile groups",
        "code_challenge_method" := "S256",
        "state" := State,
        "nonce" := Nonce,
        "code_challenge" := Challenge
    } = Params,
    true = length(State) >= 32,
    true = length(Nonce) >= 32,
    43 = length(Challenge),
    Cookie = set_cookie("__Host-ike-login", Headers),
    true = Cookie =/= none,
    Attributes = string:lowercase(cookie_attributes("__Host-ike-login", Headers)),
    [true = string:find(Attributes, A) =/= nomatch || A <- ["secure", "httponly", "samesite=lax"]],
    %% another login is another state
    {303, Headers2, _} = request(Config, get, "/login", [], none),
    #{query := Query2} = uri_string:parse(proplists:get_value("location", Headers2)),
    false = proplists:get_value("state", uri_string:dissect_query(Query2)) =:= State.

login_then_post(Config) ->
    Session = login(Config, <<"alice">>),
    Text = <<"hello from a test, with <b>angle</b> & \"quotes\"\nand a second line">>,
    {303, Headers, _} = sign(Config, "/board/b/new", Session, Text),
    "/board/b/" ++ Rest = proplists:get_value("location", Headers),
    {N, "#p" ++ P} = string:to_integer(Rest),
    N = list_to_integer(P),
    %% a row, written for the account's actor and nobody's address
    [[N, Actor, Body]] = query(Config, "SELECT thread, actor, body FROM post WHERE id = ?", [N]),
    Body = Text,
    [[<<"local">>, Issuer, <<"alice">>]] = query(
        Config, "SELECT kind, issuer, subject FROM actor WHERE id = ?", [Actor]
    ),
    Issuer = ?config(issuer, Config),
    %% a page, which is a file, and the file is what is served
    {ok, File} = file:read_file(page_file(Config, N)),
    {200, _, Served} = request(Config, get, "/board/b/" ++ integer_to_list(N), [], none),
    File = Served,
    {_, _} = binary:match(File, <<"&lt;b&gt;angle&lt;/b&gt; &amp; &quot;quotes&quot;">>),
    nomatch = binary:match(File, <<"<b>">>),
    {_, _} = binary:match(File, <<"<span class=\"name account\">alice</span>">>),
    nomatch = binary:match(File, <<"example.org">>),
    nomatch = binary:match(File, <<"A Person">>).

reply_and_index(Config) ->
    Session = login(Config, <<"bob">>),
    {303, Headers, _} = post(Config, "/board/b/new", Session, <<"a thread to reply in">>),
    {N, _} = string:to_integer(proplists:get_value("location", Headers) -- "/board/b/"),
    Thread = "/board/b/" ++ integer_to_list(N),
    {200, _, Form} = request(Config, get, Thread ++ "/reply", cookies(Session), none),
    {_, _} = binary:match(Form, <<"name=\"csrf\"">>),
    {303, Headers2, _} = post(Config, Thread ++ "/reply", Session, <<"the reply itself">>),
    Location = proplists:get_value("location", Headers2),
    true = lists:prefix(Thread ++ "#p", Location),
    {200, _, Page} = request(Config, get, Thread, [], none),
    {_, _} = binary:match(Page, <<"a thread to reply in">>),
    {_, _} = binary:match(Page, <<"the reply itself">>),
    [[2]] = query(Config, "SELECT count(*) FROM post WHERE thread = ?", [N]),
    {200, _, Index} = request(Config, get, "/board/b", [], none),
    {_, _} = binary:match(Index, list_to_binary("href=\"" ++ Thread ++ "\"")),
    {ok, Index} = file:read_file(filename:join([?config(dir, Config), "pages", "board", "b.html"])).

boards_keep_their_threads(Config) ->
    Session = login(Config, <<"britta">>),
    {303, Headers, _} = post(Config, "/board/meta/new", Session, <<"only on meta">>),
    "/board/meta/" ++ Rest =
        Thread = hd(string:split(proplists:get_value("location", Headers), "#")),
    {N, _} = string:to_integer(Rest),
    {200, _, Page} = request(Config, get, Thread, [], none),
    {_, _} = binary:match(Page, <<"only on meta">>),
    {200, _, Meta} = request(Config, get, "/board/meta", [], none),
    {_, _} = binary:match(Meta, <<"only on meta">>),
    {_, _} = binary:match(Meta, <<"about ike">>),
    {200, _, Other} = request(Config, get, "/board/b", [], none),
    nomatch = binary:match(Other, <<"only on meta">>),
    %% a thread is reached through its own board and no other
    Elsewhere = "/board/b/" ++ integer_to_list(N),
    {404, _, _} = request(Config, get, Elsewhere, [], none),
    {404, _, _} = request(Config, get, Elsewhere ++ "/reply", cookies(Session), none),
    {404, _, _} = post(Config, Elsewhere ++ "/reply", Session, <<"through the wrong door">>),
    [[1]] = query(Config, "SELECT count(*) FROM post WHERE thread = ?", [N]),
    %% both are listed, and a new board is locked (hazard a4)
    {200, _, Boards} = request(Config, get, "/board", [], none),
    [
        {_, _} = binary:match(Boards, B)
     || B <- [<<"href=\"/board/b\"">>, <<"href=\"/board/meta\"">>]
    ],
    [[<<"b">>, 1], [<<"meta">>, 1]] = query(
        Config, "SELECT name, locked FROM board WHERE log = 0 AND wiki = 0 ORDER BY name", []
    ).

only_boards_there_are(Config) ->
    Session = login(Config, <<"conrad">>),
    Before = posts(Config),
    lists:foreach(
        fun(Board) ->
            Path = "/board/" ++ Board,
            {404, _, _} = request(Config, get, Path, [], none),
            {404, _, _} = request(Config, get, Path ++ "/new", cookies(Session), none),
            {404, _, _} = post(Config, Path ++ "/new", Session, <<"nowhere">>),
            {404, _, _} = request(Config, get, Path ++ "/1", [], none)
        end,
        ["nope", "B", "b.html", "aaaaaaaaaaaaaaaaa", "b%2f1"]
    ),
    %% a path is not a file name. sent raw, since a client would tidy it
    #{port := Port} = uri_string:parse(?config(base, Config)),
    lists:foreach(
        fun(Path) ->
            {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
            ok = gen_tcp:send(Socket, [
                "GET ", Path, " HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n\r\n"
            ]),
            {ok, <<"HTTP/1.1 404", _/binary>>} = gen_tcp:recv(Socket, 0, 5000),
            ok = gen_tcp:close(Socket)
        end,
        [
            "/board/%2e%2e%2f%2e%2e%2fike.db",
            "/board/b/..%2f..%2f..%2fike.db",
            "/board/b%2f..%2fmeta",
            "/board/b/1%2f..%2f..%2fb"
        ]
    ),
    Before = posts(Config).

posting_needs_a_session(Config) ->
    Before = posts(Config),
    Body = uri_string:compose_query([{"csrf", "anything"}, {"body", "no session"}]),
    {403, _, _} = request(Config, post, "/board/b/new", [], {form, Body}),
    {403, _, _} = request(
        Config, post, "/board/b/new", [{"cookie", "__Host-ike=made-up"}], {form, Body}
    ),
    %% the form page shows no form to someone who is not logged in
    {200, _, Page} = request(Config, get, "/board/b/new", [], none),
    nomatch = binary:match(Page, <<"<form">>),
    Before = posts(Config).

%% hazard i2: a form another site could have sent changes nothing
posting_needs_the_token(Config) ->
    #{csrf := Csrf} = Session = login(Config, <<"carol">>),
    Before = posts(Config),
    Without = uri_string:compose_query([{"body", "no token"}]),
    {403, _, _} = request(Config, post, "/board/b/new", cookies(Session), {form, Without}),
    Wrong = uri_string:compose_query([{"csrf", lists:reverse(Csrf)}, {"body", "wrong token"}]),
    {403, _, _} = request(Config, post, "/board/b/new", cookies(Session), {form, Wrong}),
    %% someone else's token is not this session's
    #{csrf := Theirs} = login(Config, <<"dave">>),
    Stolen = uri_string:compose_query([{"csrf", Theirs}, {"body", "their token"}]),
    {403, _, _} = request(Config, post, "/board/b/new", cookies(Session), {form, Stolen}),
    {403, _, _} = request(Config, post, "/logout", cookies(Session), {form, Without}),
    Before = posts(Config),
    {303, _, _} = post(Config, "/board/b/new", Session, <<"still logged in">>).

bad_text_is_refused(Config) ->
    Session = login(Config, <<"erin">>),
    Before = posts(Config),
    {400, _, _} = post(Config, "/board/b/new", Session, <<>>),
    {400, _, _} = post(Config, "/board/b/new", Session, <<"   \n ">>),
    {400, _, _} = post(Config, "/board/b/new", Session, <<"a bell: ", 7>>),
    {400, _, _} = post(Config, "/board/b/new", Session, <<"not utf-8: ", 255, 254>>),
    {400, _, _} = post(Config, "/board/b/new", Session, binary:copy(<<"x">>, 16385)),
    Before = posts(Config).

%% hazard a1 for M0: nothing that could carry a file is read
only_forms_are_read(Config) ->
    #{csrf := Csrf} = Session = login(Config, <<"frank">>),
    Before = posts(Config),
    Boundary = "----ike",
    Multipart = [
        "--",
        Boundary,
        "\r\ncontent-disposition: form-data; name=\"csrf\"\r\n\r\n",
        Csrf,
        "\r\n--",
        Boundary,
        "\r\ncontent-disposition: form-data; name=\"body\"\r\n\r\ntext",
        "\r\n--",
        Boundary,
        "\r\ncontent-disposition: form-data; name=\"file\"; filename=\"a.png\"\r\n",
        "content-type: image/png\r\n\r\n",
        <<137, "PNG">>,
        "\r\n--",
        Boundary,
        "--\r\n"
    ],
    Type = "multipart/form-data; boundary=" ++ Boundary,
    {415, _, _} = request(
        Config, post, "/board/b/new", cookies(Session), {Type, iolist_to_binary(Multipart)}
    ),
    Json = json:encode(#{csrf => list_to_binary(Csrf), body => <<"text">>}),
    {415, _, _} = request(
        Config, post, "/board/b/new", cookies(Session), {"application/json", iolist_to_binary(Json)}
    ),
    Before = posts(Config).

reply_to_nothing(Config) ->
    Session = login(Config, <<"grace">>),
    {404, _, _} = request(Config, get, "/board/b/999999/reply", cookies(Session), none),
    {404, _, _} = post(Config, "/board/b/999999/reply", Session, <<"into the void">>),
    [[0]] = query(Config, "SELECT count(*) FROM post WHERE thread = 999999", []).

callback_needs_the_state(Config) ->
    #{binding := Binding} = begin_login(Config),
    Cookie = [{"cookie", "__Host-ike-login=" ++ Binding}],
    {400, H1, _} = request(Config, get, "/login/callback?code=c", Cookie, none),
    none = set_cookie("__Host-ike", H1),
    {400, H2, _} = request(Config, get, "/login/callback?code=c&state=made-up", Cookie, none),
    none = set_cookie("__Host-ike", H2).

%% the code and state alone are not enough: whoever started the login has
%% to be the one who finishes it
callback_needs_the_browser(Config) ->
    Token = fun(Nonce) -> id_token(Config, Nonce, <<"mallory">>, #{}) end,
    #{state := State} = Login = begin_login(Config),
    ok = expect(Login, "code-1", Token),
    Path = "/login/callback?" ++ uri_string:compose_query([{"code", "code-1"}, {"state", State}]),
    {400, H1, _} = request(Config, get, Path, [], none),
    none = set_cookie("__Host-ike", H1),
    #{state := State2} = Login2 = begin_login(Config),
    ok = expect(Login2, "code-2", Token),
    Path2 = "/login/callback?" ++ uri_string:compose_query([{"code", "code-2"}, {"state", State2}]),
    Wrong = [{"cookie", "__Host-ike-login=" ++ lists:reverse(maps:get(binding, Login2))}],
    {400, H2, _} = request(Config, get, Path2, Wrong, none),
    none = set_cookie("__Host-ike", H2).

state_works_once(Config) ->
    Token = fun(Nonce) -> id_token(Config, Nonce, <<"heidi">>, #{}) end,
    Login = begin_login(Config),
    ok = expect(Login, "code-once", Token),
    {303, H1, _} = callback(Config, Login, "code-once"),
    true = set_cookie("__Host-ike", H1) =/= none,
    {400, H2, _} = callback(Config, Login, "code-once"),
    none = set_cookie("__Host-ike", H2).

%% hazard i1: every way an id token can be wrong
token_must_verify(Config) ->
    Key = ?config(key, Config),
    Other = ?config(other_key, Config),
    #'RSAPrivateKey'{publicExponent = E, modulus = N} = Key,
    Public = public_key:pem_encode([
        public_key:pem_entry_encode('RSAPublicKey', #'RSAPublicKey'{
            modulus = N, publicExponent = E
        })
    ]),
    Now = erlang:system_time(second),
    Rs256 = fun(K) -> fun(Input) -> public_key:sign(Input, sha256, K) end end,
    Good = fun(Nonce) -> claims(Config, Nonce, <<"ivan">>) end,
    Wrong = [
        {another_issuer, <<"RS256">>, Rs256(Key), fun(C) -> C#{iss => <<"http://127.0.0.1:1">>} end},
        {another_audience, <<"RS256">>, Rs256(Key), fun(C) -> C#{aud => <<"someone-else">>} end},
        {audience_among_others_without_azp, <<"RS256">>, Rs256(Key), fun(C) ->
            C#{aud => [<<"someone-else">>, ?CLIENT]}
        end},
        {another_nonce, <<"RS256">>, Rs256(Key), fun(C) -> C#{nonce => <<"not-the-nonce">>} end},
        {no_nonce, <<"RS256">>, Rs256(Key), fun(C) -> maps:remove(nonce, C) end},
        {expired, <<"RS256">>, Rs256(Key), fun(C) -> C#{exp => Now - 3600} end},
        {from_the_future, <<"RS256">>, Rs256(Key), fun(C) -> C#{iat => Now + 3600} end},
        {no_subject, <<"RS256">>, Rs256(Key), fun(C) -> maps:remove(sub, C) end},
        {empty_subject, <<"RS256">>, Rs256(Key), fun(C) -> C#{sub => <<>>} end},
        {another_key, <<"RS256">>, Rs256(Other), fun(C) -> C end},
        {unsigned, <<"none">>, fun(_) -> <<>> end, fun(C) -> C end},
        %% the classic: an hmac keyed with the public key
        {hmac_with_the_public_key, <<"HS256">>,
            fun(Input) -> crypto:mac(hmac, sha256, Public, Input) end, fun(C) -> C end},
        {signature_of_something_else, <<"RS256">>,
            fun(_) -> public_key:sign(<<"something else">>, sha256, Key) end, fun(C) -> C end}
    ],
    Actors = query(Config, "SELECT count(*) FROM actor", []),
    lists:foreach(
        fun({Name, Alg, Sign, Change}) ->
            Login = begin_login(Config),
            Code = atom_to_list(Name),
            ok = expect(Login, Code, fun(Nonce) ->
                ike_mock_idp:token(Alg, Change(Good(Nonce)), Sign)
            end),
            {Status, Headers, _} = callback(Config, Login, Code),
            {Name, 400, none} = {Name, Status, set_cookie("__Host-ike", Headers)}
        end,
        Wrong
    ),
    Actors = query(Config, "SELECT count(*) FROM actor", []),
    %% and the same machinery lets a right one through
    Login = begin_login(Config),
    ok = expect(Login, "good", fun(Nonce) ->
        ike_mock_idp:token(<<"RS256">>, Good(Nonce), Rs256(Key))
    end),
    {303, Headers, _} = callback(Config, Login, "good"),
    true = set_cookie("__Host-ike", Headers) =/= none.

code_must_be_the_issued_one(Config) ->
    Login = begin_login(Config),
    ok = expect(Login, "issued", fun(Nonce) -> id_token(Config, Nonce, <<"judy">>, #{}) end),
    {400, Headers, _} = callback(Config, Login, "guessed"),
    none = set_cookie("__Host-ike", Headers).

logout(Config) ->
    #{csrf := Csrf} = Session = login(Config, <<"karl">>),
    {303, _, _} = post(Config, "/board/b/new", Session, <<"before logging out">>),
    Form = uri_string:compose_query([{"csrf", Csrf}]),
    {303, Headers, _} = request(Config, post, "/logout", cookies(Session), {form, Form}),
    "/" = proplists:get_value("location", Headers),
    "" = set_cookie("__Host-ike", Headers),
    {403, _, _} = post(Config, "/board/b/new", Session, <<"after logging out">>).

sessions_outlive_a_restart(Config) ->
    Stays = login(Config, <<"mona">>),
    #{csrf := Csrf} = Leaves = login(Config, <<"nils">>),
    Form = uri_string:compose_query([{"csrf", Csrf}]),
    {303, _, _} = request(Config, post, "/logout", cookies(Leaves), {form, Form}),
    ok = ike_browser:restart(),
    %% the same cookie and the same form token as before
    {303, _, _} = post(Config, "/board/b/new", Stays, <<"after the restart">>),
    %% and a restart undoes no logout
    {403, _, _} = post(Config, "/board/b/new", Leaves, <<"after logging out">>),
    %% what the database holds of a session is not what the cookie holds
    #{id := Id} = Stays,
    Rows = query(Config, "SELECT hash, csrf FROM session", []),
    true = length(Rows) >= 1,
    [] = [R || R <- Rows, binary:match(iolist_to_binary(R), list_to_binary(Id)) =/= nomatch],
    [[1]] = query(
        Config, "SELECT count(*) FROM session WHERE hash = ?", [
            {blob, crypto:hash(sha256, Id)}
        ]
    ).

same_subject_same_actor(Config) ->
    S1 = login(Config, <<"lena">>),
    S2 = login(Config, <<"lena">>),
    {303, H1, _} = sign(Config, "/board/b/new", S1, <<"first session">>),
    {303, H2, _} = sign(Config, "/board/b/new", S2, <<"second session">>),
    {N1, _} = string:to_integer(proplists:get_value("location", H1) -- "/board/b/"),
    {N2, _} = string:to_integer(proplists:get_value("location", H2) -- "/board/b/"),
    [[1]] = query(
        Config, "SELECT count(DISTINCT actor) FROM post WHERE id IN (?, ?)", [N1, N2]
    ),
    [[1]] = query(Config, "SELECT count(*) FROM actor WHERE subject = 'lena'", []),
    %% an account is its issuer, its subject and what it is called, and
    %% whether it is suspended and its rank at its last login; that is
    %% all there is of it
    [[<<"id,kind,issuer,subject,name,banned,rank">>]] = query(
        Config, "SELECT group_concat(name) FROM pragma_table_info('actor')", []
    ),
    [] = query(
        Config,
        "SELECT id FROM actor WHERE name LIKE '%example.org%' OR name LIKE '%Person%'",
        []
    ).

thread(Headers) ->
    {N, _} = string:to_integer(proplists:get_value("location", Headers) -- "/board/b/"),
    N.

%% a post carries its account's name only when the box is ticked. left
%% alone, it is nobody's: not on the page and not in the row
a_name_is_asked_for(Config) ->
    Session = login(Config, <<"carol">>),
    {200, _, Form} = request(Config, get, "/board/b/new", cookies(Session), none),
    {_, _} = binary:match(Form, <<"post as carol">>),
    {_, _} = binary:match(Form, <<"name=\"signed\"">>),
    nomatch = binary:match(Form, <<"checked">>),
    {303, H1, _} = post(Config, "/board/b/new", Session, <<"said by nobody">>),
    N = thread(H1),
    {303, H2, _} = sign(
        Config, "/board/b/" ++ integer_to_list(N) ++ "/reply", Session, <<"said by carol">>
    ),
    {_, "#p" ++ P} = string:to_integer(proplists:get_value("location", H2) -- "/board/b/"),
    [[<<"anonymous">>, undefined]] = query(
        Config,
        "SELECT a.kind, a.subject FROM post p JOIN actor a ON a.id = p.actor WHERE p.id = ?",
        [N]
    ),
    [[<<"local">>, <<"carol">>]] = query(
        Config,
        "SELECT a.kind, a.subject FROM post p JOIN actor a ON a.id = p.actor WHERE p.id = ?",
        [list_to_integer(P)]
    ),
    {ok, Page} = file:read_file(page_file(Config, N)),
    [_, First, Second] = binary:split(Page, <<"<article">>, [global]),
    {_, _} = binary:match(First, <<"<span class=\"name\">anon</span>">>),
    nomatch = binary:match(First, <<"carol">>),
    {_, _} = binary:match(Second, <<"<span class=\"name account\">carol</span>">>).

%% a provider that gives no name: nothing to tick, and ticking it anyway
%% signs nothing
no_name_no_asking(Config) ->
    Session = login(Config, <<"dora">>, #{preferred_username => null}),
    {200, _, Form} = request(Config, get, "/board/b/new", cookies(Session), none),
    nomatch = binary:match(Form, <<"signed">>),
    {303, Headers, _} = sign(Config, "/board/b/new", Session, <<"ticked all the same">>),
    N = thread(Headers),
    [[1]] = query(Config, "SELECT actor FROM post WHERE id = ?", [N]),
    [[undefined]] = query(Config, "SELECT name FROM actor WHERE subject = 'dora'", []).

%% a name that could not stand in a path, or that is markup, or too long,
%% is no name; the login itself still works
only_plain_names(Config) ->
    Bad = [
        <<"<script>alert(1)</script>">>,
        <<"a/b">>,
        <<"..">>,
        <<".">>,
        <<"dot.">>,
        <<"two words">>,
        <<"caf", 16#C3, 16#A9>>,
        <<>>,
        binary:copy(<<"x">>, 33),
        17
    ],
    lists:foreach(
        fun({I, Nick}) ->
            Subject = <<"erin", (integer_to_binary(I))/binary>>,
            Session = login(Config, Subject, #{preferred_username => Nick}),
            {200, _, Form} = request(Config, get, "/board/b/new", cookies(Session), none),
            nomatch = binary:match(Form, <<"signed">>),
            [[undefined]] = query(Config, "SELECT name FROM actor WHERE subject = ?", [Subject])
        end,
        lists:enumerate(Bad)
    ),
    Session = login(Config, <<"erin">>, #{preferred_username => <<"Erin_M.-2">>}),
    {200, _, Form} = request(Config, get, "/board/b/new", cookies(Session), none),
    {_, _} = binary:match(Form, <<"post as Erin_M.-2">>).

%% the provider renames an account: the pages that showed the old name
%% show the new one, since a name belongs to the account and not the post
a_new_name_is_on_old_posts(Config) ->
    Session = login(Config, <<"fay">>),
    {303, Headers, _} = sign(Config, "/board/b/new", Session, <<"signed before the change">>),
    N = thread(Headers),
    {ok, Before} = file:read_file(page_file(Config, N)),
    {_, _} = binary:match(Before, <<"\">fay</span>">>),
    _ = login(Config, <<"fay">>, #{preferred_username => <<"faye">>}),
    ok = until(fun() ->
        {ok, After} = file:read_file(page_file(Config, N)),
        binary:match(After, <<"\">faye</span>">>) =/= nomatch
    end),
    %% and losing the name altogether leaves the post nobody's to read
    _ = login(Config, <<"fay">>, #{preferred_username => null}),
    ok = until(fun() ->
        {ok, After} = file:read_file(page_file(Config, N)),
        binary:match(After, <<"faye">>) =:= nomatch
    end).

%% the names for nobody are the server's to choose. with several, a post
%% takes one by its number and keeps it
nobody_has_many_names(Config) ->
    Session = login(Config, <<"gus">>),
    ok = application:set_env(ike, anonymous_names, [<<"nemo">>, <<"outis">>]),
    try
        {303, H1, _} = post(Config, "/board/b/new", Session, <<"one of two">>),
        N = thread(H1),
        Reply = "/board/b/" ++ integer_to_list(N) ++ "/reply",
        {303, _, _} = post(Config, Reply, Session, <<"two of two">>),
        {ok, Page} = file:read_file(page_file(Config, N)),
        [_, First, Second] = binary:split(Page, <<"<article">>, [global]),
        Names = [<<"<span class=\"name\">nemo</span>">>, <<"<span class=\"name\">outis</span>">>],
        [A] = [X || X <- Names, binary:match(First, X) =/= nomatch],
        [B] = [X || X <- Names, binary:match(Second, X) =/= nomatch],
        true = A =/= B,
        {303, _, _} = post(Config, Reply, Session, <<"three, and the page is made again">>),
        {ok, Again} = file:read_file(page_file(Config, N)),
        [_, First, Second2, _] = binary:split(Again, <<"<article">>, [global]),
        {_, _} = binary:match(Second2, B),
        nomatch = binary:match(Again, <<"gus">>)
    after
        ok = application:unset_env(ike, anonymous_names)
    end.

until(Fun) ->
    until(Fun, 100).

until(_Fun, 0) ->
    timeout;
until(Fun, Tries) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            until(Fun, Tries - 1)
    end.
