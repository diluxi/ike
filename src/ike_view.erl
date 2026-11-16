%% What the pages say. Pure: rows in, a tree out; ike_render and the
%% handlers decide where it goes.
-module(ike_view).

-export([thread/3, board/2, boards/1, index/0, post_form/2, message/2, layout/2]).
-export([moderation/5, moderated/3, upload/4, upload_locked/0, account/1, acted/2]).
-export([entry/1, entries/1, moderated_entry/4, search/2]).
-export([wiki_index/1, wiki_page/3, wiki_missing/2, wiki_edit/6, wiki_history/2]).
-export_type([post/0, summary/0, board/0, held/0, image/0]).

%% name: an account's, or what stands in for one
%% links: the posts the text points at that are there, and their boards
%% replies: the posts that point at this one
-type post() :: #{
    id := integer(),
    time := integer(),
    body := binary(),
    name := {account | nobody | role, binary()},
    links := #{integer() | {booru, integer()} | {page, binary()} => binary()},
    replies := [integer()],
    images => [image() | gone]
}.
%% an asset a post shows, where the media origin has it
-type image() :: #{
    file := binary(),
    thumb := binary(),
    type := binary(),
    width := pos_integer(),
    height := pos_integer()
}.
%% a thread as its board lists it
-type summary() :: #{root := integer(), posts := integer(), body := binary()}.
%% log: the board is the record of what moderators did, and takes no posts
-type board() :: #{name := binary(), title := binary(), log := boolean()}.
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
    List = ike_html:el(ol, [ike_html:el(li, [post(P, Log)]) || P <- Posts]),
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
    layout(<<">>", N/binary>>, [
        ike_html:el(h1, [ike_html:text(<<">>", N/binary>>)]),
        ike_html:el(p, [board_link(Board)])
        | Body ++ Reply
    ]).

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

