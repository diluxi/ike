%% Curation, from outside (lux, 2026-11-17): a tack makes a meta and no
%% entry; an account tags a public meta on its page and posts it to the
%% booru, which makes it a curation, to which the meta then leads; the
%% meta's comment thread is the curation's, with each change to its tags
%% and commentary a revision between the comments, signed or not, an
%% account's next one folded into its own; the trunk marks what is
%% curated; and the trunk's threads have no pages of their own.
-module(ike_curate_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    tacks_make_metas/1,
    curated_from_its_meta/1,
    comments_go_with_it/1,
    revised_and_amended/1,
    commentary_is_ikext/1,
    the_front_page/1,
    nobody_comments_when_let/1,
    comments_retract_by_password/1,
    only_public_metas/1
]).

-import(ike_browser, [login/2, login/3, request/5, query/3, cookies/1]).

all() ->
    [
        tacks_make_metas,
        curated_from_its_meta,
        comments_go_with_it,
        revised_and_amended,
        commentary_is_ikext,
        the_front_page,
        nobody_comments_when_let,
        comments_retract_by_password,
        only_public_metas
    ].

init_per_suite(Config) ->
    ike_browser:start(Config, []).

end_per_suite(_Config) ->
    ike_browser:stop().

%% a png of W by H pixels, its bytes made from Seed: no other case's
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

%% the meta of the newest upload of the account called Subject
meta(Config, Subject) ->
    [[Id]] = query(
        Config,
        "SELECT m.id FROM upload u JOIN actor a ON a.id = u.actor JOIN meta m ON m.asset = u.asset"
        " WHERE a.subject = ? ORDER BY u.id DESC, m.owner = u.actor DESC LIMIT 1",
        [Subject]
    ),
    "/trunk/" ++ integer_to_list(Id).

uploaded(Config, Session, Bytes, Fields) ->
    #{csrf := Csrf} = Session,
    {Type, Body} = ike_browser:multipart(
        [{field, <<"csrf">>, list_to_binary(Csrf)}] ++
            [{field, list_to_binary(F), <<"1">>} || F <- Fields] ++
            [{file, <<"file">>, {<<"x.png">>, Bytes}}]
    ),
    {303, _, _} = request(Config, post, "/upload", cookies(Session), {Type, Body}).

