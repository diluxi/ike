%% Black-box: posting without an account, and how often. ike is told
%% that the loopback these requests come from is its proxy, so each
%% request says in a header where it would have come from.
-module(ike_limit_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    nobody_posts_where_it_is_open/1,
    the_form_is_this_sites/1,
    only_so_often/1,
    an_account_is_not_held_up/1,
    only_our_proxy_is_believed/1,
    a_network_is_one_address/1,
    a_board_has_a_pace/1
]).

-import(ike_browser, [login/2, post/4, request/5, query/3, anonymous/4, form/3, posts/1]).

%% three posts an address, five a board, in a stretch longer than the suite
-define(POSTS, 3).
-define(BOARD_POSTS, 5).

all() ->
    [
        nobody_posts_where_it_is_open,
        the_form_is_this_sites,
        only_so_often,
        an_account_is_not_held_up,
        only_our_proxy_is_believed,
        a_network_is_one_address,
        a_board_has_a_pace
    ].

init_per_suite(Config0) ->
    Limit = #{
        posts => ?POSTS,
        seconds => 3600,
        board_posts => ?BOARD_POSTS,
        board_seconds => 3600,
        proxies => [{127, 0, 0, 1}]
    },
    Config = ike_browser:start(Config0, [{limit, Limit}]),
    %% meta takes posts from nobody; b stays as it was made, until the
    %% last test
    ok = ike_browser:unlock(Config, <<"meta">>),
    Config.

end_per_suite(_Config) ->
    ike_browser:stop().

from(Address) ->
    [{"x-forwarded-for", Address}].

nobody_posts_where_it_is_open(Config) ->
    %% a locked board says how to log in, and takes nothing
    {200, _, Locked} = request(Config, get, "/board/b/new", from("198.51.100.1"), none),
    {_, _} = binary:match(Locked, <<"href=\"/login\"">>),
    nomatch = binary:match(Locked, <<"<form">>),
    %% an open one gives a form, and a cookie no other site can set, read
    %% or have sent along
    {Token, Cookie, Headers} = form(Config, "/board/meta/new", from("198.51.100.1")),
    true = Token =:= Cookie,
    true = length(Token) >= 43,
    Attributes = string:lowercase(ike_browser:cookie_attributes("__Host-ike-form", Headers)),
    [
        true = string:find(Attributes, A) =/= nomatch
     || A <- ["secure", "httponly", "samesite=strict", "path=/"]
    ],
    nomatch = string:find(Attributes, "domain"),
    %% a browser that has one keeps it
    {Token, none, _} = form(
        Config, "/board/meta/new", [{"cookie", "__Host-ike-form=" ++ Cookie}]
    ),
    {303, Sent, _} = anonymous(
        Config, "/board/meta/new", from("198.51.100.1"), <<"from nobody">>
    ),
    "/board/meta/" ++ Rest = proplists:get_value("location", Sent),
    {Thread, _} = string:to_integer(Rest),
    %% the post is nobody's, and a reply goes the same way
    [[<<"anonymous">>, <<"from nobody">>]] = query(
        Config,
        "SELECT a.kind, p.body FROM post p JOIN actor a ON a.id = p.actor WHERE p.id = ?",
        [Thread]
    ),
    Reply = "/board/meta/" ++ integer_to_list(Thread) ++ "/reply",
    {303, _, _} = anonymous(Config, Reply, from("198.51.100.2"), <<"and again">>),
    [[2]] = query(Config, "SELECT count(*) FROM post WHERE thread = ?", [Thread]),
    {ok, Page} = file:read_file(
        filename:join([
            ?config(dir, Config), "pages", "board", "meta", integer_to_list(Thread) ++ ".html"
        ])
    ),
    nomatch = binary:match(Page, <<"name account">>),
    %% the same form posted at a locked board is refused
    {403, _, _} = post_with(Config, "/board/b/new", from("198.51.100.3"), Token, Cookie),
    %% and what is not there is not there for nobody either
    {404, _, _} = request(Config, get, "/board/meta/999999/reply", [], none),
    {404, _, _} = post_with(
        Config, "/board/meta/999999/reply", from("198.51.100.3"), Token, Cookie
    ).

the_form_is_this_sites(Config) ->
    Before = posts(Config),
    {Token, Cookie, _} = form(Config, "/board/meta/new", []),
    Other = lists:reverse(Token),
    Body = fun(Fields) -> {form, uri_string:compose_query(Fields)} end,
    Path = "/board/meta/new",
    Refused = [
        %% another site's form: it cannot know the cookie, or cannot send it
        {from("198.51.100.10"), Body([{"csrf", Token}, {"body", "x"}])},
        {
            [{"cookie", "__Host-ike-form=" ++ Cookie} | from("198.51.100.11")],
            Body([{"body", "x"}])
        },
        {
            [{"cookie", "__Host-ike-form=" ++ Cookie} | from("198.51.100.12")],
            Body([{"csrf", Other}, {"body", "x"}])
        },
        {
            [{"cookie", "__Host-ike-form=" ++ Other} | from("198.51.100.13")],
            Body([{"csrf", Token}, {"body", "x"}])
        },
        %% a pair that matches and that ike never made
        {
            [{"cookie", "__Host-ike-form=x"} | from("198.51.100.14")],
            Body([{"csrf", "x"}, {"body", "x"}])
        },
        {
            [{"cookie", "__Host-ike-form="} | from("198.51.100.15")],
            Body([{"csrf", ""}, {"body", "x"}])
        }
    ],
    [{403, _, _} = request(Config, post, Path, Headers, Form) || {Headers, Form} <- Refused],
    %% an empty post is no post, with or without an account
    {400, _, _} = anonymous(Config, Path, from("198.51.100.16"), <<>>),
    Before = posts(Config).

