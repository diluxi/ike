%% Uploads from a link (lux, 2026-11-18, as Danbooru's from a source):
%% an account gives a tweet's link, and the fetcher, a unit of its own,
%% brings its image, its author and its words, against a stand-in for X
%% (ike_fake_x); the image is stripped as any upload, its meta says where
%% it came from, and its card takes the words. Nobody fetches; links that
%% are no site's, or that name what is not public, bring nothing.
-module(ike_fetch_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([fetched_as_danbooru_does/1, what_is_refused/1, accounts_only/1]).

-import(ike_browser, [login/2, request/5, query/3, cookies/1]).

all() ->
    [fetched_as_danbooru_does, what_is_refused, accounts_only].

init_per_suite(Config) ->
    {ok, Png} = file:read_file(filename:join(?config(data_dir, Config), "base.png")),
    {ok, _} = application:ensure_all_started(cowboy),
    ok = ike_fake_x:start(Png),
    Socket = ike_fetch_stub:start(filename:join(?config(priv_dir, Config), "fetch"), true),
    ike_browser:start(Config, [{fetch, #{socket => Socket}}]).

end_per_suite(_Config) ->
    ike_browser:stop(),
    ike_fetch_stub:stop(),
    ike_fake_x:stop().

fetch(Config, #{csrf := Csrf} = Session, Link, Fields) ->
    request(
        Config,
        post,
        "/upload/fetch",
        cookies(Session),
        {form, uri_string:compose_query([{"csrf", Csrf}, {"link", Link} | Fields])}
    ).

fetched_as_danbooru_does(Config) ->
    Session = login(Config, <<"fetcher">>),
    {200, _, Form} = request(Config, get, "/upload", cookies(Session), none),
    {_, _} = binary:match(Form, <<"action=\"/upload/fetch\"">>),
    {303, Led, _} = fetch(Config, Session, "https://x.com/an_artist/status/1", []),
    "/trunk/" ++ _ = Meta = proplists:get_value("location", Led),
    {200, _, Page} = request(Config, get, Meta, [], none),
    Has = fun(Bit) -> {_, _} = binary:match(Page, Bit) end,
    %% its source, its artist, and their words, as Danbooru keeps them:
    %% the hashtag and the mention made links, the short link given its
    %% address back, the media's own link gone
    Has(<<"source <a class=\"out\" href=\"https://x.com/an_artist/status/1\"">>),
    Has(
        <<"artist <a class=\"out\" href=\"https://x.com/an_artist\" rel=\"nofollow noreferrer\">An Artist</a>">>
    ),
    Has(<<"a drawing <a class=\"out\" href=\"https://x.com/hashtag/oc\"">>),
    Has(<<">#oc</a> &amp; more, for <a class=\"out\" href=\"https://x.com/friend\"">>),
    Has(<<"href=\"https://example.org/more\"">>),
    nomatch = binary:match(Page, <<"t.co">>),
    %% the image is what the stripper made of it
    [[Hash]] = query(
        Config,
        "SELECT m.asset FROM meta m JOIN actor a ON a.id = m.owner WHERE a.subject = 'fetcher'",
        []
    ),
    [[<<"png">>]] = query(Config, "SELECT filetype FROM asset WHERE hash = ?", [{blob, Hash}]),
    %% and the card made of it takes the words
    #{csrf := Csrf} = Session,
    {303, Curated, _} = request(
        Config,
        post,
        Meta ++ "/curate",
        cookies(Session),
        {form, uri_string:compose_query([{"csrf", Csrf}, {"tags", "image raster oc"}])}
    ),
    {200, _, Card} = request(Config, get, proplists:get_value("location", Curated), [], none),
    {_, _} = binary:match(
        Card,
        <<"<h2>commentary</h2><p>a drawing <a class=\"out\" href=\"https://x.com/hashtag/oc\"">>
    ).

what_is_refused(Config) ->
    Session = login(Config, <<"refused-fetcher">>),
    Before = ike_fake_x:hits(),
    Refused = fun(Link) ->
        {Status, _, Page} = fetch(Config, Session, Link, []),
        {Status, Page}
    end,
    {422, NoSite} = Refused("https://example.org/a/status/1"),
    {_, _} = binary:match(NoSite, <<"unknown-site">>),
    %% media at a link-local or private address, on a host not X's, at the
    %% canary, or a redirect to it: not reached
    [
        begin
            {422, Page} = Refused("https://x.com/an_artist/status/" ++ Id),
            {_, _} = binary:match(Page, <<"not-allowed">>)
        end
     || Id <- ["2", "3", "4", "5", "6"]
    ],
    Before = ike_fake_x:hits(),
    %% nothing was kept of any of it
    [[0]] = query(
        Config,
        "SELECT count(*) FROM upload u JOIN actor a ON a.id = u.actor WHERE a.subject = 'refused-fetcher'",
        []
    ).

accounts_only(Config) ->
    {403, _, _} = request(
        Config, post, "/upload/fetch", [], {form, "csrf=x&link=https://x.com/a/status/1"}
    ),
    Session = login(Config, <<"tokenless-fetcher">>),
    {403, _, _} = fetch(Config, Session#{csrf := "wrong"}, "https://x.com/a/status/1", []).
