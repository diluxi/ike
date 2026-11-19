%% What the pages say. Pure: rows in, a tree out; ike_render and the
%% handlers decide where it goes.
-module(ike_view).

-export([thread/3, board/2, boards/1, post_form/2, message/2, layout/2]).
-export([moderation/5, moderated/3, upload/4, upload_locked/0, account/1, acted/2]).
-export([entry/1, entries/1, moderated_entry/4, search/2, ambiguous/2]).
-export([wiki_index/1, wiki_many/2, wiki_page/4, wiki_missing/3, wiki_edit/5, wiki_history/2]).
-export([style/0, script/0, user/2, trunk/1, meta/4, moderated_meta/4, index/2]).
-export([preview/3, preview_button/0]).

-export_type([post/0, summary/0, board/0, held/0, image/0]).

%% name: an account's, or what stands in for one
%% links: the posts the text points at that are there, and their boards
%% replies: the posts that point at this one
-type post() :: #{
    id := integer(),
    time := integer(),
    body := binary(),
    name := {account | nobody | role, binary()},
    links := #{integer() | {booru, integer()} | {page, binary()} | {meta, integer()} => binary()},
    replies := [integer()],
    images => [image() | gone],
    title => binary() | none,
    %% a wiki revision, and what it changed of the one before
    revision => boolean(),
    changes => [ike_wiki:change()],
    %% a wiki page's first post, out of view: its title and nothing else
    tombstone => true,
    %% a curation's revision: the tags it put on and took off (its
    %% changes are then its commentary's), each kind/name and as shown
    curation => {[{binary(), binary()}], [{binary(), binary()}]}
}.
%% an asset a post shows, where the media origin has it
-type image() :: #{
    file := binary(),
    thumb := binary(),
    type := binary(),
    %% 0 for a font, which has none
    width := non_neg_integer(),
    height := non_neg_integer(),
    %% a font's variable axes, where its page tries it out
    axes => [{binary(), float(), float(), float()}]
}.
%% a thread as its board lists it
-type summary() :: #{root := integer(), posts := integer(), body := binary()}.
%% log: the board is the record of what moderators did, and takes no posts
%% wiki: its threads are pages, newest first, revisions shown as changes
%% page: a wiki thread's page name, which heads it
-type board() :: #{
    name := binary(), title := binary(), log := boolean(), wiki => boolean(), page => binary()
}.
%% a post as a moderator is shown it, whatever state it is in
-type held() :: #{
    id := integer(),
    thread := integer(),
    board := binary(),
    state := shown | hidden | trashed,
    time := integer(),
    body := binary(),
    name := binary() | none,
    account := local | suspended | none,
    %% whether its poster trashed it
    retracted := boolean(),
    %% its images, in order: there, there and blocked, or purged
    images := [{non_neg_integer(), shown | blocked | gone}],
    %% who signed it, their rank, and the rank that put it in its state
    author := integer(),
    rank := 0..3,
    undo := 0..4
}.

-define(EXCERPT, 120).

