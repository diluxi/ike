%% The booru, from outside, with booru_at_once on (lux, 2026-11-17: off
%% unless asked; a tack makes a meta, and curation makes entries, which
%% ike_curate_SUITE tests): an entry for every posted image, one for the
%% same bytes however often posted, its page and the booru's, ##N in
%% posts with its reverse, a gap where a version was purged, and entries
%% made for images posted before there was a booru.
-module(ike_booru_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    every_image_is_an_entry/1,
    one_entry_for_one_image/1,
    pointed_at_with_hashes/1,
    a_purged_image_leaves_a_gap/1,
    entries_for_older_images/1,
    tagged_and_found/1,
    tags_by_what_it_is/1
]).

-import(ike_browser, [login/2, login/3, request/5, query/3, cookies/1, upload/3]).

all() ->
    [
        every_image_is_an_entry,
        one_entry_for_one_image,
        pointed_at_with_hashes,
        a_purged_image_leaves_a_gap,
        entries_for_older_images,
        tagged_and_found,
        tags_by_what_it_is
    ].

init_per_suite(Config) ->
    ike_browser:start(Config, [{booru_at_once, true}]).

end_per_suite(_Config) ->
    ike_browser:stop().

read(Config, Name) ->
    {ok, Bytes} = file:read_file(filename:join(?config(data_dir, Config), Name)),
    Bytes.

%% posts an image as Subject's account would, unsigned; the post's number
posted(Config, Session, Subject, File, Text) ->
    {303, _, _} = upload(Config, Session, [{<<"x">>, read(Config, File)}]),
    [[U]] = query(
        Config,
        "SELECT max(u.id) FROM upload u JOIN actor a ON a.id = u.actor"
        " WHERE a.subject = ? AND u.posted IS NULL",
        [Subject]
    ),
    {303, H, _} = ike_browser:post(
        Config, "/board/b/new", Session, Text, [{<<"upload">>, integer_to_binary(U)}]
    ),
    "#p" ++ N = string:find(proplists:get_value("location", H), "#"),
    list_to_integer(N).

entry_of(Config, Post) ->
    [[E]] = query(
        Config,
        "SELECT v.booru FROM post_image pi JOIN booru_version v ON v.asset = pi.asset"
        " WHERE pi.post = ?",
        [Post]
    ),
    E.

every_image_is_an_entry(Config) ->
    Session = login(Config, <<"booruposter">>),
    Post = posted(Config, Session, <<"booruposter">>, "base.png", <<"to the booru">>),
    E = integer_to_list(entry_of(Config, Post)),
    {200, _, Page} = request(Config, get, "/booru/" ++ E, [], none),
    {_, _} = binary:match(Page, list_to_binary("<h1>card:" ++ E ++ "</h1>")),
    %% the image, where it is shown, and nothing of who brought it
    {_, _} = binary:match(Page, <<"<img src=\"http://media.test/">>),
    {_, _} = binary:match(Page, list_to_binary("href=\"/p/" ++ integer_to_list(Post) ++ "\"")),
    nomatch = binary:match(Page, <<"booruposter">>),
    {200, _, Index} = request(Config, get, "/booru", [], none),
    {_, _} = binary:match(Index, list_to_binary("href=\"/booru/" ++ E ++ "\"")),
    {200, _, Front} = request(Config, get, "/", [], none),
    {_, _} = binary:match(Front, <<"href=\"/booru\"">>).

one_entry_for_one_image(Config) ->
    A = login(Config, <<"booru-a">>),
    B = login(Config, <<"booru-b">>),
    P1 = posted(Config, A, <<"booru-a">>, "base.jpg", <<"one">>),
    P2 = posted(Config, B, <<"booru-b">>, "base.jpg", <<"two">>),
    E = entry_of(Config, P1),
    E = entry_of(Config, P2),
    {200, _, Page} = request(Config, get, "/booru/" ++ integer_to_list(E), [], none),
    [{_, _}, {_, _}] = [
        binary:match(Page, list_to_binary("href=\"/p/" ++ integer_to_list(P) ++ "\""))
     || P <- [P1, P2]
    ].

