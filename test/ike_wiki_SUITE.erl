%% The wiki, from outside: a page started and edited by accounts, each
%% edit on the revision it was opened on, its history as lines kept,
%% added and taken away, its discussion a thread, and [[name]] in posts.
-module(ike_wiki_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    started_and_read/1,
    edits_stack/1,
    signed_edits_are_amended/1,
    retracted_by_password/1,
    amend_reads_links_again/1,
    first_revision_retracted/1,
    pointed_at_by_name/1,
    accounts_write/1,
    names/1,
    a_hidden_revision_steps_back/1,
    missing_pages_are_asked_for/1
]).

-import(ike_browser, [login/2, login/3, request/5, query/3, cookies/1]).

all() ->
    [
        started_and_read,
        edits_stack,
        signed_edits_are_amended,
        retracted_by_password,
        amend_reads_links_again,
        first_revision_retracted,
        pointed_at_by_name,
        accounts_write,
        names,
        a_hidden_revision_steps_back,
        missing_pages_are_asked_for
    ].

init_per_suite(Config) ->
    ike_browser:start(Config, []).

end_per_suite(_Config) ->
    ike_browser:stop().

save(Config, Session, Name, Text) ->
    save(Config, Session, Name, Text, []).

%% an edit, unsigned unless Fields sign it
save(Config, #{csrf := Csrf} = Session, Name, Text, Fields) ->
    Form = uri_string:compose_query([{"csrf", Csrf}, {"body", Text} | Fields]),
    request(Config, post, "/wiki/" ++ Name ++ "/edit", cookies(Session), {form, Form}).

started_and_read(Config) ->
    Session = login(Config, <<"wikier">>),
    {404, _, Missing} = request(Config, get, "/wiki/blue_hair", cookies(Session), none),
    {_, _} = binary:match(Missing, <<"start it">>),
    {303, H, _} = save(
        Config, Session, "blue_hair", <<"hair that is blue.\nsee [[long_hair]].">>
    ),
    "/wiki/blue_hair" = proplists:get_value("location", H),
    {200, _, Page} = request(Config, get, "/wiki/blue_hair", [], none),
    {_, _} = binary:match(Page, <<"hair that is blue.">>),
    %% a name with no page and no tag links to where its page would be
    {_, _} = binary:match(
        Page, <<"<a class=\"missing\" href=\"/wiki/long_hair\">[[long_hair]]</a>">>
    ),
    %% the way to edit beside the title, and the key e for it; the
    %% revision's number leads to the history and the talk, and nothing
    %% else does
    {_, _} = binary:match(
        Page, <<"<h1>blue_hair <a class=\"edit\" href=\"/wiki/blue_hair/edit\">edit</a></h1>">>
    ),
    nomatch = binary:match(Page, <<">discussion<">>),
    nomatch = binary:match(Page, <<"/history\"">>),
    {200, _, Script} = request(Config, get, "/ike.js", [], none),
    {_, _} = binary:match(Script, <<"a.edit">>),
    {match, [Revision]} = re:run(Page, "as of <a href=\"/p/([0-9]+)\">", [
        {capture, all_but_first, list}
    ]),
    {303, Led, _} = request(Config, get, "/p/" ++ Revision, [], none),
    "/board/wiki/" ++ _ = Discussed = proplists:get_value("location", Led),
    {200, _, Discussion} = request(
        Config, get, hd(string:split(Discussed, "#")), [], none
    ),
    {_, _} = binary:match(Discussion, <<"hair that is blue.">>),
    {200, _, Index} = request(Config, get, "/wiki", [], none),
    {_, _} = binary:match(Index, <<"href=\"/wiki/blue_hair\"">>),
    %% the wiki's board starts no threads: a page does
    {404, _, _} = request(Config, get, "/board/wiki/new", cookies(Session), none).

edits_stack(Config) ->
    A = login(Config, <<"editor-a">>),
    B = login(Config, <<"editor-b">>),
    {303, _, _} = save(Config, A, "long_hair", <<"one\ntwo\nthree">>),
    %% both open the page on its first revision; the first to save is the
    %% next revision, and the other is stacked on it as it was written
    {200, _, _} = request(Config, get, "/wiki/long_hair/edit", cookies(B), none),
    {303, _, _} = save(Config, A, "long_hair", <<"one\n2\nthree\nfour">>),
    {303, _, _} = save(Config, B, "long_hair", <<"one\ntwo\nthree\nB's">>),
    {200, _, Page} = request(Config, get, "/wiki/long_hair", [], none),
    {_, _} = binary:match(Page, <<"B&#39;s">>),
    nomatch = binary:match(Page, <<"four">>),
    %% the history is the page's thread, newest first, each revision as
    %% what it changed from the one before
    {303, Away, _} = request(Config, get, "/wiki/long_hair/history", [], none),
    "/board/wiki/" ++ _ = Thread = proplists:get_value("location", Away),
    {200, _, History} = request(Config, get, Thread, [], none),
    {_, _} = binary:match(History, <<"<ol reversed>">>),
    {_, _} = binary:match(History, <<"<h1>long_hair</h1>">>),
    {_, _} = binary:match(
        History,
        <<"<details open><summary><span class=\"added\">+2</span> <span class=\"removed\">-2</span></summary>">>
    ),
    {_, _} = binary:match(
        History,
        <<"<details><summary><span class=\"added\">+2</span> <span class=\"removed\">-1</span></summary>">>
    ),
    {_, _} = binary:match(
        History, <<"<details><summary><span class=\"added\">+3</span></summary>">>
    ),
    %% each revision is named for the page and its count
    {_, _} = binary:match(History, <<"<span class=\"title\">long_hair 3</span>">>),
    {_, _} = binary:match(History, <<"<span class=\"title\">long_hair 1</span>">>),
    {_, _} = binary:match(History, <<"<del>two</del>">>),
    {_, _} = binary:match(History, <<"<ins>2</ins>">>),
    {_, _} = binary:match(History, <<"<del>four</del>">>),
    %% a revision is a post, and each its own number
    [[3]] = query(
        Config,
        "SELECT count(*) FROM post p JOIN page pg ON pg.thread = p.thread"
        " WHERE pg.name = 'long_hair' AND p.revision = 1",
        []
    ).

%% an account's edit right after its own signed revision is folded into
%% it: one revision, its change from the one before, its time the
%% newest. a post between, an unsigned edit or another account's is a
%% revision of its own
signed_edits_are_amended(Config) ->
    A = login(Config, <<"amender">>),
    B = login(Config, <<"other-amender">>),
    Signed = [{"signed", "1"}],
    Count = fun() ->
        [[N]] = query(
            Config,
            "SELECT count(*) FROM post p JOIN page pg ON pg.thread = p.thread"
            " WHERE pg.name = 'amended' AND p.revision = 1",
            []
        ),
        N
    end,
    {303, _, _} = save(Config, A, "amended", <<"one">>, Signed),
    {303, _, _} = save(Config, A, "amended", <<"one\ntwo">>, Signed),
    1 = Count(),
    {303, _, _} = save(Config, A, "amended", <<"one\ntwo\nthree">>, Signed),
    1 = Count(),
    {200, _, Page} = request(Config, get, "/wiki/amended", [], none),
    {_, _} = binary:match(Page, <<"three">>),
    {303, Away, _} = request(Config, get, "/wiki/amended/history", [], none),
    Thread = proplists:get_value("location", Away),
    {200, _, History} = request(Config, get, Thread, [], none),
    {_, _} = binary:match(
        History, <<"<details open><summary><span class=\"added\">+3</span></summary>">>
    ),
    %% another account's signed edit is its own revision, and so is the
    %% first account's after it
    {303, _, _} = save(Config, B, "amended", <<"one\ntwo\nthree\nfour">>, Signed),
    2 = Count(),
    {303, _, _} = save(Config, A, "amended", <<"one\ntwo\nthree\nfour\nfive">>, Signed),
    3 = Count(),
    %% a talk post between, and the next edit is a revision again
    {303, _, _} = ike_browser:post(Config, Thread ++ "/reply", A, <<"why five?">>),
    {303, _, _} = save(Config, A, "amended", <<"one\ntwo\nthree\nfour\n5">>, Signed),
    4 = Count(),
    %% an unsigned edit is nobody's: never folded, nor folded into
    {303, _, _} = save(Config, A, "amended", <<"6">>),
    {303, _, _} = save(Config, A, "amended", <<"7">>),
    6 = Count(),
    {303, _, _} = save(Config, A, "amended", <<"8">>, Signed),
    7 = Count().

%% an unsigned edit is retracted with its password, and the page steps
%% back to the revision under it
retracted_by_password(Config) ->
    Session = login(Config, <<"retractor">>),
    {200, _, Form} = request(Config, get, "/wiki/undone/edit", cookies(Session), none),
    {_, _} = binary:match(Form, <<"name=\"password\"">>),
    {303, _, _} = save(Config, Session, "undone", <<"kept">>),
    {303, _, _} = save(Config, Session, "undone", <<"mistaken">>, [{"password", "pw"}]),
    [[Last]] = query(
        Config,
        "SELECT max(p.id) FROM post p JOIN page pg ON pg.thread = p.thread WHERE pg.name = 'undone'",
        []
    ),
    Act = uri_string:compose_query([
        {"post", integer_to_list(Last)}, {"kind", "retract"}, {"password", "pw"}
    ]),
    {200, _, Said} = request(
        Config, post, "/act", [{"origin", ?config(base, Config)}], {form, Act}
    ),
    {_, _} = binary:match(Said, <<": retracted">>),
    {200, _, Page} = request(Config, get, "/wiki/undone", [], none),
    {_, _} = binary:match(Page, <<"kept">>),
    nomatch = binary:match(Page, <<"mistaken">>).

pointed_at_by_name(Config) ->
    Session = login(Config, <<"namer">>),
    {303, H, _} = ike_browser:post(
        Config, "/board/b/new", Session, <<"see [[short_hair]] and [[long_hair]]">>
    ),
    Thread = hd(string:split(proplists:get_value("location", H), "#")),
    {200, _, Before} = request(Config, get, Thread, [], none),
    {_, _} = binary:match(
        Before, <<"<a class=\"missing\" href=\"/wiki/short_hair\">[[short_hair]]</a>">>
    ),
    {_, _} = binary:match(Before, <<"<a href=\"/wiki/long_hair\">[[long_hair]]</a>">>),
    %% the page is started, and the post that pointed at it is made again
    {303, _, _} = save(Config, Session, "short_hair", <<"short.">>),
    {200, _, After} = request(Config, get, Thread, [], none),
    {_, _} = binary:match(After, <<"<a href=\"/wiki/short_hair\">[[short_hair]]</a>">>).

accounts_write(Config) ->
    {200, _, Form} = request(Config, get, "/wiki/anyone/edit", [], none),
    {_, _} = binary:match(Form, <<"href=\"/login\"">>),
    {403, _, _} = request(
        Config, post, "/wiki/anyone/edit", [], {form, "csrf=x&body=anything"}
    ),
    Session = login(Config, <<"tokenless">>),
    {403, _, _} = save(Config, Session#{csrf := "wrong"}, "anyone", <<"x">>),
    [[0]] = query(Config, "SELECT count(*) FROM page WHERE name = 'anyone'", []).

names(Config) ->
    Session = login(Config, <<"spacer">>),
    {303, H, _} = save(Config, Session, "Big%20Eyes", <<"eyes.">>),
    "/wiki/big_eyes" = proplists:get_value("location", H),
    [
        404 = element(1, request(Config, get, "/wiki/" ++ N, [], none))
     || N <- [".x", "..x", "a%2Fb", "%3Cb%3E"]
    ].

a_hidden_revision_steps_back(Config) ->
    Session = login(Config, <<"stepper">>),
    Moderator = login(Config, <<"wiki-mod">>, #{groups => [<<"ike-moderator">>]}),
    {303, _, _} = save(Config, Session, "steps", <<"first">>),
    {303, _, _} = save(Config, Session, "steps", <<"vandalised">>),
    [[Last]] = query(
        Config,
        "SELECT max(p.id) FROM post p JOIN page pg ON pg.thread = p.thread WHERE pg.name = 'steps'",
        []
    ),
    #{csrf := Csrf} = Moderator,
    {303, _, _} = request(
        Config,
        post,
        "/mod/post/" ++ integer_to_list(Last),
        cookies(Moderator),
        {form, uri_string:compose_query([{"csrf", Csrf}, {"kind", "hide"}, {"reason", "x"}])}
    ),
    {200, _, Page} = request(Config, get, "/wiki/steps", [], none),
    {_, _} = binary:match(Page, <<"first">>),
    nomatch = binary:match(Page, <<"vandalised">>),
    %% a revision after one out of view takes over what that one did
    {303, _, _} = save(Config, Session, "steps", <<"first\nsecond\nthird">>),
    [[Root]] = query(Config, "SELECT thread FROM page WHERE name = 'steps'", []),
    {200, _, History} = request(Config, get, "/board/wiki/" ++ integer_to_list(Root), [], none),
    {_, _} = binary:match(History, <<"<span class=\"title\">steps 2</span>">>),
    nomatch = binary:match(History, <<"steps 3">>),
    {_, _} = binary:match(
        History,
        <<"<details open><summary><span class=\"added\">+2</span></summary>">>
    ).

%% a page not yet written is a red link to where it would be, which asks
%% for it, whatever the name holds that a path would read otherwise
missing_pages_are_asked_for(Config) ->
    Session = login(Config, <<"asker">>),
    {303, H, _} = ike_browser:post(
        Config, "/board/b/new", Session, <<"[[doesn't_yet_exist]] and [[why?|ask]]">>
    ),
    Thread = hd(string:split(proplists:get_value("location", H), "#")),
    {200, _, Page} = request(Config, get, Thread, [], none),
    {_, _} = binary:match(
        Page,
        <<"<a class=\"missing\" href=\"/wiki/doesn%27t_yet_exist\">[[doesn&#39;t_yet_exist]]</a>">>
    ),
    {_, _} = binary:match(Page, <<"<a class=\"missing\" href=\"/wiki/why%3F\">ask</a>">>),
    {404, _, Asked} = request(Config, get, "/wiki/doesn%27t_yet_exist", cookies(Session), none),
    {_, _} = binary:match(Asked, <<"href=\"/wiki/doesn%27t_yet_exist/edit\">start it">>),
    {303, Made, _} = save(Config, Session, "why%3F", <<"because.">>),
    "/wiki/why%3F" = proplists:get_value("location", Made),
    {200, _, Why} = request(Config, get, "/wiki/why%3F", [], none),
    {_, _} = binary:match(Why, <<"because.">>),
    {200, _, Again} = request(Config, get, Thread, [], none),
    {_, _} = binary:match(Again, <<"<a href=\"/wiki/why%3F\">ask</a>">>).

%% a folded revision's links are read again from its new text: the post
%% it no longer points at loses the reply, the one it points at gains it
amend_reads_links_again(Config) ->
    A = login(Config, <<"relinker">>),
    Signed = [{"signed", "1"}],
    {303, H1, _} = ike_browser:post(Config, "/board/b/new", A, <<"first target">>),
    {303, H2, _} = ike_browser:post(Config, "/board/b/new", A, <<"second target">>),
    T1 = hd(string:split(proplists:get_value("location", H1), "#")),
    T2 = hd(string:split(proplists:get_value("location", H2), "#")),
    "/board/b/" ++ N1 = T1,
    "/board/b/" ++ N2 = T2,
    {303, _, _} = save(
        Config, A, "relinked", list_to_binary(">>" ++ N1 ++ " [[relink_gone]]"), Signed
    ),
    {303, _, _} = save(
        Config, A, "relinked", list_to_binary(">>" ++ N2 ++ " [[relinked]]"), Signed
    ),
    [[1]] = query(
        Config,
        "SELECT count(*) FROM post p JOIN page pg ON pg.thread = p.thread"
        " WHERE pg.name = 'relinked' AND p.revision = 1",
        []
    ),
    [[Rev]] = query(
        Config,
        "SELECT p.id FROM post p JOIN page pg ON pg.thread = p.id WHERE pg.name = 'relinked'",
        []
    ),
    Reply = list_to_binary("href=\"/p/" ++ integer_to_list(Rev) ++ "\""),
    {200, _, Old} = request(Config, get, T1, [], none),
    nomatch = binary:match(Old, Reply),
    {200, _, New} = request(Config, get, T2, [], none),
    {_, _} = binary:match(New, Reply),
    {200, _, Page} = request(Config, get, "/wiki/relinked", [], none),
    nomatch = binary:match(Page, <<"relink_gone">>),
    {_, _} = binary:match(Page, <<"<a href=\"/wiki/relinked\">[[relinked]]</a>">>).

%% the first revision is the thread's first post. retracted, it leaves a
%% titled tombstone while anything else of the thread is in view, and the
%% next revision is the page, named its first; with nothing else, the
%% thread is gone, and an edit starts the page again (lux, Q39)
first_revision_retracted(Config) ->
    A = login(Config, <<"rooter">>),
    B = login(Config, <<"rooter-b">>),
    Retract = fun(Post) ->
        Act = uri_string:compose_query([
            {"post", integer_to_list(Post)}, {"kind", "retract"}, {"password", "pw"}
        ]),
        {200, _, Said} = request(
            Config, post, "/act", [{"origin", ?config(base, Config)}], {form, Act}
        ),
        {_, _} = binary:match(Said, <<": retracted">>)
    end,
    {303, _, _} = save(Config, A, "rooted", <<"root">>, [{"password", "pw"}]),
    {303, _, _} = save(Config, B, "rooted", <<"root\nover it">>),
    [[Root]] = query(Config, "SELECT thread FROM page WHERE name = 'rooted'", []),
    Thread = "/board/wiki/" ++ integer_to_list(Root),
    Retract(Root),
    {200, _, Page} = request(Config, get, "/wiki/rooted", [], none),
    {_, _} = binary:match(Page, <<"over it">>),
    {200, _, History} = request(Config, get, Thread, [], none),
    {_, _} = binary:match(History, <<"<h1>rooted</h1>">>),
    {_, _} = binary:match(History, <<"<span class=\"gone\">taken down</span>">>),
    %% the next revision takes over what the first did
    {_, _} = binary:match(History, <<"<span class=\"title\">rooted 1</span>">>),
    {_, _} = binary:match(History, <<"<summary><span class=\"added\">+2</span></summary>">>),
    nomatch = binary:match(History, <<"rooted 2">>),
    %% a page with nothing in view after its first revision goes with it
    {303, _, _} = save(Config, A, "alone", <<"lonely">>, [{"password", "pw"}]),
    [[Alone]] = query(Config, "SELECT thread FROM page WHERE name = 'alone'", []),
    Retract(Alone),
    {404, _, _} = request(Config, get, "/wiki/alone", [], none),
    {404, _, _} = request(Config, get, "/board/wiki/" ++ integer_to_list(Alone), [], none),
    %% and is started again by an edit, under the tombstone
    {303, _, _} = save(Config, A, "alone", <<"again">>),
    {200, _, Again} = request(Config, get, "/wiki/alone", [], none),
    {_, _} = binary:match(Again, <<"again">>),
    {200, _, Started} = request(Config, get, "/board/wiki/" ++ integer_to_list(Alone), [], none),
    {_, _} = binary:match(Started, <<"<span class=\"gone\">taken down</span>">>),
    nomatch = binary:match(Started, <<"lonely">>).