only_so_often(Config) ->
    Before = posts(Config),
    Here = from("198.51.100.20"),
    Try = fun(Headers) ->
        {Status, ResponseHeaders, Page} = request(
            Config, post, "/board/b/new", Headers, {form, "body=x"}
        ),
        {Status, proplists:get_value("retry-after", ResponseHeaders), Page}
    end,
    %% every post counts, whatever becomes of it
    [{403, undefined, _} = Try(Here) || _ <- lists:seq(1, ?POSTS)],
    {429, "3600", Page} = Try(Here),
    {_, _} = binary:match(Page, <<"slow down">>),
    %% the answer says nothing of who was counted
    nomatch = binary:match(Page, <<"198.51.100">>),
    {429, _, _} = Try(Here),
    %% a good post from there fares no better
    {429, _, _} = anonymous(Config, "/board/meta/new", Here, <<"too late">>),
    %% someone else is not held up, and reading never is
    {403, undefined, _} = Try(from("198.51.100.21")),
    {200, _, _} = request(Config, get, "/board/meta/new", Here, none),
    {200, _, _} = request(Config, get, "/", Here, none),
    %% an ipv4 address written as ipv6 is the same address
    {429, _, _} = Try(from("::ffff:198.51.100.20")),
    Before = posts(Config).

an_account_is_not_held_up(Config) ->
    Session = login(Config, <<"lim">>),
    Here = from("198.51.100.30"),
    Cookies = ike_browser:cookies(Session),
    Form = fun(Csrf) ->
        {form, uri_string:compose_query([{"csrf", Csrf}, {"body", "with an account"}])}
    end,
    [
        {303, _, _} = request(
            Config, post, "/board/b/new", Cookies ++ Here, Form(maps:get(csrf, Session))
        )
     || _ <- lists:seq(1, ?POSTS + 2)
    ],
    %% but only who has one: a made-up cookie is nobody's
    {429, _, _} = request(
        Config, post, "/board/b/new", [{"cookie", "__Host-ike=made-up"} | Here], Form("x")
    ),
    {429, _, _} = request(Config, post, "/board/b/new", Here, Form("x")).

only_our_proxy_is_believed(Config) ->
    Try = fun(Forwarded) ->
        {Status, _, _} = request(
            Config, post, "/board/b/new", [{"x-forwarded-for", Forwarded}], {form, "body=x"}
        ),
        Status
    end,
    %% what the proxy wrote is the last of the list; a client can put
    %% anything before it, and it changes nothing
    [403 = Try("198.51.100.40") || _ <- lists:seq(1, ?POSTS)],
    429 = Try("198.51.100.40"),
    429 = Try("198.51.100.41, 198.51.100.40"),
    429 = Try("unknown,198.51.100.42 ,  198.51.100.40"),
    403 = Try("198.51.100.40, 198.51.100.43"),
    %% a proxy that says nothing readable speaks for one crowd
    [403 = Try(Odd) || Odd <- ["", "198.51.100.44,", "not an address"]],
    429 = Try("198.51.100.999"),
    429 = Try("198.51.100.45, _hidden"),
    429 = Try("198.51.100.46:4711").

a_network_is_one_address(Config) ->
    Try = fun(Forwarded) ->
        {Status, _, _} = request(
            Config, post, "/board/b/new", [{"x-forwarded-for", Forwarded}], {form, "body=x"}
        ),
        Status
    end,
    %% whoever has one ipv6 address has its whole /64
    403 = Try("2001:db8:1:1::a"),
    403 = Try("2001:db8:1:1:ffff:ffff:ffff:ffff"),
    403 = Try("2001:db8:1:1:1234::"),
    429 = Try("2001:db8:1:1::b"),
    429 = Try("2001:DB8:1:1::C"),
    403 = Try("2001:db8:1:2::a"),
    403 = Try("2001:db8:1::a").

%% last: it opens b
a_board_has_a_pace(Config) ->
    ok = ike_browser:unlock(Config, <<"b">>),
    Before = posts(Config),
    Address = fun(I) -> from("198.51.101." ++ integer_to_list(I)) end,
    %% from somewhere new each time, and still only so many
    [
        {303, _, _} = anonymous(Config, "/board/b/new", Address(I), <<"one of many">>)
     || I <- lists:seq(1, ?BOARD_POSTS)
    ],
    {429, Headers, Page} = anonymous(
        Config, "/board/b/new", Address(100), <<"one too many">>
    ),
    {_, _} = binary:match(Page, <<"slow down">>),
    undefined = proplists:get_value("set-cookie", Headers),
    [[N]] = Before,
    [[M]] = posts(Config),
    M = N + ?BOARD_POSTS,
    %% an account still posts there
    Session = login(Config, <<"pace">>),
    {303, _, _} = post(Config, "/board/b/new", Session, <<"with an account">>).

post_with(Config, Path, Headers, Token, Cookie) ->
    Form = uri_string:compose_query([{"csrf", Token}, {"body", "x"}]),
    request(Config, post, Path, [{"cookie", "__Host-ike-form=" ++ Cookie} | Headers], {form, Form}).
