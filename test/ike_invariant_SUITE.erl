%% The eleven invariants of hazards.md, one case each, in their order.
%% Black-box: HTTP, the files ike writes, the database as a file, what it
%% logs, and the compiled modules read as data (xref); never a call into
%% ike.
%%
%% Some invariants speak of things ike does not have yet: a decoder, a
%% fetcher, staged uploads, a stripper. Their cases here are
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
    inv06_tripwire_no_decoder/1,
    inv07_tripwire_no_fetcher/1,
    inv08_purge_leaves_nothing/1,
    inv09_reachability_view_is_complete/1,
    inv10_tripwire_no_staged_uploads/1,
    inv11_tripwire_no_stripper/1
]).

all() ->
    [
        inv01_no_address_is_written,
        inv02_works_without_scripts,
        inv03_one_writer,
        inv04_text_is_escaped,
        inv05_no_user_bytes_on_the_main_origin,
        inv06_tripwire_no_decoder,
        inv07_tripwire_no_fetcher,
        inv08_purge_leaves_nothing,
        inv09_reachability_view_is_complete,
        inv10_tripwire_no_staged_uploads,
        inv11_tripwire_no_stripper
    ].

-define(LOG, ike_invariant_log).
%% addresses nobody has (rfc 5737, rfc 3849), claimed in forwarding headers
-define(V4, "203.0.113.77").
-define(V6, "2001:db8::77").
%% posts an address is let, for the limiter to count to and past
-define(POSTS, 60).

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
    Config = ike_browser:start(Config0, [{backup_seconds, 1}, {limit, Limit}]),
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
    %% and ike ships nothing a browser could run
    Shipped = files(code:priv_dir(ike)) ++ files(filename:join(?config(dir, Config), "pages")),
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
    %% place and unlinks old ones. the renderer writes pages, which are
    %% derived from the database and replaced whole by rename; it unlinks
    %% nothing (see questions.md on reading the invariant this way)
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
        {ike_writer, {file, delete}},
        {ike_writer, {file, rename}},
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
    [] = Top -- ["backups", "ike.db", "ike.db-shm", "ike.db-wal", "pages"].

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
            [] = [H || [H] <- Hrefs, re:run(H, "^[#/a-z0-9]*$", [{capture, none}]) =/= match],
            {match, Classes} = re:run(Page, "class=\"([^\"]*)\"", [
                global, {capture, all_but_first, binary}
            ]),
            [] = [
                C
             || [C] <- Classes,
                not lists:member(C, [<<"name">>, <<"name account">>, <<"name role">>, <<"gone">>])
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
            <<"<a href=\"/p/1\">>>1</a> &gt;&gt;1 >>&#49;">>
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
            "/board/b/1/reply?x=" ++ Attack
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
    {415, _, _} = ike_browser:request(
        Config, post, "/board/b/new", Cookies, {"multipart/form-data; boundary=b", Multipart}
    ),
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
    %% what is served is html or plain text, typed as such and not sniffed
    lists:foreach(
        fun(Path) ->
            {_, Headers, _} = ike_browser:request(Config, get, Path, [], none),
            Type = proplists:get_value("content-type", Headers),
            true = lists:member(hd(string:split(Type, ";")), ["text/html", "text/plain"]),
            "nosniff" = proplists:get_value("x-content-type-options", Headers)
        end,
        ["/", "/board/b/new", "/health", "/nothing"]
    ),
    %% and the tree the web server reads from holds pages, nothing else
    Pages = files(filename:join(?config(dir, Config), "pages")),
    [_ | _] = Pages,
    [] = [F || F <- Pages, filename:extension(F) =/= ".html"].

%% 6. No decoder or metadata stripper runs inside the BEAM.
%%
%% TRIPWIRE. M0 decodes nothing: there is no port, no nif of ike's own and
%% no image code to run anywhere. When the asset pipeline arrives (M1)
%% this fails, and is replaced by a test that the decoder is a sandboxed
%% process outside the vm.
inv06_tripwire_no_decoder(Config) ->
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
    ].

