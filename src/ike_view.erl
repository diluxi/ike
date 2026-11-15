%% What the pages say. Pure: rows in, a tree out; ike_render and the
%% handlers decide where it goes.
-module(ike_view).

-export([thread/3, board/2, boards/1, index/0, post_form/2, message/2, layout/2]).
-export([moderation/3, moderated/3]).
-export_type([post/0, summary/0, board/0, held/0]).

%% name: an account's, or what stands in for one
%% links: the posts the text points at that are there, and their boards
%% replies: the posts that point at this one
-type post() :: #{
    id := integer(),
    time := integer(),
    body := binary(),
    name := {account | nobody | role, binary()},
    links := #{integer() => binary()},
    replies := [integer()]
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
    state := shown | hidden | deleted,
    time := integer(),
    body := binary(),
    name := binary() | none,
    account := local | suspended | none
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
    layout(<<">>", N/binary>>, [
        ike_html:el(h1, [ike_html:text(<<">>", N/binary>>)]),
        ike_html:el(p, [board_link(Board)]),
        ike_html:el(ol, [ike_html:el(li, [post(P)]) || P <- Posts])
        | Reply
    ]).

-spec post(post()) -> ike_html:html().
post(#{id := Id, time := Time, body := Body, name := {Kind, Name}, links := Links} = Post) ->
    N = integer_to_binary(Id),
    Anchor = <<"p", N/binary>>,
    Stamp = stamp(Time),
    Class =
        case Kind of
            account -> <<"name account">>;
            role -> <<"name role">>;
            nobody -> <<"name">>
        end,
    ike_html:el(article, [{id, Anchor}], [
        ike_html:el(header, [
            ike_html:el(span, [{class, Class}], [ike_html:text(Name)]),
            ike_html:text(<<" ">>),
            anchor(<<"#", Anchor/binary>>, <<">>", N/binary>>),
            ike_html:text(<<" ">>),
            ike_html:el(time, [{datetime, Stamp}], [ike_html:text(Stamp)])
        ]),
        ike_html:el(p, lines(ike_text:parse(Body), Links))
        | replies(maps:get(replies, Post))
    ]).

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

-spec piece(ike_text:piece(), #{integer() => binary()}) -> ike_html:html().
piece({text, Text}, _Links) ->
    ike_html:text(Text);
piece({post, N}, Links) ->
    case Links of
        #{N := _} -> permalink(N, <<>>);
        _ -> gone(<<">>", (integer_to_binary(N))/binary>>)
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
        ike_html:el(ul, [ike_html:el(li, [anchor(<<"/board">>, <<"board">>)])])
    ]).

%% the form for a new thread or a reply, for whoever is logged in; anyone
%% else is shown the way to log in. plain forms: nothing here needs a script
-spec post_form(
    Action :: binary(),
    {csrf, binary(), Name :: binary() | none} | {nobody, Token :: binary()} | locked
) ->
    ike_html:html().
post_form(Action, {nobody, Token}) ->
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
                ike_html:el(button, [{type, <<"submit">>}], [ike_html:text(<<"post">>)])
            ])
        ]),
        ike_html:el(p, [
            ike_html:text(<<"posted without an account: nothing is kept but the text. or ">>),
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
post_form(Action, {csrf, Csrf, Name}) ->
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
                    [{id, <<"body">>}, {name, <<"body">>}, {rows, <<"8">>}, required],
                    []
                )
            ])
            | Signed ++
                [
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
    [{Account :: integer(), Name :: binary()}]
) -> ike_html:html().
moderation({Csrf, Role}, Boards, Suspended) ->
    layout(<<"moderation">>, [
        ike_html:el(h1, [ike_html:text(<<"moderation">>)]),
        ike_html:el(p, [
            ike_html:text(
                <<"as ", (ike_role:to_binary(Role))/binary, ". what is done is written to ">>
            ),
            anchor(<<"/board/mod">>, <<"/mod/">>),
            ike_html:text(<<", with the reason given and without your name.">>)
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
                    Role,
                    case Locked of
                        true -> [unlock];
                        false -> [lock]
                    end
                )
            ])
         || {Name, Title, Locked} <- Boards
        ]),
        ike_html:el(ul, [
            ike_html:el(li, [
                ike_html:text(<<Name/binary, ": suspended">>)
                | act(<<"/mod/account/", (integer_to_binary(Account))/binary>>, Csrf, Role, [unban])
            ])
         || {Account, Name} <- Suspended
        ])
    ]).

