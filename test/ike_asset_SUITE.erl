%% Images on posts, from outside: one asset for the same bytes however
%% often they come, a post that shows an upload of its account's, and a
%% media origin whose files follow what is shown, across moderation and
%% restarts. What uploads are and who sees them staged are invariants 6,
%% 10 and 11, in ike_invariant_SUITE.
-module(ike_asset_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    the_same_bytes_are_one_asset/1,
    a_post_shows_an_upload/1,
    only_ones_own_once/1,
    the_media_follow_what_is_shown/1,
    a_restart_makes_them_again/1,
    a_blocked_image_does_not_come_back/1,
    the_uploader_can_be_suspended/1,
    a_post_shows_several/1,
    a_video_plays/1,
    files_on_the_post_form/1,
    nobody_posts_still_images_when_let/1
]).

-import(ike_browser, [login/2, login/3, post/5, request/5, query/3, cookies/1, upload/3, media/2]).

all() ->
    [
        the_same_bytes_are_one_asset,
        a_post_shows_an_upload,
        only_ones_own_once,
        the_media_follow_what_is_shown,
        a_restart_makes_them_again,
        a_blocked_image_does_not_come_back,
        the_uploader_can_be_suspended,
        a_post_shows_several,
        a_video_plays,
        files_on_the_post_form,
        %% last: it starts ike again with the switch on
        nobody_posts_still_images_when_let
    ].

init_per_suite(Config) ->
    ike_browser:start(Config, []).

end_per_suite(_Config) ->
    ike_browser:stop().

read(Config, Name) ->
    {ok, Bytes} = file:read_file(filename:join(?config(data_dir, Config), Name)),
    Bytes.

%% the newest staged upload of the account called Subject
latest(Config, Subject) ->
    [[Id]] = query(
        Config,
        "SELECT max(u.id) FROM upload u JOIN actor a ON a.id = u.actor"
        " WHERE a.subject = ? AND u.posted IS NULL",
        [Subject]
    ),
    Id.

with(Config, Session, Path, Body, Upload) ->
    post(Config, Path, Session, Body, [{<<"upload">>, integer_to_binary(Upload)}]).

page(Headers) ->
    hd(string:split(proplists:get_value("location", Headers), "#")).

%% the thread page's image: the full file's url and the thumbnail's
image(Config, Page) ->
    {200, _, Html} = request(Config, get, Page, [], none),
    case
        re:run(
            Html,
            "<a href=\"(http://media\\.test/[0-9a-f]{64}\\.[a-z]+)\"><img src=\"(http://media\\.test/[^\"]+)\"",
            [{capture, all_but_first, list}]
        )
    of
        {match, [File, Thumb]} -> {File, Thumb};
        nomatch -> none
    end.

the_same_bytes_are_one_asset(Config) ->
    Png = read(Config, "base.png"),
    A = login(Config, <<"dedup-a">>),
    B = login(Config, <<"dedup-b">>),
    [[Assets]] = query(Config, "SELECT count(*) FROM asset", []),
    {303, _, _} = upload(Config, A, [{<<"1.png">>, Png}]),
    {303, _, _} = upload(Config, B, [{<<"2.png">>, Png}]),
    {303, _, _} = upload(Config, A, [{<<"3.png">>, Png}]),
    %% one asset more, three uploads, each its account's
    [[More]] = query(Config, "SELECT count(*) FROM asset", []),
    1 = More - Assets,
    [[3]] = query(
        Config,
        "SELECT count(*) FROM upload u JOIN actor a ON a.id = u.actor"
        " WHERE a.subject IN ('dedup-a', 'dedup-b')",
        []
    ),
    [[1]] = query(
        Config,
        "SELECT count(DISTINCT asset) FROM upload u JOIN actor a ON a.id = u.actor"
        " WHERE a.subject IN ('dedup-a', 'dedup-b')",
        []
    ),
    %% two files for it on disk, whatever came in
    Assets2 = filelib:wildcard(
        binary_to_list(filename:join(?config(dir, Config), "assets")) ++ "/*"
    ),
    true = 2 * More =:= length(Assets2),
    %% several at once, and what is not an image among them
    {422, _, Refused} = upload(Config, A, [
        {<<"a.jpg">>, read(Config, "base.jpg")}, {<<"b.txt">>, <<"plain text">>}
    ]),
    {_, _} = binary:match(Refused, <<"file 2: not taken<">>),
    {200, _, Staged} = request(Config, get, "/upload", cookies(A), none),
    {match, _} = re:run(Staged, "jpeg, 61x47").

