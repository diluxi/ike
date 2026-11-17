%% The eleven invariants of hazards.md, one case each, in their order.
%% Black-box: HTTP, the files ike writes, the database as a file, what it
%% logs, and the compiled modules read as data (xref); never a call into
%% ike.
%%
%% Some invariants speak of things ike does not have yet: a decoder in
%% use, a fetcher, staged uploads. Their cases here are
%% tripwires. They assert that the thing is still absent, and fail the
%% moment it arrives, so that whoever adds it has to replace the tripwire
%% with the real test in the same change. A tripwire proves nothing about
%% the thing itself.
-module(ike_invariant_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("proper/include/proper.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    inv01_no_address_is_written/1,
    inv02_works_without_scripts/1,
    inv03_one_writer/1,
    inv04_text_is_escaped/1,
    inv05_no_user_bytes_on_the_main_origin/1,
    inv06_no_decoder_in_the_vm/1,
    inv07_tripwire_no_fetcher/1,
    inv08_purge_leaves_nothing/1,
    inv09_reachability_view_is_complete/1,
    inv10_private_metas_are_their_owners_and_moderators/1,
    inv11_stripping_is_complete_and_deterministic/1
]).

all() ->
    [
        inv01_no_address_is_written,
        inv02_works_without_scripts,
        inv03_one_writer,
        inv04_text_is_escaped,
        inv05_no_user_bytes_on_the_main_origin,
        inv06_no_decoder_in_the_vm,
        inv07_tripwire_no_fetcher,
        inv08_purge_leaves_nothing,
        inv09_reachability_view_is_complete,
        inv10_private_metas_are_their_owners_and_moderators,
        inv11_stripping_is_complete_and_deterministic
    ].

-define(LOG, ike_invariant_log).
%% addresses nobody has (rfc 5737, rfc 3849), claimed in forwarding headers
-define(V4, "203.0.113.77").
-define(V6, "2001:db8::77").
%% posts an address is let, for the limiter to count to and past
-define(POSTS, 60).
%% seconds a link to a staged upload works
-define(STAGED, 2).

init_per_suite(Config0) ->
    %% everything logged from here on, by anything, lands in a file
    Log = filename:join(?config(priv_dir, Config0), "everything.log"),
    ok = logger:add_handler(?LOG, logger_std_h, #{
        level => all, config => #{file => Log}, filters => []
    }),
    Level = maps:get(level, logger:get_primary_config()),
    ok = logger:set_primary_config(level, all),
    %% the limiter is the one thing that looks at an address, so here it
    %% is made to: the loopback is its proxy, and the headers are believed
    Limit = #{posts => ?POSTS, seconds => 3600, proxies => [{127, 0, 0, 1}]},
    Config = ike_browser:start(Config0, [
        {backup_seconds, 1}, {limit, Limit}, {staged_seconds, ?STAGED}
    ]),
    [{log, Log}, {level, Level}, {calls, calls()} | Config].

end_per_suite(Config) ->
    ike_browser:stop(),
    ok = logger:set_primary_config(level, ?config(level, Config)),
    logger:remove_handler(?LOG).

%% 1. No IP address, nor anything derived from one, is ever written to
%% disk or logs.
inv01_no_address_is_written(Config) ->
    Forwarded = [
        {"x-forwarded-for", ?V4 ++ ", " ++ ?V6},
        {"forwarded", "for=" ++ ?V4 ++ ";proto=https, for=\"[" ++ ?V6 ++ "]\""},
        {"x-real-ip", ?V4},
        {"x-client-ip", ?V6}
    ],
    %% every kind of request there is, each claiming to come from there:
    %% pages, misses, a whole login, posts, refusals, a logout
    Session = ike_browser:login(Config, <<"addr">>),
    With = fun(Headers) -> Headers ++ Forwarded end,
    Cookies = ike_browser:cookies(Session),
    Form = fun(Fields) -> {form, uri_string:compose_query(Fields)} end,
    Csrf = maps:get(csrf, Session),
    {303, Headers, _} = ike_browser:request(
        Config,
        post,
        "/board/b/new",
        With(Cookies),
        Form([{"csrf", Csrf}, {"body", "from nowhere"}])
    ),
    Thread = hd(string:split(proplists:get_value("location", Headers), "#")),
    Requests = [
        {get, "/", [], none},
        {get, Thread, [], none},
        {get, "/health", [], none},
        {get, "/nothing/here", [], none},
        {get, "/board/b/new", Cookies, none},
        {get, "/login", [], none},
        {get, "/login/callback?state=x&code=y", [], none},
        {post, Thread ++ "/reply", Cookies, Form([{"csrf", Csrf}, {"body", "a reply"}])},
        {post, "/board/b/new", Cookies, Form([{"csrf", "wrong"}, {"body", "refused"}])},
        {post, "/board/b/new", [], Form([{"body", "refused"}])},
        {post, "/board/b/new", Cookies, {"multipart/form-data; boundary=x", <<"--x--\r\n">>}},
        {post, "/board/b/new", Cookies, {"application/x-www-form-urlencoded", <<"%zz=%">>}},
        {put, "/", [], {"text/plain", <<"x">>}},
        {delete, Thread, [], none},
        {post, "/logout", Cookies, Form([{"csrf", Csrf}])}
    ],
    lists:foreach(
        fun({Method, Path, Extra, Body}) ->
            {Status, _, _} = ike_browser:request(Config, Method, Path, With(Extra), Body),
            true = Status < 500
        end,
        Requests
    ),
    %% nobody posts too, from an address the limiter counts
    ok = ike_browser:unlock(Config, <<"meta">>),
    {303, _, _} = ike_browser:anonymous(Config, "/board/meta/new", Forwarded, <<"from nobody">>),
    %% and from another until it is turned away, and then some
    Flood = [{"x-forwarded-for", ?V6 ++ ", " ++ ?V4}, {"x-real-ip", ?V4}],
    Statuses = [
        element(1, ike_browser:request(Config, post, "/board/b/new", Flood, Form([{"body", "x"}])))
     || _ <- lists:seq(1, ?POSTS + 5)
    ],
    {Let, Turned} = lists:split(?POSTS, Statuses),
    [403] = lists:usort(Let),
    [429] = lists:usort(Turned),
    %% a snapshot exists by now, so backups are among what is searched
    [_ | _] = wait_for(fun() -> files(filename:join(?config(dir, Config), "backups")) end, 20),

    %% the log sink works, or finding nothing in it would mean nothing
    logger:error("canary ~s", ["8a51c2"]),
    ok = logger_std_h:filesync(?LOG),
    {ok, Logged} = file:read_file(?config(log, Config)),
    {_, _} = binary:match(Logged, <<"canary 8a51c2">>),

    %% the claimed addresses, the loopback the requests really came from
    %% (in every way erlang prints one), and the names such fields go by
    Needles = [
        <<?V4>>,
        <<?V6>>,
        <<"203,0,113,77">>,
        <<"{127,0,0,1}">>,
        <<"127.0.0.1:">>,
        <<"::1">>,
        <<"x-forwarded-for">>,
        <<"x-real-ip">>,
        <<"peer">>,
        <<"remote_ip">>
    ],
    [{nomatch, _, _} = {binary:match(Logged, Needle), Needle, in_the_log} || Needle <- Needles],
    %% disk: every file ike has written, and every text the database holds
    lists:foreach(
        fun(File) ->
            {ok, Bytes} = file:read_file(File),
            [{nomatch, _, _} = {binary:match(Bytes, N), N, File} || N <- [<<?V4>>, <<?V6>>]]
        end,
        files(?config(dir, Config))
    ),
    %% structurally: the first thing every request passes forgets its peer
    #{stream_handlers := [ike_http_anon | _]} = ranch:get_protocol_options(ike_http),
    %% and nothing in ike asks a connection where it came from
    Asks = [
        {From, To}
     || {From, {M, F, _} = To} <- ?config(calls, Config),
        lists:member({M, F}, [
            {cowboy_req, peer},
            {cowboy_req, sock},
            {cowboy_req, cert},
            {inet, peername},
            {inet, peernames},
            {ssl, peername},
            {ranch, remove_connection}
        ])
    ],
    [] = Asks,
    %% the limiter is asked at the door, before the forgetting, and by
    %% nothing behind it that could hand it an address
    [ike_http_anon] = lists:usort([
        Mod
     || {{Mod, _, _}, {ike_limit, charge, _}} <- ?config(calls, Config)
    ]).