%% 7. The fetcher never connects to a non-public address.
%%
%% TRIPWIRE. There is no fetcher. The one module that connects out is the
%% oidc client, and only to the issuer the operator configured, never to
%% anything a user wrote. When a fetcher arrives this fails, and is
%% replaced by a test of its address checks.
inv07_tripwire_no_fetcher(Config) ->
    Connecting = [httpc, gen_tcp, gen_udp, gen_sctp, ssl, socket, inet_res, ftp, tftp, ssh],
    [ike_oidc] = lists:usort([
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
    Janitor = ike_browser:login(Config, <<"janitor8">>, #{groups => [<<"ike-janitor">>]}),
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
    %% and every file but the snapshots: the write-ahead log is folded
    %% back after a purge, and secure_delete overwrote the pages it freed
    Dir = binary_to_list(?config(dir, Config)),
    Searched = fun() ->
        [
            F
         || F <- files(Dir),
            not lists:prefix(filename:join(Dir, "backups"), F),
            holds(F, Marker)
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

%% 10. A staged upload is served to no one but its uploader.
%%
%% TRIPWIRE. Nothing can be uploaded, staged or fetched back. When staging
%% arrives (M1) this fails, and is replaced by a test with two accounts.
inv10_tripwire_no_staged_uploads(Config) ->
    Session = ike_browser:login(Config, <<"stager">>),
    lists:foreach(
        fun(Path) ->
            {404, _, _} = ike_browser:request(
                Config, get, Path, ike_browser:cookies(Session), none
            )
        end,
        ["/upload", "/uploads", "/staged", "/staged/1", "/media", "/media/1", "/a/1", "/file/1"]
    ),
    known_routes(),
    known_tables(Config).

%% 11. Stripping leaves no metadata outside the allowlist, and is
%% deterministic for a given input.
%%
%% TRIPWIRE. Nothing is stripped, since nothing is accepted. When the
%% stripper arrives (M1) this fails, and is replaced by hazard p7's
%% fixture corpus and the same-pixels-same-hash test.
inv11_tripwire_no_stripper(Config) ->
    [] = outside(Config),
    %% no asset has ever been stored
    [[0]] = ike_browser:query(Config, "SELECT count(*) FROM asset", []),
    [[0]] = ike_browser:query(Config, "SELECT count(*) FROM post WHERE asset IS NOT NULL", []),
    known_routes().

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
    [{'_', [], Routes}] = maps:get(dispatch, maps:get(env, ranch:get_protocol_options(ike_http))),
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
        [<<"login">>],
        [<<"login">>, <<"callback">>],
        [<<"logout">>],
        [<<"mod">>],
        [<<"mod">>, <<"post">>, post],
        [<<"mod">>, <<"board">>, board],
        [<<"mod">>, <<"account">>, account],
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
        [<<"board">>],
        [<<"link">>],
        [<<"migration">>],
        [<<"post">>],
        [<<"session">>],
        [<<"shown">>],
        [<<"thread">>]
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
        "<form method=\"post\" action=\"" ++ Action ++ "\">(.*?)</form>",
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

scriptless(Html) ->
    Lower = string:lowercase(Html),
    nomatch = binary:match(Lower, <<"<script">>),
    nomatch = binary:match(Lower, <<"javascript:">>),
    %% an attribute named on-something, inside a tag
    nomatch = re:run(Lower, "<[^>]*\\son[a-z]+\\s*=", [{capture, none}]),
    nomatch = re:run(Lower, "<(iframe|object|embed|link|style|img|svg|math)[\\s>]", [
        {capture, none}
    ]).

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
        <<"body">>,
        <<"br">>,
        <<"button">>,
        <<"footer">>,
        <<"form">>,
        <<"h1">>,
        <<"head">>,
        <<"header">>,
        <<"html">>,
        <<"input">>,
        <<"label">>,
        <<"li">>,
        <<"main">>,
        <<"meta">>,
        <<"nav">>,
        <<"ol">>,
        <<"p">>,
        <<"span">>,
        <<"textarea">>,
        <<"time">>,
        <<"title">>,
        <<"ul">>
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
%% a link is a link in both, so what makes one stays
benign($>) -> $>;
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
