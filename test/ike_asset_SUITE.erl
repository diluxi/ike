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
    a_blocked_image_does_not_come_back/1
]).

-import(ike_browser, [login/2, login/3, post/5, request/5, query/3, cookies/1, upload/3, media/2]).

all() ->
    [
        the_same_bytes_are_one_asset,
        a_post_shows_an_upload,
        only_ones_own_once,
        the_media_follow_what_is_shown,
        a_restart_makes_them_again,
        a_blocked_image_does_not_come_back
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
    nomatch = binary:match(Staged, <<"upload ", (integer_to_binary(Upload))/binary>>),
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

the_media_follow_what_is_shown(Config) ->
    Session = login(Config, <<"shown">>),
    Moderator = login(Config, <<"shown-mod">>, #{groups => [<<"ike-moderator">>]}),
    %% bytes no other test posts, so that no other post shows this asset
    {303, _, _} = upload(Config, Session, [{<<"t.webp">>, read(Config, "lossy.webp")}]),
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
    %% and with that one hidden too, it is gone from the media origin
    Root2 = lists:last(string:split(page(H2), "/", all)),
    #{csrf := Csrf2} = Moderator,
    {303, _, _} = request(
        Config,
        post,
        "/mod/post/" ++ Root2,
        cookies(Moderator),
        {form, uri_string:compose_query([{"csrf", Csrf2}, {"kind", "hide"}, {"reason", "x"}])}
    ),
    {404, _, _} = media(Config, File),
    {404, _, _} = media(Config, Thumb),
    Act("unhide"),
    {200, _, _} = media(Config, File),
    {200, _, _} = media(Config, Thumb).

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
        Form = uri_string:compose_query([{"csrf", Csrf}, {"kind", Kind}, {"reason", "x"}]),
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
    %% (unsigned: no account to ban)
    [<<"hide">>, <<"delete">>, <<"block">>] = Offered(Moderator),
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
