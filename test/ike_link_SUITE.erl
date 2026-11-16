%% Black-box: links between posts, as a browser and the files see them.
-module(ike_link_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    a_link_and_its_reverse/1,
    across_threads_and_boards/1,
    a_link_waits_for_its_target/1,
    what_is_not_a_link/1,
    only_so_many_links/1,
    where_a_post_is/1,
    marked_up/1
]).

-import(ike_browser, [login/2, post/4, request/5, query/3]).

all() ->
    [
        a_link_and_its_reverse,
        across_threads_and_boards,
        a_link_waits_for_its_target,
        what_is_not_a_link,
        only_so_many_links,
        where_a_post_is,
        marked_up
    ].

init_per_suite(Config) ->
    ike_browser:start(Config, []).

end_per_suite(_Config) ->
    ike_browser:stop().

a_link_and_its_reverse(Config) ->
    Session = login(Config, <<"lin">>),
    {Op, Op} = new(Config, Session, "b", <<"something to point at">>),
    N = integer_to_binary(Op),
    {Op, Reply} = reply(
        Config, Session, "b", Op, <<"see >>", N/binary, ", and >>", N/binary, " again">>
    ),
    R = integer_to_binary(Reply),
    %% one row however often it is said
    [[Reply, Op]] = query(Config, "SELECT source, post FROM link WHERE source = ?", [Reply]),
    ok = until(fun() ->
        [_, First, Second] = articles(page(Config, "b", Op)),
        Link = <<"<a href=\"/p/", N/binary, "\">&gt;&gt;", N/binary, "</a>">>,
        Back = <<"<footer><a href=\"/p/", R/binary, "\">&gt;&gt;", R/binary, "</a></footer>">>,
        length(binary:matches(Second, Link)) =:= 2 andalso
            binary:match(First, Back) =/= nomatch andalso
            binary:match(Second, <<"<footer>">>) =:= nomatch
    end).

across_threads_and_boards(Config) ->
    Session = login(Config, <<"lin">>),
    {There, There} = new(Config, Session, "meta", <<"over on meta">>),
    T = integer_to_binary(There),
    Text = <<">>>/meta/", T/binary, " is there\n>>>/b/", T/binary, " is not\n>>", T/binary, " is">>,
    {Here, Here} = new(Config, Session, "b", Text),
    H = integer_to_binary(Here),
    ok = until(fun() ->
        Page = page(Config, "b", Here),
        Right = <<"<a href=\"/p/", T/binary, "\">&gt;&gt;&gt;/meta/", T/binary, "</a>">>,
        Wrong = <<"<span class=\"gone\">&gt;&gt;&gt;/b/", T/binary, "</span>">>,
        Plain = <<"<a href=\"/p/", T/binary, "\">&gt;&gt;", T/binary, "</a>">>,
        lists:all(fun(X) -> binary:match(Page, X) =/= nomatch end, [Right, Wrong, Plain])
    end),
    %% and the page it points at is made again to say so
    ok = until(fun() ->
        Back = <<"<footer><a href=\"/p/", H/binary, "\">&gt;&gt;", H/binary, "</a></footer>">>,
        binary:match(page(Config, "meta", There), Back) =/= nomatch
    end).

%% a link to a post that is not there says so, the same way whatever the
%% reason, and becomes a link when the post is
a_link_waits_for_its_target(Config) ->
    Session = login(Config, <<"lin">>),
    [[Last]] = query(Config, "SELECT max(id) FROM post", []),
    Next = Last + 2,
    X = integer_to_binary(Next),
    {Early, Early} = new(Config, Session, "b", <<"first! >>", X/binary>>),
    Early = Last + 1,
    Gone = <<"<span class=\"gone\">&gt;&gt;", X/binary, "</span>">>,
    {_, _} = binary:match(page(Config, "b", Early), Gone),
    {404, _, _} = request(Config, get, "/p/" ++ integer_to_list(Next), [], none),
    {Next, Next} = new(Config, Session, "meta", <<"here it is">>),
    ok = until(fun() ->
        Page = page(Config, "b", Early),
        binary:match(Page, Gone) =:= nomatch andalso
            binary:match(Page, <<"<a href=\"/p/", X/binary, "\">&gt;&gt;", X/binary, "</a>">>) =/=
                nomatch
    end).

what_is_not_a_link(Config) ->
    Session = login(Config, <<"lin">>),
    Text = <<
        ">>0 >>01 >> 1 >>-1 >>x >>1234567890123456789 > >1\n"
        ">>>/B/1 >>>/b 1 >>>/b/ >>>/b/0 >>>//1 >>>/../1 >>>/abcdefghijklmnopq/1 >>>1x"
    >>,
    {Op, Op} = new(Config, Session, "b", Text),
    [_, Article] = articles(page(Config, "b", Op)),
    [_, Rest] = binary:split(Article, <<"</header>">>),
    [Whole, _] = binary:split(Rest, <<"</article>">>),
    %% the text, without what is folded away under it
    [Body | _] = binary:split(Whole, <<"<details>">>),
    %% but for the last, where a link starts at the second of three
    [[Op, 1]] = query(Config, "SELECT source, post FROM link WHERE source = ?", [Op]),
    [_] = binary:matches(Body, <<"<a ">>),
    {_, _} = binary:match(Body, <<"&gt;<a href=\"/p/1\">&gt;&gt;1</a>x">>),
    nomatch = binary:match(Body, <<"<span">>).

