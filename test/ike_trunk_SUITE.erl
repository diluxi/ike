%% The trunk, from outside: a meta bears its owner's name or reads as
%% anonymous, moderators hide and trash metas as they do posts, logged and
%% undone the same way, and an upload of bytes already there leads to them.
-module(ike_trunk_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    named_or_anonymous/1,
    moderated_as_posts/1,
    known_bytes_lead_to_them/1
]).

-import(ike_browser, [login/2, login/3, request/5, query/3, cookies/1, media/2]).

all() ->
    [named_or_anonymous, moderated_as_posts, known_bytes_lead_to_them].

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

%% an upload from /upload, with the boxes Fields ticks
upload(Config, #{csrf := Csrf} = Session, Bytes, Fields) ->
    {Type, Body} = ike_browser:multipart(
        [{field, <<"csrf">>, list_to_binary(Csrf)}] ++
            [{field, list_to_binary(F), <<"1">>} || F <- Fields] ++
            [{file, <<"file">>, {<<"x.png">>, Bytes}}]
    ),
    request(Config, post, "/upload", cookies(Session), {Type, Body}).

%% a post on /b/ with files, and the fields More
posted(Config, #{csrf := Csrf} = Session, Text, More, Files) ->
    {Type, Body} = ike_browser:multipart(
        [{field, <<"csrf">>, list_to_binary(Csrf)}, {field, <<"body">>, Text}] ++
            [{field, K, V} || {K, V} <- More] ++
            [{file, <<"file">>, F} || F <- Files]
    ),
    request(Config, post, "/board/b/new", cookies(Session), {Type, Body}).

%% the meta of the newest upload of the account called Subject: its
%% page, and its asset's hex
newest(Config, Subject) ->
    [[Id, Hash]] = query(
        Config,
        "SELECT m.id, m.asset FROM upload u JOIN actor a ON a.id = u.actor"
        " JOIN meta m ON m.asset = u.asset"
        " WHERE a.subject = ? ORDER BY u.id DESC, m.owner = u.actor DESC LIMIT 1",
        [Subject]
    ),
    {"/trunk/" ++ integer_to_list(Id), binary_to_list(binary:encode_hex(Hash, lowercase))}.

page(Config, Subject) ->
    element(1, newest(Config, Subject)).

%% the owner's forms on a meta's page
owned(Config, #{csrf := Csrf} = Session, Meta, Field, Value) ->
    request(
        Config,
        post,
        Meta,
        cookies(Session),
        {form, uri_string:compose_query([{"csrf", Csrf}, {Field, Value}])}
    ).

named_or_anonymous(Config) ->
    Session = login(Config, <<"namer">>),
    {200, _, Form} = request(Config, get, "/upload", cookies(Session), none),
    {_, _} = binary:match(Form, <<"sign as namer">>),
    {303, _, _} = upload(Config, Session, png(2, 2, 3), ["signed"]),
    Signed = page(Config, <<"namer">>),
    {200, _, Named} = request(Config, get, Signed, [], none),
    {_, _} = binary:match(Named, <<"<a href=\"/user/namer\">namer</a>">>),
    %% to its owner, "(you)", leading to their page
    {200, _, Yours} = request(Config, get, Signed, cookies(Session), none),
    {_, _} = binary:match(Yours, <<"<a href=\"/user/namer\">(you)</a>">>),
    {303, _, _} = upload(Config, Session, png(2, 2, 5), []),
    Unsigned = page(Config, <<"namer">>),
    {200, _, Anonymous} = request(Config, get, Unsigned, [], none),
    {_, _} = binary:match(Anonymous, <<"<td>anonymous</td>">>),
    nomatch = binary:match(Anonymous, <<"namer">>),
    {200, _, Mine} = request(Config, get, Unsigned, cookies(Session), none),
    {_, _} = binary:match(Mine, <<"<a href=\"/user/namer\">(you)</a>, unsigned">>),
    %% its owner puts their name on it later; nobody else can
    Other = login(Config, <<"not-namer">>),
    {403, _, _} = owned(Config, Other, Unsigned, "sign", "1"),
    {303, _, _} = owned(Config, Session, Unsigned, "sign", "1"),
    {200, _, Taken} = request(Config, get, Unsigned, [], none),
    {_, _} = binary:match(Taken, <<"<a href=\"/user/namer\">namer</a>">>),
    nomatch = binary:match(
        element(3, request(Config, get, Unsigned, cookies(Session), none)), <<"sign as">>
    ),
    %% a file posted with a signed post bears the name; with an unsigned
    %% one it does not
    {303, _, _} = posted(Config, Session, <<"signed, with a file">>, [{<<"signed">>, <<"1">>}], [
        {<<"x.png">>, png(2, 2, 7)}
    ]),
    {200, _, Posted} = request(Config, get, page(Config, <<"namer">>), [], none),
    {_, _} = binary:match(Posted, <<"<a href=\"/user/namer\">namer</a>">>),
    {303, _, _} = posted(Config, Session, <<"unsigned, with a file">>, [], [
        {<<"x.png">>, png(2, 2, 9)}
    ]),
    {200, _, Unnamed} = request(Config, get, page(Config, <<"namer">>), [], none),
    nomatch = binary:match(Unnamed, <<"namer">>).

moderated_as_posts(Config) ->
    Owner = login(Config, <<"modded">>),
    Other = login(Config, <<"modded-other">>),
    Moderator = login(Config, <<"meta-mod">>, #{groups => [<<"ike-moderator">>]}),
    Janitor = login(Config, <<"meta-jan">>, #{groups => [<<"ike-janitor-b">>]}),
    {303, _, _} = upload(Config, Owner, png(3, 3, 11), []),
    {"/trunk/" ++ N = Meta, Hex} = newest(Config, <<"modded">>),
    Mod = "/mod/meta/" ++ N,
    File = "http://media.test/" ++ Hex ++ ".png",
    {200, _, _} = media(Config, File),
    Act = fun(#{csrf := Csrf} = Who, Kind) ->
        Form = uri_string:compose_query([{"csrf", Csrf}, {"kind", Kind}, {"reason", "rule 3"}]),
        element(1, request(Config, post, Mod, cookies(Who), {form, Form}))
    end,
    %% nobody without a role has the page; a janitor is not let
    [
        404 = element(1, request(Config, get, Mod, Cookies, none))
     || Cookies <- [cookies(Owner), cookies(Other), []]
    ],
    403 = Act(Janitor, "hide"),
    {200, _, Page} = request(Config, get, Meta, cookies(Moderator), none),
    {_, _} = binary:match(Page, list_to_binary("href=\"" ++ Mod ++ "\">moderate")),
    nomatch = binary:match(
        element(3, request(Config, get, Meta, cookies(Owner), none)), <<"moderate">>
    ),
    %% hidden: gone for everyone but moderators, its files with it
    303 = Act(Moderator, "hide"),
    [
        404 = element(1, request(Config, get, Meta, Cookies, none))
     || Cookies <- [cookies(Owner), cookies(Other), []]
    ],
    {200, _, Trunk} = request(Config, get, "/trunk", cookies(Owner), none),
    nomatch = binary:match(Trunk, list_to_binary(Meta ++ "\"")),
    {200, _, Seen} = request(Config, get, "/trunk", cookies(Moderator), none),
    {_, _} = binary:match(Seen, list_to_binary(Meta ++ "\"")),
    {_, _} = binary:match(Seen, <<" hidden">>),
    {404, _, _} = media(Config, File),
    %% logged, by its number
    [[<<"hide">>]] = query(
        Config, "SELECT kind FROM action WHERE meta = ? ORDER BY entry DESC LIMIT 1", [
            list_to_integer(N)
        ]
    ),
    [[Text]] = query(
        Config,
        "SELECT p.body FROM action a JOIN post p ON p.id = a.entry ORDER BY a.entry DESC LIMIT 1",
        []
    ),
    {_, _} = binary:match(Text, list_to_binary("hide meta #" ++ N)),
    %% and undone
    409 = Act(Moderator, "restore"),
    303 = Act(Moderator, "unhide"),
    {200, _, _} = request(Config, get, Meta, [], none),
    {200, _, _} = media(Config, File),
    %% trashed: its owner still sees it, marked, its files kept and
    %% shown them by signed links; nobody else sees anything
    303 = Act(Moderator, "trash"),
    {404, _, _} = media(Config, File),
    [
        404 = element(1, request(Config, get, Meta, Cookies, none))
     || Cookies <- [cookies(Other), []]
    ],
    {200, _, Trashed} = request(Config, get, Meta, cookies(Owner), none),
    {_, _} = binary:match(Trashed, <<"<td>trashed</td>">>),
    {match, [Signed]} = re:run(
        Trashed, "<a href=\"(http://media\\.test/staged/[^\"]+)\"", [{capture, all_but_first, list}]
    ),
    {200, _, _} = media(Config, Signed),
    {200, _, Listed} = request(Config, get, "/trunk", cookies(Owner), none),
    {_, _} = binary:match(Listed, <<" trashed">>),
    303 = Act(Moderator, "restore"),
    {200, _, _} = request(Config, get, Meta, [], none),
    {200, _, _} = media(Config, File).

%% bytes are one asset however many bring them, but a meta is an
%% owner's: someone else's private meta is never seen through an upload,
%% the first to make one public keeps the public one, and the others'
%% private metas stay theirs (lux, Q41)
known_bytes_lead_to_them(Config) ->
    A = login(Config, <<"first-up">>),
    B = login(Config, <<"second-up">>),
    C = login(Config, <<"third-up">>),
    Count = fun(Hex) ->
        [[K]] = query(Config, "SELECT count(*) FROM meta WHERE asset = ?", [
            {blob, binary:decode_hex(list_to_binary(Hex))}
        ]),
        K
    end,
    %% public bytes again: to their meta, and no meta more
    Bytes = png(4, 2, 17),
    {303, First, _} = upload(Config, A, Bytes, []),
    "/upload" = proplists:get_value("location", First),
    {Meta, Hex} = newest(Config, <<"first-up">>),
    {303, Again, _} = upload(Config, B, Bytes, []),
    Meta = proplists:get_value("location", Again),
    1 = Count(Hex),
    %% private bytes again: a private meta of the second's own, and
    %% nothing said of the first's
    Hidden = png(4, 2, 19),
    {303, _, _} = upload(Config, A, Hidden, ["private"]),
    {MetaA, HiddenHex} = newest(Config, <<"first-up">>),
    {303, Quiet, _} = upload(Config, B, Hidden, ["private"]),
    "/upload" = proplists:get_value("location", Quiet),
    2 = Count(HiddenHex),
    [[IdB]] = query(
        Config,
        "SELECT m.id FROM meta m JOIN actor a ON a.id = m.owner WHERE a.subject = 'second-up'"
        " AND m.asset = ?",
        [{blob, binary:decode_hex(list_to_binary(HiddenHex))}]
    ),
    MetaB = "/trunk/" ++ integer_to_list(IdB),
    {200, _, PageB} = request(Config, get, MetaB, cookies(B), none),
    nomatch = binary:match(PageB, <<"first-up">>),
    {404, _, _} = request(Config, get, MetaA, cookies(B), none),
    %% the second makes theirs public first: it is the public one; the
    %% first's stays private, and making it public leads to the second's
    {303, _, _} = owned(Config, B, MetaB, "private", "0"),
    {200, _, _} = request(Config, get, MetaB, [], none),
    {303, Taken, _} = owned(Config, A, MetaA, "private", "0"),
    MetaB = proplists:get_value("location", Taken),
    {404, _, _} = request(Config, get, MetaA, [], none),
    {200, _, _} = request(Config, get, MetaA, cookies(A), none),
    %% a third brings the bytes: to the public meta
    {303, Third, _} = upload(Config, C, Hidden, []),
    MetaB = proplists:get_value("location", Third),
    2 = Count(HiddenHex),
    %% and to its booru entry, if it has one
    Posted = png(4, 2, 23),
    {303, _, _} = posted(Config, A, <<"entered">>, [], [{<<"x.png">>, Posted}]),
    {303, Entered, _} = upload(Config, B, Posted, []),
    "/booru/" ++ _ = proplists:get_value("location", Entered).