a_post_shows_an_upload(Config) ->
    Session = login(Config, <<"poster">>),
    {303, _, _} = upload(Config, Session, [{<<"p.jpg">>, read(Config, "base.jpg")}]),
    Upload = latest(Config, <<"poster">>),
    %% an image says enough: the text may be empty
    {303, H, _} = with(Config, Session, "/board/b/new", <<>>, Upload),
    {File, Thumb} = image(Config, page(H)),
    {200, FileHeaders, _} = media(Config, File),
    "image/jpeg" = proplists:get_value("content-type", FileHeaders),
    "nosniff" = proplists:get_value("x-content-type-options", FileHeaders),
    {200, ThumbHeaders, _} = media(Config, Thumb),
    "image/webp" = proplists:get_value("content-type", ThumbHeaders),
    %% posted, it waits no more, and nothing names its account
    {200, _, Staged} = request(Config, get, "/upload", cookies(Session), none),
    %% no longer waiting, and listed with where it went
    "#p" ++ Into = string:find(proplists:get_value("location", H), "#"),
    {_, _} = binary:match(
        Staged,
        <<"upload ", (integer_to_binary(Upload))/binary, ", posted in <a href=\"/p/",
            (list_to_binary(Into))/binary, "\">">>
    ),
    nomatch = binary:match(Staged, <<"alt=\"upload ", (integer_to_binary(Upload))/binary>>),
    {200, _, Page} = request(Config, get, page(H), [], none),
    nomatch = binary:match(Page, <<"poster">>),
    %% and without one, empty text is still nothing to post
    {400, _, _} = ike_browser:post(Config, "/board/b/new", Session, <<>>).

only_ones_own_once(Config) ->
    Owner = login(Config, <<"owner">>),
    Thief = login(Config, <<"thief">>),
    {303, _, _} = upload(Config, Owner, [{<<"o.png">>, read(Config, "base.png")}]),
    Upload = latest(Config, <<"owner">>),
    Before = ike_browser:posts(Config),
    {400, _, _} = with(Config, Thief, "/board/b/new", <<"mine now">>, Upload),
    {400, _, _} = with(Config, Owner, "/board/b/new", <<"none such">>, 999999),
    Before = ike_browser:posts(Config),
    {303, _, _} = with(Config, Owner, "/board/b/new", <<"first">>, Upload),
    {400, _, _} = with(Config, Owner, "/board/b/new", <<"again">>, Upload),
    %% a failed post took nothing with it
    [[N]] = Before,
    [[After]] = ike_browser:posts(Config),
    After = N + 1.