pointed_at_with_hashes(Config) ->
    Session = login(Config, <<"hasher">>),
    Post = posted(Config, Session, <<"hasher">>, "lossy.webp", <<"pointed at">>),
    E = integer_to_list(entry_of(Config, Post)),
    {303, H, _} = ike_browser:post(
        Config, "/board/b/new", Session, list_to_binary("see ##" ++ E ++ " and ##999999")
    ),
    "#p" ++ Pointer = string:find(proplists:get_value("location", H), "#"),
    {200, _, Thread} = request(
        Config, get, hd(string:split(proplists:get_value("location", H), "#")), [], none
    ),
    {_, _} = binary:match(
        Thread, list_to_binary("<a href=\"/booru/" ++ E ++ "\">##" ++ E ++ "</a>")
    ),
    %% to nothing: the words of every other link to nothing
    {_, _} = binary:match(Thread, <<"<span class=\"gone\">##999999</span>">>),
    {200, _, Page} = request(Config, get, "/booru/" ++ E, [], none),
    {_, _} = binary:match(Page, list_to_binary("href=\"/p/" ++ Pointer ++ "\"")),
    %% an entry hidden, the link to it is gone too
    Moderator = login(Config, <<"booru-mod">>, #{groups => [<<"ike-moderator">>]}),
    #{csrf := Csrf} = Moderator,
    {303, _, _} = request(
        Config,
        post,
        "/mod/booru/" ++ E,
        cookies(Moderator),
        {form, uri_string:compose_query([{"csrf", Csrf}, {"kind", "hide"}, {"reason", "x"}])}
    ),
    {200, _, After} = request(
        Config, get, hd(string:split(proplists:get_value("location", H), "#")), [], none
    ),
    {_, _} = binary:match(After, list_to_binary("<span class=\"gone\">##" ++ E ++ "</span>")),
    %% logged, as "hide ##N"
    [[1]] = query(Config, "SELECT count(*) FROM action WHERE booru = ? AND kind = 'hide'", [
        list_to_integer(E)
    ]),
    %% a janitor of a board keeps no entry; one of /booru/ does
    Janitor = login(Config, <<"booru-jan-b">>, #{groups => [<<"ike-janitor-b">>]}),
    {200, _, NoForms} = request(Config, get, "/mod/booru/" ++ E, cookies(Janitor), none),
    nomatch = binary:match(NoForms, <<"value=\"unhide\"">>),
    Keeper = login(Config, <<"booru-jan">>, #{groups => [<<"ike-janitor-booru">>]}),
    {200, _, Forms} = request(Config, get, "/mod/booru/" ++ E, cookies(Keeper), none),
    {_, _} = binary:match(Forms, <<"value=\"unhide\"">>).

a_purged_image_leaves_a_gap(Config) ->
    Session = login(Config, <<"gapper">>),
    Admin = login(Config, <<"booru-admin">>, #{groups => [<<"ike-admin">>]}),
    Post = posted(Config, Session, <<"gapper">>, "lossless.webp", <<"gap">>),
    E = integer_to_list(entry_of(Config, Post)),
    #{csrf := Csrf} = Admin,
    {303, _, _} = request(
        Config,
        post,
        "/mod/post/" ++ integer_to_list(Post),
        cookies(Admin),
        {form,
            uri_string:compose_query([
                {"csrf", Csrf}, {"kind", "purge_image"}, {"image", "0"}, {"reason", "x"}
            ])}
    ),
    [[undefined]] = query(Config, "SELECT asset FROM booru_version WHERE booru = ?", [
        list_to_integer(E)
    ]),
    {200, _, Page} = request(Config, get, "/booru/" ++ E, [], none),
    {_, _} = binary:match(Page, <<"1: purged">>),
    {_, _} = binary:match(Page, <<"<span class=\"gone\">image</span>">>).

%% images posted before the booru, as on a database migrated from then:
%% their entries are made at start, in the order they were posted
entries_for_older_images(Config) ->
    Session = login(Config, <<"older">>),
    Post = posted(Config, Session, <<"older">>, "base.png", <<"older">>),
    %% base.png has an entry already; take it away as a database from
    %% before the booru would not have had it
    E = entry_of(Config, Post),
    [] = query(Config, "DELETE FROM booru_version WHERE booru = ?", [E]),
    [] = query(Config, "DELETE FROM action WHERE booru = ?", [E]),
    [] = query(Config, "DELETE FROM booru WHERE id = ?", [E]),
    ok = ike_browser:restart(),
    New = entry_of(Config, Post),
    true = New > E,
    %% (pages are made after a start, one at a time)
    200 = eventually(
        fun() ->
            element(1, request(Config, get, "/booru/" ++ integer_to_list(New), [], none))
        end,
        50
    ),
    404 = element(1, request(Config, get, "/booru/" ++ integer_to_list(E), [], none)).

eventually(Fun, 0) ->
    Fun();
eventually(Fun, N) ->
    case Fun() of
        200 ->
            200;
        _ ->
            timer:sleep(100),
            eventually(Fun, N - 1)
    end.

tag(Config, Headers, E, Words) ->
    element(
        1,
        request(
            Config,
            post,
            "/booru/" ++ E ++ "/tags",
            Headers,
            {form, uri_string:compose_query([{"tags", Words}])}
        )
    ).

search(Config, Query) ->
    {200, _, Page} = request(
        Config, get, "/booru/search?" ++ uri_string:compose_query([{"tags", Query}]), [], none
    ),
    Page.

tagged_and_found(Config) ->
    Session = login(Config, <<"tagger">>),
    Here = [{"origin", ?config(base, Config)}],
    P1 = posted(Config, Session, <<"tagger">>, "base.jpg", <<"one">>),
    P2 = posted(Config, Session, <<"tagger">>, "base.png", <<"two">>),
    E1 = integer_to_list(entry_of(Config, P1)),
    E2 = integer_to_list(entry_of(Config, P2)),
    %% an account, from this site, sends the whole box (lux): what it names
    %% is what the entry has. names are lowercased, what is no name is
    %% dropped
    303 = tag(
        Config, cookies(Session) ++ Here, E1, "image raster\nBlue_Hair long_hair rating:s <b> x\"y"
    ),
    303 = tag(Config, cookies(Session) ++ Here, E2, "image raster\nblue_eyes long_hair"),
    %% (beside what it is: image, raster)
    [[<<"blue_hair">>], [<<"image">>], [<<"long_hair">>], [<<"raster">>], [<<"rating:s">>]] = query(
        Config,
        "SELECT t.name FROM booru_tag bt JOIN tag t ON t.id = bt.tag WHERE bt.booru = ? ORDER BY 1",
        [list_to_integer(E1)]
    ),
    %% nobody, or from elsewhere, tags nothing
    403 = tag(Config, Here, E1, "nobody_tag"),
    403 = tag(Config, cookies(Session), E1, "no_origin"),
    [[0]] = query(Config, "SELECT count(*) FROM tag WHERE name IN ('nobody_tag', 'no_origin')", []),
    %% the entry's page lists them, linked to a search, and what changed,
    %% as a revision in its thread (unsigned: no name)
    {200, _, Page} = request(Config, get, "/booru/" ++ E1, [], none),
    {_, _} = binary:match(Page, <<"href=\"/booru/search?tags=blue_hair\"">>),
    {_, _} = binary:match(
        Page, <<"<ins><a href=\"/booru/search?tags=rating:s\">rating:s</a></ins>">>
    ),
    nomatch = binary:match(Page, <<"tagger">>),
    %% the history keeps who
    [[_Actor]] = query(Config, "SELECT actor FROM tag_change WHERE booru = ? LIMIT 1", [
        list_to_integer(E1)
    ]),
    %% search: every name, none of the minus, a name by its start
    Has = fun(Page1, E) ->
        binary:match(Page1, list_to_binary("href=\"/booru/" ++ E ++ "\"")) =/= nomatch
    end,
    S1 = search(Config, "long_hair"),
    {true, true} = {Has(S1, E1), Has(S1, E2)},
    S2 = search(Config, "long_hair -blue_eyes"),
    {true, false} = {Has(S2, E1), Has(S2, E2)},
    S3 = search(Config, "blue*"),
    {true, true} = {Has(S3, E1), Has(S3, E2)},
    S4 = search(Config, "blue_e*"),
    {false, true} = {Has(S4, E1), Has(S4, E2)},
    S5 = search(Config, "rating:s long_hair"),
    {true, false} = {Has(S5, E1), Has(S5, E2)},
    %% taken off
    303 = tag(
        Config,
        cookies(Session) ++ Here,
        E1,
        "image raster\nblue_hair long_hair rating:s -long_hair"
    ),
    S6 = search(Config, "long_hair"),
    {false, true} = {Has(S6, E1), Has(S6, E2)}.

%% what an entry is, it is tagged as: no one tagged it, nothing tags an
%% absence, and a search can tell a silent video from one with sound
tags_by_what_it_is(Config) ->
    Session = login(Config, <<"inherent">>),
    Png = posted(Config, Session, <<"inherent">>, "base.png", <<"still">>),
    Webm = posted(Config, Session, <<"inherent">>, "base.webm", <<"moving">>),
    Tags = fun(Post) ->
        [
            T
         || [T] <- query(
                Config,
                "SELECT t.name FROM booru_version v JOIN booru_tag bt ON bt.booru = v.booru"
                " JOIN tag t ON t.id = bt.tag JOIN post_image pi ON pi.asset = v.asset"
                " WHERE pi.post = ? ORDER BY 1",
                [Post]
            )
        ]
    end,
    true = [<<"image">>, <<"raster">>] -- Tags(Png) =:= [],
    [] =
        [<<"video">>, <<"audio">>, <<"animation">>] --
            ([<<"video">>, <<"audio">>, <<"animation">>] -- Tags(Png)) -- [],
    [<<"audio">>, <<"video">>] = [
        T
     || T <- Tags(Webm), lists:member(T, [<<"audio">>, <<"video">>, <<"image">>])
    ],
    E = integer_to_list(entry_of(Config, Webm)),
    Has = fun(Page, X) ->
        binary:match(Page, list_to_binary("href=\"/booru/" ++ X ++ "\"")) =/= nomatch
    end,
    true = Has(search(Config, "video audio"), E),
    false = Has(search(Config, "video -audio"), E),
    [[0]] = query(Config, "SELECT count(*) FROM tag_change WHERE booru = ?", [list_to_integer(E)]).