-spec post(post(), Log :: boolean()) -> ike_html:html().
post(#{id := Id, time := Time, body := Body, name := {Kind, Name}, links := Links} = Post, Log) ->
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
    Header = ike_html:el(
        header,
        Tick ++
            [
                ike_html:el(span, [{class, Class}], [ike_html:text(Name)]),
                ike_html:text(<<" ">>),
                anchor(<<"#", Anchor/binary>>, <<">>", N/binary>>),
                ike_html:text(<<" ">>),
                ike_html:el(time, [{datetime, Stamp}], [ike_html:text(Stamp)])
            ]
    ),
    Text =
        case Body of
            <<>> -> [];
            _ -> [ike_html:el(p, lines(ike_text:parse(Body), Links))]
        end,
    ike_html:el(
        article,
        [{id, Anchor}],
        [Header | figures(maps:get(images, Post, []))] ++ Text ++ replies(maps:get(replies, Post))
    ).

-spec figures([image() | gone]) -> [ike_html:html()].
figures([Image | Images]) -> figure(Image) ++ figures(Images);
figures([]) -> [].

%% the thumbnail, a link to the whole, and what it is
-spec figure(image() | gone) -> [ike_html:html()].
figure(#{file := File, thumb := Thumb, type := Type, width := W, height := H}) ->
    Size = <<(integer_to_binary(W))/binary, "x", (integer_to_binary(H))/binary>>,
    case ike_media:moving(Type) of
        %% a video plays where it is, its first frame shown until then,
        %% nothing fetched before it is asked for; works without a script
        true ->
            [
                ike_html:el(p, [
                    ike_html:el(
                        video,
                        [{src, File}, {poster, Thumb}, {preload, <<"none">>}, controls],
                        [anchor(File, <<Type/binary, ", ", Size/binary>>)]
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
                ike_html:el(img, [{src, Thumb}, {alt, <<Type/binary, ", ", Size/binary>>}], [])
            ])
        ])
    ].

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

-spec piece(ike_text:piece(), #{integer() | {booru, integer()} | {page, binary()} => binary()}) ->
    ike_html:html().
piece({text, Text}, _Links) ->
    ike_html:text(Text);
piece({post, N}, Links) ->
    case Links of
        #{N := _} -> permalink(N, <<>>);
        _ -> gone(<<">>", (integer_to_binary(N))/binary>>)
    end;
piece({page, Name}, Links) ->
    Text = <<"[[", Name/binary, "]]">>,
    case Links of
        #{{page, Name} := <<"page">>} -> anchor(<<"/wiki/", Name/binary>>, Text);
        #{{page, Name} := <<"tag">>} -> anchor(<<"/booru/search?tags=", Name/binary>>, Text);
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
-spec index() -> ike_html:html().
index() ->
    layout(<<"ike">>, [
        ike_html:el(h1, [ike_html:text(<<"ike">>)]),
        ike_html:el(ul, [
            ike_html:el(li, [anchor(<<"/board">>, <<"board">>)]),
            ike_html:el(li, [anchor(<<"/booru">>, <<"booru">>)]),
            ike_html:el(li, [anchor(<<"/wiki">>, <<"wiki">>)])
        ])
    ]).

%% the form for a new thread or a reply, for whoever is logged in; anyone
%% else is shown the way to log in. plain forms: nothing here needs a script
-spec post_form(
    Action :: binary(),
    {csrf, binary(), Name :: binary() | none, Staged :: [{pos_integer(), Thumb :: binary()}],
        Password :: binary()}
    | {nobody, Token :: binary(), Password :: binary()}
    | locked
) ->
    ike_html:html().
post_form(Action, {nobody, Token, Password}) ->
    layout(<<"post">>, [
        ike_html:el(h1, [ike_html:text(<<"post">>)]),
        ike_html:el(form, [{method, <<"post">>}, {action, Action}], [
            ike_html:el(input, [{type, <<"hidden">>}, {name, <<"csrf">>}, {value, Token}], []),
            ike_html:el(p, [
                ike_html:el(label, [{for, <<"body">>}], [ike_html:text(<<"text">>)]),
                ike_html:el(br, []),
                ike_html:el(
                    textarea,
                    [{id, <<"body">>}, {name, <<"body">>}, {rows, <<"8">>}, required],
                    []
                )
            ]),
            ike_html:el(p, [
                ike_html:el(label, [{for, <<"password">>}], [
                    ike_html:text(<<"password, to retract it later; this browser keeps it ">>)
                ]),
                ike_html:el(
                    input,
                    [
                        {type, <<"text">>},
                        {id, <<"password">>},
                        {name, <<"password">>},
                        {value, Password}
                    ],
                    []
                )
            ]),
            ike_html:el(p, [
                ike_html:el(button, [{type, <<"submit">>}], [ike_html:text(<<"post">>)])
            ])
        ]),
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
        ike_html:el(form, [{method, <<"post">>}, {action, Action}], [
            Token,
            ike_html:el(p, [
                ike_html:el(label, [{for, <<"body">>}], [ike_html:text(<<"text">>)]),
                ike_html:el(br, []),
                ike_html:el(
                    textarea,
                    Area,
                    []
                )
            ])
            | Pick ++ Signed ++
                [
                    ike_html:el(p, [
                        ike_html:el(label, [{for, <<"password">>}], [
                            ike_html:text(
                                <<"password, to retract it later; this browser keeps it ">>
                            )
                        ]),
                        ike_html:el(
                            input,
                            [
                                {type, <<"text">>},
                                {id, <<"password">>},
                                {name, <<"password">>},
                                {value, Password}
                            ],
                            []
                        )
                    ]),
                    ike_html:el(p, [
                        ike_html:el(button, [{type, <<"submit">>}], [ike_html:text(<<"post">>)])
                    ])
                ]
        ]),
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
    Csrf :: binary(),
    Refused :: [binary()],
    [#{atom() => term()}],
    [{pos_integer(), pos_integer()}]
) -> ike_html:html().
upload(Csrf, Refused, Staged, Posted) ->
    layout(<<"uploads">>, [
        ike_html:el(h1, [ike_html:text(<<"uploads">>)]),
        ike_html:el(p, [
            ike_html:text(
                <<"images wait here until they are posted, seen by you alone. jpeg, png or",
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
                            {type, <<"file">>},
                            {name, <<"file">>},
                            {accept, <<"image/jpeg,image/png,image/webp,video/webm,video/mp4">>},
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
        ike_html:el(ul, [ike_html:el(li, [ike_html:text(R)]) || R <- Refused]),
        ike_html:el(ul, [staged(S) || S <- Staged]),
        %% and those posted, wherever their posts are now
        ike_html:el(ul, [
            ike_html:el(li, [
                ike_html:text(<<"upload ", (integer_to_binary(U))/binary, ", posted in ">>),
                permalink(P, <<>>)
            ])
         || {U, P} <- Posted
        ])
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
        ike_html:text(
            <<" upload ", N/binary, ", ", Type/binary, ", ", (integer_to_binary(W))/binary, "x",
                (integer_to_binary(H))/binary>>
        )
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

%% a booru entry: its newest version large enough to look at, every
%% version, and where on the boards it is shown and pointed at
-spec entry(#{
    id := pos_integer(),
    time := integer(),
    versions := [{non_neg_integer(), image() | gone}],
    shown_in := [pos_integer()],
    linked_from := [pos_integer()],
    tags := [binary()],
    changes := [{integer(), binary(), binary()}]
}) -> ike_html:html().
entry(
    #{id := Id, time := Time, versions := Versions, shown_in := Shown, linked_from := Linked} =
        Entry
) ->
    #{tags := Tags, changes := Changes} = Entry,
    N = integer_to_binary(Id),
    Stamp = stamp(Time),
    Newest =
        case Versions of
            [{_, Image} | _] -> figure(Image);
            [] -> []
        end,
    layout(
        <<"##", N/binary>>,
        [
            ike_html:el(h1, [ike_html:text(<<"##", N/binary>>)]),
            ike_html:el(p, [
                anchor(<<"/booru">>, <<"booru">>),
                ike_html:text(<<", since ">>),
                ike_html:el(time, [{datetime, Stamp}], [ike_html:text(Stamp)])
            ])
            | Newest
        ] ++
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
                                        ", ",
                                        (integer_to_binary(W))/binary,
                                        "x",
                                        (integer_to_binary(H))/binary
                                    >>;
                                gone ->
                                    <<(integer_to_binary(Position + 1))/binary, ": purged">>
                            end
                        )
                    ])
                 || {Position, Image} <- Versions
                ]),
                ike_html:el(p, [ike_html:text(<<"tags ">>) | spaced([tag_link(T) || T <- Tags])]),
                %% a plain form for accounts, on a page the same for
                %% everyone: guarded as the thread's is
                ike_html:el(
                    form, [{method, <<"post">>}, {action, <<"/booru/", N/binary, "/tags">>}], [
                        ike_html:el(p, [
                            ike_html:el(label, [{for, <<"tags">>}], [
                                ike_html:text(<<"tag (accounts; -name takes one off) ">>)
                            ]),
                            ike_html:el(
                                input,
                                [{id, <<"tags">>}, {name, <<"tags">>}, {maxlength, <<"2000">>}],
                                []
                            ),
                            ike_html:text(<<" ">>),
                            ike_html:el(button, [{type, <<"submit">>}], [ike_html:text(<<"tag">>)])
                        ])
                    ]
                ),
                ike_html:el(ul, [changed(C) || C <- Changes]),
                ike_html:el(p, [
                    ike_html:text(<<"shown in ">>) | spaced([permalink(P, <<>>) || P <- Shown])
                ]),
                ike_html:el(p, [
                    ike_html:text(<<"pointed at by ">>)
                    | spaced([permalink(P, <<>>) || P <- Linked])
                ])
            ]
    ).

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

-spec tag_link(binary()) -> ike_html:html().
tag_link(Name) ->
    anchor(<<"/booru/search?tags=", Name/binary>>, Name).

%% entries by their tags: the form, what it was asked, and what it found
-spec search(
    Said :: binary(),
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
        ike_html:el(h1, [ike_html:text(<<"search">>)]),
        ike_html:el(form, [{method, <<"get">>}, {action, <<"/booru/search">>}], [
            ike_html:el(p, [
                ike_html:el(
                    input, [{name, <<"tags">>}, {value, Said}, {maxlength, <<"1000">>}], []
                ),
                ike_html:text(<<" ">>),
                ike_html:el(button, [{type, <<"submit">>}], [ike_html:text(<<"search">>)])
            ])
        ]),
        ike_html:el(ul, [found(F) || F <- Found])
    ]).

-spec found(
    {
        pos_integer(),
        binary() | undefined,
        binary() | undefined,
        integer() | undefined,
        integer() | undefined
    }
) -> ike_html:html().
found({Id, Hash, Type, _W, _H}) ->
    I = integer_to_binary(Id),
    Href = <<"/booru/", I/binary>>,
    ike_html:el(li, [
        case {Hash, Type} of
            {<<_/binary>>, <<_/binary>>} ->
                Thumb = ike_media:thumb_url(binary:encode_hex(Hash, lowercase)),
                ike_html:el(a, [{href, Href}], [
                    ike_html:el(img, [{src, Thumb}, {alt, <<"##", I/binary>>}], [])
                ]);
            _ ->
                anchor(Href, <<"##", I/binary>>)
        end
    ]).

%% a booru entry on its moderation page
-spec moderated_entry(binary(), pos_integer(), shown | hidden | trashed, [ike_role:kind()]) ->
    ike_html:html().
moderated_entry(Csrf, Id, State, Kinds) ->
    N = integer_to_binary(Id),
    layout(<<"moderating ##", N/binary>>, [
        ike_html:el(h1, [ike_html:text(<<"##", N/binary>>)]),
        ike_html:el(p, [anchor(<<"/mod">>, <<"moderation">>)]),
        ike_html:el(p, [ike_html:text(atom_to_binary(State))])
        | act(<<"/mod/booru/", N/binary>>, Csrf, Kinds, [])
    ]).

%% the booru: the newest entries, each its thumbnail, linking to it
-spec entries([{pos_integer(), image() | gone}]) -> ike_html:html().
entries(Entries) ->
    layout(<<"booru">>, [
        ike_html:el(h1, [ike_html:text(<<"booru">>)]),
        ike_html:el(ul, [
            ike_html:el(li, [
                case Image of
                    #{thumb := Thumb} ->
                        ike_html:el(a, [{href, <<"/booru/", (integer_to_binary(Id))/binary>>}], [
                            ike_html:el(
                                img,
                                [{src, Thumb}, {alt, <<"##", (integer_to_binary(Id))/binary>>}],
                                []
                            )
                        ]);
                    gone ->
                        anchor(
                            <<"/booru/", (integer_to_binary(Id))/binary>>,
                            <<"##", (integer_to_binary(Id))/binary>>
                        )
                end
            ])
         || {Id, Image} <- Entries
        ])
    ]).

%% the wiki's pages, by name
-spec wiki_index([binary()]) -> ike_html:html().
wiki_index(Names) ->
    layout(<<"wiki">>, [
        ike_html:el(h1, [ike_html:text(<<"wiki">>)]),
        ike_html:el(ul, [ike_html:el(li, [anchor(<<"/wiki/", N/binary>>, N)]) || N <- Names])
    ]).

%% a page as it now reads, and the ways to its history, its editing and
%% its discussion
-spec wiki_page(
    binary(),
    #{thread := pos_integer(), revision := pos_integer(), time := integer(), body := binary()},
    #{integer() | {booru, integer()} | {page, binary()} => binary()}
) -> ike_html:html().
wiki_page(Name, #{thread := Thread, revision := Revision, time := Time, body := Body}, Links) ->
    Stamp = stamp(Time),
    layout(Name, [
        ike_html:el(h1, [ike_html:text(Name)]),
        ike_html:el(p, lines(ike_text:parse(Body), Links)),
        ike_html:el(p, [
            ike_html:text(<<"as of ">>),
            permalink(Revision, <<>>),
            ike_html:text(<<", ">>),
            ike_html:el(time, [{datetime, Stamp}], [ike_html:text(Stamp)])
        ]),
        ike_html:el(
            p,
            spaced([
                anchor(<<"/wiki/", Name/binary, "/edit">>, <<"edit">>),
                anchor(<<"/wiki/", Name/binary, "/history">>, <<"history">>),
                anchor(<<"/board/wiki/", (integer_to_binary(Thread))/binary>>, <<"discussion">>)
            ])
        )
    ]).

%% a name with no page yet
-spec wiki_missing(binary(), SignedIn :: boolean()) -> ike_html:html().
wiki_missing(Name, SignedIn) ->
    layout(Name, [
        ike_html:el(h1, [ike_html:text(Name)]),
        ike_html:el(p, [
            ike_html:text(<<"no page by this name yet. ">>),
            case SignedIn of
                true -> anchor(<<"/wiki/", Name/binary, "/edit">>, <<"start it">>);
                false -> anchor(<<"/login">>, <<"log in to start it">>)
            end
        ])
    ]).

%% the editing form, on the revision Base; with Theirs, the text that was
%% refused because the page changed meanwhile, to be made again on it
-spec wiki_edit(binary(), binary(), binary() | none, binary(), binary(), binary() | none) ->
    ike_html:html().
wiki_edit(Name, Csrf, Signer, Base, Text, Theirs) ->
    Conflict =
        case Theirs of
            none ->
                [];
            _ ->
                [
                    ike_html:el(p, [
                        ike_html:text(
                            <<"the page changed while you edited it. below is it now; yours was:">>
                        )
                    ]),
                    ike_html:el(p, plain(binary:split(Theirs, <<"\n">>, [global])))
                ]
        end,
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
        | Conflict ++
            [
                ike_html:el(
                    form, [{method, <<"post">>}, {action, <<"/wiki/", Name/binary, "/edit">>}], [
                        ike_html:el(
                            input, [{type, <<"hidden">>}, {name, <<"csrf">>}, {value, Csrf}], []
                        ),
                        ike_html:el(
                            input, [{type, <<"hidden">>}, {name, <<"base">>}, {value, Base}], []
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
                                ike_html:el(p, [
                                    ike_html:el(button, [{type, <<"submit">>}], [
                                        ike_html:text(<<"save">>)
                                    ])
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
        ike_html:el(p, [anchor(<<"/wiki/", Name/binary>>, Name)]),
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

%% a page that only says something
-spec message(Title :: binary(), Text :: binary()) -> ike_html:html().
message(Title, Text) ->
    layout(Title, [
        ike_html:el(h1, [ike_html:text(Title)]),
        ike_html:el(p, [ike_html:text(Text)])
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
-spec lines([[ike_text:piece()]], #{integer() | {booru, integer()} | {page, binary()} => binary()}) ->
    [ike_html:html()].
lines([], _Links) ->
    [];
lines([Line], Links) ->
    [piece(P, Links) || P <- Line];
lines([Line | Rest], Links) ->
    [piece(P, Links) || P <- Line] ++ [ike_html:el(br, []) | lines(Rest, Links)].

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