%% one post, as it is stored, and what this role may do with it
-spec moderated({Csrf :: binary(), ike_role:role()}, held(), [ike_role:kind()]) ->
    ike_html:html().
moderated({Csrf, Role}, #{id := Id, thread := Thread, board := Board} = Post, Kinds) ->
    #{state := State, time := Time, body := Body, name := Name} = Post,
    N = integer_to_binary(Id),
    Stamp = stamp(Time),
    Where =
        case Id of
            Thread -> <<"/", Board/binary, "/, the first post of its thread">>;
            _ -> <<"/", Board/binary, "/, in >>", (integer_to_binary(Thread))/binary>>
        end,
    layout(<<"moderating >>", N/binary>>, [
        ike_html:el(h1, [ike_html:text(<<">>", N/binary>>)]),
        ike_html:el(p, [anchor(<<"/mod">>, <<"moderation">>)]),
        ike_html:el(p, [
            ike_html:text(<<(atom_to_binary(State))/binary, ", on ", Where/binary, ", ">>),
            ike_html:el(time, [{datetime, Stamp}], [ike_html:text(Stamp)]),
            ike_html:text(
                case Name of
                    none -> <<", unsigned">>;
                    _ -> <<", signed ", Name/binary>>
                end
            )
        ]),
        %% as text and nothing more: no link in it is followed from here
        ike_html:el(article, [ike_html:el(p, plain(binary:split(Body, <<"\n">>, [global])))])
        | act(<<"/mod/post/", N/binary>>, Csrf, Role, Kinds)
    ]).

-spec plain([binary()]) -> [ike_html:html()].
plain([Line]) -> [ike_html:text(Line)];
plain([Line | Rest]) -> [ike_html:text(Line), ike_html:el(br, []) | plain(Rest)];
plain([]) -> [].

%% a form for each thing the role may do, each with its reason
-spec act(Action :: binary(), Csrf :: binary(), ike_role:role(), [ike_role:kind()]) ->
    [ike_html:html()].
act(Action, Csrf, Role, Kinds) ->
    [
        ike_html:el(form, [{method, <<"post">>}, {action, Action}], [
            ike_html:el(input, [{type, <<"hidden">>}, {name, <<"csrf">>}, {value, Csrf}], []),
            ike_html:el(
                input, [{type, <<"hidden">>}, {name, <<"kind">>}, {value, atom_to_binary(Kind)}], []
            ),
            ike_html:el(p, [
                ike_html:el(
                    input,
                    [{name, <<"reason">>}, {maxlength, <<"200">>}, required],
                    []
                ),
                ike_html:text(<<" ">>),
                ike_html:el(button, [{type, <<"submit">>}], [ike_html:text(atom_to_binary(Kind))])
            ])
        ])
     || Kind <- Kinds, ike_role:may(Role, Kind)
    ].

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
        ike_html:el(nav, [anchor(<<"/">>, <<"ike">>)]),
        ike_html:el(main, Content)
    ]).

-spec anchor(Href :: binary(), Text :: binary()) -> ike_html:html().
anchor(Href, Text) ->
    ike_html:el(a, [{href, Href}], [ike_html:text(Text)]).

%% each line's pieces, with a br between lines
-spec lines([[ike_text:piece()]], #{integer() => binary()}) -> [ike_html:html()].
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