form(Config, #{csrf := Csrf} = Session, Path, Fields) ->
    request(
        Config,
        post,
        Path,
        cookies(Session),
        {form, uri_string:compose_query([{"csrf", Csrf} | Fields])}
    ).

%% the curation form on an entry's page, from this site
revise(Config, Session, Entry, Fields) ->
    #{csrf := _} = Session,
    request(
        Config,
        post,
        Entry ++ "/tags",
        cookies(Session) ++ [{"origin", ?config(base, Config)}],
        {form, uri_string:compose_query(Fields)}
    ).

curate(Config, Session, Meta, Tags, Fields) ->
    {303, H, _} = form(Config, Session, Meta ++ "/curate", [{"tags", Tags} | Fields]),
    "/booru/" ++ _ = proplists:get_value("location", H).

tacks_make_metas(Config) ->
    Session = login(Config, <<"tacker">>),
    #{csrf := Csrf} = Session,
    {Type, Body} = ike_browser:multipart([
        {field, <<"csrf">>, list_to_binary(Csrf)},
        {field, <<"body">>, <<"a tack">>},
        {file, <<"file">>, {<<"t.png">>, png(3, 2, 31)}}
    ]),
    {303, _, _} = request(Config, post, "/board/b/new", cookies(Session), {Type, Body}),
    Meta = meta(Config, <<"tacker">>),
    {200, _, Page} = request(Config, get, Meta, cookies(Session), none),
    {_, _} = binary:match(Page, <<"post to the booru">>),
    [[0]] = query(Config, "SELECT count(*) FROM booru", []),
    %% the trunk is no board, and has no thread pages of its own
    {200, _, Boards} = request(Config, get, "/board", [], none),
    nomatch = binary:match(Boards, <<"/board/trunk">>),
    {303, To, _} = request(Config, get, "/board/trunk", [], none),
    "/trunk" = proplists:get_value("location", To).

curated_from_its_meta(Config) ->
    Owner = login(Config, <<"meta-owner">>),
    Curator = login(Config, <<"curator">>),
    uploaded(Config, Owner, png(3, 3, 37), ["signed"]),
    Meta = meta(Config, <<"meta-owner">>),
    %% any account curates a public meta, signed if it asks
    "/booru/" ++ N =
        Entry = curate(
            Config, Curator, Meta, "image\nraster\nblue_sky -x cloud", [{"signed", "1"}]
        ),
    %% the meta leads there now, and the trunk says it is curated
    {303, Led, _} = request(Config, get, Meta, [], none),
    Entry = proplists:get_value("location", Led),
    {200, _, Trunk} = request(Config, get, "/trunk", [], none),
    {_, _} = binary:match(Trunk, list_to_binary("<a href=\"" ++ Entry ++ "\">")),
    {_, _} = binary:match(Trunk, list_to_binary(" card:" ++ N)),
    %% the curation: its owner is the meta's, its tags those given and
    %% what it is, and its first revision in its thread, by the curator,
    %% counting only what the curator gave
    {200, _, Page} = request(Config, get, Entry, [], none),
    {_, _} = binary:match(Page, <<"owner <a href=\"/user/meta-owner\">meta-owner</a>">>),
    [[<<"blue_sky">>], [<<"cloud">>], [<<"image">>], [<<"raster">>]] = query(
        Config,
        "SELECT t.name FROM booru_tag bt JOIN tag t ON t.id = bt.tag WHERE bt.booru = ? ORDER BY 1",
        [list_to_integer(N)]
    ),
    {_, _} = binary:match(Page, list_to_binary("<span class=\"title\">card:" ++ N ++ " 1</span>")),
    {_, _} = binary:match(
        Page,
        <<"<summary>tags <span class=\"added\">+2</span>, commentary =</summary>">>
    ),
    {_, _} = binary:match(Page, <<"<a href=\"/user/curator\">curator</a>">>),
    %% the same bytes are curated once
    Again = curate(Config, Curator, Meta, "x", []),
    Entry = Again.

comments_go_with_it(Config) ->
    Owner = login(Config, <<"commenter">>),
    Other = login(Config, <<"other-commenter">>),
    uploaded(Config, Owner, png(3, 4, 41), []),
    Meta = meta(Config, <<"commenter">>),
    {303, Said, _} = form(Config, Other, Meta ++ "/comment", [
        {"body", "a first word"}, {"signed", "1"}
    ]),
    Location = proplists:get_value("location", Said),
    "#p" ++ P = string:find(Location, "#"),
    Meta = hd(string:split(Location, "#")),
    {200, _, MetaPage} = request(Config, get, Meta, [], none),
    {_, _} = binary:match(MetaPage, <<"a first word">>),
    {_, _} = binary:match(MetaPage, <<"<a href=\"/user/other-commenter\">other-commenter</a>">>),
    %% nobody comments
    {200, _, _} = request(Config, get, Meta, [], none),
    {403, _, _} = request(
        Config, post, Meta ++ "/comment", [], {form, "csrf=x&body=nobody"}
    ),
    %% curated: the comment is in the curation's thread, before its first
    %% revision, and the thread's page and the comment's lead there
    Entry = curate(Config, Owner, Meta, "rain", []),
    {200, _, Page} = request(Config, get, Entry, [], none),
    {Word, _} = binary:match(Page, <<"a first word">>),
    {Revision, _} = binary:match(Page, <<"<summary>tags">>),
    true = Word < Revision,
    [[Thread]] = query(Config, "SELECT thread FROM post WHERE id = ?", [list_to_integer(P)]),
    {303, Led, _} = request(Config, get, "/board/trunk/" ++ integer_to_list(Thread), [], none),
    Entry = proplists:get_value("location", Led),
    {303, ToThread, _} = request(Config, get, "/p/" ++ P, [], none),
    "/board/trunk/" ++ _ = proplists:get_value("location", ToThread),
    %% replies, through the thread's own form, are read on the curation
    {303, _, _} = ike_browser:post(
        Config, "/board/trunk/" ++ integer_to_list(Thread) ++ "/reply", Other, <<"a reply after">>
    ),
    {200, _, After} = request(Config, get, Entry, [], none),
    {_, _} = binary:match(After, <<"a reply after">>),
    {_, _} = binary:match(
        After, list_to_binary("href=\"/board/trunk/" ++ integer_to_list(Thread) ++ "/reply\"")
    ).

revised_and_amended(Config) ->
    Session = login(Config, <<"reviser">>),
    Other = login(Config, <<"other-reviser">>),
    uploaded(Config, Session, png(4, 4, 43), []),
    Meta = meta(Config, <<"reviser">>),
    "/booru/" ++ N = Entry = curate(Config, Session, Meta, "image raster\nsun", []),
    Revisions = fun() ->
        [[Count]] = query(
            Config,
            "SELECT count(*) FROM post p JOIN booru b ON b.thread = p.thread"
            " WHERE b.id = ? AND p.revision = 1",
            [list_to_integer(N)]
        ),
        Count
    end,
    Tags = fun() ->
        [
            T
         || [T] <- query(
                Config,
                "SELECT t.name FROM booru_tag bt JOIN tag t ON t.id = bt.tag WHERE bt.booru = ?"
                " ORDER BY 1",
                [list_to_integer(N)]
            )
        ]
    end,
    1 = Revisions(),
    %% the box is laid out as given, and is the whole of the tags
    {200, _, First} = request(Config, get, Entry, [], none),
    {_, _} = binary:match(First, <<"class=\"tags\"">>),
    {_, _} = binary:match(First, <<">image raster\nsun</textarea>">>),
    Signed = [{"signed", "1"}],
    {303, _, _} = revise(
        Config, Session, Entry, [{"tags", "image raster\nmoon"}, {"commentary", "a line"}] ++ Signed
    ),
    2 = Revisions(),
    [<<"image">>, <<"moon">>, <<"raster">>] = Tags(),
    {200, _, Page} = request(Config, get, Entry, [], none),
    {_, _} = binary:match(
        Page,
        <<"<summary>tags <span class=\"added\">+1</span> <span class=\"removed\">-1</span>,",
            " commentary <span class=\"added\">+1</span></summary>">>
    ),
    {_, _} = binary:match(
        Page,
        <<"<del><a class=\"tag tag-description\" href=\"/wiki/description/sun\">sun</a></del>">>
    ),
    {_, _} = binary:match(Page, <<"<h2>commentary</h2><p>a line</p>">>),
    %% the same account again, signed, right after: folded into its own
    {303, _, _} = revise(
        Config,
        Session,
        Entry,
        [{"tags", "image raster\nmoon star"}, {"commentary", "a line\nand another"}] ++ Signed
    ),
    2 = Revisions(),
    {200, _, Folded} = request(Config, get, Entry, [], none),
    {_, _} = binary:match(
        Folded,
        <<"<summary>tags <span class=\"added\">+2</span> <span class=\"removed\">-1</span>,",
            " commentary <span class=\"added\">+2</span></summary>">>
    ),
    %% lux's box: names twice, a name taken off where it was given, a line
    %% with nothing left; kept as laid out, tidied
    Box =
        "copyright:ガールズバンドクライ\ncharacter:海老塚智\nsolo\nsimple_background\n"
        "brown_hair short_hair full_body\nraster\nsimple_background -full_body feet_out_of_frame",
    {303, _, _} = revise(Config, Other, Entry, [{"tags", Box}] ++ Signed),
    3 = Revisions(),
    [
        <<"brown_hair">>,
        <<"character:海老塚智"/utf8>>,
        <<"copyright:ガールズバンドクライ"/utf8>>,
        <<"feet_out_of_frame">>,
        <<"raster">>,
        <<"short_hair">>,
        <<"simple_background">>,
        <<"solo">>
    ] = Tags(),
    {200, _, Laid} = request(Config, get, Entry, [], none),
    {_, _} = binary:match(
        Laid,
        <<
            "copyright:ガールズバンドクライ\ncharacter:海老塚智\nsolo\nsimple_background\n"
            "brown_hair short_hair\nraster\nfeet_out_of_frame</textarea>"/utf8
        >>
    ),
    {_, _} = binary:match(
        Laid,
        <<"href=\"/wiki/description/copyright:%E3%82%AC%E3%83%BC%E3%83%AB%E3%82%BA%E3%83%90%E3%83%B3%E3%83%89%E3%82%AF%E3%83%A9%E3%82%A4\"">>
    ),
    %% the same box again, tidied the same, is no change; an unsigned
    %% change is a revision of its own
    {303, _, _} = revise(Config, Other, Entry, [{"tags", Box ++ " solo"}]),
    3 = Revisions(),
    {303, _, _} = revise(Config, Other, Entry, [{"tags", "raster solo"}]),
    4 = Revisions(),
    %% a form without the commentary box keeps the text
    {200, _, Last} = request(Config, get, Entry, [], none),
    {_, _} = binary:match(Last, <<"<h2>commentary</h2><p>a line<br>and another</p>">>),
    %% nobody, or from elsewhere, revises nothing
    {403, _, _} = request(
        Config,
        post,
        Entry ++ "/tags",
        [{"origin", ?config(base, Config)}],
        {form, "tags=nobody"}
    ),
    4 = Revisions().

only_public_metas(Config) ->
    Owner = login(Config, <<"private-curator">>),
    Moderator = login(Config, <<"curate-mod">>, #{groups => [<<"ike-moderator">>]}),
    uploaded(Config, Owner, png(5, 3, 47), ["private"]),
    Meta = meta(Config, <<"private-curator">>),
    {200, _, Page} = request(Config, get, Meta, cookies(Owner), none),
    nomatch = binary:match(Page, <<"post to the booru">>),
    {409, _, _} = form(Config, Owner, Meta ++ "/curate", [{"tags", "x"}]),
    [[0]] = query(Config, "SELECT count(*) FROM booru WHERE meta = ?", [
        list_to_integer(lists:nthtail(length("/trunk/"), Meta))
    ]),
    %% a moderator sees the meta, and comments there, which only those
    %% who see the meta read
    {303, _, _} = form(Config, Moderator, Meta ++ "/comment", [{"body", "a moderator's note"}]),
    {200, _, Seen} = request(Config, get, Meta, cookies(Owner), none),
    {_, _} = binary:match(Seen, <<"a moderator&#39;s note">>).

%% commentary is ikext, as a post is: a hashtag is text (a curator makes
%% it a link by hand); meta:N and card:N lead to a meta and a card, and
%% site:what to somewhere else, an outlink marked as one; every ikext form
%% previews in a tab of its own
commentary_is_ikext(Config) ->
    Session = login(Config, <<"commentator">>),
    uploaded(Config, Session, png(5, 5, 53), []),
    Meta = meta(Config, <<"commentator">>),
    "/booru/" ++ N = Entry = curate(Config, Session, Meta, "night", []),
    uploaded(Config, Session, png(5, 6, 59), []),
    "/trunk/" ++ M = meta(Config, <<"commentator">>),
    uploaded(Config, Session, png(6, 6, 61), ["private"]),
    "/trunk/" ++ Hidden = meta(Config, <<"commentator">>),
    Said = list_to_binary(
        "[b]new[/b] art #fanart \"#fanart\":[https://x.com/hashtag/fanart]\n"
        "see meta:" ++ M ++ " and card:" ++ N ++ ", not meta:" ++ Hidden ++
            " nor submeta:" ++ M ++
            "\n"
            "from twitter:1234567890 by twitter:some_artist, pixiv:98765, "
            "github:diluxi/ike. and danbooru:12, 4chan:g/123 and twitter:no-such-name"
    ),
    {303, _, _} = revise(Config, Session, Entry, [
        {"tags", "image raster night"}, {"commentary", Said}
    ]),
    {200, _, Page} = request(Config, get, Entry, [], none),
    Has = fun(Bit) -> {_, _} = binary:match(Page, Bit) end,
    Has(<<"<b>new</b> art #fanart <a class=\"out\" href=\"https://x.com/hashtag/fanart\"">>),
    Has(list_to_binary("<a href=\"/trunk/" ++ M ++ "\">meta:" ++ M ++ "</a>")),
    Has(list_to_binary("<a href=\"/booru/" ++ N ++ "\">card:" ++ N ++ "</a>")),
    %% a private meta is no link for everyone, nor is a word's end
    Has(list_to_binary("<span class=\"gone\">meta:" ++ Hidden ++ "</span>")),
    Has(list_to_binary("submeta:" ++ M)),
    Out = fun(Url, Text) ->
        Has(
            <<"<a class=\"out\" href=\"", Url/binary, "\" rel=\"nofollow noreferrer\">",
                Text/binary, "</a>">>
        )
    end,
    Out(<<"https://x.com/i/status/1234567890">>, <<"twitter:1234567890">>),
    Out(<<"https://x.com/some_artist">>, <<"twitter:some_artist">>),
    Out(<<"https://www.pixiv.net/artworks/98765">>, <<"pixiv:98765">>),
    %% the full stop ends the sentence, not the path
    Out(<<"https://github.com/diluxi/ike">>, <<"github:diluxi/ike">>),
    Has(<<"github:diluxi/ike</a>. and">>),
    Out(<<"https://danbooru.donmai.us/posts/12">>, <<"danbooru:12">>),
    Out(<<"https://boards.4chan.org/g/thread/123">>, <<"4chan:g/123">>),
    nomatch = binary:match(Page, <<"x.com/no-such-name">>),
    %% the forms carry the way to the preview, which sends no file
    Has(<<"formaction=\"/preview\"">>),
    {200, _, Form} = request(Config, get, "/board/b/new", cookies(Session), none),
    {_, _} = binary:match(
        Form,
        <<"formaction=\"/preview\" formmethod=\"post\" formenctype=\"application/x-www-form-urlencoded\" formtarget=\"_blank\" formnovalidate">>
    ),
    Previewed = uri_string:compose_query([{"body", "[i]soon[/i] #notatag"}, {"commentary", "said"}]),
    {200, _, Look} = request(Config, post, "/preview", cookies(Session), {form, Previewed}),
    {_, _} = binary:match(Look, <<"<i>soon</i> #notatag">>),
    {_, _} = binary:match(Look, <<"<h2>commentary</h2><p>said</p>">>),
    %% nothing was posted by it
    {200, _, Board} = request(Config, get, "/board/b", [], none),
    nomatch = binary:match(Board, <<"soon">>).

%% the front page: the newest curations as thumbnails, the newest board
%% posts as their board and first words (lux, after rain.meth.cat's)
the_front_page(Config) ->
    Session = login(Config, <<"fronter">>),
    {303, H, _} = ike_browser:post(Config, "/board/b/new", Session, <<"the newest words here">>),
    "#p" ++ P = string:find(proplists:get_value("location", H), "#"),
    uploaded(Config, Session, png(7, 5, 67), []),
    Meta = meta(Config, <<"fronter">>),
    "/booru/" ++ N = curate(Config, Session, Meta, "image raster front", []),
    {200, _, Front} = request(Config, get, "/", [], none),
    {_, _} = binary:match(
        Front,
        list_to_binary(
            "<li><a href=\"/board/b\">random</a>: <a href=\"/p/" ++ P ++
                "\">the newest words here</a></li>"
        )
    ),
    {_, _} = binary:match(
        Front, list_to_binary("<a href=\"/booru/" ++ N ++ "\"><img src=\"http://media.test/")
    ),
    %% not the trunk's posts, which are read on their metas
    nomatch = binary:match(Front, <<"/board/trunk">>).

%% nobody comments on public metas and curations once an admin opens the
%% trunk (lux), as on an open board; a moderator may not open it
nobody_comments_when_let(Config) ->
    Session = login(Config, <<"opener">>),
    Moderator = login(Config, <<"trunk-moderator">>, #{groups => [<<"ike-moderator">>]}),
    Admin = login(Config, <<"trunk-admin">>, #{groups => [<<"ike-admin">>]}),
    Here = [{"origin", ?config(base, Config)}],
    uploaded(Config, Session, png(7, 7, 71), []),
    Meta = meta(Config, <<"opener">>),
    Nobody = fun(Text) ->
        element(
            1,
            request(
                Config,
                post,
                Meta ++ "/comment",
                Here,
                {form, uri_string:compose_query([{"body", Text}])}
            )
        )
    end,
    %% shut, as it begins
    {200, _, Shut} = request(Config, get, Meta, [], none),
    {_, _} = binary:match(Shut, <<"log in to comment">>),
    403 = Nobody("let me in"),
    Switch = fun(Who, Kind) ->
        #{csrf := Csrf} = Who,
        element(
            1,
            request(
                Config,
                post,
                "/mod/board/trunk",
                cookies(Who),
                {form, uri_string:compose_query([{"csrf", Csrf}, {"kind", Kind}, {"reason", "x"}])}
            )
        )
    end,
    403 = Switch(Moderator, "unlock"),
    {200, _, ModPage} = request(Config, get, "/mod", cookies(Moderator), none),
    nomatch = binary:match(ModPage, <<"/mod/board/trunk">>),
    {200, _, AdminPage} = request(Config, get, "/mod", cookies(Admin), none),
    {_, _} = binary:match(AdminPage, <<"/trunk/ comments on metas and curations: accounts only">>),
    303 = Switch(Admin, "unlock"),
    %% open: nobody comments on the meta, from this site only
    {200, _, Open} = request(Config, get, Meta, [], none),
    {_, _} = binary:match(Open, list_to_binary("action=\"" ++ Meta ++ "/comment\"")),
    403 = element(
        1,
        request(Config, post, Meta ++ "/comment", [], {form, "body=from+elsewhere"})
    ),
    303 = Nobody("a word from nobody"),
    {200, _, Said} = request(Config, get, Meta, [], none),
    {_, _} = binary:match(Said, <<"a word from nobody">>),
    %% and on its curation, through the thread's own form
    Entry = curate(Config, Session, Meta, "image raster open", []),
    [[Thread]] = query(Config, "SELECT thread FROM booru WHERE id = ?", [
        list_to_integer(lists:nthtail(length("/booru/"), Entry))
    ]),
    {303, _, _} = ike_browser:anonymous(
        Config,
        "/board/trunk/" ++ integer_to_list(Thread) ++ "/reply",
        Here,
        <<"nobody on the curation">>
    ),
    {200, _, Curation} = request(Config, get, Entry, [], none),
    {_, _} = binary:match(Curation, <<"a word from nobody">>),
    {_, _} = binary:match(Curation, <<"nobody on the curation">>),
    %% shut again: nobody is let no more
    303 = Switch(Admin, "lock"),
    403 = Nobody("too late").

%% a comment on a meta takes a password, as a post does (lux), and is
%% retracted with it from the meta's page; it leads back there
comments_retract_by_password(Config) ->
    Session = login(Config, <<"retracting">>),
    uploaded(Config, Session, png(8, 3, 73), []),
    Meta = meta(Config, <<"retracting">>),
    {200, _, Page} = request(Config, get, Meta, cookies(Session), none),
    {_, _} = binary:match(Page, <<"name=\"password\"">>),
    {303, Said, _} = form(Config, Session, Meta ++ "/comment", [
        {"body", "said too soon"}, {"password", "hunter2"}
    ]),
    "#p" ++ P = string:find(proplists:get_value("location", Said), "#"),
    {200, _, With} = request(Config, get, Meta, [], none),
    {_, _} = binary:match(With, <<"said too soon">>),
    {_, _} = binary:match(
        With, list_to_binary("<input type=\"checkbox\" name=\"post\" value=\"" ++ P ++ "\">")
    ),
    Act = fun(Password) ->
        request(
            Config,
            post,
            "/act",
            [{"origin", ?config(base, Config)}],
            {form,
                uri_string:compose_query([
                    {"post", P}, {"kind", "retract"}, {"password", Password}, {"back", Meta}
                ])}
        )
    end,
    {200, _, Wrong} = Act("wrong"),
    nomatch = binary:match(Wrong, <<": retracted">>),
    {200, _, Right} = Act("hunter2"),
    {_, _} = binary:match(Right, <<": retracted">>),
    {_, _} = binary:match(Right, list_to_binary("href=\"" ++ Meta ++ "\"")),
    {200, _, Without} = request(Config, get, Meta, [], none),
    nomatch = binary:match(Without, <<"said too soon">>).