only_so_many_links(Config) ->
    Session = login(Config, <<"lin">>),
    Text = iolist_to_binary([[">>", integer_to_list(900000 + I), " "] || I <- lists:seq(1, 40)]),
    {Op, Op} = new(Config, Session, "b", Text),
    [[32]] = query(Config, "SELECT count(*) FROM link WHERE source = ?", [Op]),
    [_, Article] = articles(page(Config, "b", Op)),
    32 = length(binary:matches(Article, <<"<span class=\"gone\">">>)),
    {_, _} = binary:match(Article, <<" &gt;&gt;900040">>),
    nomatch = binary:match(Article, <<"<span class=\"gone\">&gt;&gt;900033">>).

where_a_post_is(Config) ->
    Session = login(Config, <<"lin">>),
    {Op, Op} = new(Config, Session, "meta", <<"an op">>),
    {Op, Reply} = reply(Config, Session, "meta", Op, <<"a reply">>),
    Thread = "/board/meta/" ++ integer_to_list(Op),
    {303, H1, <<>>} = request(Config, get, "/p/" ++ integer_to_list(Op), [], none),
    {303, H2, <<>>} = request(Config, get, "/p/" ++ integer_to_list(Reply), [], none),
    true = Thread ++ "#p" ++ integer_to_list(Op) =:= proplists:get_value("location", H1),
    true = Thread ++ "#p" ++ integer_to_list(Reply) =:= proplists:get_value("location", H2),
    Posts = ike_browser:posts(Config),
    lists:foreach(
        fun(Path) -> {404, _, _} = request(Config, get, Path, [], none) end,
        [
            "/p/0",
            "/p/-1",
            "/p/999999999",
            "/p/x",
            "/p/",
            "/p",
            "/p/1/2",
            "/p/99999999999999999999999"
        ]
    ),
    {404, _, _} = request(
        Config, post, "/p/" ++ integer_to_list(Op), ike_browser:cookies(Session), {form, "x=1"}
    ),
    Posts = ike_browser:posts(Config).

%% a new thread, or a reply: the thread and the post, by their numbers
new(Config, Session, Board, Text) ->
    sent(post(Config, "/board/" ++ Board ++ "/new", Session, Text), Board).

reply(Config, Session, Board, Thread, Text) ->
    Path = "/board/" ++ Board ++ "/" ++ integer_to_list(Thread) ++ "/reply",
    sent(post(Config, Path, Session, Text), Board).

sent({303, Headers, _}, Board) ->
    Rest = proplists:get_value("location", Headers) -- ("/board/" ++ Board ++ "/"),
    {Thread, "#p" ++ Post} = string:to_integer(Rest),
    {Thread, list_to_integer(Post)}.

page(Config, Board, Thread) ->
    File = filename:join([
        ?config(dir, Config), "pages", "board", Board, integer_to_list(Thread) ++ ".html"
    ]),
    {ok, Page} = file:read_file(File),
    Page.

articles(Page) ->
    binary:split(Page, <<"<article">>, [global]).

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

%% DText's subset: what each mark makes, and what is left as typed
marked_up(Config) ->
    Session = login(Config, <<"marker">>),
    Text = <<
        "h4. Clients\n"
        "* [b]Gajim[/b] and [i]Dino[/i]\n"
        "* [s]Pidgin[/s] [u]u[/u] [spoiler]end[/spoiler] [code]<x>[/code]\n"
        "\n"
        "\"XMPP\":[https://xmpp.org/about] and https://example.org/a.\n"
        "{{blue_hair -x}} [[xmpp|the page]] [b]never closed\n"
        "[quote]\nsaid [i]so[/i]\n[/quote]\n"
        "[code]\nlet x = <y>;\n[/code]"
    >>,
    {Op, Op} = new(Config, Session, "b", Text),
    [_, Article] = articles(page(Config, "b", Op)),
    Has = fun(Bit) -> {_, _} = binary:match(Article, Bit) end,
    Has(<<"<h5>Clients</h5>">>),
    Has(
        <<"<ul><li><b>Gajim</b> and <i>Dino</i></li><li><s>Pidgin</s> <u>u</u> <span class=\"spoiler\">end</span> <code>&lt;x&gt;</code></li></ul>">>
    ),
    Has(<<"<a href=\"https://xmpp.org/about\" rel=\"nofollow noreferrer\">XMPP</a>">>),
    Has(
        <<"<a href=\"https://example.org/a\" rel=\"nofollow noreferrer\">https://example.org/a</a>.">>
    ),
    Has(<<"<a href=\"/booru/search?tags=blue_hair%20-x\">{{blue_hair -x}}</a>">>),
    Has(<<"<a class=\"missing\" href=\"/wiki/xmpp\">the page</a>">>),
    Has(<<"[b]never closed">>),
    Has(<<"<blockquote><p>said <i>so</i></p></blockquote>">>),
    Has(<<"<pre><code>let x = &lt;y&gt;;</code></pre>">>).