%% 2. Every page and action works with JS disabled; islands only enhance
%% pages that already work.
inv02_works_without_scripts(Config) ->
    %% a browser that runs nothing: it reads the forms out of the html it
    %% is given and submits exactly those. log in, start a thread, reply
    Session = ike_browser:login(Config, <<"noscript">>),
    Cookies = ike_browser:cookies(Session),
    %% from the front page to the board by links alone
    {200, _, Front} = ike_browser:request(Config, get, "/", [], none),
    {_, _} = binary:match(Front, <<"href=\"/board\"">>),
    {200, _, Boards} = ike_browser:request(Config, get, "/board", [], none),
    {_, _} = binary:match(Boards, <<"href=\"/board/b\"">>),
    {200, _, Index} = ike_browser:request(Config, get, "/board/b", [], none),
    {_, _} = binary:match(Index, <<"href=\"/board/b/new\"">>),
    {200, _, New} = ike_browser:request(Config, get, "/board/b/new", Cookies, none),
    {303, H1, _} = submit(Config, Cookies, New, "/board/b/new", "a thread, by form alone"),
    Thread = hd(string:split(proplists:get_value("location", H1), "#")),
    {200, _, Page} = ike_browser:request(Config, get, Thread, [], none),
    Reply = Thread ++ "/reply",
    {_, _} = binary:match(Page, list_to_binary("href=\"" ++ Reply ++ "\"")),
    {200, _, ReplyForm} = ike_browser:request(Config, get, Reply, Cookies, none),
    {303, H2, _} = submit(Config, Cookies, ReplyForm, Reply, "a reply, by form alone"),
    {200, _, Page2} = ike_browser:request(
        Config, get, hd(string:split(proplists:get_value("location", H2), "#")), [], none
    ),
    {_, _} = binary:match(Page2, <<"a reply, by form alone">>),
    %% moderation is forms too: look a post up by number, hide it with a
    %% reason, and bring it back, from the fields the pages give
    Admin = ike_browser:cookies(
        ike_browser:login(Config, <<"noscript-admin">>, #{groups => [<<"ike-admin">>]})
    ),
    "#p" ++ ReplyNumber = string:find(proplists:get_value("location", H2), "#"),
    {200, _, Mod} = ike_browser:request(Config, get, "/mod", Admin, none),
    {_, _} = binary:match(Mod, <<"<form method=\"get\" action=\"/mod\">">>),
    ModPost = "/mod/post/" ++ ReplyNumber,
    {303, Found, _} = ike_browser:request(Config, get, "/mod?post=" ++ ReplyNumber, Admin, none),
    ModPost = proplists:get_value("location", Found),
    {200, _, Held} = ike_browser:request(Config, get, ModPost, Admin, none),
    {303, _, _} = act(Config, Admin, Held, ModPost, <<"hide">>, "by form alone"),
    {200, _, Hidden} = ike_browser:request(Config, get, Thread, [], none),
    nomatch = binary:match(Hidden, <<"a reply, by form alone">>),
    {200, _, Held2} = ike_browser:request(Config, get, ModPost, Admin, none),
    {303, _, _} = act(Config, Admin, Held2, ModPost, <<"unhide">>, "and back"),
    {200, _, Back} = ike_browser:request(Config, get, Thread, [], none),
    {_, _} = binary:match(Back, <<"a reply, by form alone">>),
    [scriptless(H) || H <- [Mod, Held, Held2]],
    %% an upload is a plain form too: its fields, and a file
    {200, _, UploadPage} = ike_browser:request(Config, get, "/upload", Cookies, none),
    {match, [UploadForm]} = re:run(
        UploadPage,
        "<form method=\"post\" action=\"/upload\" enctype=\"multipart/form-data\">(.*?)</form>",
        [dotall, {capture, all_but_first, binary}]
    ),
    {match, UploadHidden} = re:run(
        UploadForm,
        "<input type=\"hidden\" name=\"([^\"]+)\" value=\"([^\"]*)\"",
        [global, {capture, all_but_first, binary}]
    ),
    {match, [FileField]} = re:run(
        UploadForm, "<input type=\"file\" name=\"([^\"]+)\"", [{capture, all_but_first, binary}]
    ),
    {Multipart, UploadBody} = ike_browser:multipart(
        [{field, N, V} || [N, V] <- UploadHidden] ++
            [{file, FileField, {<<"x.png">>, read(?config(data_dir, Config), "base.png")}}]
    ),
    {303, _, _} = ike_browser:request(Config, post, "/upload", Cookies, {Multipart, UploadBody}),
    {200, _, Staged} = ike_browser:request(Config, get, "/upload", Cookies, none),
    {_, _} = binary:match(Staged, <<"<img src=\"http://media.test/staged/">>),
    scriptless(Staged),
    %% and posting it: the reply form offers it as a checkbox
    {200, _, WithUpload} = ike_browser:request(Config, get, Reply, Cookies, none),
    {match, [Picked]} = re:run(
        WithUpload,
        "<input type=\"checkbox\" id=\"u[0-9]+\" name=\"upload\" value=\"([0-9]+)\">",
        [{capture, all_but_first, binary}]
    ),
    {match, PostHidden} = re:run(
        WithUpload,
        "<input type=\"hidden\" name=\"([^\"]+)\" value=\"([^\"]*)\"",
        [global, {capture, all_but_first, binary}]
    ),
    PostFields = [{N, V} || [N, V] <- PostHidden] ++ [{<<"body">>, <<>>}, {<<"upload">>, Picked}],
    {303, _, _} = ike_browser:request(
        Config, post, Reply, Cookies, {form, uri_string:compose_query(PostFields)}
    ),
    {200, _, Pictured} = ike_browser:request(Config, get, Thread, [], none),
    {match, [Shown]} = re:run(
        Pictured,
        "<img src=\"(http://media\\.test/[0-9a-f]{64}\\.thumb\\.webp)\"",
        [{capture, all_but_first, list}]
    ),
    scriptless(Pictured),
    {200, _, _} = ike_browser:media(Config, Shown),
    %% a post is retracted from the thread's own form: ticked, and its
    %% password
    {303, H3, _} = ike_browser:post(
        Config, Reply, Session, <<"to be taken back">>, [{<<"password">>, <<"pw">>}]
    ),
    "#p" ++ Taken = string:find(proplists:get_value("location", H3), "#"),
    {200, _, WithBack} = ike_browser:request(Config, get, Thread, [], none),
    match = re:run(WithBack, "<form method=\"post\" action=\"/act\">", [{capture, none}]),
    match = re:run(
        WithBack,
        "<input type=\"checkbox\" name=\"post\" value=\"" ++ Taken ++ "\">",
        [{capture, none}]
    ),
    match = re:run(
        WithBack,
        "<button type=\"submit\" name=\"kind\" value=\"retract\">",
        [{capture, none}]
    ),
    {200, _, Done} = ike_browser:request(
        Config,
        post,
        "/act",
        [{"origin", ?config(base, Config)}],
        {form,
            uri_string:compose_query([
                {"post", Taken}, {"password", "pw"}, {"kind", "retract"}, {"back", Thread}
            ])}
    ),
    {_, _} = binary:match(Done, list_to_binary("&gt;&gt;" ++ Taken ++ ": retracted")),
    {200, _, Without} = ike_browser:request(Config, get, Thread, [], none),
    nomatch = binary:match(Without, <<"to be taken back">>),
    %% and every page leads to the account page, which logs out by form
    {_, _} = binary:match(Page, <<"href=\"/account\"">>),
    Leaving = ike_browser:login(Config, <<"noscript-leaving">>),
    {200, _, Account} = ike_browser:request(
        Config, get, "/account", ike_browser:cookies(Leaving), none
    ),
    {match, [Out]} = re:run(
        Account,
        "<form method=\"post\" action=\"/logout\"><input type=\"hidden\" name=\"csrf\" value=\"([^\"]+)\">",
        [{capture, all_but_first, binary}]
    ),
    {303, _, _} = ike_browser:request(
        Config,
        post,
        "/logout",
        ike_browser:cookies(Leaving),
        {form, uri_string:compose_query([{<<"csrf">>, Out}])}
    ),
    {200, _, Gone} = ike_browser:request(
        Config, get, "/account", ike_browser:cookies(Leaving), none
    ),
    {_, _} = binary:match(Gone, <<"not logged in">>),
    %% logged out, the same pages say how to log in, with a link
    {200, _, Anonymous} = ike_browser:request(Config, get, "/board/b/new", [], none),
    {_, _} = binary:match(Anonymous, <<"href=\"/login\"">>),

    %% no page carries a script, an event handler or a script url, and
    %% every response forbids them outright
    Pages = [
        {get, "/", []},
        {get, "/board", []},
        {get, "/board/b", []},
        {get, Thread, []},
        {get, "/board/b/new", []},
        {get, "/board/b/new", Cookies},
        {get, Reply, Cookies},
        {get, "/upload", Cookies},
        {get, "/upload", []},
        {get, "/account", Cookies},
        {get, "/account", []},
        {get, "/booru", []},
        {get, "/booru/1", []},
        {get, "/booru/search?tags=a+-b+c*", []},
        {get, "/wiki", []},
        {get, "/wiki/nothing_yet", []},
        {get, "/wiki/nothing_yet/edit", Cookies},
        {get, "/nothing/here", []},
        {get, "/login/callback", []},
        {post, "/board/b/new", []}
    ],
    lists:foreach(
        fun({Method, Path, Extra}) ->
            Body =
                case Method of
                    post -> {form, "body=x"};
                    get -> none
                end,
            {_, Headers, Html} = ike_browser:request(Config, Method, Path, Extra, Body),
            scriptless(Html),
            "default-src 'none'" ++ _ = proplists:get_value("content-security-policy", Headers)
        end,
        Pages
    ),
    %% and ike ships nothing a browser could run, but its own keys for
    %% the text box (lux), which every page above works without
    Shipped = [
        F
     || F <- files(code:priv_dir(ike)) ++ files(filename:join(?config(dir, Config), "pages")),
        filename:basename(F) =/= "ike.js"
    ],
    [] = [
        F
     || F <- Shipped,
        lists:member(filename:extension(F), [".js", ".mjs", ".wasm", ".map", ".ts"])
    ].

%% 3. Every write, deletion and file unlink goes through the single
%% writer.
%%
%% Read off the compiled modules: which of them can change the database,
%% and which call anything that changes a file. Both lists are exact, so a
%% new place that writes fails here until it is put on the list, which is
%% the moment to ask whether it should not be a message to the writer.
inv03_one_writer(Config) ->
    Calls = ?config(calls, Config),
    Callers = fun(Pred) ->
        lists:usort([{Mod, {M, F}} || {{Mod, _, _}, {M, F, _}} <- Calls, Pred(Mod, M, F)])
    end,
    %% sqlite itself is spoken to by one module
    [ike_db] = lists:usort([Mod || {Mod, _} <- Callers(fun(_, M, _) -> M =:= esqlite3 end)]),
    %% a writable connection is opened in one place, by the writer
    [{ike_writer, {ike_db, open_writer}}] =
        Callers(fun(_, M, F) -> {M, F} =:= {ike_db, open_writer} end),
    %% what needs one is the writer, and the migrations it runs before it
    %% answers anybody
    Writing = [exec, transaction, snapshot],
    [ike_migrate, ike_writer] = lists:usort([
        Mod
     || {Mod, _} <- Callers(fun(Mod, M, F) ->
            Mod =/= ike_db andalso M =:= ike_db andalso lists:member(F, Writing)
        end)
    ]),
    [{ike_writer, {ike_migrate, run}}] =
        Callers(fun(Mod, M, _) -> M =:= ike_migrate andalso Mod =/= ike_migrate end),
    %% files. the writer makes its directories, moves a snapshot into
    %% place and unlinks old ones, unlinks the page of a thread that was
    %% taken down, and writes an asset's files under a temporary name
    %% and renames them into place. the renderer writes pages, which are derived from
    %% the database and replaced whole by rename; it unlinks nothing (see
    %% decisions.md on reading the invariant this way)
    Changing = [
        change_group,
        change_mode,
        change_owner,
        change_time,
        copy,
        del_dir,
        del_dir_r,
        delete,
        make_dir,
        make_link,
        make_symlink,
        open,
        pwrite,
        rename,
        truncate,
        write,
        write_file,
        write_file_info,
        ensure_dir,
        ensure_path
    ],
    [
        {ike_render, {file, rename}},
        {ike_render, {file, write_file}},
        {ike_render, {filelib, ensure_path}},
        {ike_writer, {file, copy}},
        {ike_writer, {file, delete}},
        {ike_writer, {file, rename}},
        {ike_writer, {file, write_file}},
        {ike_writer, {filelib, ensure_path}}
    ] = Callers(fun(_, M, F) ->
        (M =:= file orelse M =:= filelib) andalso lists:member(F, Changing)
    end),
    %% no other store, and no way around the above: nothing shells out,
    %% and no call's target is computed
    [] = Callers(fun(_, M, F) ->
        lists:member(M, [dets, disk_log, mnesia, prim_file, raw_file_io, ram_file]) orelse
            lists:member({M, F}, [{os, cmd}, {erlang, open_port}, {erlang, apply}])
    end),
    %% (but for the fun a transaction is handed, which is the point of it)
    [{{ike_db, transaction, 2}, {'$M_EXPR', '$F_EXPR', 0}}] =
        [Edge || {_, {M, F, _}} = Edge <- Calls, M =:= '$M_EXPR' orelse F =:= '$F_EXPR'],
    %% and from outside: the database is one file with its wal beside it,
    %% in a directory nothing else of ike's is written to
    Top = lists:sort(element(2, file:list_dir(?config(dir, Config)))),
    [] = Top -- ["assets", "backups", "ike.db", "ike.db-shm", "ike.db-wal", "media", "pages"].

%% 4. Every text node is escaped by construction, in static and
%% per-request renderers alike.
inv04_text_is_escaped(Config) ->
    Session = ike_browser:login(Config, <<"hostile">>),
    Prop = ?FORALL(
        Text,
        hostile(),
        begin
            %% the same shape, harmless: what the page should be built like
            Benign = <<<<(benign(C))>> || <<C/utf8>> <= Text>>,
            {HostilePage, HostileIndex} = posted(Config, Session, Text),
            {BenignPage, _} = posted(Config, Session, Benign),
            %% whatever the text was, the page has the tags of the harmless
            %% one, in the same order, and no others
            Same = tags(HostilePage) =:= tags(BenignPage),
            %% the text itself is there, escaped; a link in it is the
            %% same text between tags, so the tags are read past
            Bare = re:replace(HostilePage, "<[^>]*>", "", [global, {return, binary}]),
            Kept = binary:match(Bare, escaped(Text)) =/= nomatch,
            %% and the index, which quotes it, has only the tags ike writes
            Closed = lists:all(fun known_tag/1, tags(HostileIndex)),
            ?WHENFAIL(
                ct:pal("text ~p~nsame ~p kept ~p closed ~p", [Text, Same, Kept, Closed]),
                Same andalso Kept andalso Closed
            )
        end
    ),
    true = proper:quickcheck(Prop, [{numtests, 40}, {to_file, user}]),
    %% links are markup made from text: whatever stands around one, a
    %% link says only its number, and a board's name only if it is one
    lists:foreach(
        fun(Text) ->
            {Page, Index} = posted(Config, Session, Text),
            scriptless(Page),
            true = lists:all(fun known_tag/1, tags(Page) ++ tags(Index)),
            {match, Hrefs} = re:run(Page, "href=\"([^\"]*)\"", [
                global, {capture, all_but_first, binary}
            ]),
            %% ike's own paths, or someone else's site by http(s), with
            %% nothing in it that ends an attribute
            [] = [
                H
             || [H] <- Hrefs,
                H =/= <<"/style.css">>,
                re:run(H, "^[#/a-z0-9]*$", [{capture, none}]) =/= match,
                re:run(H, "^/booru/search\\?tags=[A-Za-z0-9%_()!.:'*~-]*$", [{capture, none}]) =/=
                    match,
                re:run(H, "^/wiki/([a-z0-9_()!:.-]|%27|%3F)*$", [{capture, none}]) =/= match,
                re:run(H, "^https?://[^\"<>\\s`]+$", [{capture, none}]) =/= match
            ],
            {match, Classes} = re:run(Page, "class=\"([^\"]*)\"", [
                global, {capture, all_but_first, binary}
            ]),
            [] = [
                C
             || [C] <- Classes,
                not lists:member(C, [
                    <<"name">>,
                    <<"name account">>,
                    <<"name role">>,
                    <<"gone">>,
                    <<"missing">>,
                    <<"title">>,
                    <<"spoiler">>
                ])
            ]
        end,
        [
            <<">>1\"><script>alert(1)</script>">>,
            <<">>1<b>bold</b> >>1' onmouseover='alert(1)">>,
            <<">>>/b\"><script>/1">>,
            <<">>>/<script>/1 >>>/b/1\" onmouseover=\"alert(1)">>,
            <<">>>/b/../../login >>>/../1 >>>/b/1/../../../logout">>,
            <<">>>/b:alert(1)/1 >>1:alert(1) >>>/b/1:alert(1)">>,
            <<">>999999999<img src=x onerror=alert(1)> >>>/meta/999999999<svg onload=alert(1)>">>,
            <<"<a href=\"/p/1\">>>1</a> &gt;&gt;1 >>&#49;">>,
            <<"##1\"><script>alert(1)</script> ###1 ##>>1 ##0 ##-1 ##1'onmouseover='x">>,
            %% markup: tags around tags, links with attributes in them, and
            %% addresses that are not http
            <<"[b]<script>[/b] [i][b]x[/i][/b] [spoiler]\" onmouseover=\"x[/spoiler]">>,
            <<"\"a\":[https://x.org/\"onmouseover=\"alert(1)] \"b\":[javascript:alert(1)]">>,
            <<"https://x.org/a\"><script>alert(1)</script> http://y.org/<b>">>,
            <<"{{\"><script>alert(1)</script>}} [[x|<b>label</b>]] [code]<script>[/code]">>,
            <<"[[doesn't]] [[a?b]] [[x\"y]] [[x'onclick='y]] [[../login]] [[a/b]] [[a#b]]">>,
            %% quotes and lists past any depth, and tags across them
            <<"> > > > > > > > > > > > > > <script>x\n> **************** <b>\n> [quote]\n> </blockquote>\n*** [i]\n* [/i]">>,
            <<"h1. <script>alert(1)</script>\n* <img src=x onerror=alert(1)>\n[quote]\n<b>\n[/quote]">>
        ]
    ),
    %% a moderator's pages are made per request from the same text, and
    %% the log quotes a reason: both escaped, both only ike's tags
    Admin = ike_browser:login(Config, <<"hostile-admin">>, #{groups => [<<"ike-admin">>]}),
    lists:foreach(
        fun(Text) ->
            {303, Headers, _} = ike_browser:post(Config, "/board/b/new", Session, Text),
            "#p" ++ N = string:find(proplists:get_value("location", Headers), "#"),
            Path = "/mod/post/" ++ N,
            {200, _, Look} = ike_browser:request(
                Config, get, Path, ike_browser:cookies(Admin), none
            ),
            scriptless(Look),
            true = lists:all(fun known_tag/1, tags(Look)),
            {_, _} = binary:match(Look, escaped(Text)),
            #{csrf := Csrf} = Admin,
            Form = uri_string:compose_query([
                {"csrf", Csrf}, {"kind", "hide"}, {"reason", Text}
            ]),
            {303, _, _} = ike_browser:request(
                Config, post, Path, ike_browser:cookies(Admin), {form, Form}
            ),
            [[Entry]] = ike_browser:query(
                Config,
                "SELECT entry FROM action WHERE kind = 'hide' AND post = ?",
                [list_to_integer(N)]
            ),
            {303, At, _} = ike_browser:request(
                Config, get, "/p/" ++ integer_to_list(Entry), [], none
            ),
            Log = hd(string:split(proplists:get_value("location", At), "#")),
            {200, _, LogPage} = ike_browser:request(Config, get, Log, [], none),
            scriptless(LogPage),
            true = lists:all(fun known_tag/1, tags(LogPage)),
            {_, _} = binary:match(LogPage, escaped(Text))
        end,
        [
            <<"\"><script>alert(1)</script>">>,
            <<"' onmouseover='alert(1)' x='">>,
            <<"<img src=x onerror=alert(1)> &amp; &lt;b&gt;">>,
            <<"</textarea></form><form action=\"//evil\"><input name=csrf>">>
        ]
    ),
    %% per-request pages: what a request says of itself is never echoed
    Attack = uri_string:quote("\"><script>alert(1)</script>"),
    lists:foreach(
        fun(Path) ->
            {_, _, Html} = ike_browser:request(Config, get, Path, [], none),
            scriptless(Html),
            true = lists:all(fun known_tag/1, tags(Html))
        end,
        [
            "/" ++ Attack,
            "/board/b/new?" ++ Attack ++ "=" ++ Attack,
            "/login/callback?state=" ++ Attack ++ "&code=" ++ Attack,
            "/board/b/" ++ Attack,
            "/board/b/1/reply?x=" ++ Attack,
            "/upload?x=" ++ Attack,
            "/account?x=" ++ Attack,
            "/booru/search?tags=" ++ Attack,
            "/wiki/" ++ Attack,
            "/wiki/" ++ Attack ++ "/history"
        ]
    ).

%% 5. No user-supplied bytes are served from the main origin.
%%
%% In M0 the only bytes a user supplies are a post's text, which reaches a
%% page as escaped text nodes (invariant 4) and never as a response of its
%% own. So: nothing that could carry a file is accepted, everything ike
%% serves is one of its own pages, and the pages are all it has rendered.
inv05_no_user_bytes_on_the_main_origin(Config) ->
    #{csrf := Csrf} = Session = ike_browser:login(Config, <<"uploader">>),
    Cookies = ike_browser:cookies(Session),
    Before = ike_browser:posts(Config),
    Multipart = iolist_to_binary([
        "--b\r\ncontent-disposition: form-data; name=\"csrf\"\r\n\r\n",
        Csrf,
        "\r\n--b\r\ncontent-disposition: form-data; name=\"body\"\r\n\r\ntext",
        "\r\n--b\r\ncontent-disposition: form-data; name=\"file\"; filename=\"a.html\"\r\n",
        "content-type: text/html\r\n\r\n<script>alert(1)</script>\r\n--b--\r\n"
    ]),
    %% the post form takes files too: this one is no image, and nothing
    %% of it is kept, nor any post made
    Kept = fun() -> ike_browser:query(Config, "SELECT count(*) FROM asset", []) end,
    Assets = Kept(),
    {422, _, _} = ike_browser:request(
        Config, post, "/board/b/new", Cookies, {"multipart/form-data; boundary=b", Multipart}
    ),
    Assets = Kept(),
    %% the upload form, as the post form, reads no file that does not
    %% come after the form's token
    Uploads = fun() -> ike_browser:query(Config, "SELECT count(*) FROM upload", []) end,
    Held = Uploads(),
    {403, _, _} = ike_browser:request(
        Config,
        post,
        "/upload",
        Cookies,
        ike_browser:multipart([
            {file, <<"file">>, {<<"a.png">>, <<"x">>}}, {field, <<"csrf">>, list_to_binary(Csrf)}
        ])
    ),
    %% and a part that is not a file, after it, ends the form
    {400, _, _} = ike_browser:request(
        Config, post, "/upload", Cookies, {"multipart/form-data; boundary=b", Multipart}
    ),
    %% (without a session: refused, or held back by the limiter that
    %% invariant 1 has run to its end; either way nothing is read)
    {Nobody, _, _} = ike_browser:request(
        Config, post, "/upload", [], ike_browser:multipart([{field, <<"csrf">>, <<"x">>}])
    ),
    true = lists:member(Nobody, [403, 429]),
    Held = Uploads(),
    lists:foreach(
        fun({Method, Path}) ->
            {Status, _, _} = ike_browser:request(
                Config, Method, Path, Cookies, {"application/octet-stream", <<0, 1, 2>>}
            ),
            true = lists:member(Status, [404, 405, 415])
        end,
        [
            {M, P}
         || M <- [put, post, patch], P <- ["/", "/board/b/1", "/board/b/new", "/upload", "/media/x"]
        ]
    ),
    Before = ike_browser:posts(Config),
    %% a posted image's file is on the media origin and not on this one
    Png = read(?config(data_dir, Config), "base.png"),
    {303, _, _} = ike_browser:upload(Config, Session, [{<<"p.png">>, Png}]),
    [[Mine]] = ike_browser:query(
        Config,
        "SELECT max(u.id) FROM upload u JOIN actor a ON a.id = u.actor WHERE a.subject = 'uploader'",
        []
    ),
    {303, Where, _} = ike_browser:post(
        Config, "/board/b/new", Session, <<"with a picture">>, [
            {<<"upload">>, integer_to_binary(Mine)}
        ]
    ),
    {200, _, Page} = ike_browser:request(
        Config, get, hd(string:split(proplists:get_value("location", Where), "#")), [], none
    ),
    {match, [Full]} = re:run(
        Page, "<a href=\"http://media\\.test(/[0-9a-f]{64}\\.png)\">", [
            {capture, all_but_first, list}
        ]
    ),
    {200, _, Png2} = ike_browser:media(Config, "http://media.test" ++ Full),
    true = byte_size(Png2) > 0,
    {404, _, _} = ike_browser:request(Config, get, Full, [], none),
    {404, _, _} = ike_browser:request(Config, get, Full, Cookies, none),
    Before2 = ike_browser:posts(Config),
    %% what is served is html or plain text, typed as such and not sniffed
    lists:foreach(
        fun(Path) ->
            {_, Headers, _} = ike_browser:request(Config, get, Path, [], none),
            Type = proplists:get_value("content-type", Headers),
            true = lists:member(hd(string:split(Type, ";")), ["text/html", "text/plain"]),
            "nosniff" = proplists:get_value("x-content-type-options", Headers)
        end,
        ["/", "/board/b/new", "/health", "/nothing", "/upload"]
    ),
    Before2 = ike_browser:posts(Config),
    %% and the tree the web server reads from holds pages, nothing else
    Pages = files(filename:join(?config(dir, Config), "pages")),
    [_ | _] = Pages,
    [] = [
        F
     || F <- Pages,
        filename:extension(F) =/= ".html",
        not lists:member(filename:basename(F), ["style.css", "ike.js"])
    ].

%% 6. No decoder or metadata stripper runs inside the BEAM.
%%
%% ike has no port, no nif of its own and no image code: what an upload
%% becomes is decided by whatever listens on the stripper's socket, a
%% sandboxed unit in production and the built ike-strip here. Read off
%% the compiled modules, and then from outside: an upload loaded with
%% metadata is stored as exactly the bytes ike-strip makes of it.
inv06_no_decoder_in_the_vm(Config) ->
    [] = outside(Config),
    %% the one nif in the release is sqlite's
    Nifs = [
        F
     || App <- [ike, cowboy, cowlib, ranch],
        F <- files(code:priv_dir(App)),
        lists:member(filename:extension(F), [".so", ".dll", ".dylib"])
    ],
    [] = Nifs,
    [] = [
        Edge
     || {_, {M, F, _}} = Edge <- ?config(calls, Config),
        {M, F} =:= {erlang, load_nif} orelse lists:member(M, [zlib, egd, wx, erl_ddll])
    ],
    %% the stripper's client sends bytes over a socket and reads some back
    [close, connect, recv, send, shutdown] = lists:usort([
        F
     || {{ike_strip, _, _}, {gen_tcp, F, _}} <- ?config(calls, Config)
    ]),
    %% from outside
    Data = ?config(data_dir, Config),
    Work = filename:join(?config(priv_dir, Config), "inv06"),
    ok = filelib:ensure_path(Work),
    Laden = filename:join(Work, "laden.jpg"),
    {ok, _} = file:copy(filename:join(Data, "base.jpg"), Laden),
    exiftool(["-q", "-overwrite_original", "-GPSLatitude=52.516", "-GPSLatitudeRef=N", Laden]),
    Session = ike_browser:login(Config, <<"decoder">>),
    {303, _, _} = ike_browser:upload(Config, Session, [{<<"laden.jpg">>, read(Work, "laden.jpg")}]),
    [[Hash]] = ike_browser:query(
        Config,
        "SELECT u.asset FROM upload u JOIN actor a ON a.id = u.actor"
        " WHERE a.subject = 'decoder'",
        []
    ),
    Golden = maps:get("base.jpg", golden()),
    Golden = binary:encode_hex(Hash, lowercase),
    Stored = read(filename:join(?config(dir, Config), "assets"), binary_to_list(Golden)),
    Golden = binary:encode_hex(crypto:hash(sha256, Stored), lowercase),
    %% and the upload as it came is kept as a hash, not as bytes
    [[Original]] = ike_browser:query(
        Config, "SELECT original FROM upload WHERE asset = ?", [{blob, Hash}]
    ),
    Original = crypto:hash(sha256, read(Work, "laden.jpg")).

%% 7. The fetcher never connects to a non-public address.
%%
%% TRIPWIRE. There is no fetcher. The one module that connects out is the
%% oidc client, and only to the issuer the operator configured, never to
%% anything a user wrote. When a fetcher arrives this fails, and is
%% replaced by a test of its address checks.
inv07_tripwire_no_fetcher(Config) ->
    Connecting = [httpc, gen_tcp, gen_udp, gen_sctp, ssl, socket, inet_res, ftp, tftp, ssh],
    %% ike_strip speaks to the stripper's unix socket, named by the
    %% operator, and to nothing a user wrote
    [ike_oidc, ike_strip] = lists:usort([
        Mod
     || {{Mod, _, _}, {M, _, _}} <- ?config(calls, Config), lists:member(M, Connecting)
    ]),
    %% from outside: a post full of links, to a server that counts visits
    Session = ike_browser:login(Config, <<"linker">>),
    Hits = ike_mock_idp:hits(),
    Canary = <<(?config(issuer, Config))/binary, "/canary/">>,
    Text = <<
        Canary/binary,
        "plain\n",
        "<a href=\"",
        Canary/binary,
        "anchor\">x</a>\n",
        "[[",
        Canary/binary,
        "wiki]] >>",
        Canary/binary,
        "quote\n",
        "http://169.254.169.254/latest/meta-data/ http://[::1]/ http://localhost/"
    >>,
    {303, Headers, _} = ike_browser:post(Config, "/board/b/new", Session, Text),
    Thread = hd(string:split(proplists:get_value("location", Headers), "#")),
    {200, _, _} = ike_browser:request(Config, get, Thread, [], none),
    {200, _, _} = ike_browser:request(Config, get, "/", [], none),
    timer:sleep(1500),
    Hits = ike_mock_idp:hits(),
    %% the counter counts
    {ok, {{_, 200, _}, _, _}} = httpc:request(
        get, {binary_to_list(Canary) ++ "self", []}, [{ssl, [{verify, verify_none}]}], []
    ),
    true = ike_mock_idp:hits() =:= Hits + 1.

%% 8. Purge leaves no row, file, thumbnail, static page or reverse link
%% referencing the content, except the mod-log entry (see G5).
%%
%% An admin purges a thread whose first post was quoted from elsewhere.
%% Then the marker the thread carried is looked for in every file under
%% the data directory (the database, its write-ahead log, the pages)
%% and through HTTP; the rows and links are counted; and the log's entry
%% is read for the reason, which is all of it that stays.
%%
%% The backups directory is not searched: a snapshot taken before the
%% purge holds the content until it ages out (D7, questions.md).
inv08_purge_leaves_nothing(Config) ->
    Marker = <<"purge-marker-c4a1f0">>,
    Writer = ike_browser:login(Config, <<"purgee">>),
    {303, H1, _} = ike_browser:post(
        Config, "/board/b/new", Writer, <<Marker/binary, " at the root">>
    ),
    Thread = hd(string:split(proplists:get_value("location", H1), "#")),
    {Root, _} = string:to_integer(lists:last(string:split(Thread, "/", all))),
    R = integer_to_binary(Root),
    {303, _, _} = ike_browser:post(
        Config, Thread ++ "/reply", Writer, <<">>", R/binary, " ", Marker/binary, " replied">>
    ),
    %% quoted from another thread, so that a page outside it links to it
    {303, H2, _} = ike_browser:post(
        Config, "/board/b/new", Writer, <<"see >>", R/binary>>
    ),
    Quoting = hd(string:split(proplists:get_value("location", H2), "#")),
    {200, _, Before} = ike_browser:request(Config, get, Quoting, [], none),
    {_, _} = binary:match(Before, <<"href=\"/p/", R/binary, "\"">>),
    %% a janitor may only hide, and nobody else is shown that there is
    %% anything here at all
    Janitor = ike_browser:login(Config, <<"janitor8">>, #{groups => [<<"ike-janitor-b">>]}),
    Purge = fun(#{csrf := Csrf} = Session) ->
        Form = uri_string:compose_query([
            {"csrf", Csrf}, {"kind", "purge"}, {"reason", "rule 1, the reason stays"}
        ]),
        ike_browser:request(
            Config,
            post,
            "/mod/post/" ++ integer_to_list(Root),
            ike_browser:cookies(Session),
            {form, Form}
        )
    end,
    {404, _, _} = Purge(Writer),
    {404, _, _} = ike_browser:request(
        Config, get, "/mod/post/" ++ integer_to_list(Root), ike_browser:cookies(Writer), none
    ),
    {403, _, _} = Purge(Janitor),
    Admin = ike_browser:login(Config, <<"admin8">>, #{groups => [<<"ike-admin">>]}),
    {200, _, Look} = ike_browser:request(
        Config, get, "/mod/post/" ++ integer_to_list(Root), ike_browser:cookies(Admin), none
    ),
    scriptless(Look),
    {_, _} = binary:match(Look, <<"value=\"purge\"">>),
    %% a reply goes alone: its thread's page stays, made again without it
    Kept = <<"purge-marker-77d2e9">>,
    {303, H3, _} = ike_browser:post(Config, "/board/b/new", Writer, <<"a thread that stays">>),
    Stays = hd(string:split(proplists:get_value("location", H3), "#")),
    {303, H4, _} = ike_browser:post(
        Config, Stays ++ "/reply", Writer, <<Kept/binary, " in a reply">>
    ),
    "#p" ++ Reply = string:find(proplists:get_value("location", H4), "#"),
    #{csrf := AdminCsrf} = Admin,
    {303, _, _} = ike_browser:request(
        Config,
        post,
        "/mod/post/" ++ Reply,
        ike_browser:cookies(Admin),
        {form,
            uri_string:compose_query([
                {"csrf", AdminCsrf}, {"kind", "purge"}, {"reason", "spam"}
            ])}
    ),
    {200, _, StaysPage} = ike_browser:request(Config, get, Stays, [], none),
    {_, _} = binary:match(StaysPage, <<"a thread that stays">>),
    nomatch = binary:match(StaysPage, Kept),
    {404, _, _} = ike_browser:request(Config, get, "/p/" ++ Reply, [], none),
    [[0]] = ike_browser:query(
        Config, "SELECT count(*) FROM post WHERE id = ?", [list_to_integer(Reply)]
    ),
    {303, _, _} = Purge(Admin),
    %% through HTTP: the thread, the post and its reply are not there
    {404, _, _} = ike_browser:request(Config, get, Thread, [], none),
    {404, _, _} = ike_browser:request(Config, get, "/p/" ++ integer_to_list(Root), [], none),
    {200, _, After} = ike_browser:request(Config, get, Quoting, [], none),
    nomatch = binary:match(After, <<"href=\"/p/", R/binary, "\"">>),
    {_, _} = binary:match(After, <<"<span class=\"gone\">&gt;&gt;", R/binary, "</span>">>),
    {200, _, Index} = ike_browser:request(Config, get, "/board/b", [], none),
    nomatch = binary:match(Index, Marker),
    %% the rows, and every link to or from them
    [[0]] = ike_browser:query(Config, "SELECT count(*) FROM post WHERE thread = ?", [Root]),
    [[0]] = ike_browser:query(Config, "SELECT count(*) FROM thread WHERE root = ?", [Root]),
    [[0]] = ike_browser:query(Config, "SELECT count(*) FROM link WHERE post = ?", [Root]),
    [[0]] = ike_browser:query(
        Config, "SELECT count(*) FROM post WHERE instr(body, ?) > 0", [Marker]
    ),
    %% the log keeps who in what role, what, and why; not the content
    [[<<"admin">>, Entry]] = ike_browser:query(
        Config, "SELECT role, entry FROM action WHERE kind = 'purge' AND post = ?", [Root]
    ),
    [[Logged]] = ike_browser:query(Config, "SELECT body FROM post WHERE id = ?", [Entry]),
    <<"purge >>", R:(byte_size(R))/binary, "\nrule 1, the reason stays">> = Logged,
    %% shown on the log's board under the role, never the account
    {303, LogHeaders, _} = ike_browser:request(
        Config, get, "/p/" ++ integer_to_list(Entry), [], none
    ),
    LogPage = hd(string:split(proplists:get_value("location", LogHeaders), "#")),
    "/board/mod/" ++ _ = LogPage,
    {200, _, Log} = ike_browser:request(Config, get, LogPage, [], none),
    {_, _} = binary:match(Log, <<"<span class=\"name role\">admin</span>">>),
    nomatch = binary:match(Log, <<"admin8">>),
    nomatch = binary:match(Log, Marker),
    %% an image, purged wherever it is shown (hazard G3): the posts keep
    %% their text and say the image is gone, every upload of it goes, and
    %% what is left is its hashes on the blocklist, which lux kept on
    %% purpose (the exception beside the log)
    Webp = read(?config(data_dir, Config), "lossless.webp"),
    {303, _, _} = ike_browser:upload(Config, Writer, [{<<"i.webp">>, Webp}]),
    [[Staged]] = ike_browser:query(
        Config,
        "SELECT max(u.id) FROM upload u JOIN actor a ON a.id = u.actor"
        " WHERE a.subject = 'purgee' AND u.posted IS NULL",
        []
    ),
    {303, H5, _} = ike_browser:post(
        Config,
        "/board/b/new",
        Writer,
        <<"an image to purge">>,
        [{<<"upload">>, integer_to_binary(Staged)}]
    ),
    Imaged = hd(string:split(proplists:get_value("location", H5), "#")),
    "#p" ++ Image = string:find(proplists:get_value("location", H5), "#"),
    {200, _, WithImage} = ike_browser:request(Config, get, Imaged, [], none),
    {match, [Full, Small]} = re:run(
        WithImage,
        "<a href=\"(http://media\\.test/[^\"]+)\"><img src=\"(http://media\\.test/[^\"]+)\"",
        [{capture, all_but_first, list}]
    ),
    {200, _, StoredImage} = ike_browser:media(Config, Full),
    %% (its thumbnail's bytes are not looked for: another image of the
    %% same pixels has the same thumbnail. its files are, by name)
    {200, _, _} = ike_browser:media(Config, Small),
    [[ImageHash]] = ike_browser:query(
        Config, "SELECT asset FROM post_image WHERE post = ? AND position = 0", [
            list_to_integer(Image)
        ]
    ),
    ImageHex = binary_to_list(binary:encode_hex(ImageHash, lowercase)),
    #{csrf := ImageCsrf} = Admin,
    %% its meta hidden and shown again, so that the log names it
    [[ImageMeta]] = ike_browser:query(Config, "SELECT id FROM meta WHERE asset = ?", [
        {blob, ImageHash}
    ]),
    ImageMetaPath = integer_to_list(ImageMeta),
    [
        {303, _, _} = ike_browser:request(
            Config,
            post,
            "/mod/meta/" ++ ImageMetaPath,
            ike_browser:cookies(Admin),
            {form, uri_string:compose_query([{"csrf", ImageCsrf}, {"kind", K}, {"reason", "x"}])}
        )
     || K <- ["hide", "unhide"]
    ],
    [[2]] = ike_browser:query(Config, "SELECT count(*) FROM action WHERE meta = ?", [ImageMeta]),
    {303, _, _} = ike_browser:request(
        Config,
        post,
        "/mod/post/" ++ Image,
        ike_browser:cookies(Admin),
        {form,
            uri_string:compose_query([
                {"csrf", ImageCsrf}, {"kind", "purge_image"}, {"image", "0"}, {"reason", "rule 1"}
            ])}
    ),
    {200, _, Tombstoned} = ike_browser:request(Config, get, Imaged, [], none),
    {_, _} = binary:match(Tombstoned, <<"an image to purge">>),
    {_, _} = binary:match(Tombstoned, <<"<span class=\"gone\">image</span>">>),
    nomatch = binary:match(Tombstoned, <<"<img">>),
    {404, _, _} = ike_browser:media(Config, Full),
    {404, _, _} = ike_browser:media(Config, Small),
    [[0]] = ike_browser:query(Config, "SELECT count(*) FROM asset WHERE hash = ?", [
        {blob, ImageHash}
    ]),
    [[0]] = ike_browser:query(Config, "SELECT count(*) FROM upload WHERE asset = ?", [
        {blob, ImageHash}
    ]),
    %% and its meta, with the trunk's page of it
    [[0]] = ike_browser:query(Config, "SELECT count(*) FROM meta WHERE asset = ?", [
        {blob, ImageHash}
    ]),
    %% the log keeps its entries, but not which meta (G5)
    [[0]] = ike_browser:query(Config, "SELECT count(*) FROM action WHERE meta = ?", [ImageMeta]),
    {404, _, _} = ike_browser:request(
        Config, get, "/trunk/" ++ ImageMetaPath, ike_browser:cookies(Admin), none
    ),
    [[0]] = ike_browser:query(Config, "SELECT count(*) FROM post WHERE asset = ?", [
        {blob, ImageHash}
    ]),
    [[1]] = ike_browser:query(Config, "SELECT count(*) FROM blocklist WHERE hash = ?", [
        {blob, ImageHash}
    ]),
    %% and it does not come back
    {422, _, Again} = ike_browser:upload(Config, Writer, [{<<"again.webp">>, Webp}]),
    {_, _} = binary:match(Again, <<"file 1: not taken">>),
    %% a post with an image, purged as a post: its text goes, and its
    %% image stays, kept, out of sight, its hash free. the image is not
    %% the post's content (lux, 2026-11-16); purge_image erases one
    Lossy = read(?config(data_dir, Config), "lossy.webp"),
    {303, _, _} = ike_browser:upload(Config, Writer, [{<<"l.webp">>, Lossy}]),
    [[Staged2]] = ike_browser:query(
        Config,
        "SELECT max(u.id) FROM upload u JOIN actor a ON a.id = u.actor"
        " WHERE a.subject = 'purgee' AND u.posted IS NULL",
        []
    ),
    {303, H6, _} = ike_browser:post(
        Config, "/board/b/new", Writer, <<"a post to purge">>, [
            {<<"upload">>, integer_to_binary(Staged2)}
        ]
    ),
    "#p" ++ Whole = string:find(proplists:get_value("location", H6), "#"),
    [[WholeHash]] = ike_browser:query(
        Config, "SELECT asset FROM post_image WHERE post = ? AND position = 0", [
            list_to_integer(Whole)
        ]
    ),
    WholeHex = binary_to_list(binary:encode_hex(WholeHash, lowercase)),
    {200, _, _} = ike_browser:media(Config, "http://media.test/" ++ WholeHex ++ ".webp"),
    {303, _, _} = ike_browser:request(
        Config,
        post,
        "/mod/post/" ++ Whole,
        ike_browser:cookies(Admin),
        {form,
            uri_string:compose_query([{"csrf", ImageCsrf}, {"kind", "purge"}, {"reason", "rule 2"}])}
    ),
    [[1]] = ike_browser:query(Config, "SELECT count(*) FROM asset WHERE hash = ?", [
        {blob, WholeHash}
    ]),
    [[0]] = ike_browser:query(Config, "SELECT count(*) FROM blocklist WHERE hash = ?", [
        {blob, WholeHash}
    ]),
    [[0]] = ike_browser:query(Config, "SELECT count(*) FROM post WHERE id = ?", [
        list_to_integer(Whole)
    ]),
    %% (and stays public through its booru entry: the image is the
    %% archive's, not the post's, until the entry is taken down too)
    {200, _, _} = ike_browser:media(Config, "http://media.test/" ++ WholeHex ++ ".webp"),
    [[1]] = ike_browser:query(
        Config, "SELECT count(*) FROM shown_entry WHERE asset = ?", [{blob, WholeHash}]
    ),
    true = filelib:is_regular(filename:join([?config(dir, Config), "assets", WholeHex])),
    %% and every file but the snapshots: the write-ahead log is folded
    %% back after a purge, and secure_delete overwrote the pages it freed
    Dir = binary_to_list(?config(dir, Config)),
    Searched = fun() ->
        [
            F
         || F <- files(Dir),
            not lists:prefix(filename:join(Dir, "backups"), F),
            holds(F, Marker) orelse holds(F, Kept) orelse holds(F, StoredImage) orelse
                string:find(F, ImageHex) =/= nomatch orelse holds(F, <<"a post to purge">>)
        ]
    end,
    [] = eventually(Searched, 50),
    %% the routes are these and no others, and so are the tables
    known_routes(),
    known_tables(Config).

holds(File, Marker) ->
    case file:read_file(File) of
        {ok, Bytes} -> binary:match(Bytes, Marker) =/= nomatch;
        {error, _} -> false
    end.

%% a checkpoint can wait on a reader; it is retried for a few seconds
eventually(Fun, 0) ->
    Fun();
eventually(Fun, N) ->
    case Fun() of
        [] ->
            [];
        _ ->
            timer:sleep(100),
            eventually(Fun, N - 1)
    end.

%% 9. Every column that references an asset is part of the reachability
%% view.
%%
%% The test proper is ike_schema_SUITE's, against a migrated database: it
%% walks every foreign key and every hash-shaped column. Here, against the
%% running one: every foreign key to asset shows up in the view when used.
inv09_reachability_view_is_complete(Config) ->
    Referencing = ike_browser:query(
        Config,
        "SELECT m.name, f.\"from\" FROM sqlite_master m, pragma_foreign_key_list(m.name) f"
        " WHERE m.type = 'table' AND f.\"table\" = 'asset' ORDER BY 1, 2",
        []
    ),
    [_ | _] = Referencing,
    [[View]] = ike_browser:query(
        Config, "SELECT sql FROM sqlite_master WHERE name = 'asset_reference'", []
    ),
    lists:foreach(
        fun([Table, Column]) ->
            Via = <<"'", Table/binary, ".", Column/binary, "'">>,
            {_, _} = binary:match(View, Via)
        end,
        Referencing
    ).

%% 10. A private meta is served only to its owner and moderators.
%% Moderators see all metas in the trunk. Users see only public and their
%% own metas.
%%
%% The media origin knows no session, so a link to a private meta's files
%% is its own credential, signed and short-lived (hazard G7), and only a
%% page its owner or a moderator asked for carries one. An owner, another
%% account, nobody and a moderator: the owner and the moderator are shown
%% the private meta, in the trunk and on its page, the other two nothing
%% of it; its files are not on the media origin by name; a link changed
%% in any part, or past its time, or asked of the main origin, gets
%% nothing. A public meta is listed for everyone and its files are
%% public, and the owner's switch moves a meta between the two.
inv10_private_metas_are_their_owners_and_moderators(Config) ->
    %% images of their own: a meta is its asset's first uploader's, and
    %% the suite's files have been uploaded before
    Png = png(3, 2, 17),
    Jpeg = png(2, 3, 23),
    Owner = ike_browser:login(Config, <<"stager">>),
    Other = ike_browser:login(Config, <<"onlooker">>),
    Moderator = ike_browser:login(Config, <<"trunk-mod">>, #{groups => [<<"ike-moderator">>]}),
    Janitor = ike_browser:login(Config, <<"trunk-janitor">>, #{groups => [<<"ike-janitor-b">>]}),
    #{csrf := Csrf} = Owner,
    {Type, Body} = ike_browser:multipart([
        {field, <<"csrf">>, list_to_binary(Csrf)},
        {field, <<"private">>, <<"1">>},
        {file, <<"file">>, {<<"a.png">>, Png}}
    ]),
    {303, Sent, _} = ike_browser:request(
        Config, post, "/upload", ike_browser:cookies(Owner), {Type, Body}
    ),
    "/upload" = proplists:get_value("location", Sent),
    [[Id, Hash]] = ike_browser:query(
        Config,
        "SELECT m.id, m.asset FROM meta m JOIN actor a ON a.id = m.owner"
        " WHERE a.subject = 'stager' AND m.private = 1",
        []
    ),
    Hex = binary_to_list(binary:encode_hex(Hash, lowercase)),
    Meta = "/trunk/" ++ integer_to_list(Id),
    Signed =
        "<a href=\"(http://media\\.test/staged/[^\"]+)\"><img src=\"(http://media\\.test/staged/[^\"]+)\"",
    %% the owner and the moderator: listed, and its page with links
    [
        begin
            {200, _, Trunk} = ike_browser:request(Config, get, "/trunk", Cookies, none),
            {_, _} = binary:match(Trunk, list_to_binary(Meta)),
            {200, _, Page} = ike_browser:request(Config, get, Meta, Cookies, none),
            {match, [_, _]} = re:run(Page, Signed, [{capture, all_but_first, list}])
        end
     || Cookies <- [ike_browser:cookies(Owner), ike_browser:cookies(Moderator)]
    ],
    {200, _, Mine} = ike_browser:request(Config, get, Meta, ike_browser:cookies(Owner), none),
    {match, [File, Thumb]} = re:run(Mine, Signed, [{capture, all_but_first, list}]),
    {200, Headers, Stored} = ike_browser:media(Config, File),
    "image/png" = proplists:get_value("content-type", Headers),
    "nosniff" = proplists:get_value("x-content-type-options", Headers),
    "default-src 'none'; sandbox" = proplists:get_value("content-security-policy", Headers),
    undefined = proplists:get_value("set-cookie", Headers),
    %% it is what the stripper made of the upload
    Hash = crypto:hash(sha256, Stored),
    {200, ThumbHeaders, _} = ike_browser:media(Config, Thumb),
    "image/webp" = proplists:get_value("content-type", ThumbHeaders),
    %% everyone else, a janitor too: not listed, no page, no link, and
    %% the files are not on the media origin by name
    [
        begin
            {200, _, Trunk} = ike_browser:request(Config, get, "/trunk", Cookies, none),
            nomatch = binary:match(Trunk, list_to_binary(Meta ++ "\"")),
            {404, _, Missing} = ike_browser:request(Config, get, Meta, Cookies, none),
            nomatch = binary:match(Missing, <<"media.test">>),
            {200, _, Uploads} = ike_browser:request(Config, get, "/upload", Cookies, none),
            nomatch = binary:match(Uploads, <<"media.test">>)
        end
     || Cookies <- [ike_browser:cookies(Other), ike_browser:cookies(Janitor), []]
    ],
    {404, _, _} = ike_browser:media(Config, "http://media.test/" ++ Hex ++ ".png"),
    {404, _, _} = ike_browser:media(Config, "http://media.test/" ++ Hex ++ ".thumb.webp"),
    %% nor does uploading the same bytes say anything of it: the other
    %% is sent where any upload goes, and given a meta of their own
    #{csrf := OtherCsrf} = Other,
    {SameType, SameBody} = ike_browser:multipart([
        {field, <<"csrf">>, list_to_binary(OtherCsrf)},
        {field, <<"private">>, <<"1">>},
        {file, <<"file">>, {<<"same.png">>, Png}}
    ]),
    {303, Same, _} = ike_browser:request(
        Config, post, "/upload", ike_browser:cookies(Other), {SameType, SameBody}
    ),
    "/upload" = proplists:get_value("location", Same),
    [[Theirs]] = ike_browser:query(
        Config,
        "SELECT m.id FROM meta m JOIN actor a ON a.id = m.owner"
        " WHERE a.subject = 'onlooker' AND m.asset = ?",
        [{blob, Hash}]
    ),
    true = Theirs =/= Id,
    {200, _, OwnPage} = ike_browser:request(
        Config, get, "/trunk/" ++ integer_to_list(Theirs), ike_browser:cookies(Other), none
    ),
    nomatch = binary:match(OwnPage, <<"stager">>),
    nomatch = binary:match(OwnPage, list_to_binary(Meta ++ "\"")),
    {200, _, OtherTrunk} = ike_browser:request(
        Config, get, "/trunk", ike_browser:cookies(Other), none
    ),
    nomatch = binary:match(OtherTrunk, list_to_binary(Meta ++ "\"")),
    %% only the owner switches it: not another account, not a moderator
    Switch = fun(#{csrf := C} = Who, To) ->
        ike_browser:request(
            Config,
            post,
            Meta,
            ike_browser:cookies(Who),
            {form, uri_string:compose_query([{"csrf", C}, {"private", To}])}
        )
    end,
    {403, _, _} = Switch(Other, "0"),
    {403, _, _} = Switch(Moderator, "0"),
    {404, _, _} = ike_browser:request(Config, get, Meta, [], none),
    %% a link is good for what it names and no more
    {match, [Upload, Expires, Sig]} = re:run(
        File, "/staged/([0-9]+)/([0-9]+)/([^/]+)$", [{capture, all_but_first, list}]
    ),
    Base = "http://media.test/staged/",
    Next = integer_to_list(list_to_integer(Upload) + 1),
    Later = integer_to_list(list_to_integer(Expires) + 1),
    Changed = lists:droplast(Sig) ++ [other(lists:last(Sig))],
    [
        {404, _, _} = ike_browser:media(Config, Url)
     || Url <- [
            Base ++ Upload ++ "/" ++ Expires ++ "/" ++ Changed,
            Base ++ Next ++ "/" ++ Expires ++ "/" ++ Sig,
            Base ++ Upload ++ "/" ++ Later ++ "/" ++ Sig,
            Base ++ Upload ++ "/" ++ Expires ++ "/" ++ Sig ++ "/thumb",
            lists:sublist(Thumb, length(Thumb) - length("/thumb")),
            Base ++ Upload,
            "http://media.test/"
        ]
    ],
    %% the main origin has no such path at all
    "http://media.test" ++ Path = File,
    {404, _, _} = ike_browser:request(Config, get, Path, [], none),
    %% made public by its owner: listed for everyone, its files public;
    %% private again, and they are not
    {303, _, _} = Switch(Owner, "0"),
    {200, _, Public} = ike_browser:request(Config, get, "/trunk", [], none),
    {_, _} = binary:match(Public, list_to_binary(Meta)),
    {200, _, _} = ike_browser:request(Config, get, Meta, [], none),
    {200, _, _} = ike_browser:media(Config, "http://media.test/" ++ Hex ++ ".png"),
    {303, _, _} = Switch(Owner, "1"),
    {404, _, _} = ike_browser:request(Config, get, Meta, [], none),
    {404, _, _} = ike_browser:media(Config, "http://media.test/" ++ Hex ++ ".png"),
    %% an upload not ticked private is public at once, to everyone
    {303, _, _} = ike_browser:upload(Config, Other, [{<<"b.png">>, Jpeg}]),
    [[OpenId, Open]] = ike_browser:query(
        Config,
        "SELECT m.id, m.asset FROM meta m JOIN actor a ON a.id = m.owner"
        " WHERE a.subject = 'onlooker' AND m.private = 0",
        []
    ),
    OpenHex = binary_to_list(binary:encode_hex(Open, lowercase)),
    OpenMeta = "/trunk/" ++ integer_to_list(OpenId),
    {200, _, Listed} = ike_browser:request(Config, get, "/trunk", [], none),
    {_, _} = binary:match(Listed, list_to_binary(OpenMeta ++ "\"")),
    {200, _, OpenPage} = ike_browser:request(Config, get, OpenMeta, [], none),
    nomatch = binary:match(OpenPage, <<"onlooker">>),
    nomatch = binary:match(OpenPage, <<"/staged/">>),
    {200, _, _} = ike_browser:media(Config, "http://media.test/" ++ OpenHex ++ ".png"),
    %% and once its time is up, a link is nothing
    timer:sleep((?STAGED + 1) * 1000),
    {404, _, _} = ike_browser:media(Config, File),
    known_routes(),
    known_tables(Config).

%% a png of W by H pixels, its bytes made from Seed: no other test's
png(W, H, Seed) ->
    Chunk = fun(Kind, Data) ->
        [<<(byte_size(Data)):32>>, Kind, Data, <<(erlang:crc32([Kind, Data])):32>>]
    end,
    Rows = <<
        <<0,
            <<
                <<((Seed * (X + 1) * (Y + 3)) rem 256):8, (Seed + X):8, (Y * 40):8>>
             || X <- lists:seq(0, W - 1)
            >>/binary>>
     || Y <- lists:seq(0, H - 1)
    >>,
    iolist_to_binary([
        <<137, "PNG\r\n", 26, "\n">>,
        Chunk(<<"IHDR">>, <<W:32, H:32, 8, 2, 0, 0, 0>>),
        Chunk(<<"IDAT">>, zlib:compress(Rows)),
        Chunk(<<"IEND">>, <<>>)
    ]).

other($A) -> $B;
other(_) -> $A.

%% 11. Stripping leaves no metadata outside the allowlist, and is
%% deterministic for a given input.
%%
%% Hazard P7's corpus, black-box over ike-strip as it is built: four base
%% images in the data directory, and copies of each that exiftool loads
%% with EXIF and GPS, XMP, IPTC, comments and trailing bytes. Every copy
%% strips to the same bytes as its base; nothing of what was added
%% survives, in the stored file or its thumbnail; exiftool reports
%% nothing outside the tags a bare image has; and the stored bytes of
%% each base have the hash written down here, so that a bump of libvips,
%% jpegtran or Zig that changes them fails (P7: a migration).
%%
%% What makes the image what it is stays, on lux's word that an archive
%% keeps assets whole (decisions.md): a colour profile comes out byte for
%% byte, an orientation tag goes without the pixels being turned, and an
%% animated PNG keeps its frames. Video's GPMF tracks and chapters wait
%% for video (M2).
inv11_stripping_is_complete_and_deterministic(Config) ->
    Data = ?config(data_dir, Config),
    Work = filename:join(?config(priv_dir, Config), "strip"),
    ok = filelib:ensure_path(Work),
    Bases = [
        {"base.jpg", <<"jpeg">>},
        {"base.png", <<"png">>},
        {"lossy.webp", <<"webp">>},
        {"lossless.webp", <<"webp">>}
    ],
    Icc = filename:join(Data, "profile.icc"),
    Laden = [
        "-EXIF:Artist=SECRET-ARTIST",
        "-EXIF:Make=SECRET-MAKE",
        "-EXIF:Model=SECRET-MODEL",
        "-GPSLatitude=52.516",
        "-GPSLatitudeRef=N",
        "-GPSLongitude=13.377",
        "-GPSLongitudeRef=E",
        "-XMP:Creator=SECRET-CREATOR",
        "-XMP:Description=SECRET-DESCRIPTION"
    ],
    Profile = read(Data, "profile.icc"),
    For = #{
        <<"jpeg">> => ["-IPTC:By-line=SECRET-BYLINE", "-Comment=SECRET-COMMENT"],
        <<"png">> => ["-PNG:Comment=SECRET-COMMENT", "-PNG:Title=SECRET-TITLE"],
        <<"webp">> => []
    },
    lists:foreach(
        fun({Name, Type}) ->
            Base = filename:join(Data, Name),
            {ok, Type, W, H, Stored, Thumb} = strip(Work, Base),
            {61, 47} = {W, H},
            %% the same input twice is the same output
            {ok, Type, W, H, Stored, Thumb} = strip(Work, Base),
            Golden = maps:get(Name, golden()),
            Golden = binary:encode_hex(crypto:hash(sha256, Stored), lowercase),
            bare(Work, Stored),
            bare(Work, Thumb),
            %% metadata in, the same bytes out
            Copy = filename:join(Work, "laden-" ++ Name),
            {ok, _} = file:copy(Base, Copy),
            exiftool(["-q", "-overwrite_original" | Laden ++ maps:get(Type, For)] ++ [Copy]),
            {ok, Bytes} = file:read_file(Copy),
            ok = file:write_file(Copy, [Bytes, <<"TRAILING-SECRET">>]),
            {ok, Type, W, H, Stored, _} = strip(Work, Copy),
            %% and the copy really carried it: else this proves nothing
            {ok, Carried} = file:read_file(Copy),
            {_, _} = binary:match(Carried, <<"SECRET-CREATOR">>),
            [] = secrets(Stored),
            %% a profile stays, whole, and the rest still goes
            Coloured = filename:join(Work, "coloured-" ++ Name),
            {ok, _} = file:copy(Base, Coloured),
            exiftool(["-q", "-overwrite_original", "-ICC_Profile<=" ++ Icc, Coloured]),
            {ok, Type, W, H, Kept, _} = strip(Work, Coloured),
            ColouredLaden = filename:join(Work, "coloured-laden-" ++ Name),
            {ok, _} = file:copy(Coloured, ColouredLaden),
            exiftool(
                ["-q", "-overwrite_original" | Laden ++ maps:get(Type, For)] ++ [ColouredLaden]
            ),
            {ok, Type, W, H, Kept, _} = strip(Work, ColouredLaden),
            true = Kept =/= Stored,
            bare(Work, Kept),
            Profile = profile(Work, Kept)
        end,
        Bases
    ),
    %% a png's profile has a name of its own, free text: it becomes the
    %% same for every image, and the profile stays as it was
    [{_, Ihdr} | _] = PngChunks = chunks(read(Data, "base.png")),
    Named = iolist_to_binary([
        <<137, "PNG\r\n", 26, "\n">>,
        chunk(<<"IHDR">>, Ihdr),
        chunk(<<"iCCP">>, <<"SECRET-DEVICE", 0, 0, (zlib:compress(Profile))/binary>>)
        | [chunk(K, D) || {K, D} <- tl(PngChunks)]
    ]),
    {ok, <<"png">>, 61, 47, Renamed, _} = strip_bytes(Work, Named, caps()),
    [] = secrets(Renamed),
    {_, _} = binary:match(Renamed, <<"ICC profile", 0, 0>>),
    Profile = profile(Work, Renamed),
    %% video: remuxed with one video and one audio stream, no tags of the
    %% uploader's, no chapters, nothing its encoder said of itself, and the
    %% same bytes whatever metadata came with it
    lists:foreach(
        fun({Name, Type}) ->
            Base = filename:join(Data, Name),
            {ok, Type, 64, 48, Stored, Thumb} = strip(Work, Base),
            Golden = maps:get(Name, golden()),
            Golden = binary:encode_hex(crypto:hash(sha256, Stored), lowercase),
            bare(Work, Thumb),
            Meta = filename:join(Work, "meta.txt"),
            ok = file:write_file(Meta, <<
                ";FFMETADATA1\ntitle=SECRET-TITLE\ncomment=SECRET-COMMENT\n"
                "location=+52.5160+013.3770/\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=500\n"
                "title=SECRET-CHAPTER\n"
            >>),
            Remuxed = filename:join(Work, "laden-" ++ Name),
            ffmpeg([
                "-v",
                "error",
                "-y",
                "-i",
                Base,
                "-i",
                Meta,
                "-map",
                "0",
                "-map_metadata",
                "1",
                "-map_chapters",
                "1",
                "-metadata:s:v",
                "title=SECRET-STREAM",
                "-c",
                "copy",
                Remuxed
            ]),
            {_, _} = binary:match(read(Work, "laden-" ++ Name), <<"SECRET-CHAPTER">>),
            {ok, Type, 64, 48, Stored, _} = strip(Work, Remuxed),
            [] = secrets(Stored),
            nomatch = binary:match(Stored, <<"x264">>),
            [] =
                video_tags(Work, Stored) --
                    [
                        <<"DURATION">>,
                        <<"encoder">>,
                        <<"language">>,
                        <<"handler_name">>,
                        <<"vendor_id">>,
                        <<"major_brand">>,
                        <<"minor_version">>,
                        <<"compatible_brands">>
                    ]
        end,
        [{"base.webm", <<"webm">>}, {"base.mp4", <<"mp4">>}]
    ),
    %% an animated png: its frames stay, in order, its text goes
    Frames = apng(read(Data, "base.png")),
    {ok, <<"png">>, 61, 47, Animated, _} = strip_bytes(Work, Frames, caps()),
    Kinds = [K || {K, _} <- chunks(Animated)],
    [<<"acTL">>, <<"fcTL">>, <<"fdAT">>] = lists:usort([
        K
     || K <- Kinds, lists:member(K, [<<"acTL">>, <<"fcTL">>, <<"fdAT">>])
    ]),
    Kinds = [K || {K, _} <- chunks(Frames), K =/= <<"tEXt">>],
    [] = secrets(Animated),
    bare(Work, Animated),
    %% an orientation is dropped with the rest, and the pixels stay as
    %% they were stored
    Turned = filename:join(Work, "turned.jpg"),
    {ok, _} = file:copy(filename:join(Data, "base.jpg"), Turned),
    exiftool(["-q", "-overwrite_original", "-Orientation#=6", Turned]),
    {ok, <<"jpeg">>, 61, 47, Unturned, _} = strip(Work, Turned),
    {ok, <<"jpeg">>, 61, 47, Unturned, _} = strip(Work, filename:join(Data, "base.jpg")),
    %% a font (lux, 2026-11-17): the names that say which font it is stay,
    %% and nothing else it says of itself (credits, license, vendor, a
    %% woff's metadata), which is the upload's commentary instead; so the
    %% same font credited to someone else is the same bytes. the fonts are
    %% ike's own, made by ike_font_SUITE_data/make.py, credits SECRET-*
    Font = filename:join(Data, "font.ttf"),
    {ok, <<"ttf">>, 0, 0, Kept0, FontThumb} = strip(Work, Font),
    {ok, <<"ttf">>, 0, 0, Kept0, FontThumb} = strip(Work, Font),
    {ok, <<"ttf">>, 0, 0, Kept0, _} = strip(Work, filename:join(Data, "font-other.ttf")),
    FontGolden = maps:get("font.ttf", golden()),
    FontGolden = binary:encode_hex(crypto:hash(sha256, Kept0), lowercase),
    {_, _} = binary:match(read(Data, "font.ttf"), <<"SCRT">>),
    nomatch = binary:match(Kept0, <<"SCRT">>),
    [] = secrets(Kept0),
    named_only(Work, Kept0),
    bare(Work, FontThumb),
    %% a woff2, compressed, is looked at by what the stripper itself
    %% reads of it again: no record, no vendor, no metadata left to say
    Woff2 = filename:join(Data, "font.woff2"),
    {ok, <<"woff2">>, 0, 0, Kept2, _} = strip(Work, Woff2),
    {ok, <<"woff2">>, 0, 0, Kept2, _} = strip(Work, Woff2),
    Woff2Golden = maps:get("font.woff2", golden()),
    Woff2Golden = binary:encode_hex(crypto:hash(sha256, Kept2), lowercase),
    {_, Said} = said(Work, read(Data, "font.woff2")),
    {_, _} = binary:match(Said, <<"SECRET-META">>),
    %% (OTS gives a font with no version name one of its own, from the
    %% version its head table holds: not the upload's, and the same for
    %% every copy)
    {Kept2, Again} = said(Work, Kept2),
    [<<"family\tIke Test">>] = [
        L
     || L <- binary:split(Again, <<"\n">>, [global, trim_all]), L =/= <<"name\t5\t1.000">>
    ],
    {Kept0, Plain} = said(Work, Kept0),
    [<<"family\tIke Test">>] = [
        L
     || L <- binary:split(Plain, <<"\n">>, [global, trim_all]), L =/= <<"name\t5\t1.000">>
    ],
    %% the thumbnail: the F alone, on nothing
    true = alpha(FontThumb),
    %% what is not taken
    Refused = [
        {<<"not an image">>, "not-an-image"},
        {binary:part(read(Data, "base.png"), 0, 200), "unreadable"},
        {<<(read(Data, "base.png"))/binary>>, "too-large", ["10000000", "32", "20000000", "128"]},
        {<<(read(Data, "base.png"))/binary>>, "too-large", ["1000", "4096", "20000000", "128"]},
        {<<"RIFF", 4:32/little, "WEBP">>, "unreadable"},
        %% a font's header and nothing that OTS would take for a font
        {<<0, 1, 0, 0, 0, 1, "nothing", 0:800>>, "unreadable"},
        {<<"wOF2", 0:800>>, "unreadable"}
    ],
    lists:foreach(
        fun
            ({Bytes, Reason}) ->
                {no, Reason} = strip_bytes(Work, Bytes, caps());
            ({Bytes, Reason, Caps}) ->
                {no, Reason} = strip_bytes(Work, Bytes, Caps)
        end,
        Refused
    ),
    known_routes().

%% the stored bytes' sha-256 for each base, as this nixpkgs strips them
golden() ->
    #{
        "base.jpg" =>
            <<"b2df20f1b2948243d6fe136c9e0cab2383a44c3ff08ac99943d26d00ea8058fc">>,
        "base.png" =>
            <<"cba5288fc8f5b68745b95ccae1fe01737bd14d3aee4dbf7c5710b02e4717259a">>,
        "lossy.webp" =>
            <<"5a4de3595f1d3c5dc1bb846b15661f221f7638852705d4c363c3490ead92376a">>,
        "base.webm" =>
            <<"5d529e13dc4d1ec63651083b99a96792a2741badbfd2963180e24b7c7a18f153">>,
        "base.mp4" =>
            <<"efb8883bfa667674c911168e7af19ca38e01a127a243e3e9dab90e064a618f37">>,
        "lossless.webp" =>
            <<"12860a83c965555f000702cd5d7c7098662cd8c868a787448e7757f322e0e1d1">>,
        "font.ttf" =>
            <<"c0c5831b481be88752538ebed3c7b1804da2d031cb7137e0ee05111361dfc01e">>,
        "font.woff2" =>
            <<"70823b986299629980046b2df7b6776f0eb593ba78e7cee0589e300da43b7b0f">>
    }.

caps() -> ["10000000", "4096", "20000000", "128"].

read(Data, Name) ->
    {ok, Bytes} = file:read_file(filename:join(Data, Name)),
    Bytes.

strip(Work, File) ->
    strip_bytes(Work, read(filename:dirname(File), filename:basename(File)), caps()).

%% a font's stored bytes and what the stripper says the font says of
%% itself beyond its names
said(Work, Bytes) ->
    In = filename:join(Work, "said-in"),
    Out = filename:join(Work, "said-out"),
    ok = file:write_file(In, Bytes),
    _ = os:cmd(
        lists:flatten([
            lists:join(" ", [quote(A) || A <- [os:find_executable("ike-strip") | caps()]]),
            " <",
            quote(In),
            " >",
            quote(Out)
        ])
    ),
    {ok, Answer} = file:read_file(Out),
    [Line, Rest] = binary:split(Answer, <<"\n">>),
    [<<"ok">>, _, <<"-">>, <<"-">>, L1, L2, _, L3] = binary:split(Line, <<" ">>, [global]),
    S = binary_to_integer(L1),
    T = binary_to_integer(L2),
    I = binary_to_integer(L3),
    <<Stored:S/binary, _:T/binary, Info:I/binary>> = Rest,
    {Stored, Info}.

%% what exiftool finds in a stored font: the names that say which font it
%% is (in any language), and nothing else of its own
named_only(Work, Bytes) ->
    File = filename:join(Work, "named"),
    ok = file:write_file(File, Bytes),
    [Found] = json:decode(list_to_binary(exiftool(["-j", "-G1", "-a", "-u", File]))),
    Names = [
        <<"FontFamily">>,
        <<"FontSubfamily">>,
        <<"FontName">>,
        <<"PostScriptFontName">>,
        <<"PreferredFamily">>,
        <<"PreferredSubfamily">>
    ],
    Other = [
        K
     || K := _ <- Found,
        not system(K),
        not lists:member(K, [
            <<"SourceFile">>,
            <<"ExifTool:ExifToolVersion">>,
            <<"File:FileType">>,
            <<"File:FileTypeExtension">>,
            <<"File:MIMEType">>
        ]),
        not lists:member(hd(binary:split(font_tag(K), <<"-">>)), Names)
    ],
    [] = Other,
    <<"Ike Test">> = maps:get(<<"Font:FontFamily">>, Found).

%% whether a webp says it has an alpha channel: the extended header's
%% flag for one (VP8X, bit 4)
alpha(<<"RIFF", _:32, "WEBP", "VP8X", _:32, Flags, _/binary>>) -> Flags band 16 =:= 16;
alpha(_) -> false.

font_tag(<<"Font:", Tag/binary>>) -> Tag;
font_tag(Other) -> Other.

%% ike-strip, as a unit would run it: the upload on stdin
strip_bytes(Work, Bytes, Caps) ->
    In = filename:join(Work, "in"),
    Out = filename:join(Work, "out"),
    ok = file:write_file(In, Bytes),
    Exe = os:find_executable("ike-strip"),
    true = is_list(Exe),
    _ = os:cmd(
        lists:flatten([
            lists:join(" ", [quote(A) || A <- [Exe | Caps]]), " <", quote(In), " >", quote(Out)
        ])
    ),
    {ok, Answer} = file:read_file(Out),
    [Line, Rest] = binary:split(Answer, <<"\n">>),
    case binary:split(Line, <<" ">>, [global]) of
        %% a font: no size, and what it says of itself after
        [<<"ok">>, Type, <<"-">>, <<"-">>, L1, L2, _Traits, L3] ->
            S = binary_to_integer(L1),
            T = binary_to_integer(L2),
            I = binary_to_integer(L3),
            S = byte_size(Rest) - T - I,
            <<Stored:S/binary, Thumb:T/binary, _:I/binary>> = Rest,
            {ok, Type, 0, 0, Stored, Thumb};
        [<<"ok">>, Type, W, H, L1, L2, _Traits] ->
            S = binary_to_integer(L1),
            T = binary_to_integer(L2),
            S = byte_size(Rest) - T,
            <<Stored:S/binary, Thumb:T/binary>> = Rest,
            {ok, Type, binary_to_integer(W), binary_to_integer(H), Stored, Thumb};
        [<<"no">>, Reason] ->
            <<>> = Rest,
            {no, binary_to_list(Reason)}
    end.

%% what exiftool finds in Bytes is what a bare image of its type has
bare(Work, Bytes) ->
    File = filename:join(Work, "inspect"),
    ok = file:write_file(File, Bytes),
    [Found] = json:decode(list_to_binary(exiftool(["-j", "-G1", "-a", "-u", File]))),
    Tags = [K || K := _ <- Found, not lists:member(K, [<<"SourceFile">>]), not system(K)],
    [] = Tags -- allowed(),
    [] = secrets(Bytes).

system(<<"System:", _/binary>>) -> true;
%% a colour profile is kept whole, its own tags with it
system(<<"ICC", _/binary>>) -> true;
system(_) -> false.

%% the profile exiftool finds in Bytes
profile(Work, Bytes) ->
    File = filename:join(Work, "profiled"),
    ok = file:write_file(File, Bytes),
    Out = filename:join(Work, "profile.out"),
    _ = os:cmd(
        lists:flatten([
            quote(os:find_executable("exiftool")),
            " -b -ICC_Profile ",
            quote(File),
            " >",
            quote(Out)
        ])
    ),
    read(Work, "profile.out").

%% a png's chunks, in order, as {Type, Data}
chunks(<<137, "PNG\r\n", 26, "\n", Rest/binary>>) ->
    chunks(Rest);
chunks(<<Length:32, Type:4/binary, Data:Length/binary, _Crc:32, Rest/binary>>) ->
    [{Type, Data} | chunks(Rest)];
chunks(<<>>) ->
    [].

chunk(Type, Data) ->
    <<
        (byte_size(Data)):32,
        Type/binary,
        Data/binary,
        (erlang:crc32(<<Type/binary, Data/binary>>)):32
    >>.

%% base.png as an animated png of two frames, the same image twice, and
%% a text chunk to be stripped
apng(Png) ->
    All = chunks(Png),
    [{<<"IHDR">>, Ihdr = <<W:32, H:32, _/binary>>}] = [C || {<<"IHDR">>, _} = C <- All],
    Idats = [D || {<<"IDAT">>, D} <- All],
    Frame = fun(Seq) -> <<Seq:32, W:32, H:32, 0:32, 0:32, 1:16, 10:16, 0, 0>> end,
    iolist_to_binary([
        <<137, "PNG\r\n", 26, "\n">>,
        chunk(<<"IHDR">>, Ihdr),
        chunk(<<"acTL">>, <<2:32, 0:32>>),
        chunk(<<"tEXt">>, <<"Comment", 0, "SECRET-FRAMES">>),
        chunk(<<"fcTL">>, Frame(0)),
        [chunk(<<"IDAT">>, D) || D <- Idats],
        chunk(<<"fcTL">>, Frame(1)),
        [chunk(<<"fdAT">>, <<(I + 1):32, D/binary>>) || {I, D} <- lists:enumerate(1, Idats)],
        chunk(<<"IEND">>, <<>>)
    ]).

allowed() ->
    [
        <<"Composite:ImageSize">>,
        <<"Composite:Megapixels">>,
        <<"ExifTool:ExifToolVersion">>,
        <<"File:BitsPerSample">>,
        <<"File:ColorComponents">>,
        <<"File:EncodingProcess">>,
        <<"File:FileType">>,
        <<"File:FileTypeExtension">>,
        <<"File:ImageHeight">>,
        <<"File:ImageWidth">>,
        <<"File:MIMEType">>,
        <<"File:YCbCrSubSampling">>,
        <<"JFIF:JFIFVersion">>,
        <<"JFIF:ResolutionUnit">>,
        <<"JFIF:XResolution">>,
        <<"JFIF:YResolution">>,
        <<"PNG:AnimationFrames">>,
        <<"PNG:AnimationPlays">>,
        <<"PNG:BitDepth">>,
        <<"PNG:ColorType">>,
        <<"PNG:Compression">>,
        <<"PNG:Filter">>,
        <<"PNG:ImageHeight">>,
        <<"PNG:ImageWidth">>,
        <<"PNG:ProfileName">>,
        <<"PNG:Interlace">>,
        <<"RIFF:AlphaCompression">>,
        <<"RIFF:AlphaFiltering">>,
        <<"RIFF:AlphaIsUsed">>,
        <<"RIFF:AlphaPreprocessing">>,
        <<"RIFF:HorizontalScale">>,
        <<"RIFF:ImageHeight">>,
        <<"RIFF:ImageWidth">>,
        <<"RIFF:VP8Version">>,
        <<"RIFF:VerticalScale">>,
        <<"RIFF:WebP_Flags">>
    ].

secrets(Bytes) ->
    [M || M <- [<<"SECRET">>, <<"TRAILING">>, <<"ExifTool">>], binary:match(Bytes, M) =/= nomatch].

%% every tag ffprobe finds on the container or its streams, by name
video_tags(Work, Bytes) ->
    File = filename:join(Work, "probe"),
    ok = file:write_file(File, Bytes),
    Exe = os:find_executable("ffprobe"),
    true = is_list(Exe),
    Out = os:cmd(
        lists:flatten(
            lists:join(" ", [
                quote(A)
             || A <- [
                    Exe,
                    "-v",
                    "error",
                    "-show_entries",
                    "format_tags:stream_tags",
                    "-of",
                    "json",
                    File
                ]
            ])
        )
    ),
    #{<<"format">> := Format, <<"streams">> := Streams} = json:decode(list_to_binary(Out)),
    Tags = [maps:get(<<"tags">>, S, #{}) || S <- [Format | Streams]],
    lists:usort([K || T <- Tags, K := _ <- T]).

ffmpeg(Args) ->
    Exe = os:find_executable("ffmpeg"),
    true = is_list(Exe),
    os:cmd(lists:flatten(lists:join(" ", [quote(A) || A <- [Exe | Args]]))).

exiftool(Args) ->
    Exe = os:find_executable("exiftool"),
    true = is_list(Exe),
    os:cmd(lists:flatten(lists:join(" ", [quote(A) || A <- [Exe | Args]]))).

quote(Arg) ->
    "'" ++ string:replace(Arg, "'", "'\\''", all) ++ "'".

%% what the tripwires share

%% every way out of the vm that ike's own code takes: none
outside(Config) ->
    [
        Edge
     || {_, {M, F, _}} = Edge <- ?config(calls, Config),
        lists:member({M, F}, [{erlang, open_port}, {os, cmd}, {erlang, load_nif}]) orelse
            lists:member(M, [exec, erlexec, port_command])
    ].

known_routes() ->
    [{Media, [], MediaRoutes}, {'_', [], Routes}] =
        maps:get(dispatch, maps:get(env, ranch:get_protocol_options(ike_http))),
    %% the media origin answers staged uploads and the files of shown
    %% posts, and nothing else
    [<<"media">>, <<"test">>] = lists:reverse(Media),
    ['_', [file], [<<"staged">>, upload, expires, sig], [<<"staged">>, upload, expires, sig, part]] =
        lists:sort([Path || {Path, _, _, _} <- MediaRoutes]),
    Paths = lists:sort([Path || {Path, _, _, _} <- Routes]),
    Paths = lists:sort([
        [<<"health">>],
        [],
        [<<"board">>],
        [<<"board">>, board],
        [<<"board">>, board, <<"new">>],
        [<<"board">>, board, thread],
        [<<"board">>, board, thread, <<"reply">>],
        [<<"p">>, post],
        [<<"act">>],
        [<<"booru">>],
        [<<"booru">>, booru],
        [<<"booru">>, <<"search">>],
        [<<"booru">>, booru, <<"tags">>],
        [<<"wiki">>],
        [<<"style.css">>],
        [<<"ike.js">>],
        [<<"user">>, name],
        [<<"trunk">>],
        [<<"trunk">>, meta],
        [<<"wiki">>, name],
        [<<"wiki">>, name, <<"edit">>],
        [<<"wiki">>, name, <<"history">>],
        [<<"mod">>, <<"booru">>, booru],
        [<<"mod">>, <<"meta">>, meta],
        [<<"mod">>, <<"report">>, report],
        [<<"login">>],
        [<<"login">>, <<"callback">>],
        [<<"logout">>],
        [<<"mod">>],
        [<<"mod">>, <<"post">>, post],
        [<<"mod">>, <<"board">>, board],
        [<<"mod">>, <<"account">>, account],
        [<<"upload">>],
        [<<"account">>],
        '_'
    ]).

known_tables(Config) ->
    Tables = ike_browser:query(
        Config,
        "SELECT name FROM sqlite_master WHERE type IN ('table', 'view')"
        " AND name NOT LIKE 'sqlite_%' ORDER BY name",
        []
    ),
    [
        [<<"action">>],
        [<<"actor">>],
        [<<"asset">>],
        [<<"asset_reference">>],
        [<<"blocklist">>],
        [<<"board">>],
        [<<"booru">>],
        [<<"booru_tag">>],
        [<<"booru_version">>],
        [<<"link">>],
        [<<"meta">>],
        [<<"migration">>],
        [<<"page">>],
        [<<"post">>],
        [<<"post_image">>],
        [<<"report">>],
        [<<"session">>],
        [<<"shown">>],
        [<<"shown_entry">>],
        [<<"tag">>],
        [<<"tag_change">>],
        [<<"tag_search">>],
        [<<"tag_search_config">>],
        [<<"tag_search_data">>],
        [<<"tag_search_docsize">>],
        [<<"tag_search_idx">>],
        [<<"thread">>],
        [<<"upload">>]
    ] = Tables.

%% the pages

%% posts Text as a new thread; the thread's page and the index after it
posted(Config, Session, Text) ->
    {303, Headers, _} = ike_browser:post(Config, "/board/b/new", Session, Text),
    Thread = hd(string:split(proplists:get_value("location", Headers), "#")),
    {200, _, Page} = ike_browser:request(Config, get, Thread, [], none),
    {200, _, Index} = ike_browser:request(Config, get, "/board/b", [], none),
    {Page, Index}.

%% fills in and sends the form on a page whose action is Action, the way
%% a browser without scripts would: its hidden fields, and the textarea
submit(Config, Cookies, Html, Action, Text) ->
    {match, [Form]} = re:run(
        Html,
        "<form method=\"post\" action=\"" ++ Action ++ "\"[^>]*>(.*?)</form>",
        [dotall, {capture, all_but_first, binary}]
    ),
    {match, Hidden} = re:run(
        Form,
        "<input type=\"hidden\" name=\"([^\"]+)\" value=\"([^\"]*)\"",
        [global, {capture, all_but_first, binary}]
    ),
    {match, [Area]} = re:run(Form, "<textarea[^>]* name=\"([^\"]+)\"", [
        {capture, all_but_first, binary}
    ]),
    {_, _} = binary:match(Form, <<"<button type=\"submit\">">>),
    Fields = [{N, V} || [N, V] <- Hidden] ++ [{Area, list_to_binary(Text)}],
    ike_browser:request(Config, post, Action, Cookies, {form, uri_string:compose_query(Fields)}).

%% the same for a moderator's page, which has a form per action under
%% one address: the one whose hidden kind is Kind, its reason filled in
act(Config, Cookies, Html, Action, Kind, Reason) ->
    {match, Forms} = re:run(
        Html,
        "<form method=\"post\" action=\"" ++ Action ++ "\"[^>]*>(.*?)</form>",
        [global, dotall, {capture, all_but_first, binary}]
    ),
    [Form] = [
        F
     || [F] <- Forms,
        binary:match(F, <<"name=\"kind\" value=\"", Kind/binary, "\"">>) =/= nomatch
    ],
    {match, Hidden} = re:run(
        Form,
        "<input type=\"hidden\" name=\"([^\"]+)\" value=\"([^\"]*)\"",
        [global, {capture, all_but_first, binary}]
    ),
    {match, [Field]} = re:run(Form, "<input name=\"([^\"]+)\"[^>]* required", [
        {capture, all_but_first, binary}
    ]),
    {_, _} = binary:match(Form, <<"<button type=\"submit\">">>),
    Fields = [{N, V} || [N, V] <- Hidden] ++ [{Field, unicode:characters_to_binary(Reason)}],
    ike_browser:request(Config, post, Action, Cookies, {form, uri_string:compose_query(Fields)}).

scriptless(Html) ->
    %% the one script, ike's own, from this origin, deferred; a page
    %% works without it, which is what the rest of this suite shows
    Lower = binary:replace(
        string:lowercase(Html), <<"<script src=\"/ike.js\" defer></script>">>, <<>>, [global]
    ),
    nomatch = binary:match(Lower, <<"<script">>),
    %% no script address in any tag: in text, escaped, the word runs nothing
    nomatch = re:run(Lower, "<[^>]*javascript:[^>]*>", [{capture, none}]),
    %% an attribute named on-something, inside a tag
    nomatch = re:run(Lower, "<[^>]*\\son[a-z]+\\s*=", [{capture, none}]),
    nomatch = re:run(Lower, "<(iframe|object|embed|style|svg|math)[\\s>]", [
        {capture, none}
    ]),
    %% the one stylesheet, from this origin, and no other link
    [] = [
        L
     || {match, Ls} <- [re:run(Lower, "<link[^>]*>", [global, {capture, first, binary}])],
        [L] <- Ls,
        L =/= <<"<link rel=\"stylesheet\" href=\"/style.css\">">>
    ],
    %% an image is a plain one, from the media origin
    Images =
        case re:run(Lower, "<img[^>]*>", [global, {capture, first, binary}]) of
            {match, Found} -> [I || [I] <- Found];
            nomatch -> []
        end,
    [] = [
        I
     || I <- Images,
        re:run(I, "^<img src=\"http://media\\.test/[^\"]*\" alt=\"[^\"]*\">$") =:= nomatch
    ],
    %% and a video plays from there too, with controls and nothing fetched
    %% before it is asked for
    Videos =
        case re:run(Lower, "<video[^>]*>", [global, {capture, first, binary}]) of
            {match, Vs} -> [V || [V] <- Vs];
            nomatch -> []
        end,
    [] = [
        V
     || V <- Videos,
        re:run(
            V,
            "^<video src=\"http://media\\.test/[^\"]*\" poster=\"http://media\\.test/[^\"]*\" preload=\"none\" controls>$"
        ) =:= nomatch
    ].

%% the names of a page's tags, closing ones included, in order
tags(Html) ->
    case re:run(Html, "<(/?[^\\s>]*)", [global, {capture, all_but_first, binary}]) of
        {match, Names} -> [N || [N] <- Names];
        nomatch -> []
    end.

known_tag(<<"!doctype">>) ->
    true;
known_tag(<<"!DOCTYPE">>) ->
    true;
known_tag(<<"/", Name/binary>>) ->
    known_tag(Name);
known_tag(Name) ->
    lists:member(Name, [
        <<"a">>,
        <<"article">>,
        <<"b">>,
        <<"blockquote">>,
        <<"body">>,
        <<"br">>,
        <<"button">>,
        <<"code">>,
        <<"del">>,
        <<"details">>,
        <<"footer">>,
        <<"form">>,
        <<"h1">>,
        <<"h2">>,
        <<"h3">>,
        <<"h4">>,
        <<"h5">>,
        <<"h6">>,
        <<"head">>,
        <<"i">>,
        <<"img">>,
        <<"ins">>,
        <<"header">>,
        <<"html">>,
        <<"input">>,
        <<"label">>,
        <<"li">>,
        <<"link">>,
        <<"main">>,
        <<"meta">>,
        <<"nav">>,
        <<"ol">>,
        <<"p">>,
        <<"pre">>,
        <<"s">>,
        <<"script">>,
        <<"span">>,
        <<"summary">>,
        <<"textarea">>,
        <<"time">>,
        <<"title">>,
        <<"u">>,
        <<"ul">>,
        <<"video">>
    ]).

%% the escaping, written a second time and on purpose not shared
escaped(Text) ->
    <<
        <<
            (case C of
                $& -> <<"&amp;">>;
                $< -> <<"&lt;">>;
                $> -> <<"&gt;">>;
                $" -> <<"&quot;">>;
                $' -> <<"&#39;">>;
                _ -> <<C/utf8>>
            end)/binary
        >>
     || <<C/utf8>> <= first_line(Text)
    >>.

first_line(Text) ->
    hd(binary:split(Text, <<"\n">>)).

benign($\n) -> $\n;
%% a link is a link in both, and a quote a quote ("> " at a line's
%% start), so what makes one stays
benign($>) -> $>;
benign($\s) -> $\s;
benign(C) when C >= $0, C =< $9 -> C;
benign(_) -> $x.

%% text that tries: markup, attribute breakouts, entities, comments,
%% things other escapers trip over, between ordinary words and newlines
hostile() ->
    Fragment = oneof([
        <<"<script>alert(1)</script>">>,
        <<"</article></main><script src=//x>">>,
        <<"<img src=x onerror=alert(1)>">>,
        <<"\" onmouseover=\"alert(1)">>,
        <<"' onfocus='alert(1)' autofocus='">>,
        <<"<a href=\"javascript:alert(1)\">x</a>">>,
        <<"<!-- ">>,
        <<" -->">>,
        <<"<![CDATA[">>,
        <<"]]>">>,
        <<"&lt;script&gt;">>,
        <<"&amp;&#60;&#x3c;">>,
        <<"</textarea><script>">>,
        <<"</title><svg onload=alert(1)>">>,
        <<"<<<>>>">>,
        <<"&">>,
        <<"<">>,
        <<">">>,
        <<"\"">>,
        <<"'">>,
        <<"`">>,
        <<"\\">>,
        <<"%3Cscript%3E">>,
        <<"\x{202e}"/utf8>>,
        <<"\x{feff}<\x{200b}script>"/utf8>>,
        <<"＜script＞"/utf8>>,
        <<"\t">>,
        <<"\n">>,
        <<"\n>>1\n">>,
        <<">>1">>,
        <<">>999999999">>,
        <<">>>">>,
        <<" plain words ">>,
        <<"ü ñ 語 🮲"/utf8>>
    ]),
    %% a leading word keeps it from being empty, a trailing one from being
    %% trimmed: the page has to hold it exactly
    ?LET(Parts, non_empty(list(Fragment)), iolist_to_binary([<<"t">>, Parts, <<"t">>])).

%% files and calls

files(Dir) ->
    filelib:fold_files(to_list(Dir), "", true, fun(F, Acc) -> [F | Acc] end, []).

to_list(Path) when is_binary(Path) -> binary_to_list(Path);
to_list(Path) -> Path.

wait_for(Fun, Tries) when Tries > 0 ->
    case Fun() of
        [] ->
            timer:sleep(500),
            wait_for(Fun, Tries - 1);
        Found ->
            Found
    end.

%% every call any of ike's modules makes, as {From, To} with To possibly
%% outside ike, read from the compiled modules
calls() ->
    {ok, _} = xref:start(?MODULE),
    try
        ok = xref:set_default(?MODULE, [{warnings, false}, {verbose, false}]),
        {ok, ike} = xref:add_application(?MODULE, code:lib_dir(ike)),
        {ok, Calls} = xref:q(?MODULE, "E"),
        Calls
    after
        xref:stop(?MODULE)
    end.
