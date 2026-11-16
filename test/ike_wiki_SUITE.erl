%% The wiki, from outside: a page started and edited by accounts, each
%% edit on the revision it was opened on, its history as lines kept,
%% added and taken away, its discussion a thread, and [[name]] in posts.
-module(ike_wiki_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    started_and_read/1,
    edited_on_its_revision/1,
    pointed_at_by_name/1,
    accounts_write/1,
    names/1,
    a_hidden_revision_steps_back/1
]).

-import(ike_browser, [login/2, login/3, request/5, query/3, cookies/1]).

all() ->
    [
        started_and_read,
        edited_on_its_revision,
        pointed_at_by_name,
        accounts_write,
        names,
        a_hidden_revision_steps_back
    ].

init_per_suite(Config) ->
    ike_browser:start(Config, []).

end_per_suite(_Config) ->
    ike_browser:stop().

%% the edit form's base, as a browser would read it
base(Config, Session, Name) ->
    {200, _, Form} = request(Config, get, "/wiki/" ++ Name ++ "/edit", cookies(Session), none),
    {match, [Base]} = re:run(Form, "name=\"base\" value=\"([^\"]+)\"", [
        {capture, all_but_first, list}
    ]),
    Base.

save(Config, #{csrf := Csrf} = Session, Name, Base, Text) ->
    Form = uri_string:compose_query([{"csrf", Csrf}, {"base", Base}, {"body", Text}]),
    request(Config, post, "/wiki/" ++ Name ++ "/edit", cookies(Session), {form, Form}).

started_and_read(Config) ->
    Session = login(Config, <<"wikier">>),
    {404, _, Missing} = request(Config, get, "/wiki/blue_hair", cookies(Session), none),
    {_, _} = binary:match(Missing, <<"start it">>),
    "none" = base(Config, Session, "blue_hair"),
    {303, H, _} = save(
        Config, Session, "blue_hair", "none", <<"hair that is blue.\nsee [[long_hair]].">>
    ),
    "/wiki/blue_hair" = proplists:get_value("location", H),
    {200, _, Page} = request(Config, get, "/wiki/blue_hair", [], none),
    {_, _} = binary:match(Page, <<"hair that is blue.">>),
    %% a name with no page and no tag is a link to nothing
    {_, _} = binary:match(Page, <<"<span class=\"gone\">[[long_hair]]</span>">>),
    {match, [Thread]} = re:run(Page, "href=\"/board/wiki/([0-9]+)\">discussion", [
        {capture, all_but_first, list}
    ]),
    {200, _, Discussion} = request(Config, get, "/board/wiki/" ++ Thread, [], none),
    {_, _} = binary:match(Discussion, <<"hair that is blue.">>),
    {200, _, Index} = request(Config, get, "/wiki", [], none),
    {_, _} = binary:match(Index, <<"href=\"/wiki/blue_hair\"">>),
    %% the wiki's board starts no threads: a page does
    {404, _, _} = request(Config, get, "/board/wiki/new", cookies(Session), none).

edited_on_its_revision(Config) ->
    A = login(Config, <<"editor-a">>),
    B = login(Config, <<"editor-b">>),
    {303, _, _} = save(Config, A, "long_hair", "none", <<"one\ntwo\nthree">>),
    BaseA = base(Config, A, "long_hair"),
    BaseB = base(Config, B, "long_hair"),
    BaseA = BaseB,
    {303, _, _} = save(Config, A, "long_hair", BaseA, <<"one\n2\nthree\nfour">>),
    %% B edited the revision A replaced: refused, shown the page as it is
    {409, _, Conflict} = save(Config, B, "long_hair", BaseB, <<"one\ntwo\nthree\nB's">>),
    {_, _} = binary:match(Conflict, <<"the page changed while you edited it">>),
    {_, _} = binary:match(Conflict, <<"four">>),
    {200, _, Page} = request(Config, get, "/wiki/long_hair", [], none),
    {_, _} = binary:match(Page, <<"four">>),
    nomatch = binary:match(Page, <<"B&#39;s">>),
    {200, _, History} = request(Config, get, "/wiki/long_hair/history", [], none),
    {_, _} = binary:match(History, <<"<del>two</del>">>),
    {_, _} = binary:match(History, <<"<ins>2</ins>">>),
    {_, _} = binary:match(History, <<"<ins>four</ins>">>),
    %% a revision is a post, and each its own number
    [[2]] = query(
        Config,
        "SELECT count(*) FROM post p JOIN page pg ON pg.thread = p.thread"
        " WHERE pg.name = 'long_hair' AND p.revision = 1",
        []
    ).

pointed_at_by_name(Config) ->
    Session = login(Config, <<"namer">>),
    {303, H, _} = ike_browser:post(
        Config, "/board/b/new", Session, <<"see [[short_hair]] and [[long_hair]]">>
    ),
    Thread = hd(string:split(proplists:get_value("location", H), "#")),
    {200, _, Before} = request(Config, get, Thread, [], none),
    {_, _} = binary:match(Before, <<"<span class=\"gone\">[[short_hair]]</span>">>),
    {_, _} = binary:match(Before, <<"<a href=\"/wiki/long_hair\">[[long_hair]]</a>">>),
    %% the page is started, and the post that pointed at it is made again
    {303, _, _} = save(Config, Session, "short_hair", "none", <<"short.">>),
    {200, _, After} = request(Config, get, Thread, [], none),
    {_, _} = binary:match(After, <<"<a href=\"/wiki/short_hair\">[[short_hair]]</a>">>).

accounts_write(Config) ->
    {200, _, Form} = request(Config, get, "/wiki/anyone/edit", [], none),
    {_, _} = binary:match(Form, <<"href=\"/login\"">>),
    {403, _, _} = request(
        Config, post, "/wiki/anyone/edit", [], {form, "csrf=x&base=none&body=anything"}
    ),
    Session = login(Config, <<"tokenless">>),
    {403, _, _} = save(Config, Session#{csrf := "wrong"}, "anyone", "none", <<"x">>),
    [[0]] = query(Config, "SELECT count(*) FROM page WHERE name = 'anyone'", []).

names(Config) ->
    Session = login(Config, <<"spacer">>),
    {303, H, _} = save(Config, Session, "Big%20Eyes", "none", <<"eyes.">>),
    "/wiki/big_eyes" = proplists:get_value("location", H),
    [
        404 = element(1, request(Config, get, "/wiki/" ++ N, [], none))
     || N <- [".x", "..x", "a%2Fb", "%3Cb%3E"]
    ].

a_hidden_revision_steps_back(Config) ->
    Session = login(Config, <<"stepper">>),
    Moderator = login(Config, <<"wiki-mod">>, #{groups => [<<"ike-moderator">>]}),
    {303, _, _} = save(Config, Session, "steps", "none", <<"first">>),
    {303, _, _} = save(Config, Session, "steps", base(Config, Session, "steps"), <<"vandalised">>),
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
    nomatch = binary:match(Page, <<"vandalised">>).