-spec thread(board(), Root :: integer(), [post()]) -> ike_html:html().
thread(#{name := Name, log := Log} = Board, Root, Posts) ->
    N = integer_to_binary(Root),
    Here = <<"/board/", Name/binary, "/", N/binary>>,
    Reply =
        case Log of
            true -> [];
            false -> [ike_html:el(p, [anchor(<<Here/binary, "/reply">>, <<"reply">>)])]
        end,
    Wiki = maps:get(wiki, Board, false),
    %% the newest revision is shown open; older ones fold into their header
    Newest = newest(Posts, 0),
    List =
        case Wiki of
            %% a page's thread is its history and its talk, newest first
            true ->
                ike_html:el(ol, [reversed], [
                    ike_html:el(li, [post(P, Log, Newest)])
                 || P <- backwards(Posts, [])
                ]);
            false ->
                ike_html:el(ol, [ike_html:el(li, [post(P, Log, Newest)]) || P <- Posts])
        end,
    Heading =
        case {Board, [T || #{id := I, title := T} <- Posts, I =:= Root, is_binary(T)]} of
            {#{page := Page}, _} -> Page;
            {_, [T | _]} -> T;
            {_, []} -> <<">>", N/binary>>
        end,
    Body =
        case Log of
            true ->
                [List];
            %% the posts and what can be done to the ticked ones, in one
            %% form, as vichan has it
            false ->
                [
                    ike_html:el(form, [{method, <<"post">>}, {action, <<"/act">>}], [
                        List | act_on(Here)
                    ])
                ]
        end,
    layout(Heading, [
        ike_html:el(h1, [ike_html:text(Heading)]),
        ike_html:el(p, [board_link(Board)])
        | Body ++ Reply
    ]).

-spec newest([post()], non_neg_integer()) -> non_neg_integer().
newest([#{id := I, revision := true} | Ps], N) when I > N -> newest(Ps, I);
newest([_ | Ps], N) -> newest(Ps, N);
newest([], N) -> N.

-spec backwards([post()], [post()]) -> [post()].
backwards([P | Ps], Acc) -> backwards(Ps, [P | Acc]);
backwards([], Acc) -> Acc.

%% the foot of a thread's form: retract with a password (left empty, the
%% one this browser posted with), report with a reason, and, doing
%% nothing for anyone without a role, the moderators' rungs
-spec act_on(binary()) -> [ike_html:html()].
act_on(Here) ->
    Button = fun(Kind, Label) ->
        ike_html:el(button, [{type, <<"submit">>}, {name, <<"kind">>}, {value, Kind}], [
            ike_html:text(Label)
        ])
    end,
    [
        ike_html:el(input, [{type, <<"hidden">>}, {name, <<"back">>}, {value, Here}], []),
        ike_html:el(p, [
            ike_html:el(label, [{for, <<"act-password">>}], [ike_html:text(<<"password ">>)]),
            ike_html:el(
                input,
                [{type, <<"password">>}, {id, <<"act-password">>}, {name, <<"password">>}],
                []
            ),
            ike_html:text(<<" ">>),
            Button(<<"retract">>, <<"retract">>)
        ]),
        ike_html:el(p, [
            ike_html:el(label, [{for, <<"act-reason">>}], [ike_html:text(<<"reason ">>)]),
            ike_html:el(
                input, [{id, <<"act-reason">>}, {name, <<"reason">>}, {maxlength, <<"1000">>}], []
            ),
            ike_html:text(<<" ">>),
            Button(<<"report">>, <<"report">>)
        ]),
        ike_html:el(details, [
            ike_html:el(summary, [ike_html:text(<<"moderate">>)]),
            ike_html:el(
                p,
                spaced([
                    Button(K, K)
                 || K <- [<<"hide">>, <<"trash">>, <<"purge">>, <<"ban">>]
                ])
            )
        ])
    ].

%% what /act did, a line for each post, and the way back
-spec acted([binary()], Back :: binary()) -> ike_html:html().
acted(Lines, Back) ->
    layout(<<"done">>, [
        ike_html:el(h1, [ike_html:text(<<"done">>)]),
        ike_html:el(ul, [ike_html:el(li, [ike_html:text(L)]) || L <- Lines]),
        ike_html:el(p, [anchor(Back, <<"back">>)])
    ]).

-spec post(post(), Log :: boolean(), Newest :: non_neg_integer()) -> ike_html:html().
post(#{id := Id, tombstone := true} = Post, _Log, _Newest) ->
    N = integer_to_binary(Id),
    Title =
        case maps:get(title, Post, none) of
            T when is_binary(T) -> T;
            _ -> <<>>
        end,
    ike_html:el(article, [{id, <<"p", N/binary>>}], [
        ike_html:el(header, [
            ike_html:el(span, [{class, <<"title">>}], [ike_html:text(Title)]),
            ike_html:text(<<" ">>),
            anchor(<<"#p", N/binary>>, <<">>", N/binary>>)
        ]),
        ike_html:el(p, [gone(<<"taken down">>)])
    ]);
post(
    #{id := Id, time := Time, body := Body, name := {Kind, Name}, links := Links} = Post,
    Log,
    Newest
) ->
    N = integer_to_binary(Id),
    Anchor = <<"p", N/binary>>,
    Stamp = stamp(Time),
    Class =
        case Kind of
            account -> <<"name account">>;
            role -> <<"name role">>;
            nobody -> <<"name">>
        end,
    Tick =
        case Log of
            true ->
                [];
            false ->
                [
                    ike_html:el(
                        input, [{type, <<"checkbox">>}, {name, <<"post">>}, {value, N}], []
                    ),
                    ike_html:text(<<" ">>)
                ]
        end,
    %% a signed name leads to the account's own page
    Named =
        case Kind of
            account -> [anchor(<<"/user/", Name/binary>>, Name)];
            _ -> [ike_html:text(Name)]
        end,
    Titled =
        case maps:get(title, Post, none) of
            T when is_binary(T) ->
                [
                    ike_html:el(span, [{class, <<"title">>}], [ike_html:text(T)]),
                    ike_html:text(<<" ">>)
                ];
            _ ->
                []
        end,
    %% a wiki revision: what it changed, folded beside the header but for
    %% the newest
    {Folded, Text} =
        case Post of
            #{revision := true, changes := Changes, curation := {On, Off}} ->
                Lines = {
                    length([x || {added, _} <- Changes]), length([x || {removed, _} <- Changes])
                },
                Summary =
                    [ike_html:text(<<"tags ">>) | counted({length(On), length(Off)})] ++
                        [ike_html:text(<<", commentary ">>) | counted(Lines)],
                Open = [open || Id =:= Newest],
                {
                    [
                        ike_html:text(<<" ">>),
                        ike_html:el(details, Open, [
                            ike_html:el(summary, Summary),
                            ike_html:el(
                                p,
                                spaced(
                                    [ike_html:el(ins, [tag_link(T)]) || T <- On] ++
                                        [ike_html:el(del, [tag_link(T)]) || T <- Off]
                                )
                            )
                            | [ike_html:el(p, changes(Changes)) || Changes =/= []]
                        ])
                    ],
                    []
                };
            #{revision := true, changes := Changes} ->
                Added = length([x || {added, _} <- Changes]),
                Removed = length([x || {removed, _} <- Changes]),
                Count =
                    [
                        ike_html:el(span, [{class, <<"added">>}], [
                            ike_html:text(<<"+", (integer_to_binary(Added))/binary>>)
                        ])
                     || Added > 0
                    ] ++
                        [ike_html:text(<<" ">>) || Added > 0, Removed > 0] ++
                        [
                            ike_html:el(span, [{class, <<"removed">>}], [
                                ike_html:text(<<"-", (integer_to_binary(Removed))/binary>>)
                            ])
                         || Removed > 0
                        ] ++
                        [ike_html:text(<<"=">>) || Added =:= 0, Removed =:= 0],
                Open = [open || Id =:= Newest],
                {
                    [
                        ike_html:text(<<" ">>),
                        ike_html:el(details, Open, [
                            ike_html:el(summary, Count),
                            ike_html:el(p, changes(Changes))
                        ])
                    ],
                    []
                };
            _ ->
                {
                    [],
                    case Body of
                        <<>> -> [];
                        _ -> blocks(ike_markup:parse(Body), Links)
                    end
                }
        end,
    Header = ike_html:el(
        header,
        Tick ++ Titled ++
            [ike_html:el(span, [{class, Class}], Named)] ++
            [
                ike_html:text(<<" ">>),
                anchor(<<"#", Anchor/binary>>, <<">>", N/binary>>),
                ike_html:text(<<" ">>),
                ike_html:el(time, [{datetime, Stamp}], [ike_html:text(Stamp)])
            ] ++ Folded
    ),
    ike_html:el(
        article,
        [{id, Anchor}],
        [Header | figures(maps:get(images, Post, []))] ++ Text ++ replies(maps:get(replies, Post))
    ).

%% a revision's count, coloured: +n green, -n red, = for no change
-spec counted({non_neg_integer(), non_neg_integer()}) -> [ike_html:html()].
counted({0, 0}) ->
    [ike_html:text(<<"=">>)];
counted({Added, Removed}) ->
    [
        ike_html:el(span, [{class, <<"added">>}], [
            ike_html:text(<<"+", (integer_to_binary(Added))/binary>>)
        ])
     || Added > 0
    ] ++
        [ike_html:text(<<" ">>) || Added > 0, Removed > 0] ++
        [
            ike_html:el(span, [{class, <<"removed">>}], [
                ike_html:text(<<"-", (integer_to_binary(Removed))/binary>>)
            ])
         || Removed > 0
        ].

-spec figures([image() | gone]) -> [ike_html:html()].
figures([Image | Images]) -> figure(Image) ++ figures(Images);
figures([]) -> [].

%% the thumbnail, a link to the whole, and what it is
-spec figure(image() | gone) -> [ike_html:html()].
figure(#{file := File, thumb := Thumb, type := Type, width := W, height := H}) ->
    Size = size(W, H),
    case ike_media:moving(Type) of
        %% a video plays where it is, its first frame shown until then,
        %% nothing fetched before it is asked for; works without a script
        true ->
            [
                ike_html:el(p, [
                    ike_html:el(
                        video,
                        [{src, File}, {poster, Thumb}, {preload, <<"none">>}, controls],
                        [anchor(File, <<Type/binary, Size/binary>>)]
                    )
                ])
            ];
        false ->
            still(File, Thumb, Type, Size)
    end;
figure(gone) ->
    %% the words of every link to something taken down (hazard G5)
    [ike_html:el(p, [gone(<<"image">>)])].

-spec still(binary(), binary(), binary(), binary()) -> [ike_html:html()].
still(File, Thumb, Type, Size) ->
    [
        ike_html:el(p, [
            ike_html:el(a, [{href, File}], [
                ike_html:el(img, [{src, Thumb}, {alt, <<Type/binary, Size/binary>>}], [])
            ])
        ])
    ].

%% ", WxH", or nothing for what has no size (a font)
-spec size(non_neg_integer(), non_neg_integer()) -> binary().
size(0, _) -> <<>>;
size(_, 0) -> <<>>;
size(W, H) -> <<", ", (integer_to_binary(W))/binary, "x", (integer_to_binary(H))/binary>>.

-spec replies([integer()]) -> [ike_html:html()].
replies([]) ->
    [];
replies(Sources) ->
    [ike_html:el(footer, spaced([permalink(S, <<>>) || S <- Sources]))].

-spec spaced([ike_html:html()]) -> [ike_html:html()].
spaced([First, Second | Rest]) -> [First, ike_html:text(<<" ">>) | spaced([Second | Rest])];
spaced(Short) -> Short.

%% a link to a post wherever it is now, written as it was typed
-spec permalink(integer(), Board :: binary()) -> ike_html:html().
permalink(Post, Board) ->
    N = integer_to_binary(Post),
    Text =
        case Board of
            <<>> -> <<">>", N/binary>>;
            _ -> <<">>>/", Board/binary, "/", N/binary>>
        end,
    anchor(<<"/p/", N/binary>>, Text).

%% what a link to nothing leaves: the same whether its target is gone,
%% was never there or is yet to come (hazard g5)
-spec gone(binary()) -> ike_html:html().
gone(Text) ->
    ike_html:el(span, [{class, <<"gone">>}], [ike_html:text(Text)]).

%% a page not yet written: a link to where it would be, which asks for it
-spec missing(binary(), binary()) -> ike_html:html().
missing(Name, Text) ->
    ike_html:el(a, [{class, <<"missing">>}, {href, ike_wiki:path(Name)}], [ike_html:text(Text)]).

-spec piece(ike_text:piece(), #{
    integer() | {booru, integer()} | {page, binary()} | {meta, integer()} => binary()
}) ->
    ike_html:html().
piece({text, Text}, _Links) ->
    ike_html:text(Text);
piece({post, N}, Links) ->
    case Links of
        #{N := _} -> permalink(N, <<>>);
        _ -> gone(<<">>", (integer_to_binary(N))/binary>>)
    end;
%% a page, or a tag, whose page in the wiki leads to its cards; kind/name
%% that kind's, a name alone whichever has it (lux)
piece({page, Name}, Links) ->
    Text = <<"[[", Name/binary, "]]">>,
    case Links of
        #{{page, Name} := Found} when Found =:= <<"page">>; Found =:= <<"tag">> ->
            anchor(ike_wiki:path(Name), Text);
        _ ->
            missing(Name, Text)
    end;
piece({page, Name, Label}, Links) ->
    case Links of
        #{{page, Name} := Found} when Found =:= <<"page">>; Found =:= <<"tag">> ->
            anchor(ike_wiki:path(Name), Label);
        _ ->
            missing(Name, Label)
    end;
piece({entry, N}, Links) ->
    Text = <<"card:", (integer_to_binary(N))/binary>>,
    case Links of
        #{{booru, N} := _} -> anchor(<<"/booru/", (integer_to_binary(N))/binary>>, Text);
        _ -> gone(Text)
    end;
piece({out, Typed, Url}, _Links) ->
    ike_html:el(a, [{class, <<"out">>}, {href, Url}, {rel, <<"nofollow noreferrer">>}], [
        ike_html:text(Typed)
    ]);
piece({meta, N}, Links) ->
    Text = <<"meta:", (integer_to_binary(N))/binary>>,
    case Links of
        #{{meta, N} := _} -> anchor(<<"/trunk/", (integer_to_binary(N))/binary>>, Text);
        _ -> gone(Text)
    end;
piece({booru, N}, Links) ->
    Text = <<"##", (integer_to_binary(N))/binary>>,
    case Links of
        #{{booru, N} := _} -> anchor(<<"/booru/", (integer_to_binary(N))/binary>>, Text);
        _ -> gone(Text)
    end;
piece({post, Board, N}, Links) ->
    case Links of
        #{N := Board} -> permalink(N, Board);
        _ -> gone(<<">>>/", Board/binary, "/", (integer_to_binary(N))/binary>>)
    end.

-spec board(board(), [summary()]) -> ike_html:html().
board(#{name := Name, title := Title, log := Log}, Threads) ->
    Here = <<"/board/", Name/binary>>,
    Heading = <<"/", Name/binary, "/ ", Title/binary>>,
    New =
        case Log of
            true -> [];
            false -> [ike_html:el(p, [anchor(<<Here/binary, "/new">>, <<"new thread">>)])]
        end,
    layout(
        Heading,
        [ike_html:el(h1, [ike_html:text(Heading)]) | New] ++
            [ike_html:el(ul, [ike_html:el(li, summary(Here, T)) || T <- Threads])]
    ).

-spec summary(Board :: binary(), summary()) -> [ike_html:html()].
summary(Here, #{root := Root, posts := Posts, body := Body}) ->
    N = integer_to_binary(Root),
    [
        anchor(<<Here/binary, "/", N/binary>>, <<">>", N/binary>>),
        ike_html:text(<<" ">>),
        ike_html:text(excerpt(Body)),
        ike_html:text(<<" (", (integer_to_binary(Posts))/binary, ")">>)
    ].

-spec boards([board()]) -> ike_html:html().
boards(Boards) ->
    layout(<<"boards">>, [
        ike_html:el(h1, [ike_html:text(<<"boards">>)]),
        ike_html:el(ul, [ike_html:el(li, [board_link(B)]) || B <- Boards])
    ]).

-spec board_link(board()) -> ike_html:html().
board_link(#{name := Name, title := Title}) ->
    anchor(<<"/board/", Name/binary>>, <<"/", Name/binary, "/ ", Title/binary>>).

%% the page in front of everything: the views there are
%% the page in front of everything: where to go, the newest curations
%% as thumbnails, and the newest posts as their board and their first
%% words (lux, after rain.meth.cat's front page; no styles yet)
-spec index([{pos_integer(), image() | gone}], [{pos_integer(), binary(), binary(), binary()}]) ->
    ike_html:html().
index(Curations, Posts) ->
    layout(<<"ike">>, [
        ike_html:el(h1, [ike_html:text(<<"ike">>)]),
        ike_html:el(ul, [
            ike_html:el(li, [anchor(<<"/board">>, <<"board">>)]),
            ike_html:el(li, [anchor(<<"/booru">>, <<"booru">>)]),
            ike_html:el(li, [anchor(<<"/trunk">>, <<"trunk">>)]),
            ike_html:el(li, [anchor(<<"/wiki">>, <<"wiki">>)])
        ]),
        ike_html:el(h2, [ike_html:text(<<"recent cards">>)]),
        ike_html:el(ul, [
            ike_html:el(li, [
                case Image of
                    #{thumb := Thumb} ->
                        ike_html:el(a, [{href, <<"/booru/", (integer_to_binary(Id))/binary>>}], [
                            ike_html:el(
                                img,
                                [{src, Thumb}, {alt, <<"card:", (integer_to_binary(Id))/binary>>}],
                                []
                            )
                        ]);
                    gone ->
                        anchor(
                            <<"/booru/", (integer_to_binary(Id))/binary>>,
                            <<"card:", (integer_to_binary(Id))/binary>>
                        )
                end
            ])
         || {Id, Image} <- Curations
        ]),
        ike_html:el(h2, [ike_html:text(<<"latest posts">>)]),
        ike_html:el(ul, [
            ike_html:el(li, [
                anchor(<<"/board/", Name/binary>>, Title),
                ike_html:text(<<": ">>),
                anchor(
                    <<"/p/", (integer_to_binary(Id))/binary>>,
                    case excerpt(Text) of
                        <<>> -> <<"(no text)">>;
                        E -> E
                    end
                )
            ])
         || {Id, Name, Title, Text} <- Posts
        ])
    ]).

%% the form for a new thread or a reply, for whoever is logged in; anyone
%% else is shown the way to log in. plain forms: nothing here needs a script
-spec post_form(
    Action :: binary(),
    {csrf, binary(), Name :: binary() | none, Staged :: [{pos_integer(), Thumb :: binary()}],
        Password :: binary()}
    | {nobody, Token :: binary(), Password :: binary(), Files :: boolean()}
    | locked
) ->
    ike_html:html().
post_form(Action, {nobody, Token, Password, Files}) ->
    layout(<<"post">>, [
        ike_html:el(h1, [ike_html:text(<<"post">>)]),
        ike_html:el(
            form, [{method, <<"post">>}, {action, Action}, {enctype, <<"multipart/form-data">>}], [
                ike_html:el(input, [{type, <<"hidden">>}, {name, <<"csrf">>}, {value, Token}], []),
                ike_html:el(p, [
                    ike_html:el(label, [{for, <<"title">>}], [ike_html:text(<<"title (optional)">>)]),
                    ike_html:el(br, []),
                    ike_html:el(
                        input, [{id, <<"title">>}, {name, <<"title">>}, {maxlength, <<"100">>}], []
                    ),
                    ike_html:el(br, []),
                    ike_html:el(label, [{for, <<"body">>}], [ike_html:text(<<"text">>)]),
                    ike_html:el(br, []),
                    ike_html:el(
                        textarea,
                        [{id, <<"body">>}, {name, <<"body">>}, {rows, <<"8">>}, required],
                        []
                    )
                ])
                | [files_field(still) || Files] ++
                    [
                        password_field(Password),
                        ike_html:el(p, [
                            ike_html:el(button, [{type, <<"submit">>}], [ike_html:text(<<"post">>)]),
                            ike_html:text(<<" ">>),
                            preview_button()
                        ])
                    ]
            ]
        ),
        ike_html:el(p, [
            ike_html:text(
                <<"posted without an account: nothing is kept but the text (and a password, if given, as a salted hash). or ">>
            ),
            anchor(<<"/login">>, <<"log in">>),
            ike_html:text(<<".">>)
        ])
    ]);
post_form(Action, locked) ->
    layout(<<"post">>, [
        ike_html:el(h1, [ike_html:text(<<"post">>)]),
        ike_html:el(p, [
            ike_html:text(<<"posting here needs an account: ">>),
            anchor(<<"/login">>, <<"log in">>),
            ike_html:text(<<", then come back to ">>),
            anchor(Action, <<"this page">>),
            ike_html:text(<<".">>)
        ])
    ]);
post_form(Action, {csrf, Csrf, Name, Staged, Password}) ->
    %% uploads waiting to be posted, any of them, in the order shown, by
    %% plain checkboxes; with one, the text may be left empty
    Pick =
        case Staged of
            [] ->
                [];
            _ ->
                [
                    ike_html:el(p, [ike_html:text(<<"with your uploads, as many as you tick:">>)])
                    | [
                        ike_html:el(p, [
                            ike_html:el(
                                input,
                                [
                                    {type, <<"checkbox">>},
                                    {id, <<"u", (integer_to_binary(U))/binary>>},
                                    {name, <<"upload">>},
                                    {value, integer_to_binary(U)}
                                ],
                                []
                            ),
                            ike_html:text(<<" ">>),
                            ike_html:el(label, [{for, <<"u", (integer_to_binary(U))/binary>>}], [
                                ike_html:el(
                                    img,
                                    [{src, T}, {alt, <<"upload ", (integer_to_binary(U))/binary>>}],
                                    []
                                )
                            ])
                        ])
                     || {U, T} <- Staged
                    ]
                ]
        end,
    Area =
        case Staged of
            [] -> [{id, <<"body">>}, {name, <<"body">>}, {rows, <<"8">>}, required];
            _ -> [{id, <<"body">>}, {name, <<"body">>}, {rows, <<"8">>}]
        end,
    %% unticked unless asked for: a post carries no name by default
    Signed =
        case Name of
            none ->
                [];
            _ ->
                [
                    ike_html:el(p, [
                        ike_html:el(
                            input,
                            [
                                {type, <<"checkbox">>},
                                {id, <<"signed">>},
                                {name, <<"signed">>},
                                {value, <<"1">>}
                            ],
                            []
                        ),
                        ike_html:text(<<" ">>),
                        ike_html:el(label, [{for, <<"signed">>}], [
                            ike_html:text(<<"post as ", Name/binary>>)
                        ])
                    ])
                ]
        end,
    Token = ike_html:el(input, [{type, <<"hidden">>}, {name, <<"csrf">>}, {value, Csrf}], []),
    layout(<<"post">>, [
        ike_html:el(h1, [ike_html:text(<<"post">>)]),
        ike_html:el(
            form, [{method, <<"post">>}, {action, Action}, {enctype, <<"multipart/form-data">>}], [
                Token,
                ike_html:el(p, [
                    ike_html:el(label, [{for, <<"title">>}], [ike_html:text(<<"title (optional)">>)]),
                    ike_html:el(br, []),
                    ike_html:el(
                        input, [{id, <<"title">>}, {name, <<"title">>}, {maxlength, <<"100">>}], []
                    ),
                    ike_html:el(br, []),
                    ike_html:el(label, [{for, <<"body">>}], [ike_html:text(<<"text">>)]),
                    ike_html:el(br, []),
                    ike_html:el(
                        textarea,
                        Area,
                        []
                    )
                ])
                | Pick ++ [files_field(any)] ++ Signed ++
                    [
                        password_field(Password),
                        ike_html:el(p, [
                            ike_html:el(button, [{type, <<"submit">>}], [ike_html:text(<<"post">>)]),
                            ike_html:text(<<" ">>),
                            preview_button()
                        ])
                    ]
            ]
        ),
        ike_html:el(form, [{method, <<"post">>}, {action, <<"/logout">>}], [
            Token,
            ike_html:el(p, [
                ike_html:el(button, [{type, <<"submit">>}], [ike_html:text(<<"log out">>)])
            ])
        ])
    ]).

%% what a moderator starts from: a way to a post by its number, the
%% boards and whether nobody may post on them, and who is suspended
-spec moderation(
    {Csrf :: binary(), ike_role:role()},
    [{Name :: binary(), Title :: binary(), Locked :: boolean()}],
    [{Account :: integer(), Name :: binary(), Rank :: 0..3}],
    [{pos_integer(), binary(), hidden | trashed}],
    [{pos_integer(), pos_integer(), binary(), binary()}]
) -> ike_html:html().
moderation({Csrf, Role}, Boards, Suspended, Down, Reports) ->
    layout(<<"moderation">>, [
        ike_html:el(h1, [ike_html:text(<<"moderation">>)]),
        ike_html:el(p, [
            ike_html:text(
                <<"as ", (as(Role))/binary, ". what is done is written to ">>
            ),
            anchor(<<"/board/mod">>, <<"/mod/">>),
            ike_html:text(<<", with the reason given and without your name.">>)
        ]),
        %% what readers reported, oldest first
        ike_html:el(ul, [
            ike_html:el(li, [
                anchor(
                    <<"/mod/post/", (integer_to_binary(Post))/binary>>,
                    <<">>", (integer_to_binary(Post))/binary, " on /", Board/binary, "/">>
                ),
                ike_html:text(<<": ", Reason/binary>>)
                | act(
                    <<"/mod/report/", (integer_to_binary(Report))/binary>>, Csrf, [dismiss], []
                )
            ])
         || {Report, Post, Board, Reason} <- Reports
        ]),
        ike_html:el(form, [{method, <<"get">>}, {action, <<"/mod">>}], [
            ike_html:el(p, [
                ike_html:el(label, [{for, <<"post">>}], [ike_html:text(<<"post number ">>)]),
                ike_html:el(input, [{id, <<"post">>}, {name, <<"post">>}, required], []),
                ike_html:text(<<" ">>),
                ike_html:el(button, [{type, <<"submit">>}], [ike_html:text(<<"look">>)])
            ])
        ]),
        ike_html:el(ul, [
            ike_html:el(li, [
                ike_html:text(
                    <<"/", Name/binary, "/ ", Title/binary,
                        (case Locked of
                            true -> <<": accounts only">>;
                            false -> <<": open to anyone">>
                        end)/binary>>
                )
                | act(
                    <<"/mod/board/", Name/binary>>,
                    Csrf,
                    [
                        K
                     || K <- [
                            case Locked of
                                true -> unlock;
                                false -> lock
                            end
                        ],
                        ike_role:may(Role, K)
                    ],
                    []
                )
            ])
         || {Name, Title, Locked} <- Boards
        ]),
        ike_html:el(ul, [
            ike_html:el(li, [
                ike_html:text(<<Name/binary, ": suspended">>)
                | act(
                    <<"/mod/account/", (integer_to_binary(Account))/binary>>,
                    Csrf,
                    [
                        unban
                     || ike_role:permits(Role, unban, #{
                            board => any, self => false, account => Rank, undo => 0
                        })
                    ],
                    []
                )
            ])
         || {Account, Name, Rank} <- Suspended
        ]),
        %% what is out of sight and kept, to be looked at again
        ike_html:el(ul, [
            ike_html:el(li, [
                anchor(
                    <<"/mod/post/", (integer_to_binary(Id))/binary>>,
                    <<">>", (integer_to_binary(Id))/binary, " on /", Board/binary, "/, ",
                        (atom_to_binary(State))/binary>>
                )
            ])
         || {Id, Board, State} <- Down
        ])
    ]).

%% one post, as it is stored, and what this role may do with it
-spec moderated(
    {Csrf :: binary(), ike_role:role()},
    held(),
    {[ike_role:kind()], [{non_neg_integer(), shown | blocked | gone, [ike_role:kind()]}]}
) ->
    ike_html:html().
moderated({Csrf, _Role}, #{id := Id, thread := Thread, board := Board} = Post, {PostKinds, Images}) ->
    #{state := State, time := Time, body := Body, name := Name} = Post,
    N = integer_to_binary(Id),
    Stamp = stamp(Time),
    Where =
        case Id of
            Thread -> <<"/", Board/binary, "/, the first post of its thread">>;
            _ -> <<"/", Board/binary, "/, in >>", (integer_to_binary(Thread))/binary>>
        end,
    layout(
        <<"moderating >>", N/binary>>,
        [
            ike_html:el(h1, [ike_html:text(<<">>", N/binary>>)]),
            ike_html:el(p, [anchor(<<"/mod">>, <<"moderation">>)]),
            ike_html:el(p, [
                ike_html:text(
                    <<
                        (atom_to_binary(State))/binary,
                        (case maps:get(retracted, Post) of
                            true -> <<" (retracted by its poster)">>;
                            false -> <<"">>
                        end)/binary,
                        ", on ",
                        Where/binary,
                        ", "
                    >>
                ),
                ike_html:el(time, [{datetime, Stamp}], [ike_html:text(Stamp)]),
                ike_html:text(
                    case Name of
                        none -> <<", unsigned">>;
                        _ -> <<", signed ", Name/binary>>
                    end
                ),
                ike_html:text(
                    case length(maps:get(images, Post)) of
                        0 -> <<"">>;
                        1 -> <<"; with an image">>;
                        Count -> <<"; with ", (integer_to_binary(Count))/binary, " images">>
                    end
                )
            ]),
            %% as text and nothing more: no link in it is followed from here
            ike_html:el(article, [ike_html:el(p, plain(binary:split(Body, <<"\n">>, [global])))])
            | act(<<"/mod/post/", N/binary>>, Csrf, PostKinds, [])
        ] ++ pictured(N, Csrf, Images)
    ).

%% each of a post's images, and what can be done to it
-spec pictured(binary(), binary(), [{non_neg_integer(), shown | blocked | gone, [ike_role:kind()]}]) ->
    [ike_html:html()].
pictured(N, Csrf, [{Position, Shown, Kinds} | Rest]) ->
    Line =
        <<"image ", (integer_to_binary(Position + 1))/binary,
            (case Shown of
                shown -> <<"">>;
                blocked -> <<", its hash blocked">>;
                gone -> <<", purged">>
            end)/binary>>,
    [
        ike_html:el(p, [ike_html:text(Line)])
        | act(<<"/mod/post/", N/binary>>, Csrf, Kinds, [{<<"image">>, integer_to_binary(Position)}])
    ] ++ pictured(N, Csrf, Rest);
pictured(_N, _Csrf, []) ->
    [].

-spec as(ike_role:role()) -> binary().
as({janitor, [First | Rest]}) ->
    <<"janitor of /", First/binary, "/", <<<<" /", B/binary, "/">> || B <- Rest>>/binary>>;
as(Role) ->
    ike_role:to_binary(Role).

-spec plain([binary()]) -> [ike_html:html()].
plain([Line]) -> [ike_html:text(Line)];
plain([Line | Rest]) -> [ike_html:text(Line), ike_html:el(br, []) | plain(Rest)];
plain([]) -> [].

%% one form for each thing that would go through, each with its reason
-spec act(Action :: binary(), Csrf :: binary(), [ike_role:kind() | dismiss], [{binary(), binary()}]) ->
    [ike_html:html()].
act(Action, Csrf, Kinds, Fields) ->
    Hidden = [
        ike_html:el(input, [{type, <<"hidden">>}, {name, F}, {value, V}], [])
     || {F, V} <- [{<<"csrf">>, Csrf} | Fields]
    ],
    [
        ike_html:el(
            form,
            [{method, <<"post">>}, {action, Action}],
            Hidden ++
                [
                    ike_html:el(
                        input,
                        [{type, <<"hidden">>}, {name, <<"kind">>}, {value, atom_to_binary(Kind)}],
                        []
                    ),
                    ike_html:el(p, [
                        ike_html:el(
                            input, [{name, <<"reason">>}, {maxlength, <<"200">>}, required], []
                        ),
                        ike_html:text(<<" ">>),
                        ike_html:el(button, [{type, <<"submit">>}], [
                            ike_html:text(atom_to_binary(Kind))
                        ])
                    ])
                ]
        )
     || Kind <- Kinds
    ].

%% the uploads page: the form, what was refused just now, and what waits
-spec upload(
    {Csrf :: binary(), Name :: binary() | none, Fetch :: boolean()},
    Refused :: [binary()],
    [#{atom() => term()}],
    [{pos_integer(), pos_integer()}]
) -> ike_html:html().
upload({Csrf, Name, Fetch}, Refused, Staged, Posted) ->
    Sign =
        case Name of
            none ->
                [];
            _ ->
                [
                    ike_html:text(<<" ">>),
                    ike_html:el(
                        input,
                        [
                            {type, <<"checkbox">>},
                            {id, <<"signed">>},
                            {name, <<"signed">>},
                            {value, <<"1">>}
                        ],
                        []
                    ),
                    ike_html:text(<<" ">>),
                    ike_html:el(label, [{for, <<"signed">>}], [
                        ike_html:text(<<"sign as ", Name/binary>>)
                    ])
                ]
        end,
    layout(<<"uploads">>, [
        ike_html:el(h1, [ike_html:text(<<"uploads">>)]),
        ike_html:el(p, [
            ike_html:text(
                <<"images wait here until they are posted, and are listed in the trunk for",
                    " everyone, unless you tick private: then only you and the moderators see",
                    " them. jpeg, png or",
                    " webp; what a file says about itself (place, camera, time) is taken out.",
                    " an upload is tied to your account: a post that uses it shows no name",
                    " unless you sign it, but a moderator can suspend the account behind an",
                    " image without being shown whose it is.">>
            )
        ]),
        ike_html:el(
            form,
            [{method, <<"post">>}, {action, <<"/upload">>}, {enctype, <<"multipart/form-data">>}],
            [
                ike_html:el(input, [{type, <<"hidden">>}, {name, <<"csrf">>}, {value, Csrf}], []),
                ike_html:el(p, [
                    ike_html:el(
                        input,
                        [
                            {type, <<"checkbox">>},
                            {id, <<"private">>},
                            {name, <<"private">>},
                            {value, <<"1">>}
                        ],
                        []
                    ),
                    ike_html:text(<<" ">>),
                    ike_html:el(label, [{for, <<"private">>}], [ike_html:text(<<"private">>)])
                    | Sign
                ]),
                ike_html:el(p, [
                    ike_html:el(
                        input,
                        [
                            {type, <<"file">>},
                            {name, <<"file">>},
                            {accept, <<
                                "image/jpeg,image/png,image/webp,image/svg+xml,.svg,video/webm,video/mp4,",
                                ".ttf,.otf,.woff,.woff2,font/ttf,font/otf,font/woff,font/woff2"
                            >>},
                            multiple,
                            required
                        ],
                        []
                    ),
                    ike_html:text(<<" ">>),
                    ike_html:el(button, [{type, <<"submit">>}], [ike_html:text(<<"upload">>)])
                ])
            ]
        ),
        ike_html:el(ul, [ike_html:el(li, [ike_html:text(R)]) || R <- Refused])
        | [fetch_form(Csrf, Name) || Fetch] ++
            [
                ike_html:el(ul, [staged(S) || S <- Staged]),
                %% and those posted, wherever their posts are now
                ike_html:el(ul, [
                    ike_html:el(li, [
                        ike_html:text(<<"upload ", (integer_to_binary(U))/binary, ", posted in ">>),
                        permalink(P, <<>>)
                    ])
                 || {U, P} <- Posted
                ])
            ]
    ]).

%% an upload from a link (lux, as Danbooru's from a source): the fetcher
%% brings what the link shows, and where it came from goes with it
-spec fetch_form(binary(), binary() | none) -> ike_html:html().
fetch_form(Csrf, Name) ->
    ike_html:el(form, [{method, <<"post">>}, {action, <<"/upload/fetch">>}], [
        ike_html:el(input, [{type, <<"hidden">>}, {name, <<"csrf">>}, {value, Csrf}], []),
        ike_html:el(p, [
            ike_html:el(label, [{for, <<"link">>}], [
                ike_html:text(<<"or from a link (a tweet, for now) ">>)
            ]),
            ike_html:el(
                input,
                [
                    {type, <<"url">>},
                    {id, <<"link">>},
                    {name, <<"link">>},
                    {maxlength, <<"2000">>},
                    required
                ],
                []
            )
        ]),
        ike_html:el(
            p,
            [
                ike_html:el(
                    input,
                    [
                        {type, <<"checkbox">>},
                        {id, <<"link-private">>},
                        {name, <<"private">>},
                        {value, <<"1">>}
                    ],
                    []
                ),
                ike_html:text(<<" ">>),
                ike_html:el(label, [{for, <<"link-private">>}], [ike_html:text(<<"private">>)])
            ] ++
                case Name of
                    none ->
                        [];
                    _ ->
                        [
                            ike_html:text(<<" ">>),
                            ike_html:el(
                                input,
                                [
                                    {type, <<"checkbox">>},
                                    {id, <<"link-signed">>},
                                    {name, <<"signed">>},
                                    {value, <<"1">>}
                                ],
                                []
                            ),
                            ike_html:text(<<" ">>),
                            ike_html:el(label, [{for, <<"link-signed">>}], [
                                ike_html:text(<<"sign as ", Name/binary>>)
                            ])
                        ]
                end ++
                [
                    ike_html:text(<<" ">>),
                    ike_html:el(button, [{type, <<"submit">>}], [ike_html:text(<<"fetch">>)])
                ]
        )
    ]).

-spec staged(#{atom() => term()}) -> ike_html:html().
staged(#{id := Id, type := Type, width := W, height := H, file := File, thumb := Thumb}) when
    is_integer(Id), is_binary(Type), is_integer(W), is_integer(H), is_binary(File), is_binary(Thumb)
->
    N = integer_to_binary(Id),
    ike_html:el(li, [
        ike_html:el(a, [{href, File}], [
            ike_html:el(img, [{src, Thumb}, {alt, <<"upload ", N/binary>>}], [])
        ]),
        ike_html:text(<<" upload ", N/binary, ", ", Type/binary, (size(W, H))/binary>>)
    ]).

%% the trunk: the metas the asker may see, newest first, each its
%% thumbnail, linking to its page, or to its curation, marked, once it is
%% curated; a private one says so, and one a moderator took down says how
-spec trunk([{ike_reader:meta(), image()}]) -> ike_html:html().
trunk(Metas) ->
    layout(<<"trunk">>, [
        ike_html:el(h1, [ike_html:text(<<"trunk">>)]),
        ike_html:el(p, [
            ike_html:text(<<"every upload, as it came in, a card or not. ">>),
            anchor(<<"/upload">>, <<"upload">>)
        ]),
        ike_html:el(ul, [
            ike_html:el(li, [
                ike_html:el(
                    a,
                    [
                        {href,
                            case Curation of
                                none -> meta_path(Id);
                                C -> <<"/booru/", (integer_to_binary(C))/binary>>
                            end}
                    ],
                    [
                        ike_html:el(
                            img,
                            [{src, Thumb}, {alt, <<Type/binary, " ", (number(Id))/binary>>}],
                            []
                        )
                    ]
                )
                | [
                    ike_html:text(<<" card:", (integer_to_binary(C1))/binary>>)
                 || C1 <- [Curation], is_integer(C1)
                ] ++
                    [ike_html:text(<<" private">>) || Private] ++
                    [ike_html:text(<<" ", (atom_to_binary(State))/binary>>) || State =/= shown]
            ])
         || {
                #{id := Id, type := Type, private := Private, state := State, curation := Curation},
                #{thumb := Thumb}
            } <- Metas
        ])
    ]).

-spec meta_path(pos_integer()) -> binary().
meta_path(Id) ->
    <<"/trunk/", (integer_to_binary(Id))/binary>>.

-spec number(pos_integer()) -> binary().
number(Id) ->
    <<"#", (integer_to_binary(Id))/binary>>.

%% a meta's page: the asset, what is known of it, its owner (a name, or
%% anonymous; "(you)" to the owner), the posts that show it, and to its
%% owner the switch between private and public, and, while it bears no
%% name, the way to put theirs on it (lux, Q42)
-spec meta(
    ike_reader:meta(),
    image(),
    [pos_integer()],
    #{
        csrf := binary() | none,
        moderator := boolean(),
        name := binary() | none,
        account := {binary(), binary() | none} | none,
        comments := [post()],
        %% the password this browser comments with
        password := binary(),
        %% whether nobody may comment: the trunk open, the meta public
        open := boolean()
    }
) ->
    ike_html:html().
meta(Meta, Image, Posts, #{csrf := Csrf, moderator := Moderator, name := Viewer} = Who) ->
    #{account := Account, comments := Comments, open := Open, password := Password} = Who,
    #{
        id := Id,
        type := Type,
        width := W,
        height := H,
        traits := Traits,
        time := Time,
        private := Private,
        mine := Mine,
        name := Owner,
        state := State,
        family := Family,
        axes := Axes,
        commentary := Said,
        entry := Entry,
        source := Source
    } = Meta,
    %% where it was fetched from, who made it (outlinks, as written in
    %% ikext), and what they said there
    Fetched =
        case Source of
            none ->
                [];
            #{source := From, artist := Artist, artist_url := ArtistUrl, said := SourceSaid} ->
                Out = fun(Href, Text) ->
                    ike_html:el(
                        a, [{class, <<"out">>}, {href, Href}, {rel, <<"nofollow noreferrer">>}], [
                            ike_html:text(Text)
                        ]
                    )
                end,
                [
                    ike_html:el(p, [ike_html:text(<<"source ">>), Out(From, From)]),
                    ike_html:el(p, [ike_html:text(<<"artist ">>), Out(ArtistUrl, Artist)])
                ] ++
                    case SourceSaid of
                        <<>> ->
                            [];
                        _ ->
                            [
                                ike_html:el(
                                    'div',
                                    [{class, <<"said">>}],
                                    blocks(
                                        ike_markup:parse(SourceSaid), ike_reader:links(SourceSaid)
                                    )
                                )
                            ]
                    end
        end,
    Title = <<"meta ", (number(Id))/binary>>,
    Here = meta_path(Id),
    Sign = fun(Name) ->
        case Name of
            none ->
                [];
            _ ->
                [
                    ike_html:el(
                        input,
                        [{type, <<"checkbox">>}, {name, <<"signed">>}, {value, <<"1">>}],
                        []
                    ),
                    ike_html:text(<<" sign as ", Name/binary, " ">>)
                ]
        end
    end,
    %% tagged and posted to the booru: by any account, while the meta is
    %% public and shown and its bytes on the booru nowhere yet
    Curate =
        case {Account, Private, State, Entry} of
            {{Token, Name0}, false, shown, none} ->
                [
                    ike_html:el(h2, [ike_html:text(<<"make a card">>)]),
                    ike_html:el(
                        form, [{method, <<"post">>}, {action, <<Here/binary, "/curate">>}], [
                            ike_html:el(
                                input,
                                [{type, <<"hidden">>}, {name, <<"csrf">>}, {value, Token}],
                                []
                            ),
                            %% what ike knows it is, to begin with
                            tag_box(joined_lines(ike_tag:inherent(Type, Traits))),
                            ike_html:el(
                                p,
                                Sign(Name0) ++
                                    [
                                        ike_html:el(button, [{type, <<"submit">>}], [
                                            ike_html:text(<<"post to the booru">>)
                                        ])
                                    ]
                            )
                        ]
                    )
                ];
            {_, _, _, E} when is_integer(E) ->
                [
                    ike_html:el(p, [
                        ike_html:text(<<"on the booru as ">>),
                        anchor(
                            <<"/booru/", (integer_to_binary(E))/binary>>,
                            <<"card:", (integer_to_binary(E))/binary>>
                        )
                    ])
                ];
            _ ->
                []
        end,
    Talk =
        [ike_html:el(h2, [ike_html:text(<<"comments">>)])] ++
            %% retracted as a board's posts are: ticked, with a password
            [
                ike_html:el(form, [{method, <<"post">>}, {action, <<"/act">>}], [
                    ike_html:el(ol, [ike_html:el(li, [post(P, false, 0)]) || P <- Comments])
                    | act_on(Here)
                ])
             || Comments =/= []
            ] ++
            case Account of
                {Token1, Name1} ->
                    [
                        ike_html:el(
                            form, [{method, <<"post">>}, {action, <<Here/binary, "/comment">>}], [
                                ike_html:el(
                                    input,
                                    [{type, <<"hidden">>}, {name, <<"csrf">>}, {value, Token1}],
                                    []
                                ),
                                ike_html:el(p, [
                                    ike_html:el(
                                        textarea,
                                        [{name, <<"body">>}, {rows, <<"4">>}, required],
                                        []
                                    )
                                ]),
                                password_field(Password),
                                ike_html:el(
                                    p,
                                    Sign(Name1) ++
                                        [
                                            ike_html:el(button, [{type, <<"submit">>}], [
                                                ike_html:text(<<"comment">>)
                                            ]),
                                            ike_html:text(<<" ">>),
                                            preview_button()
                                        ]
                                )
                            ]
                        )
                    ];
                none when Open ->
                    %% from this site, its pace kept, with no account
                    [
                        ike_html:el(
                            form, [{method, <<"post">>}, {action, <<Here/binary, "/comment">>}], [
                                ike_html:el(p, [
                                    ike_html:el(
                                        textarea,
                                        [{name, <<"body">>}, {rows, <<"4">>}, required],
                                        []
                                    )
                                ]),
                                password_field(Password),
                                ike_html:el(p, [
                                    ike_html:el(button, [{type, <<"submit">>}], [
                                        ike_html:text(<<"comment">>)
                                    ]),
                                    ike_html:text(<<" ">>),
                                    preview_button(),
                                    ike_html:text(<<" or ">>),
                                    anchor(<<"/login">>, <<"log in">>)
                                ])
                            ]
                        )
                    ];
                none ->
                    [ike_html:el(p, [anchor(<<"/login">>, <<"log in to comment">>)])]
            end,
    Row = fun(Name, Value) ->
        ike_html:el(tr, [
            ike_html:el(th, [ike_html:text(Name)]),
            ike_html:el(td, [ike_html:text(Value)])
        ])
    end,
    Whose =
        case {Mine, Viewer, Owner} of
            {true, V, _} when is_binary(V) -> anchor(<<"/user/", V/binary>>, <<"(you)">>);
            {true, _, _} -> ike_html:text(<<"(you)">>);
            {false, _, none} -> ike_html:text(<<"anonymous">>);
            {false, _, O} when is_binary(O) -> anchor(<<"/user/", O/binary>>, O)
        end,
    Rows =
        [
            Row(<<"type">>, Type),
            case Family of
                none ->
                    Row(<<"size">>, <<
                        (integer_to_binary(W))/binary, "x", (integer_to_binary(H))/binary
                    >>);
                _ ->
                    Row(<<"family">>, Family)
            end,
            ike_html:el(tr, [
                ike_html:el(th, [ike_html:text(<<"owner">>)]),
                ike_html:el(td, [Whose | [ike_html:text(<<", unsigned">>) || Mine, Owner =:= none]])
            ]),
            Row(<<"uploaded">>, stamp(Time)),
            Row(
                <<"seen by">>,
                case Private of
                    true -> <<"its owner and moderators">>;
                    false -> <<"everyone">>
                end
            )
        ] ++
            [Row(<<"what it is">>, Traits) || Traits =/= <<>>] ++
            [
                Row(
                    <<"axis ", Tag/binary>>,
                    <<
                        (axis_number(A))/binary,
                        " to ",
                        (axis_number(C))/binary,
                        ", ",
                        (axis_number(B))/binary,
                        " by default"
                    >>
                )
             || {Tag, A, B, C} <- Axes
            ] ++
            [Row(<<"state">>, atom_to_binary(State)) || State =/= shown],
    Form = fun(Token, Field, Value, Label) ->
        ike_html:el(form, [{method, <<"post">>}, {action, meta_path(Id)}], [
            ike_html:el(input, [{type, <<"hidden">>}, {name, <<"csrf">>}, {value, Token}], []),
            ike_html:el(input, [{type, <<"hidden">>}, {name, Field}, {value, Value}], []),
            ike_html:el(p, [ike_html:el(button, [{type, <<"submit">>}], [ike_html:text(Label)])])
        ])
    end,
    Owned =
        case Csrf of
            none ->
                [];
            _ when is_binary(Csrf) ->
                case Private of
                    true -> [Form(Csrf, <<"private">>, <<"0">>, <<"make public">>)];
                    false -> [Form(Csrf, <<"private">>, <<"1">>, <<"make private">>)]
                end ++
                    [
                        Form(Csrf, <<"sign">>, <<"1">>, <<"sign as ", Viewer/binary>>)
                     || Owner =:= none, is_binary(Viewer)
                    ]
        end,
    Shown =
        case Posts of
            [] ->
                [];
            _ ->
                [
                    ike_html:el(p, [
                        ike_html:text(<<"shown in ">>)
                        | spaced([permalink(P, <<>>) || P <- Posts])
                    ])
                ]
        end,
    layout(Title, [
        ike_html:el(h1, [ike_html:text(Title)]),
        ike_html:el(p, [anchor(<<"/trunk">>, <<"trunk">>)])
        | case Family of
            none -> figure(Image);
            _ -> specimen(Image, Axes)
        end ++ Fetched ++ [ike_html:el(table, Rows)] ++ commentary(Said) ++ Shown ++ Owned ++ Curate ++
            Talk ++
            [
                ike_html:el(p, [
                    anchor(<<"/mod/meta/", (integer_to_binary(Id))/binary>>, <<"moderate">>)
                ])
             || Moderator
            ]
    ]).

%% a font tried out, in the thumbnail's place (lux): its text, which the
%% reader may type over, in a box of its own lines, drawn in the font,
%% and sliders for its size, its weight and each other axis it has.
%% ike.js loads the font from the media origin and moves the text with
%% the sliders; without scripts the text stands in the page's own font
%% (a textarea is the plain-text, many-lined edit field a form already
%% has; contenteditable would take in pasted styles)
-spec specimen(image(), [{binary(), float(), float(), float()}]) -> [ike_html:html()].
specimen(#{file := File}, Axes) ->
    Sample = <<"The quick brown fox\njumps over the lazy dog">>,
    Slider = fun(Label, Axis, Min, Default, Max) ->
        ike_html:el(p, [
            ike_html:el(label, [
                ike_html:text(<<Label/binary, " ">>),
                ike_html:el(
                    input,
                    [
                        {type, <<"range">>},
                        {data_axis, Axis},
                        {min, axis_number(Min)},
                        {max, axis_number(Max)},
                        {value, axis_number(Default)},
                        {step, <<"any">>}
                    ],
                    []
                )
            ])
        ])
    end,
    %% a variable font's own weight axis, else the weights a browser makes
    Weight =
        case lists:keyfind(<<"wght">>, 1, Axes) of
            {_, A, B, C} -> Slider(<<"weight">>, <<"wght">>, A, B, C);
            false -> Slider(<<"weight">>, <<"weight">>, 100.0, 400.0, 900.0)
        end,
    [
        ike_html:el('div', [{class, <<"specimen">>}, {data_font, File}], [
            ike_html:el(
                textarea,
                [{class, <<"sample">>}, {rows, <<"3">>}, {spellcheck, <<"false">>}],
                [ike_html:text(Sample)]
            ),
            Slider(<<"size">>, <<"size">>, 8.0, 48.0, 200.0),
            Weight
            | [Slider(Tag, Tag, A, B, C) || {Tag, A, B, C} <- Axes, Tag =/= <<"wght">>]
        ])
    ].

-spec axis_number(float()) -> binary().
axis_number(F) when F == trunc(F) -> integer_to_binary(trunc(F));
axis_number(F) -> float_to_binary(F, [short]).

%% what a font said of itself beyond its names, as danbooru shows an
%% artist's commentary: text, links in it left as text
-spec commentary([{binary(), binary()}]) -> [ike_html:html()].
commentary([]) ->
    [];
commentary(Said) ->
    [
        ike_html:el(h2, [ike_html:text(<<"commentary">>)]),
        ike_html:el(table, [
            ike_html:el(tr, [
                ike_html:el(th, [ike_html:text(said(Kind))]),
                ike_html:el(td, plain(binary:split(Text, <<"\n">>, [global])))
            ])
         || {Kind, Text} <- Said
        ])
    ].

%% a name record's number, as OpenType calls it
-spec said(binary()) -> binary().
said(<<"0">>) -> <<"copyright">>;
said(<<"3">>) -> <<"unique id">>;
said(<<"5">>) -> <<"version">>;
said(<<"7">>) -> <<"trademark">>;
said(<<"8">>) -> <<"manufacturer">>;
said(<<"9">>) -> <<"designer">>;
said(<<"10">>) -> <<"description">>;
said(<<"11">>) -> <<"vendor url">>;
said(<<"12">>) -> <<"designer url">>;
said(<<"13">>) -> <<"license">>;
said(<<"14">>) -> <<"license url">>;
said(<<"19">>) -> <<"sample text">>;
said(<<"vendor">>) -> <<"vendor id">>;
said(<<"meta">>) -> <<"woff metadata">>;
said(Other) -> <<"name ", Other/binary>>.

%% what a form's text will look like: its title, its body as a post's,
%% its commentary as a curation's
-type text() :: {binary(), #{
    integer() | {booru, integer()} | {page, binary()} | {meta, integer()} => binary()
}}.
-spec preview(binary(), text(), text()) -> ike_html:html().
preview(Title, {Body, BodyLinks}, {Said, SaidLinks}) ->
    layout(<<"preview">>, [
        ike_html:el(h1, [ike_html:text(<<"preview">>)]),
        ike_html:el(p, [ike_html:text(<<"as it will look; close this tab to go on editing.">>)])
        | [
            ike_html:el(p, [ike_html:el(span, [{class, <<"title">>}], [ike_html:text(Title)])])
         || Title =/= <<>>
        ] ++
            [ike_html:el(article, blocks(ike_markup:parse(Body), BodyLinks)) || Body =/= <<>>] ++
            [
                ike_html:el(article, [
                    ike_html:el(h2, [ike_html:text(<<"commentary">>)])
                    | blocks(ike_markup:parse(Said), SaidLinks)
                ])
             || Said =/= <<>>
            ]
    ]).

%% a form's way to its preview, in a tab of its own, urlencoded so that
%% no file goes with it
-spec preview_button() -> ike_html:html().
preview_button() ->
    ike_html:el(
        button,
        [
            {type, <<"submit">>},
            {formaction, <<"/preview">>},
            {formmethod, <<"post">>},
            {formenctype, <<"application/x-www-form-urlencoded">>},
            {formtarget, <<"_blank">>},
            formnovalidate
        ],
        [ike_html:text(<<"preview">>)]
    ).

%% a meta on its moderation page
-spec moderated_meta(binary(), pos_integer(), shown | hidden | trashed, [ike_role:kind()]) ->
    ike_html:html().
moderated_meta(Csrf, Id, State, Kinds) ->
    Title = <<"meta ", (number(Id))/binary>>,
    layout(<<"moderating ", Title/binary>>, [
        ike_html:el(h1, [ike_html:text(Title)]),
        ike_html:el(p, [
            anchor(<<"/mod">>, <<"moderation">>),
            ike_html:text(<<" ">>),
            anchor(meta_path(Id), <<"its page">>)
        ]),
        ike_html:el(p, [ike_html:text(atom_to_binary(State))])
        | act(<<"/mod/meta/", (integer_to_binary(Id))/binary>>, Csrf, Kinds, [])
    ]).

-spec upload_locked() -> ike_html:html().
upload_locked() ->
    layout(<<"uploads">>, [
        ike_html:el(h1, [ike_html:text(<<"uploads">>)]),
        ike_html:el(p, [
            ike_html:text(<<"uploading needs an account: ">>),
            anchor(<<"/login">>, <<"log in">>),
            ike_html:text(<<".">>)
        ])
    ]).

%% who you are here: the name posts may carry, the role the provider's
%% groups gave, and the way out
-spec account(
    {Csrf :: binary(), Name :: binary() | none, ike_role:role() | none} | nobody
) -> ike_html:html().
account(nobody) ->
    layout(<<"account">>, [
        ike_html:el(h1, [ike_html:text(<<"account">>)]),
        ike_html:el(p, [
            ike_html:text(<<"not logged in. ">>),
            anchor(<<"/login">>, <<"log in">>)
        ])
    ]);
account({Csrf, Name, Role}) ->
    Called =
        case Name of
            none -> <<"logged in, without a name to sign with">>;
            _ -> <<"logged in as ", Name/binary>>
        end,
    Is =
        case Role of
            none -> <<"no role">>;
            _ -> <<"role: ", (as(Role))/binary>>
        end,
    layout(<<"account">>, [
        ike_html:el(h1, [ike_html:text(<<"account">>)]),
        ike_html:el(p, [ike_html:text(Called)]),
        ike_html:el(p, [ike_html:text(Is)]),
        ike_html:el(ul, [
            ike_html:el(li, [anchor(<<"/upload">>, <<"your uploads">>)])
            | case Role of
                none -> [];
                _ -> [ike_html:el(li, [anchor(<<"/mod">>, <<"moderation">>)])]
            end
        ]),
        ike_html:el(form, [{method, <<"post">>}, {action, <<"/logout">>}], [
            ike_html:el(input, [{type, <<"hidden">>}, {name, <<"csrf">>}, {value, Csrf}], []),
            ike_html:el(p, [
                ike_html:el(button, [{type, <<"submit">>}], [ike_html:text(<<"log out">>)])
            ])
        ])
    ]).

%% a booru entry, a curation: its newest version large enough to look at
%% (a font tried out), whose it is, its tags and commentary, the form
%% that changes them, every version, where on the boards it is shown and
%% pointed at, and its thread: comments, with each revision between them
%% as what it changed (lux), in the order they came
-spec entry(#{
    id := pos_integer(),
    time := integer(),
    versions := [{non_neg_integer(), image() | gone}],
    shown_in := [pos_integer()],
    linked_from := [pos_integer()],
    %% each kind/name, and as shown: its name alone until another kind
    %% has the name
    tags := [{binary(), binary()}],
    %% the search its bar holds: none for its file, the reader's when
    %% made per request
    query := [binary()],
    changes := [{integer(), binary(), binary()}],
    thread := pos_integer() | none,
    posts := [post()],
    commentary := binary(),
    %% the tag box as the newest revision laid it out
    box := binary() | none,
    owner := {account, binary()} | anonymous | none
}) -> ike_html:html().
entry(
    #{id := Id, time := Time, versions := Versions, shown_in := Shown, linked_from := Linked} =
        Entry
) ->
    #{
        tags := Tags,
        query := Query,
        changes := Changes,
        thread := Thread,
        posts := Posts,
        commentary := Said,
        box := Box0,
        owner := Owner
    } = Entry,
    %% a curation with no revision yet has its tags one to a line
    Box =
        case Box0 of
            none -> joined_lines([S || {_, S} <- Tags]);
            _ -> Box0
        end,
    N = integer_to_binary(Id),
    Stamp = stamp(Time),
    Newest =
        case Versions of
            [{_, #{axes := Axes} = Font} | _] -> specimen(Font, Axes);
            [{_, Image} | _] -> figure(Image);
            [] -> []
        end,
    Whose =
        case Owner of
            {account, Name} ->
                [
                    ike_html:el(p, [
                        ike_html:text(<<"owner ">>), anchor(<<"/user/", Name/binary>>, Name)
                    ])
                ];
            anonymous ->
                [ike_html:el(p, [ike_html:text(<<"owner anonymous">>)])];
            none ->
                []
        end,
    Commentary =
        case Said of
            <<>> ->
                [];
            _ ->
                %% ikext (lux), with the thread's links
                SaidLinks =
                    case Posts of
                        [#{links := L} | _] -> L;
                        [] -> #{}
                    end,
                [
                    ike_html:el(h2, [ike_html:text(<<"commentary">>)])
                    | blocks(ike_markup:parse(Said), SaidLinks)
                ]
        end,
    Edit = ike_html:el(
        form, [{method, <<"post">>}, {action, <<"/booru/", N/binary, "/tags">>}], [
            tag_box(Box),
            ike_html:el(p, [
                ike_html:el(label, [{for, <<"commentary">>}], [ike_html:text(<<"commentary">>)]),
                ike_html:el(br, []),
                ike_html:el(
                    textarea,
                    [{id, <<"commentary">>}, {name, <<"commentary">>}, {rows, <<"4">>}],
                    [ike_html:text(Said)]
                )
            ]),
            ike_html:el(p, [
                ike_html:el(
                    input,
                    [
                        {type, <<"checkbox">>},
                        {id, <<"signed">>},
                        {name, <<"signed">>},
                        {value, <<"1">>}
                    ],
                    []
                ),
                ike_html:text(<<" ">>),
                ike_html:el(label, [{for, <<"signed">>}], [ike_html:text(<<"sign with your name">>)]),
                ike_html:text(<<" ">>),
                ike_html:el(button, [{type, <<"submit">>}], [ike_html:text(<<"save">>)]),
                ike_html:text(<<" ">>),
                preview_button()
            ])
        ]
    ),
    Newest0 = newest(Posts, 0),
    Talk =
        case Thread of
            none ->
                [];
            _ ->
                T = integer_to_binary(Thread),
                [
                    ike_html:el(h2, [ike_html:text(<<"comments">>)]),
                    %% retracted as a board's posts are: ticked, with a password
                    ike_html:el(form, [{method, <<"post">>}, {action, <<"/act">>}], [
                        ike_html:el(ol, [ike_html:el(li, [post(P, false, Newest0)]) || P <- Posts])
                        | act_on(<<"/booru/", N/binary>>)
                    ]),
                    ike_html:el(p, [anchor(<<"/board/trunk/", T/binary, "/reply">>, <<"comment">>)])
                ]
        end,
    layout(
        <<"card:", N/binary>>,
        [
            search_bar(Query),
            ike_html:el(h1, [ike_html:text(<<"card:", N/binary>>)]),
            ike_html:el(p, [
                anchor(<<"/booru">>, <<"booru">>),
                ike_html:text(<<", since ">>),
                ike_html:el(time, [{datetime, Stamp}], [ike_html:text(Stamp)])
            ])
            | Newest
        ] ++ Whose ++
            [
                ike_html:el(p, [ike_html:text(<<"tags">>)]),
                ike_html:el(ul, [{class, <<"tags">>}], [card_tag(T, Query) || T <- Tags])
            ] ++
            Commentary ++
            [Edit] ++
            [
                ike_html:el(p, [ike_html:text(<<"versions">>)]),
                ike_html:el(ol, [
                    ike_html:el(li, [
                        ike_html:text(
                            case Image of
                                #{type := Type, width := W, height := H} ->
                                    <<
                                        (integer_to_binary(Position + 1))/binary,
                                        ": ",
                                        Type/binary,
                                        (size(W, H))/binary
                                    >>;
                                gone ->
                                    <<(integer_to_binary(Position + 1))/binary, ": purged">>
                            end
                        )
                    ])
                 || {Position, Image} <- Versions
                ])
            ] ++
            %% the tag history, for an entry with no thread to show it in
            [ike_html:el(ul, [changed(C) || C <- Changes]) || Thread =:= none] ++
            [
                ike_html:el(p, [
                    ike_html:text(<<"shown in ">>) | spaced([permalink(P, <<>>) || P <- Shown])
                ]),
                ike_html:el(p, [
                    ike_html:text(<<"pointed at by ">>)
                    | spaced([permalink(P, <<>>) || P <- Linked])
                ])
            ] ++ Talk
    ).

%% the tag box (lux): every tag the entry has, as laid out, one name or
%% several a line, in a monospace box; what it names is what the entry
%% has, and -name takes one off
-spec tag_box(binary()) -> ike_html:html().
tag_box(Box) ->
    Lines = length(binary:split(Box, <<"\n">>, [global])),
    ike_html:el(p, [
        ike_html:el(label, [{for, <<"tags">>}], [
            ike_html:text(<<"tags (accounts; what is here is what it has; -name takes one off)">>)
        ]),
        ike_html:el(br, []),
        ike_html:el(
            textarea,
            [
                {id, <<"tags">>},
                {name, <<"tags">>},
                {class, <<"tags">>},
                {rows, integer_to_binary(min(24, Lines + 2))},
                {maxlength, <<"8000">>}
            ],
            [ike_html:text(Box)]
        )
    ]).

-spec joined_lines([binary()]) -> binary().
joined_lines([L]) -> L;
joined_lines([L | Ls]) -> <<L/binary, "\n", (joined_lines(Ls))/binary>>;
joined_lines([]) -> <<>>.

%% one change to an entry's tags: when, and what; not who
-spec changed({integer(), binary(), binary()}) -> ike_html:html().
changed({When, Added, Removed}) ->
    Plus =
        case Added of
            <<>> -> <<>>;
            _ -> <<" +", Added/binary>>
        end,
    Minus =
        case Removed of
            <<>> -> <<>>;
            _ -> <<" -", Removed/binary>>
        end,
    ike_html:el(li, [
        ike_html:el(time, [{datetime, stamp(When)}], [ike_html:text(stamp(When))]),
        ike_html:text(<<Plus/binary, Minus/binary>>)
    ]).

%% a card's tag (lux): + puts it in the search the bar holds, - takes it
%% out (or, not in it, leaves out what has it, as a minus does); the
%% name leads to its wiki page
-spec card_tag({binary(), binary()}, [binary()]) -> ike_html:html().
card_tag({_, Name} = Tag, Query) ->
    ike_html:el(li, [
        ike_html:el(
            a,
            [
                {class, <<"with">>},
                {href, ike_tag:search_href(ike_tag:with(Query, Name))},
                {title, <<"search with it">>}
            ],
            [ike_html:text(<<"+">>)]
        ),
        ike_html:text(<<" ">>),
        ike_html:el(
            a,
            [
                {class, <<"without">>},
                {href, ike_tag:search_href(ike_tag:without(Query, Name))},
                {title, <<"search without it">>}
            ],
            [ike_html:text(<<"-">>)]
        ),
        ike_html:text(<<" ">>),
        tag_link(Tag)
    ]).

%% a tag, to its page in the wiki, as shown; a name no page can have
%% (one starting with a dot), to the cards that have it. classed by its
%% kind, for a theme to tell them apart (lux)
-spec tag_link({binary(), binary()}) -> ike_html:html().
tag_link({Word, Shown}) ->
    Class =
        case ike_tag:split(Word) of
            {Kind, _} when is_binary(Kind) -> <<"tag tag-", Kind/binary>>;
            {any, _} -> <<"tag">>
        end,
    Href =
        case ike_wiki:name(Word) of
            {ok, Word} -> ike_wiki:path(Word);
            _ -> ike_tag:search_href([Shown])
        end,
    ike_html:el(a, [{class, Class}, {href, Href}], [ike_html:text(Shown)]).

-spec words([binary()]) -> binary().
words([W]) -> W;
words([W | Ws]) -> <<W/binary, " ", (words(Ws))/binary>>;
words([]) -> <<>>.

%% a name alone that more than one kind of tag has (lux): which to say
-spec ambiguous(binary(), [binary()]) -> ike_html:html().
ambiguous(Name, Words) ->
    message(
        <<"not saved">>,
        <<Name/binary, " is more than one tag: ", (words(Words))/binary,
            ". say which, as kind/name.">>
    ).

%% the booru's search bar, on each of its pages, holding the search the
%% reader came by (lux): a card reached from a search keeps it
-spec search_bar([binary()]) -> ike_html:html().
search_bar(Query) ->
    ike_html:el(
        form,
        [{class, <<"search">>}, {method, <<"get">>}, {action, <<"/booru/search">>}],
        [
            ike_html:el(
                input,
                [
                    {type, <<"search">>},
                    {name, <<"tags">>},
                    {value, words(Query)},
                    {maxlength, <<"1000">>},
                    {aria_label, <<"tags">>}
                ],
                []
            ),
            ike_html:text(<<" ">>),
            ike_html:el(button, [{type, <<"submit">>}], [ike_html:text(<<"search">>)])
        ]
    ).

%% entries by their tags: the form, what it was asked, and what it found
-spec search(
    Said :: [binary()],
    [
        {
            pos_integer(),
            binary() | undefined,
            binary() | undefined,
            integer() | undefined,
            integer() | undefined
        }
    ]
) -> ike_html:html().
search(Said, Found) ->
    layout(<<"search">>, [
        search_bar(Said),
        ike_html:el(h1, [ike_html:text(<<"search">>)]),
        ike_html:el(ul, [found(F, Said) || F <- Found])
    ]).

-spec found(
    {
        pos_integer(),
        binary() | undefined,
        binary() | undefined,
        integer() | undefined,
        integer() | undefined
    },
    [binary()]
) -> ike_html:html().
found({Id, Hash, Type, _W, _H}, Said) ->
    I = integer_to_binary(Id),
    %% the card, with the search it was found by
    Href =
        case Said of
            [] -> <<"/booru/", I/binary>>;
            _ -> <<"/booru/", I/binary, "?tags=", (ike_tag:query_string(Said))/binary>>
        end,
    ike_html:el(li, [
        case {Hash, Type} of
            {<<_/binary>>, <<_/binary>>} ->
                Thumb = ike_media:thumb_url(binary:encode_hex(Hash, lowercase)),
                ike_html:el(a, [{href, Href}], [
                    ike_html:el(img, [{src, Thumb}, {alt, <<"card:", I/binary>>}], [])
                ]);
            _ ->
                anchor(Href, <<"card:", I/binary>>)
        end
    ]).

%% a booru entry on its moderation page
-spec moderated_entry(binary(), pos_integer(), shown | hidden | trashed, [ike_role:kind()]) ->
    ike_html:html().
moderated_entry(Csrf, Id, State, Kinds) ->
    N = integer_to_binary(Id),
    layout(<<"moderating card:", N/binary>>, [
        ike_html:el(h1, [ike_html:text(<<"card:", N/binary>>)]),
        ike_html:el(p, [anchor(<<"/mod">>, <<"moderation">>)]),
        ike_html:el(p, [ike_html:text(atom_to_binary(State))])
        | act(<<"/mod/booru/", N/binary>>, Csrf, Kinds, [])
    ]).

%% the booru: the newest entries, each its thumbnail, linking to it
-spec entries([{pos_integer(), image() | gone}]) -> ike_html:html().
entries(Entries) ->
    layout(<<"booru">>, [
        search_bar([]),
        ike_html:el(h1, [ike_html:text(<<"booru">>)]),
        ike_html:el(ul, [
            ike_html:el(li, [
                case Image of
                    #{thumb := Thumb} ->
                        ike_html:el(a, [{href, <<"/booru/", (integer_to_binary(Id))/binary>>}], [
                            ike_html:el(
                                img,
                                [{src, Thumb}, {alt, <<"card:", (integer_to_binary(Id))/binary>>}],
                                []
                            )
                        ]);
                    gone ->
                        anchor(
                            <<"/booru/", (integer_to_binary(Id))/binary>>,
                            <<"card:", (integer_to_binary(Id))/binary>>
                        )
                end
            ])
         || {Id, Image} <- Entries
        ])
    ]).

%% the wiki's pages, by name
-spec wiki_index([{binary(), binary()}]) -> ike_html:html().
wiki_index(Names) ->
    layout(<<"wiki">>, [
        ike_html:el(h1, [ike_html:text(<<"wiki">>)]),
        ike_html:el(ul, [ike_html:el(li, [page_link(N)]) || N <- Names])
    ]).

%% a page, as shown, classed by its kind (lux: for a theme)
-spec page_link({binary(), binary()}) -> ike_html:html().
page_link({Word, Shown}) ->
    ike_html:el(a, [{class, kind_class(Word)}, {href, ike_wiki:path(Word)}], [
        ike_html:text(Shown)
    ]).

%% a name alone that pages or tags of more than one kind have: each
-spec wiki_many(binary(), [binary()]) -> ike_html:html().
wiki_many(Bare, Words) ->
    layout(Bare, [
        ike_html:el(h1, [ike_html:text(Bare)]),
        ike_html:el(p, [ike_html:text(<<"more than one kind has this name:">>)]),
        ike_html:el(ul, [ike_html:el(li, [page_link({W, W})]) || W <- Words])
    ]).

-spec kind_class(binary()) -> binary().
kind_class(Word) ->
    case ike_tag:split(Word) of
        {Kind, _} when is_binary(Kind) -> <<"page page-", Kind/binary>>;
        {any, _} -> <<"page">>
    end.

%% a page as it now reads, and the ways to its history, its editing and
%% its discussion
-spec wiki_page(
    {binary(), binary()},
    #{thread := pos_integer(), revision := pos_integer(), time := integer(), body := binary()},
    #{integer() | {booru, integer()} | {page, binary()} | {meta, integer()} => binary()},
    Tagged :: boolean()
) -> ike_html:html().
%% the page, its title with the way to edit it beside it (a word for now,
%% a pen later; the key e too, where scripts run), and the revision it
%% is as of, whose number leads to the history and the talk alike
wiki_page({Name, Shown}, #{revision := Revision, time := Time, body := Body}, Links, Tagged) ->
    Stamp = stamp(Time),
    Edit = ike_html:el(
        a, [{class, <<"edit">>}, {href, <<(ike_wiki:path(Name))/binary, "/edit">>}], [
            ike_html:text(<<"edit">>)
        ]
    ),
    layout(Shown, [
        ike_html:el(h1, [{class, kind_class(Name)}], [
            ike_html:text(Shown), ike_html:text(<<" ">>), Edit
        ])
        | blocks(ike_markup:parse(Body), Links) ++
            [
                ike_html:el(p, [
                    ike_html:text(<<"as of ">>),
                    permalink(Revision, <<>>),
                    ike_html:text(<<", ">>),
                    ike_html:el(time, [{datetime, Stamp}], [ike_html:text(Stamp)])
                ])
            ] ++ tagged(Name, Shown, Tagged)
    ]).

%% a tag's page leads to the cards that have it
-spec tagged(binary(), binary(), boolean()) -> [ike_html:html()].
tagged(Name, Shown, true) ->
    [
        ike_html:el(p, [{class, <<"cards">>}], [
            anchor(ike_tag:search_href([Name]), <<"cards tagged ", Shown/binary>>)
        ])
    ];
tagged(_Name, _Shown, false) ->
    [].

%% a name with no page yet
-spec wiki_missing({binary(), binary()}, SignedIn :: boolean(), Tagged :: boolean()) ->
    ike_html:html().
wiki_missing({Name, Shown}, SignedIn, Tagged) ->
    layout(
        Shown,
        [
            ike_html:el(h1, [{class, kind_class(Name)}], [ike_html:text(Shown)])
            | tagged(Name, Shown, Tagged)
        ] ++
            [
                ike_html:el(p, [
                    ike_html:text(<<"no page by this name yet. ">>),
                    case SignedIn of
                        true -> anchor(<<(ike_wiki:path(Name))/binary, "/edit">>, <<"start it">>);
                        false -> anchor(<<"/login">>, <<"log in to start it">>)
                    end
                ])
            ]
    ).

%% where a poster gives the password a post is retracted with
-spec password_field(binary()) -> ike_html:html().
password_field(Password) ->
    ike_html:el(p, [
        ike_html:el(label, [{for, <<"password">>}], [
            ike_html:text(<<"password, to retract it later; this browser keeps it ">>)
        ]),
        ike_html:el(
            input,
            [{type, <<"text">>}, {id, <<"password">>}, {name, <<"password">>}, {value, Password}],
            []
        )
    ]).

%% the editing form, on the page's text now; an unsigned edit is
%% retracted with the password
-spec wiki_edit(binary(), binary(), binary() | none, binary(), binary()) -> ike_html:html().
wiki_edit(Name, Csrf, Signer, Text, Password) ->
    Sign =
        case Signer of
            none ->
                [];
            _ ->
                [
                    ike_html:el(p, [
                        ike_html:el(
                            input,
                            [
                                {type, <<"checkbox">>},
                                {id, <<"signed">>},
                                {name, <<"signed">>},
                                {value, <<"1">>}
                            ],
                            []
                        ),
                        ike_html:text(<<" ">>),
                        ike_html:el(label, [{for, <<"signed">>}], [
                            ike_html:text(<<"sign as ", Signer/binary>>)
                        ])
                    ])
                ]
        end,
    layout(<<"editing ", Name/binary>>, [
        ike_html:el(h1, [ike_html:text(<<"editing ", Name/binary>>)])
        | [
            ike_html:el(
                form,
                [{method, <<"post">>}, {action, <<(ike_wiki:path(Name))/binary, "/edit">>}],
                [
                    ike_html:el(
                        input, [{type, <<"hidden">>}, {name, <<"csrf">>}, {value, Csrf}], []
                    ),
                    ike_html:el(p, [
                        ike_html:el(
                            textarea, [{name, <<"body">>}, {rows, <<"20">>}, required], [
                                ike_html:text(Text)
                            ]
                        )
                    ])
                    | Sign ++
                        [
                            password_field(Password),
                            ike_html:el(p, [
                                ike_html:el(button, [{type, <<"submit">>}], [
                                    ike_html:text(<<"save">>)
                                ]),
                                ike_html:text(<<" ">>),
                                preview_button()
                            ])
                        ]
                ]
            )
        ]
    ]).

%% each revision, newest first, as lines kept, added and taken away
-spec wiki_history(binary(), [{pos_integer(), integer(), [ike_wiki:change()]}]) -> ike_html:html().
wiki_history(Name, Revisions) ->
    layout(<<Name/binary, " history">>, [
        ike_html:el(h1, [ike_html:text(<<Name/binary, " history">>)]),
        ike_html:el(p, [anchor(ike_wiki:path(Name), Name)]),
        ike_html:el(ol, [
            ike_html:el(li, [
                ike_html:el(p, [
                    permalink(Id, <<>>),
                    ike_html:text(<<" ">>),
                    ike_html:el(time, [{datetime, stamp(T)}], [ike_html:text(stamp(T))])
                ]),
                ike_html:el(p, changes(Changes))
            ])
         || {Id, T, Changes} <- Revisions
        ])
    ]).

-spec changes([ike_wiki:change()]) -> [ike_html:html()].
changes([{Kind, Line} | Rest]) ->
    Piece =
        case Kind of
            same -> ike_html:text(Line);
            added -> ike_html:el(ins, [ike_html:text(Line)]);
            removed -> ike_html:el(del, [ike_html:text(Line)])
        end,
    case Rest of
        [] -> [Piece];
        _ -> [Piece, ike_html:el(br, []) | changes(Rest)]
    end;
changes([]) ->
    [].

%% files to post with the text: any kind for an account, still images
%% for nobody (when the switch lets nobody post files at all)
-spec files_field(any | still) -> ike_html:html().
files_field(Which) ->
    Accept =
        case Which of
            any ->
                <<"image/jpeg,image/png,image/webp,image/svg+xml,.svg,video/webm,video/mp4,.ttf,.otf,.woff,.woff2">>;
            still ->
                <<"image/jpeg,image/png,image/webp">>
        end,
    ike_html:el(p, [
        ike_html:el(label, [{for, <<"file">>}], [ike_html:text(<<"files ">>)]),
        ike_html:el(
            input,
            [{type, <<"file">>}, {id, <<"file">>}, {name, <<"file">>}, {accept, Accept}, multiple],
            []
        )
    ]).

%% a page that only says something
-spec message(Title :: binary(), Text :: binary()) -> ike_html:html().
message(Title, Text) ->
    layout(Title, [
        ike_html:el(h1, [ike_html:text(Title)]),
        ike_html:el(p, [ike_html:text(Text)])
    ]).

%% plain looks: what is added green, what is taken red, a revision's
%% count of lines beside its header until it is opened
-spec style() -> iodata().
style() ->
    <<
        "ins { color: #116329; background: #dafbe1; text-decoration: none; }\n"
        "del { color: #82071e; background: #ffebe9; }\n"
        "header details { display: inline; }\n"
        "header details[open] { display: block; }\n"
        "header details > summary { display: inline; cursor: pointer; }\n"
        ".spoiler { background: #24292f; color: #24292f; }\n"
        ".spoiler:hover { color: #ffffff; }\n"
        ".gone { color: #6e7781; }\n"
        ".added { color: #116329; }\n"
        ".removed { color: #82071e; }\n"
        "a.missing { color: #cf222e; }\n"
        %% a link out of ike says so before it (lux); a site's own icon later
        "a.out::before { content: \"\\2197\\FE0E\\00A0\"; font-size: 0.85em; }\n"
        ".title { font-weight: bold; }\n"
        ".specimen .sample { font-size: 48px; width: 100%; min-height: 3em;"
        " box-sizing: border-box; border: 1px dashed #8c959f; background: transparent; }\n"
        "textarea.tags { font-family: monospace; width: 100%; max-width: 50em; }\n"
        %% kinds of tag and page, in danbooru's colours (lux: a theme may
        %% tell them apart as it likes)
        "a.tag-artist, .page-artist { color: #c00004; }\n"
        "a.tag-canon, .page-canon { color: #a800aa; }\n"
        "a.tag-character, .page-character { color: #00ab2c; }\n"
        "a.tag-meta, .page-meta { color: #fd9200; }\n"
        "ul.tags { list-style: none; padding-left: 0; }\n"
        "h1 a.edit { font-size: 0.5em; font-weight: normal; vertical-align: middle; }\n"
    >>.

%% keys for a text box, for whoever runs scripts: ctrl+enter sends the
%% form, ctrl+b and ctrl+i put [b] and [i] around what is selected; and
%% e, outside a text box, follows a page's edit link.
%% nothing a page needs (invariant 2); no library, ike's own
-spec script() -> iodata().
script() ->
    <<
        "'use strict';\n"
        "document.addEventListener('keydown', function (e) {\n"
        "  var t = e.target;\n"
        "  if (!t || t.tagName !== 'TEXTAREA' || !(e.ctrlKey || e.metaKey)) return;\n"
        "  if (e.key === 'Enter') {\n"
        "    e.preventDefault();\n"
        "    if (t.form) t.form.requestSubmit();\n"
        "    return;\n"
        "  }\n"
        "  var tag = e.key === 'b' ? 'b' : e.key === 'i' ? 'i' : null;\n"
        "  if (!tag) return;\n"
        "  e.preventDefault();\n"
        "  var start = t.selectionStart, end = t.selectionEnd;\n"
        "  var inside = t.value.slice(start, end);\n"
        "  var text = '[' + tag + ']' + inside + '[/' + tag + ']';\n"
        "  t.focus();\n"
        "  if (!document.execCommand || !document.execCommand('insertText', false, text)) {\n"
        "    t.setRangeText(text, start, end, 'end');\n"
        "  }\n"
        "  t.selectionStart = start + tag.length + 2;\n"
        "  t.selectionEnd = t.selectionStart + inside.length;\n"
        "});\n"
        "document.querySelectorAll('.specimen[data-font]').forEach(function (s) {\n"
        "  var sample = s.querySelector('.sample');\n"
        "  var wght = s.querySelector('input[data-axis=wght]');\n"
        "  var family = 'ike-specimen-' + Math.random().toString(36).slice(2);\n"
        "  if (window.FontFace && sample) {\n"
        "    var how = wght ? { weight: wght.min + ' ' + wght.max } : {};\n"
        "    new FontFace(family, 'url(\"' + s.dataset.font + '\")', how).load().then(function (f) {\n"
        "      document.fonts.add(f);\n"
        "      sample.style.fontFamily = '\"' + family + '\", sans-serif';\n"
        "    }, function () {});\n"
        "  }\n"
        "  function apply() {\n"
        "    var settings = [];\n"
        "    s.querySelectorAll('input[data-axis]').forEach(function (i) {\n"
        "      var a = i.dataset.axis;\n"
        "      if (a === 'size') sample.style.fontSize = i.value + 'px';\n"
        "      else if (a === 'wght' || a === 'weight') sample.style.fontWeight = i.value;\n"
        "      else settings.push('\"' + a + '\" ' + i.value);\n"
        "    });\n"
        "    sample.style.fontVariationSettings = settings.length ? settings.join(', ') : 'normal';\n"
        "  }\n"
        "  if (sample) { s.addEventListener('input', apply); apply(); }\n"
        "});\n"
        "document.addEventListener('keydown', function (e) {\n"
        "  if (e.key !== 'e' || e.ctrlKey || e.metaKey || e.altKey || e.defaultPrevented) return;\n"
        "  var t = e.target;\n"
        "  if (t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))) return;\n"
        "  var a = document.querySelector('a.edit');\n"
        "  if (!a) return;\n"
        "  e.preventDefault();\n"
        "  window.location.href = a.href;\n"
        "});\n"
    >>.

%% an account's own page: the posts it signed, newest first
-spec user(binary(), [{pos_integer(), binary(), integer(), binary()}]) -> ike_html:html().
user(Name, Posts) ->
    layout(Name, [
        ike_html:el(h1, [ike_html:text(Name)]),
        ike_html:el(ol, [
            ike_html:el(li, [
                permalink(Id, <<>>),
                ike_html:text(<<" on /", Board/binary, "/, ">>),
                ike_html:el(time, [{datetime, stamp(T)}], [ike_html:text(stamp(T))]),
                ike_html:text(<<": ", (excerpt(Body))/binary>>)
            ])
         || {Id, Board, T, Body} <- Posts
        ])
    ]).

-spec layout(Title :: binary(), [ike_html:html()]) -> ike_html:html().
layout(Title, Content) ->
    ike_html:document(Title, [
        ike_html:el(nav, [
            anchor(<<"/">>, <<"ike">>),
            ike_html:text(<<" ">>),
            anchor(<<"/account">>, <<"account">>)
        ]),
        ike_html:el(main, Content)
    ]).

-spec anchor(Href :: binary(), Text :: binary()) -> ike_html:html().
anchor(Href, Text) ->
    ike_html:el(a, [{href, Href}], [ike_html:text(Text)]).

%% each line's pieces, with a br between lines
%% a text's blocks, from its markup; every leaf is text (invariant 4)
-spec blocks([ike_markup:block()], #{
    integer() | {booru, integer()} | {page, binary()} | {meta, integer()} => binary()
}) ->
    [ike_html:html()].
blocks([{para, Lines} | Rest], Links) ->
    [ike_html:el(p, broken([inline(L, Links) || L <- Lines])) | blocks(Rest, Links)];
blocks([{heading, Level, Inline} | Rest], Links) ->
    %% the page's own title is h1; a text's headings come below it
    Tag =
        case Level of
            1 -> h2;
            2 -> h3;
            3 -> h4;
            4 -> h5;
            _ -> h6
        end,
    [ike_html:el(Tag, inline(Inline, Links)) | blocks(Rest, Links)];
blocks([{list, Items} | Rest], Links) ->
    [listed(Items, Links) | blocks(Rest, Links)];
blocks([{quote, Inner} | Rest], Links) ->
    [ike_html:el(blockquote, blocks(Inner, Links)) | blocks(Rest, Links)];
blocks([{code, Code} | Rest], Links) ->
    [ike_html:el(pre, [ike_html:el(code, [ike_html:text(Code)])]) | blocks(Rest, Links)];
blocks([], _Links) ->
    [].

-spec listed([ike_markup:item()], #{
    integer() | {booru, integer()} | {page, binary()} | {meta, integer()} => binary()
}) ->
    ike_html:html().
listed(Items, Links) ->
    ike_html:el(ul, [
        ike_html:el(
            li,
            inline(Text, Links) ++
                case Under of
                    [] -> [];
                    _ -> [listed(Under, Links)]
                end
        )
     || {Text, Under} <- Items
    ]).

-spec broken([[ike_html:html()]]) -> [ike_html:html()].
broken([Line]) -> Line;
broken([Line | Rest]) -> Line ++ [ike_html:el(br, []) | broken(Rest)];
broken([]) -> [].

-spec inline([ike_markup:inline()], #{
    integer() | {booru, integer()} | {page, binary()} | {meta, integer()} => binary()
}) ->
    [ike_html:html()].
inline([{bold, C} | Rest], Links) ->
    [ike_html:el(b, inline(C, Links)) | inline(Rest, Links)];
inline([{italic, C} | Rest], Links) ->
    [ike_html:el(i, inline(C, Links)) | inline(Rest, Links)];
inline([{strike, C} | Rest], Links) ->
    [ike_html:el(s, inline(C, Links)) | inline(Rest, Links)];
inline([{under, C} | Rest], Links) ->
    [ike_html:el(u, inline(C, Links)) | inline(Rest, Links)];
inline([{spoiler, C} | Rest], Links) ->
    [ike_html:el(span, [{class, <<"spoiler">>}], inline(C, Links)) | inline(Rest, Links)];
inline([{mono, Code} | Rest], Links) ->
    [ike_html:el(code, [ike_html:text(Code)]) | inline(Rest, Links)];
inline([{url, Url, Label} | Rest], Links) ->
    %% someone else's site: no referrer, and no weight given it
    [
        ike_html:el(
            a,
            [{class, <<"out">>}, {href, Url}, {rel, <<"nofollow noreferrer">>}],
            inline(Label, Links)
        )
        | inline(Rest, Links)
    ];
inline([{search, Query} | Rest], Links) ->
    Href =
        case uri_string:quote(Query) of
            Quoted when is_binary(Quoted) -> <<"/booru/search?tags=", Quoted/binary>>;
            _ -> <<"/booru/search">>
        end,
    [anchor(Href, <<"{{", Query/binary, "}}">>) | inline(Rest, Links)];
inline([{text, _} = Piece | Rest], Links) ->
    [piece(Piece, Links) | inline(Rest, Links)];
inline([{post, _} = Piece | Rest], Links) ->
    [piece(Piece, Links) | inline(Rest, Links)];
inline([{post, _, _} = Piece | Rest], Links) ->
    [piece(Piece, Links) | inline(Rest, Links)];
inline([{booru, _} = Piece | Rest], Links) ->
    [piece(Piece, Links) | inline(Rest, Links)];
inline([{entry, _} = Piece | Rest], Links) ->
    [piece(Piece, Links) | inline(Rest, Links)];
inline([{meta, _} = Piece | Rest], Links) ->
    [piece(Piece, Links) | inline(Rest, Links)];
inline([{out, _, _} = Piece | Rest], Links) ->
    [piece(Piece, Links) | inline(Rest, Links)];
inline([{page, _} = Piece | Rest], Links) ->
    [piece(Piece, Links) | inline(Rest, Links)];
inline([{page, _, _} = Piece | Rest], Links) ->
    [piece(Piece, Links) | inline(Rest, Links)];
inline([], _Links) ->
    [].

%% the first line, cut at a character boundary
-spec excerpt(binary()) -> binary().
excerpt(Body) ->
    [Line | _] = binary:split(Body, <<"\n">>),
    cut(Line, ?EXCERPT, <<>>).

-spec cut(binary(), non_neg_integer(), binary()) -> binary().
cut(<<C/utf8, Rest/binary>>, N, Acc) when N > 0 ->
    cut(Rest, N - 1, <<Acc/binary, C/utf8>>);
cut(<<>>, _N, Acc) ->
    Acc;
cut(_Rest, _N, Acc) ->
    <<Acc/binary, "…"/utf8>>.

-spec stamp(integer()) -> binary().
stamp(Time) ->
    case calendar:system_time_to_rfc3339(Time, [{offset, "Z"}, {return, binary}]) of
        Stamp when is_binary(Stamp) -> Stamp;
        _ -> <<>>
    end.
