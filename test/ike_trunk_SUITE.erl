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

%% the meta of the newest upload of the account called Subject
newest(Config, Subject) ->
    [[Hash]] = query(
        Config,
        "SELECT u.asset FROM upload u JOIN actor a ON a.id = u.actor"
        " WHERE a.subject = ? ORDER BY u.id DESC LIMIT 1",
        [Subject]
    ),
    "/trunk/" ++ binary_to_list(binary:encode_hex(Hash, lowercase)).

named_or_anonymous(Config) ->
    Session = login(Config, <<"namer">>),
    {200, _, Form} = request(Config, get, "/upload", cookies(Session), none),
    {_, _} = binary:match(Form, <<"sign as namer">>),
    {303, _, _} = upload(Config, Session, png(2, 2, 3), ["signed"]),
    Signed = newest(Config, <<"namer">>),
    {200, _, Named} = request(Config, get, Signed, [], none),
    {_, _} = binary:match(Named, <<"<a href=\"/user/namer\">namer</a>">>),
    {303, _, _} = upload(Config, Session, png(2, 2, 5), []),
    Unsigned = newest(Config, <<"namer">>),
    {200, _, Anonymous} = request(Config, get, Unsigned, [], none),
    {_, _} = binary:match(Anonymous, <<"<td>anonymous</td>">>),
    nomatch = binary:match(Anonymous, <<"namer">>),
    %% its owner is told it is theirs, and nobody else
    {200, _, Mine} = request(Config, get, Unsigned, cookies(Session), none),
    {_, _} = binary:match(Mine, <<"anonymous (you)">>),
    %% a file posted with a signed post bears the name; with an unsigned
    %% one it does not
    {303, _, _} = posted(
        Config, Session, <<"signed, with a file">>, [{<<"signed">>, <<"1">>}], [
            {<<"x.png">>, png(2, 2, 7)}
        ]
    ),
    {200, _, Posted} = request(Config, get, newest(Config, <<"namer">>), [], none),
    {_, _} = binary:match(Posted, <<"<a href=\"/user/namer\">namer</a>">>),
    {303, _, _} = posted(
        Config, Session, <<"unsigned, with a file">>, [], [
            {<<"x.png">>, png(2, 2, 9)}
        ]
    ),
    {200, _, Unnamed} = request(Config, get, newest(Config, <<"namer">>), [], none),
    nomatch = binary:match(Unnamed, <<"namer">>).

moderated_as_posts(Config) ->
    Owner = login(Config, <<"modded">>),
    Other = login(Config, <<"modded-other">>),
    Moderator = login(Config, <<"meta-mod">>, #{groups => [<<"ike-moderator">>]}),
    Janitor = login(Config, <<"meta-jan">>, #{groups => [<<"ike-janitor-b">>]}),
    {303, _, _} = upload(Config, Owner, png(3, 3, 11), []),
    "/trunk/" ++ Hex = Meta = newest(Config, <<"modded">>),
    Mod = "/mod/meta/" ++ Hex,
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
    nomatch = binary:match(Trunk, list_to_binary(Hex)),
    {200, _, Seen} = request(Config, get, "/trunk", cookies(Moderator), none),
    {_, _} = binary:match(Seen, list_to_binary(Meta)),
    {_, _} = binary:match(Seen, <<" hidden">>),
    {404, _, _} = media(Config, File),
    %% logged, publicly, by its short name, as a post by its number
    Short = list_to_binary(lists:sublist(Hex, 12)),
    [[<<"hide">>, 1]] = query(
        Config,
        "SELECT kind, meta = ? FROM action WHERE meta IS NOT NULL ORDER BY entry DESC LIMIT 1",
        [{blob, binary:decode_hex(list_to_binary(Hex))}]
    ),
    [[Text]] = query(
        Config,
        "SELECT p.body FROM action a JOIN post p ON p.id = a.entry ORDER BY a.entry DESC LIMIT 1",
        []
    ),
    {_, _} = binary:match(Text, <<"hide meta ", Short/binary>>),
    %% and undone
    409 = Act(Moderator, "restore"),
    303 = Act(Moderator, "unhide"),
    {200, _, _} = request(Config, get, Meta, [], none),
    {200, _, _} = media(Config, File),
    303 = Act(Moderator, "trash"),
    {404, _, _} = request(Config, get, Meta, cookies(Owner), none),
    {404, _, _} = media(Config, File),
    303 = Act(Moderator, "restore"),
    {200, _, _} = request(Config, get, Meta, cookies(Owner), none),
    {200, _, _} = media(Config, File),
    %% a private meta's hash is not written in the public log
    {303, _, _} = upload(Config, Owner, png(3, 3, 13), ["private"]),
    "/trunk/" ++ Hidden = newest(Config, <<"modded">>),
    #{csrf := C} = Moderator,
    {303, _, _} = request(
        Config,
        post,
        "/mod/meta/" ++ Hidden,
        cookies(Moderator),
        {form, uri_string:compose_query([{"csrf", C}, {"kind", "hide"}, {"reason", "x"}])}
    ),
    [[Private]] = query(
        Config,
        "SELECT p.body FROM action a JOIN post p ON p.id = a.entry ORDER BY a.entry DESC LIMIT 1",
        []
    ),
    {_, _} = binary:match(Private, <<"hide a private meta">>),
    nomatch = binary:match(Private, list_to_binary(lists:sublist(Hidden, 12))).

known_bytes_lead_to_them(Config) ->
    A = login(Config, <<"first-up">>),
    B = login(Config, <<"second-up">>),
    Bytes = png(4, 2, 17),
    {303, First, _} = upload(Config, A, Bytes, []),
    "/upload" = proplists:get_value("location", First),
    Meta = newest(Config, <<"first-up">>),
    %% the same bytes again, by anyone: to the meta they have
    {303, Again, _} = upload(Config, B, Bytes, []),
    Meta = proplists:get_value("location", Again),
    %% but not to a private one that is not theirs: it is not said there
    %% is one
    Hidden = png(4, 2, 19),
    {303, _, _} = upload(Config, A, Hidden, ["private"]),
    {303, Quiet, _} = upload(Config, B, Hidden, []),
    "/upload" = proplists:get_value("location", Quiet),
    %% and to its booru entry, if it has one
    Posted = png(4, 2, 23),
    {303, _, _} = posted(Config, A, <<"entered">>, [], [
        {<<"x.png">>, Posted}
    ]),
    {303, Entered, _} = upload(Config, B, Posted, []),
    "/booru/" ++ _ = proplists:get_value("location", Entered).