%% an upload whose meta is private: its files are public only while a
%% post or an entry shows them
private(Config, #{csrf := Csrf} = Session, Name, Bytes) ->
    {Type, Body} = ike_browser:multipart([
        {field, <<"csrf">>, list_to_binary(Csrf)},
        {field, <<"private">>, <<"1">>},
        {file, <<"file">>, {Name, Bytes}}
    ]),
    request(Config, post, "/upload", cookies(Session), {Type, Body}).

the_media_follow_what_is_shown(Config) ->
    Session = login(Config, <<"shown">>),
    Moderator = login(Config, <<"shown-mod">>, #{groups => [<<"ike-moderator">>]}),
    %% bytes no other test posts, so that no other post shows this asset,
    %% and private, so that the trunk does not (a public meta's files are
    %% public whatever else shows them)
    {303, _, _} = private(Config, Session, <<"t.webp">>, read(Config, "lossy.webp")),
    Upload = latest(Config, <<"shown">>),
    {303, H, _} = with(Config, Session, "/board/b/new", <<"look">>, Upload),
    {File, Thumb} = image(Config, page(H)),
    {200, _, _} = media(Config, File),
    Root = lists:last(string:split(page(H), "/", all)),
    Act = fun(Kind) ->
        #{csrf := Csrf} = Moderator,
        Form = uri_string:compose_query([{"csrf", Csrf}, {"kind", Kind}, {"reason", "x"}]),
        {303, _, _} = request(Config, post, "/mod/post/" ++ Root, cookies(Moderator), {form, Form})
    end,
    %% another post shows the same asset, so hiding one keeps it
    {303, _, _} = upload(Config, Session, [{<<"u.webp">>, read(Config, "lossy.webp")}]),
    {303, H2, _} = with(Config, Session, "/board/b/new", <<"also">>, latest(Config, <<"shown">>)),
    {File, _} = image(Config, page(H2)),
    Act("hide"),
    {200, _, _} = media(Config, File),
    %% with that one hidden too, its booru entry still shows it: the image
    %% is the archive's (lux)
    Root2 = lists:last(string:split(page(H2), "/", all)),
    #{csrf := Csrf2} = Moderator,
    Mod = fun(Path, Kind) ->
        {303, _, _} = request(
            Config,
            post,
            Path,
            cookies(Moderator),
            {form, uri_string:compose_query([{"csrf", Csrf2}, {"kind", Kind}, {"reason", "x"}])}
        )
    end,
    Mod("/mod/post/" ++ Root2, "hide"),
    {200, _, _} = media(Config, File),
    %% and with the entry hidden as well, it is gone from the media origin
    "http://media.test/" ++ Name = File,
    [[Entry]] = query(
        Config,
        "SELECT booru FROM booru_version WHERE asset = ?",
        [{blob, binary:decode_hex(list_to_binary(filename:rootname(Name)))}]
    ),
    Mod("/mod/booru/" ++ integer_to_list(Entry), "hide"),
    {404, _, _} = media(Config, File),
    {404, _, _} = media(Config, Thumb),
    {404, _, _} = request(Config, get, "/booru/" ++ integer_to_list(Entry), [], none),
    Act("unhide"),
    {200, _, _} = media(Config, File),
    {200, _, _} = media(Config, Thumb),
    Mod("/mod/booru/" ++ integer_to_list(Entry), "unhide"),
    {200, _, _} = request(Config, get, "/booru/" ++ integer_to_list(Entry), [], none).

a_restart_makes_them_again(Config) ->
    Session = login(Config, <<"restarted">>),
    {303, _, _} = upload(Config, Session, [{<<"r.png">>, read(Config, "base.png")}]),
    {303, H, _} = with(
        Config, Session, "/board/b/new", <<"kept">>, latest(Config, <<"restarted">>)
    ),
    {File, _} = image(Config, page(H)),
    Media = binary_to_list(filename:join(?config(dir, Config), "media")),
    "http://media.test/" ++ Name = File,
    ok = file:delete(filename:join(Media, Name)),
    Stray = filename:join(Media, "stray.txt"),
    ok = file:write_file(Stray, <<"not ours">>),
    {404, _, _} = media(Config, File),
    ok = ike_browser:restart(),
    {200, _, _} = media(Config, File),
    false = filelib:is_regular(Stray).

a_blocked_image_does_not_come_back(Config) ->
    Session = login(Config, <<"blocked">>),
    Other = login(Config, <<"blocked-too">>),
    Janitor = login(Config, <<"blocked-jan">>, #{groups => [<<"ike-janitor-b">>]}),
    Moderator = login(Config, <<"blocked-mod">>, #{groups => [<<"ike-moderator">>]}),
    Admin = login(Config, <<"blocked-admin">>, #{groups => [<<"ike-admin">>]}),
    Jpg = read(Config, "base.jpg"),
    {303, _, _} = upload(Config, Session, [{<<"b.jpg">>, Jpg}]),
    {303, H, _} = with(
        Config, Session, "/board/b/new", <<"blockable">>, latest(Config, <<"blocked">>)
    ),
    "#p" ++ N = string:find(proplists:get_value("location", H), "#"),
    Path = "/mod/post/" ++ N,
    Act = fun(#{csrf := Csrf} = Who, Kind) ->
        Form = uri_string:compose_query([
            {"csrf", Csrf}, {"kind", Kind}, {"image", "0"}, {"reason", "x"}
        ]),
        element(1, request(Config, post, Path, cookies(Who), {form, Form}))
    end,
    %% offered as each role may
    Offered = fun(Who) ->
        {200, _, Look} = request(Config, get, Path, cookies(Who), none),
        {match, Kinds} = re:run(Look, "name=\"kind\" value=\"([a-z_]+)\"", [
            global, {capture, all_but_first, binary}
        ]),
        [K || [K] <- Kinds]
    end,
    [<<"hide">>] = Offered(Janitor),
    %% unsigned, and still the account behind the image can be suspended
    [<<"hide">>, <<"trash">>, <<"ban">>, <<"block">>] = Offered(Moderator),
    %% (an image's rung needs to know which image)
    #{csrf := ModCsrf} = Moderator,
    {409, _, _} = request(
        Config,
        post,
        Path,
        cookies(Moderator),
        {form, uri_string:compose_query([{"csrf", ModCsrf}, {"kind", "block"}, {"reason", "x"}])}
    ),
    %% a janitor's own unsigned image is the janitor's, and below a
    %% moderator; nobody sees whose it is
    {200, _, Look} = request(Config, get, Path, cookies(Moderator), none),
    nomatch = binary:match(Look, <<"blocked">>),
    403 = Act(Janitor, "block"),
    403 = Act(Moderator, "purge_image"),
    303 = Act(Moderator, "block"),
    409 = Act(Moderator, "block"),
    %% the same image, with whatever metadata, from anyone: not taken,
    %% in the same words as a file that is no image
    {422, _, Refused} = upload(Config, Other, [{<<"c.jpg">>, Jpg}]),
    {_, _} = binary:match(Refused, <<"file 1: not taken<">>),
    %% and the post that shows it still does: a block is of what comes
    {File, _} = image(Config, page(H)),
    {200, _, _} = media(Config, File),
    303 = Act(Moderator, "unblock"),
    {303, _, _} = upload(Config, Other, [{<<"d.jpg">>, Jpg}]),
    %% purged: gone from both posts, and from the other's staged upload
    303 = Act(Admin, "purge_image"),
    {404, _, _} = media(Config, File),
    [[0]] = query(
        Config,
        "SELECT count(*) FROM upload u JOIN actor a ON a.id = u.actor WHERE a.subject = 'blocked-too'",
        []
    ),
    {200, _, Page} = request(Config, get, page(H), [], none),
    {_, _} = binary:match(Page, <<"<span class=\"gone\">image</span>">>),
    {422, _, _} = upload(Config, Other, [{<<"e.jpg">>, Jpg}]).

the_uploader_can_be_suspended(Config) ->
    Uploader = login(Config, <<"suspendable">>),
    Peer = login(Config, <<"suspend-mod">>, #{groups => [<<"ike-moderator">>]}),
    Other = login(Config, <<"suspend-mod2">>, #{groups => [<<"ike-moderator">>]}),
    Act = fun(#{csrf := Csrf} = Who, Path) ->
        Form = uri_string:compose_query([{"csrf", Csrf}, {"kind", "ban"}, {"reason", "x"}]),
        element(1, request(Config, post, Path, cookies(Who), {form, Form}))
    end,
    %% a moderator's own unsigned image: not by a peer, nor by itself
    {303, _, _} = upload(Config, Other, [{<<"m.png">>, read(Config, "base.png")}]),
    {303, H1, _} = with(
        Config, Other, "/board/b/new", <<"unsigned">>, latest(Config, <<"suspend-mod2">>)
    ),
    "#p" ++ N1 = string:find(proplists:get_value("location", H1), "#"),
    403 = Act(Peer, "/mod/post/" ++ N1),
    403 = Act(Other, "/mod/post/" ++ N1),
    %% an account's unsigned image: banned through it, unseen
    {303, _, _} = upload(Config, Uploader, [{<<"s.png">>, read(Config, "base.png")}]),
    {303, H2, _} = with(
        Config, Uploader, "/board/b/new", <<"unsigned">>, latest(Config, <<"suspendable">>)
    ),
    "#p" ++ N2 = string:find(proplists:get_value("location", H2), "#"),
    {200, _, Look} = request(Config, get, "/mod/post/" ++ N2, cookies(Peer), none),
    {_, _} = binary:match(Look, <<"unsigned">>),
    nomatch = binary:match(Look, <<"suspendable">>),
    303 = Act(Peer, "/mod/post/" ++ N2),
    [[1]] = query(Config, "SELECT banned FROM actor WHERE subject = 'suspendable'", []),
    {200, _, Form} = request(Config, get, "/board/b/new", cookies(Uploader), none),
    nomatch = binary:match(Form, <<"/logout">>).

a_post_shows_several(Config) ->
    Session = login(Config, <<"several">>),
    Other = login(Config, <<"several-other">>),
    Moderator = login(Config, <<"several-mod">>, #{groups => [<<"ike-moderator">>]}),
    Admin = login(Config, <<"several-admin">>, #{groups => [<<"ike-admin">>]}),
    {303, _, _} = upload(Config, Session, [
        {<<"a.png">>, read(Config, "base.png")}, {<<"b.webp">>, read(Config, "lossy.webp")}
    ]),
    [[A, B]] = [
        [
            X
         || [X] <- query(
                Config,
                "SELECT u.id FROM upload u JOIN actor a ON a.id = u.actor"
                " WHERE a.subject = 'several' AND u.posted IS NULL ORDER BY u.id",
                []
            )
        ]
    ],
    {303, _, _} = upload(Config, Other, [{<<"c.png">>, read(Config, "base.png")}]),
    Theirs = latest(Config, <<"several-other">>),
    Ids = fun(L) -> [{<<"upload">>, integer_to_binary(I)} || I <- L] end,
    %% all or none: one that is not the account's fails the post, and
    %% takes nothing with it
    {400, _, _} = post(Config, "/board/b/new", Session, <<"three">>, Ids([A, B, Theirs])),
    [[0]] = query(
        Config, "SELECT count(*) FROM upload WHERE id IN (?, ?) AND posted IS NOT NULL", [A, B]
    ),
    {303, H, _} = post(Config, "/board/b/new", Session, <<"two">>, Ids([B, A])),
    {200, _, Page} = request(Config, get, page(H), [], none),
    {match, Shown} = re:run(
        Page,
        "<a href=\"(http://media\\.test/[0-9a-f]{64}\\.[a-z]+)\"><img",
        [global, {capture, all_but_first, list}]
    ),
    %% in the order ticked
    [[First], [Second]] = Shown,
    ".webp" = filename:extension(First),
    ".png" = filename:extension(Second),
    "#p" ++ N = string:find(proplists:get_value("location", H), "#"),
    Path = "/mod/post/" ++ N,
    %% the post, with both, can be moderated: hidden and back
    Act = fun(#{csrf := Csrf} = Who, Fields) ->
        Form = uri_string:compose_query([{"csrf", Csrf}, {"reason", "x"} | Fields]),
        element(1, request(Config, post, Path, cookies(Who), {form, Form}))
    end,
    303 = Act(Moderator, [{"kind", "hide"}]),
    303 = Act(Moderator, [{"kind", "unhide"}]),
    {200, _, Look} = request(Config, get, Path, cookies(Admin), none),
    {_, _} = binary:match(Look, <<"with 2 images">>),
    %% one image purged, the other stays
    303 = Act(Admin, [{"kind", "purge_image"}, {"image", "0"}]),
    {200, _, After} = request(Config, get, page(H), [], none),
    {_, _} = binary:match(After, <<"<span class=\"gone\">image</span>">>),
    {match, [[Left]]} = re:run(
        After,
        "<a href=\"(http://media\\.test/[0-9a-f]{64}\\.[a-z]+)\"><img",
        [global, {capture, all_but_first, list}]
    ),
    Second = Left,
    {200, _, _} = media(Config, Second),
    %% and too many at once is refused
    Many = [I || I <- lists:seq(1, 9)],
    {400, _, _} = post(Config, "/board/b/new", Session, <<"many">>, Ids(Many)).

a_video_plays(Config) ->
    Session = login(Config, <<"filmer">>),
    {303, _, _} = upload(Config, Session, [{<<"v.webm">>, read(Config, "base.webm")}]),
    {303, H, _} = with(
        Config, Session, "/board/b/new", <<"a video">>, latest(Config, <<"filmer">>)
    ),
    {200, _, Page} = request(Config, get, page(H), [], none),
    {match, [Src, Poster]} = re:run(
        Page,
        "<video src=\"(http://media\\.test/[0-9a-f]{64}\\.webm)\" poster=\"(http://media\\.test/[0-9a-f]{64}\\.thumb\\.webp)\" preload=\"none\" controls>",
        [{capture, all_but_first, list}]
    ),
    {200, VH, _} = media(Config, Src),
    "video/webm" = proplists:get_value("content-type", VH),
    {200, PH, _} = media(Config, Poster),
    "image/webp" = proplists:get_value("content-type", PH),
    %% and what will not play is refused, in the words of any refusal
    Mkv = <<16#1A, 16#45, 16#DF, 16#A3, "not really a video">>,
    {422, _, Refused} = upload(Config, Session, [{<<"x.mkv">>, Mkv}]),
    {_, _} = binary:match(Refused, <<"file 1: not taken<">>).

%% the post form as a browser sends it with files: its token first
post_with_files(Config, Headers, Path, Token, Text, Files) ->
    {Type, Body} = ike_browser:multipart(
        [{field, <<"csrf">>, Token}, {field, <<"body">>, Text}] ++
            [{file, <<"file">>, F} || F <- Files]
    ),
    request(Config, post, Path, Headers, {Type, Body}).

files_on_the_post_form(Config) ->
    #{csrf := Csrf} = Session = login(Config, <<"oneform">>),
    %% the form takes files, with no trip through /upload
    {200, _, Form} = request(Config, get, "/board/b/new", cookies(Session), none),
    {_, _} = binary:match(Form, <<"enctype=\"multipart/form-data\"">>),
    {_, _} = binary:match(Form, <<"<input type=\"file\"">>),
    {303, H, _} = post_with_files(
        Config,
        cookies(Session),
        "/board/b/new",
        list_to_binary(Csrf),
        <<"in one go">>,
        [{<<"a.png">>, read(Config, "base.png")}, {<<"b.webm">>, read(Config, "base.webm")}]
    ),
    {200, _, Page} = request(Config, get, page(H), [], none),
    {_, _} = binary:match(Page, <<"<img src=\"http://media.test/">>),
    {_, _} = binary:match(Page, <<"<video src=\"http://media.test/">>),
    %% one that is no image fails the post, and nothing of it is kept
    Before = ike_browser:posts(Config),
    {422, _, Refused} = post_with_files(
        Config,
        cookies(Session),
        "/board/b/new",
        list_to_binary(Csrf),
        <<"no">>,
        [{<<"x.txt">>, <<"plain text">>}]
    ),
    {_, _} = binary:match(Refused, <<"file 1: not taken">>),
    Before = ike_browser:posts(Config),
    %% and a form from elsewhere has its files never read
    {403, _, _} = post_with_files(
        Config,
        cookies(Session),
        "/board/b/new",
        <<"wrong">>,
        <<"no">>,
        [{<<"a.png">>, read(Config, "base.png")}]
    ),
    %% nobody posts no files while the switch is off
    ok = ike_browser:unlock(Config, <<"b">>),
    {Token, Cookie, _} = ike_browser:form(Config, "/board/b/new", []),
    {403, _, _} = post_with_files(
        Config,
        [{"cookie", "__Host-ike-form=" ++ Cookie}],
        "/board/b/new",
        list_to_binary(Token),
        <<"mine">>,
        [{<<"a.png">>, read(Config, "base.png")}]
    ).

nobody_posts_still_images_when_let(Config0) ->
    ike_browser:stop(),
    Config = ike_browser:start(Config0, [{anonymous_uploads, true}]),
    ok = ike_browser:unlock(Config, <<"meta">>),
    {Token, Cookie, _} = ike_browser:form(Config, "/board/meta/new", []),
    Headers = [{"cookie", "__Host-ike-form=" ++ Cookie}],
    {200, _, Form} = request(Config, get, "/board/meta/new", Headers, none),
    {_, _} = binary:match(Form, <<"accept=\"image/jpeg,image/png,image/webp\"">>),
    {303, H, _} = post_with_files(
        Config,
        Headers,
        "/board/meta/new",
        list_to_binary(Token),
        <<"from nobody">>,
        [{<<"a.png">>, read(Config, "base.png")}]
    ),
    {200, _, Page} = request(Config, get, page(H), [], none),
    {_, _} = binary:match(Page, <<"<img src=\"http://media.test/">>),
    %% the upload is nobody's, and was never staged
    [[1, 1]] = query(Config, "SELECT u.actor, u.posted IS NOT NULL FROM upload u", []),
    %% what moves is not nobody's to post
    {422, _, _} = post_with_files(
        Config,
        Headers,
        "/board/meta/new",
        list_to_binary(Token),
        <<"a video">>,
        [{<<"v.webm">>, read(Config, "base.webm")}]
    ).
