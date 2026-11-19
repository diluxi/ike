%% Fonts, from outside (lux, 2026-11-17): an account uploads one, and its
%% meta shows a thumbnail of an F drawn in it, a line to try it on with
%% sliders for its size, weight and other axes, and what it said of
%% itself as commentary; the same font credited to someone else is the
%% same asset; the media origin serves it to pages with cors; posted, it
%% is an entry tagged font, tried out on its page; purged, its files go.
-module(ike_font_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    a_font_and_its_meta/1,
    credits_are_no_part_of_it/1,
    variable_axes_are_sliders/1,
    posted_it_is_an_entry/1,
    purged_its_files_go/1
]).

-import(ike_browser, [login/2, login/3, request/5, query/3, cookies/1, media/2]).

all() ->
    [
        a_font_and_its_meta,
        credits_are_no_part_of_it,
        variable_axes_are_sliders,
        posted_it_is_an_entry,
        purged_its_files_go
    ].

init_per_suite(Config) ->
    ike_browser:start(Config, []).

end_per_suite(_Config) ->
    ike_browser:stop().

read(Config, Name) ->
    {ok, Bytes} = file:read_file(filename:join(?config(data_dir, Config), Name)),
    Bytes.

%% the asset of the newest upload of the account called Subject, as hex
uploaded(Config, Subject) ->
    [[Hash]] = query(
        Config,
        "SELECT u.asset FROM upload u JOIN actor a ON a.id = u.actor"
        " WHERE a.subject = ? ORDER BY u.id DESC LIMIT 1",
        [Subject]
    ),
    binary_to_list(binary:encode_hex(Hash, lowercase)).

%% the newest meta of the account called Subject, and its asset's hex
newest(Config, Subject) ->
    [[Id, Hash]] = query(
        Config,
        "SELECT m.id, m.asset FROM meta m JOIN actor a ON a.id = m.owner"
        " WHERE a.subject = ? ORDER BY m.id DESC LIMIT 1",
        [Subject]
    ),
    {"/trunk/" ++ integer_to_list(Id), binary_to_list(binary:encode_hex(Hash, lowercase))}.

a_font_and_its_meta(Config) ->
    Session = login(Config, <<"typographer">>),
    {200, _, Form} = request(Config, get, "/upload", cookies(Session), none),
    {_, _} = binary:match(Form, <<".ttf,.otf,.woff,.woff2">>),
    {303, _, _} = ike_browser:upload(Config, Session, [{<<"f.ttf">>, read(Config, "font.ttf")}]),
    {Meta, Hex} = newest(Config, <<"typographer">>),
    {200, _, Page} = request(Config, get, Meta, [], none),
    File = list_to_binary("http://media.test/" ++ Hex ++ ".ttf"),
    %% no thumbnail on its page (lux): its text in its place, drawn in it
    %% by ike.js, and the reader's to type over
    nomatch = binary:match(Page, list_to_binary("<img src=\"http://media.test/" ++ Hex)),
    {_, _} = binary:match(
        Page,
        <<"<div class=\"specimen\" data-font=\"", File/binary,
            "\"><textarea class=\"sample\" rows=\"3\" spellcheck=\"false\">The quick brown fox">>
    ),
    %% (the trunk shows its thumbnail, an F drawn in it)
    {200, _, Trunk} = request(Config, get, "/trunk", [], none),
    {_, _} = binary:match(Trunk, list_to_binary("http://media.test/" ++ Hex ++ ".thumb.webp")),
    {_, _} = binary:match(Page, <<"data-axis=\"size\"">>),
    %% a font without a weight axis gets the weights a browser makes
    {_, _} = binary:match(Page, <<"data-axis=\"weight\" min=\"100\" max=\"900\" value=\"400\"">>),
    {_, _} = binary:match(Page, <<"<td>Ike Test</td>">>),
    %% what it said of itself, as commentary: in the meta, not the file
    {_, _} = binary:match(Page, <<"<th>designer</th><td>SECRET-DESIGNER</td>">>),
    {_, _} = binary:match(Page, <<"<th>license</th><td>SECRET-LICENSE</td>">>),
    {_, _} = binary:match(Page, <<"<th>vendor id</th><td>SCRT</td>">>),
    {200, Headers, Stored} = media(Config, binary_to_list(File)),
    nomatch = binary:match(Stored, <<"SECRET">>),
    "font/ttf" = proplists:get_value("content-type", Headers),
    "*" = proplists:get_value("access-control-allow-origin", Headers),
    "nosniff" = proplists:get_value("x-content-type-options", Headers),
    %% pages may load fonts from the media origin, and from nowhere else
    {200, PageHeaders, _} = request(Config, get, "/", [], none),
    true =
        string:find(
            proplists:get_value("content-security-policy", PageHeaders),
            "font-src http://media.test;"
        ) =/= nomatch,
    {200, _, Script} = request(Config, get, "/ike.js", [], none),
    {_, _} = binary:match(Script, <<"new FontFace(">>),
    %% a woff2 stays a woff2
    {303, _, _} = ike_browser:upload(Config, Session, [{<<"f.woff2">>, read(Config, "font.woff2")}]),
    {Woff2Meta, Woff2Hex} = newest(Config, <<"typographer">>),
    {200, _, Woff2Page} = request(Config, get, Woff2Meta, [], none),
    {_, _} = binary:match(Woff2Page, <<"<th>woff metadata</th>">>),
    {200, Woff2Headers, _} = media(Config, "http://media.test/" ++ Woff2Hex ++ ".woff2"),
    "font/woff2" = proplists:get_value("content-type", Woff2Headers),
    %% nobody posts a font: their files are still images, when let at all
    [[0]] = query(
        Config,
        "SELECT count(*) FROM upload u JOIN asset x ON x.hash = u.asset"
        " WHERE u.actor = 1 AND x.filetype IN ('ttf', 'otf', 'woff', 'woff2')",
        []
    ).

%% the same font credited to someone else is the same bytes, and leads
%% to the meta there is; what it said is kept with the upload all the same
credits_are_no_part_of_it(Config) ->
    A = login(Config, <<"first-type">>),
    B = login(Config, <<"second-type">>),
    {303, _, _} = ike_browser:upload(Config, A, [{<<"f.ttf">>, read(Config, "font.ttf")}]),
    [[Assets]] = query(Config, "SELECT count(*) FROM asset WHERE filetype = 'ttf'", []),
    {303, Led, _} = ike_browser:upload(Config, B, [{<<"g.ttf">>, read(Config, "font-other.ttf")}]),
    "/trunk/" ++ _ = proplists:get_value("location", Led),
    [[Assets]] = query(Config, "SELECT count(*) FROM asset WHERE filetype = 'ttf'", []),
    [[Said]] = query(
        Config,
        "SELECT u.commentary FROM upload u JOIN actor a ON a.id = u.actor"
        " WHERE a.subject = 'second-type' ORDER BY u.id DESC LIMIT 1",
        []
    ),
    {_, _} = binary:match(Said, <<"SECRET-OTHER-DESIGNER">>).

variable_axes_are_sliders(Config) ->
    Session = login(Config, <<"varier">>),
    {303, _, _} = ike_browser:upload(Config, Session, [{<<"v.ttf">>, read(Config, "variable.ttf")}]),
    {Meta, _} = newest(Config, <<"varier">>),
    {200, _, Page} = request(Config, get, Meta, [], none),
    {_, _} = binary:match(Page, <<"data-axis=\"wght\" min=\"100\" max=\"900\" value=\"400\"">>),
    {_, _} = binary:match(Page, <<"<th>axis wght</th><td>100 to 900, 400 by default</td>">>),
    {_, _} = binary:match(Page, <<"<td>Ike Var</td>">>),
    {_, _} = binary:match(Page, <<"<td>font variable</td>">>).

%% a font curated is an entry, tagged font, tried out on its page as on
%% its meta's
posted_it_is_an_entry(Config) ->
    #{csrf := Csrf} = Session = login(Config, <<"poster-type">>),
    %% the bytes have a public meta (variable_axes_are_sliders'): there
    {303, Led, _} = ike_browser:upload(Config, Session, [
        {<<"v.ttf">>, read(Config, "variable.ttf")}
    ]),
    "/trunk/" ++ _ = Meta = proplists:get_value("location", Led),
    {303, Curated, _} = request(
        Config,
        post,
        Meta ++ "/curate",
        cookies(Session),
        {form, uri_string:compose_query([{"csrf", Csrf}, {"tags", "font\nsans"}])}
    ),
    "/booru/" ++ _ = Entry = proplists:get_value("location", Curated),
    {200, _, Page} = request(Config, get, Entry, [], none),
    {_, _} = binary:match(Page, <<"class=\"specimen\"">>),
    {_, _} = binary:match(Page, <<"data-axis=\"wght\"">>),
    {_, _} = binary:match(Page, <<"href=\"/wiki/meta/font\"">>),
    {_, _} = binary:match(Page, <<"href=\"/wiki/description/sans\"">>).

purged_its_files_go(Config) ->
    #{csrf := Csrf} = Session = login(Config, <<"purged-type">>),
    Admin = login(Config, <<"type-admin">>, #{groups => [<<"ike-admin">>]}),
    {Type, Body} = ike_browser:multipart([
        {field, <<"csrf">>, list_to_binary(Csrf)},
        {field, <<"body">>, <<"to purge">>},
        {file, <<"file">>, {<<"w.woff2">>, read(Config, "font.woff2")}}
    ]),
    {303, H, _} = request(Config, post, "/board/b/new", cookies(Session), {Type, Body}),
    "#p" ++ Post = string:find(proplists:get_value("location", H), "#"),
    Hex = uploaded(Config, <<"purged-type">>),
    File = "http://media.test/" ++ Hex ++ ".woff2",
    {200, _, _} = media(Config, File),
    #{csrf := AdminCsrf} = Admin,
    {303, _, _} = request(
        Config,
        post,
        "/mod/post/" ++ Post,
        cookies(Admin),
        {form,
            uri_string:compose_query([
                {"csrf", AdminCsrf}, {"kind", "purge_image"}, {"image", "0"}, {"reason", "x"}
            ])}
    ),
    {404, _, _} = media(Config, File),
    {404, _, _} = media(Config, "http://media.test/" ++ Hex ++ ".thumb.webp"),
    Media = filename:join(?config(dir, Config), "media"),
    false = filelib:is_regular(filename:join(Media, Hex ++ ".woff2")).
