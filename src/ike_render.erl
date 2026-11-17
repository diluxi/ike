%% The static renderer: pages are files, rebuilt from the database after
%% each commit, and all of them at start, so the tree can be thrown away.
%% A page is written beside its place and renamed into it (hazard d2).
-module(ike_render).
-behaviour(gen_server).

-export([start_link/0, dirty/1, dirty_board/1, dirty_booru/1, settle/1, sync/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    conn :: ike_db:reader(),
    dir :: binary(),
    %% what is out of date, each once: threads by root, boards by name,
    %% and the pages that list boards
    threads = [] :: [integer()],
    boards = [] :: [binary()],
    lists = false :: boolean(),
    %% booru entries by number, and the booru's own page
    boorus = [] :: [integer()],
    booru = false :: boolean()
}).

%% threads on a board's page; there is no paging yet
-define(INDEX, 100).
-define(SYNC_TIMEOUT, 15000).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% told by the writer, after it committed
-spec dirty(Thread :: integer()) -> ok.
dirty(Thread) ->
    gen_server:cast(?MODULE, {dirty, Thread}).

%% a booru entry's page, and the booru's, which lists entries
-spec dirty_booru(Entry :: integer()) -> ok.
dirty_booru(Entry) ->
    gen_server:cast(?MODULE, {dirty_booru, Entry}).

%% a board's own page, when no thread's page says it changed
-spec dirty_board(Name :: binary()) -> ok.
dirty_board(Name) ->
    gen_server:cast(?MODULE, {dirty_board, Name}).

%% asked by the writer before it unlinks a thread's page: once this
%% returns, no page read before the writer's last commit is still to be
%% written, since the pages are written one at a time, here
-spec settle(Thread :: integer() | {booru, integer()}) -> ok.
settle(Thread) ->
    case gen_server:call(?MODULE, {settle, Thread}, ?SYNC_TIMEOUT) of
        ok -> ok;
        _ -> ok
    end.

%% returns once every page known to be out of date has been written
-spec sync() -> ok | {error, term()}.
sync() ->
    case gen_server:call(?MODULE, sync, ?SYNC_TIMEOUT) of
        ok -> ok;
        Other -> {error, Other}
    end.

-spec init([]) -> {ok, #state{}} | {stop, term()}.
init([]) ->
    process_flag(trap_exit, true),
    Dir = ike_config:pages_dir(),
    case
        {
            filelib:ensure_path(<<Dir/binary, "/board">>),
            filelib:ensure_path(<<Dir/binary, "/booru">>)
        }
    of
        {ok, ok} ->
            case ike_db:open_reader(ike_config:db_path()) of
                {ok, Conn} ->
                    case everything(Conn) of
                        {ok, Threads, Boards, Entries} ->
                            self() ! render,
                            {ok, #state{
                                conn = Conn,
                                dir = Dir,
                                threads = Threads,
                                boards = Boards,
                                lists = true,
                                boorus = Entries,
                                booru = true
                            }};
                        {error, Reason} ->
                            _ = ike_db:close(Conn),
                            {stop, Reason}
                    end;
                {error, Reason} ->
                    {stop, Reason}
            end;
        {{error, Reason}, _} ->
            {stop, {pages_dir, Reason}};
        {_, {error, Reason}} ->
            {stop, {pages_dir, Reason}}
    end.

-spec handle_call(term(), gen_server:from(), #state{}) ->
    {reply, term(), #state{}}.
handle_call({settle, Thread}, _From, #state{threads = Threads} = State) when
    is_integer(Thread)
->
    {reply, ok, State#state{threads = ordsets:del_element(Thread, Threads)}};
handle_call({settle, {booru, Entry}}, _From, #state{boorus = Entries} = State) when
    is_integer(Entry)
->
    {reply, ok, State#state{boorus = ordsets:del_element(Entry, Entries), booru = true}};
handle_call(sync, _From, State) ->
    {reply, ok, drain(State)};
handle_call(_Request, _From, State) ->
    {reply, {error, bad_request}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast({dirty, Thread}, #state{threads = Threads} = State) when
    is_integer(Thread)
->
    self() ! render,
    {noreply, State#state{threads = ordsets:add_element(Thread, Threads)}};
handle_cast({dirty_board, Name}, #state{boards = Boards} = State) when is_binary(Name) ->
    self() ! render,
    {noreply, State#state{boards = ordsets:add_element(Name, Boards)}};
handle_cast({dirty_booru, Entry}, #state{boorus = Entries} = State) when is_integer(Entry) ->
    self() ! render,
    {noreply, State#state{boorus = ordsets:add_element(Entry, Entries), booru = true}};
handle_cast(_Request, State) ->
    {noreply, State}.

%% one page per message, so that what arrives meanwhile joins the set
-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info(render, State) ->
    {noreply, step(State)};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), #state{}) -> ok.
terminate(_Reason, #state{conn = Conn}) ->
    _ = ike_db:close(Conn),
    ok.

-spec drain(#state{}) -> #state{}.
drain(#state{threads = [], boards = [], lists = false, boorus = [], booru = false} = State) ->
    State;
drain(State) ->
    drain(step(State)).

%% a thread's page first, then its board's: the board lists what exists
-spec step(#state{}) -> #state{}.
step(#state{threads = [Thread | Threads], boards = Boards} = State) ->
    self() ! render,
    case render_thread(State, Thread) of
        {ok, Board} ->
            State#state{threads = Threads, boards = ordsets:add_element(Board, Boards)};
        none ->
            State#state{threads = Threads}
    end;
step(#state{threads = [], boorus = [Entry | Entries]} = State) ->
    _ = render_entry(State, Entry),
    self() ! render,
    State#state{boorus = Entries, booru = true};
step(#state{threads = [], boards = [Board | Boards]} = State) ->
    ok = render_board(State, Board),
    self() ! render,
    State#state{boards = Boards};
step(#state{threads = [], boards = [], booru = true} = State) ->
    ok = render_entries(State),
    self() ! render,
    State#state{booru = false};
step(#state{threads = [], boards = [], lists = true} = State) ->
    ok = render_lists(State),
    State#state{lists = false};
step(State) ->
    State.

-spec everything(ike_db:reader()) -> {ok, [integer()], [binary()], [integer()]} | ike_db:error().
everything(Conn) ->
    case ike_db:q(Conn, <<"SELECT DISTINCT thread FROM shown ORDER BY thread">>, []) of
        {ok, Threads} ->
            case
                {
                    ike_db:q(Conn, <<"SELECT name FROM board ORDER BY name">>, []),
                    ike_db:q(Conn, <<"SELECT id FROM shown_entry ORDER BY id">>, [])
                }
            of
                {{ok, Boards}, {ok, Entries}} ->
                    {ok, [Root || [Root] <- Threads, is_integer(Root)],
                        [Name || [Name] <- Boards, is_binary(Name)], [
                            E
                         || [E] <- Entries, is_integer(E)
                        ]};
                {{error, _} = Error, _} ->
                    Error;
                {_, {error, _} = Error} ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%% a thread that is on no board has no page yet, and one whose first
%% post was taken down has none any more: the writer unlinks that
-spec render_thread(#state{}, integer()) -> {ok, Board :: binary()} | none.
render_thread(#state{conn = Conn, dir = Dir}, Thread) ->
    Where = <<
        "SELECT b.name, b.title, b.log, b.wiki FROM thread t JOIN board b ON b.id = t.board"
        " WHERE t.root = ?1 AND EXISTS (SELECT 1 FROM shown s WHERE s.thread = t.root)"
    >>,
    %% the role is there on the log's entries, and stands for the name
    Sql = <<
        "SELECT p.id, p.time, p.body, a.name, b.log, m.role, q.title, q.revision"
        " FROM shown p JOIN post q ON q.id = p.id"
        " JOIN actor a ON a.id = p.actor JOIN thread t ON t.root = p.thread"
        " JOIN board b ON b.id = t.board LEFT JOIN action m ON m.entry = p.id"
        " WHERE p.thread = ?1 ORDER BY p.id"
    >>,
    case ike_db:q(Conn, Where, [Thread]) of
        {ok, [[Name, Title, Logs, Wiki]]} when is_binary(Name), is_binary(Title) ->
            case ike_db:q(Conn, Sql, [Thread]) of
                {ok, Rows} ->
                    Names = ike_config:anonymous_names(),
                    Links = links(Conn, Thread),
                    Replies = replies(Conn, Thread),
                    Images = images(Conn, Thread),
                    Posts0 = [
                        #{
                            id => Id,
                            time => Time,
                            body => Body,
                            name => name(Name0, Id, Names, Log, Role),
                            links => Links,
                            replies => maps:get(Id, Replies, []),
                            images => maps:get(Id, Images, []),
                            title =>
                                case PostTitle of
                                    _ when is_binary(PostTitle) -> PostTitle;
                                    _ -> none
                                end,
                            revision => Revision =:= 1
                        }
                     || [Id, Time, Body, Name0, Log, Role, PostTitle, Revision] <- Rows,
                        is_integer(Id),
                        is_integer(Time),
                        is_binary(Body)
                    ],
                    Board0 = #{
                        name => Name, title => Title, log => Logs =:= 1, wiki => Wiki =:= 1
                    },
                    {Board, Posts} =
                        case Wiki of
                            1 -> paged(Conn, Thread, Board0, Posts0);
                            _ -> {Board0, Posts0}
                        end,
                    File =
                        <<"board/", Name/binary, "/", (integer_to_binary(Thread))/binary, ".html">>,
                    ok = write(Dir, File, ike_view:thread(Board, Thread, Posts)),
                    {ok, Name};
                {error, Reason} ->
                    error({render, Thread, Reason})
            end;
        {ok, _} ->
            none;
        {error, Reason} ->
            error({render, Thread, Reason})
    end.

%% a page's thread: headed by the page's name, its first post a titled
%% tombstone if it is out of view, and each revision in view named for
%% the page and its count, shown as what it changed of the one in view
%% before it, which so takes over what a revision out of view did (lux)
-spec paged(ike_db:reader(), integer(), ike_view:board(), [ike_view:post()]) ->
    {ike_view:board(), [ike_view:post()]}.
paged(Conn, Thread, Board, Posts0) ->
    Page =
        case ike_db:q(Conn, <<"SELECT name FROM page WHERE thread = ?1">>, [Thread]) of
            {ok, [[N]]} when is_binary(N) -> N;
            _ -> <<">>", (integer_to_binary(Thread))/binary>>
        end,
    Posts1 =
        case Posts0 of
            [#{id := Thread} | _] ->
                Posts0;
            _ ->
                [
                    #{
                        id => Thread,
                        time => 0,
                        body => <<>>,
                        name => {nobody, <<>>},
                        links => #{},
                        replies => [],
                        title => Page,
                        tombstone => true
                    }
                    | Posts0
                ]
        end,
    {Board#{page => Page}, revised(Posts1, <<>>, Page, 1)}.

-spec revised([ike_view:post()], binary(), binary(), pos_integer()) -> [ike_view:post()].
revised([#{revision := true, body := Body} = P | Rest], Before, Page, N) ->
    Title = <<Page/binary, " ", (integer_to_binary(N))/binary>>,
    [
        P#{changes => ike_wiki:diff(Before, Body), title => Title}
        | revised(Rest, Body, Page, N + 1)
    ];
revised([P | Rest], Before, Page, N) ->
    [P | revised(Rest, Before, Page, N)];
revised([], _Before, _Page, _N) ->
    [].

%% the posts this thread's posts point at, those that are there to be
%% shown, and the board each is on
-spec links(ike_db:reader(), integer()) ->
    #{integer() | {booru, integer()} | {page, binary()} => binary()}.
links(Conn, Thread) ->
    Sql = <<
        "SELECT DISTINCT l.post, b.name FROM post s"
        " JOIN link l ON l.source = s.id JOIN shown p ON p.id = l.post"
        " JOIN thread t ON t.root = p.thread JOIN board b ON b.id = t.board"
        " WHERE s.thread = ?1"
    >>,
    %% the names they point at: a page, else a tag
    Names = <<
        "SELECT DISTINCT l.name,"
        " EXISTS (SELECT 1 FROM page pg JOIN shown s2 ON s2.thread = pg.thread"
        " JOIN post p2 ON p2.id = s2.id WHERE pg.name = l.name AND p2.revision = 1),"
        " EXISTS (SELECT 1 FROM tag WHERE name = l.name)"
        " FROM post s JOIN link l ON l.source = s.id WHERE s.thread = ?1 AND l.name IS NOT NULL"
    >>,
    Named =
        case ike_db:q(Conn, Names, [Thread]) of
            {ok, NRows} ->
                #{
                    {page, N} =>
                        case IsPage of
                            1 -> <<"page">>;
                            _ -> <<"tag">>
                        end
                 || [N, IsPage, IsTag] <- NRows, is_binary(N), IsPage =:= 1 orelse IsTag =:= 1
                };
            {error, NReason} ->
                error({render, Thread, NReason})
        end,
    %% and the entries they point at that are there to be shown
    Entries = <<
        "SELECT DISTINCT l.booru FROM post s JOIN link l ON l.source = s.id"
        " JOIN shown_entry e ON e.id = l.booru WHERE s.thread = ?1"
    >>,
    case {ike_db:q(Conn, Sql, [Thread]), ike_db:q(Conn, Entries, [Thread])} of
        {{ok, Rows}, {ok, Shown}} ->
            maps:merge(
                maps:merge(
                    #{Post => Board || [Post, Board] <- Rows, is_integer(Post), is_binary(Board)},
                    #{{booru, E} => <<>> || [E] <- Shown, is_integer(E)}
                ),
                Named
            );
        {{error, Reason}, _} ->
            error({render, Thread, Reason});
        {_, {error, Reason}} ->
            error({render, Thread, Reason})
    end.

%% who points at each post of this thread, oldest first
-spec replies(ike_db:reader(), integer()) -> #{integer() => [integer()]}.
replies(Conn, Thread) ->
    Sql = <<
        "SELECT l.post, l.source FROM post p JOIN link l ON l.post = p.id"
        " JOIN shown s ON s.id = l.source WHERE p.thread = ?1 ORDER BY l.source DESC"
    >>,
    case ike_db:q(Conn, Sql, [Thread]) of
        {ok, Rows} ->
            grouped(Rows, #{});
        {error, Reason} ->
            error({render, Thread, Reason})
    end.

-spec grouped([ike_db:row()], #{integer() => [integer()]}) -> #{integer() => [integer()]}.
grouped([[Post, Source] | Rows], Acc) when is_integer(Post), is_integer(Source) ->
    grouped(Rows, Acc#{Post => [Source | maps:get(Post, Acc, [])]});
grouped([_ | Rows], Acc) ->
    grouped(Rows, Acc);
grouped([], Acc) ->
    Acc.

%% an account's name, or one of the names for nobody: always the same
%% one for the same post, so that a page rendered again reads the same
-spec name(term(), integer(), [binary(), ...], Log :: term(), Role :: term()) ->
    {account | nobody | role, binary()}.
name(_, _Id, _Names, 1, Role) when is_binary(Role) ->
    {role, Role};
name(_, _Id, _Names, 1, _) ->
    {role, <<"system">>};
name(Name, _Id, _Names, _, _) when is_binary(Name) ->
    {account, Name};
name(_, Id, [First | _] = Names, _, _) ->
    case lists:nth(Id rem length(Names) + 1, Names) of
        Name when is_binary(Name) -> {nobody, Name};
        _ -> {nobody, First}
    end.

%% the images each of the thread's posts shows, in order
-spec images(ike_db:reader(), integer()) -> #{integer() => [ike_view:image() | gone]}.
images(Conn, Thread) ->
    Sql = <<
        "SELECT pa.post, pa.gone, x.hash, x.filetype, coalesce(x.width, 0), coalesce(x.height, 0)"
        " FROM post_image pa JOIN shown s ON s.id = pa.post"
        " LEFT JOIN asset x ON x.hash = pa.asset"
        " WHERE s.thread = ?1 ORDER BY pa.post DESC, pa.position DESC"
    >>,
    case ike_db:q(Conn, Sql, [Thread]) of
        {ok, Rows} -> pictures(Rows, #{});
        {error, Reason} -> error({render, Thread, Reason})
    end.

-spec pictures([ike_db:row()], #{integer() => [ike_view:image() | gone]}) ->
    #{integer() => [ike_view:image() | gone]}.
pictures([[Post, Gone, Hash, Type, W, H] | Rows], Acc) when is_integer(Post) ->
    Image =
        case {Gone, image(Hash, Type, W, H)} of
            {0, #{} = Found} -> Found;
            _ -> gone
        end,
    pictures(Rows, Acc#{Post => [Image | maps:get(Post, Acc, [])]});
pictures([_ | Rows], Acc) ->
    pictures(Rows, Acc);
pictures([], Acc) ->
    Acc.

-spec image(term(), term(), term(), term()) -> ike_view:image() | none.
image(Hash, Type, W, H) when
    is_binary(Hash), is_binary(Type), is_integer(W), is_integer(H)
->
    Hex = binary:encode_hex(Hash, lowercase),
    #{
        file => ike_media:url(Hex, Type),
        thumb => ike_media:thumb_url(Hex),
        type => Type,
        width => W,
        height => H
    };
image(_, _, _, _) ->
    none.

-spec render_board(#state{}, binary()) -> ok.
render_board(#state{conn = Conn, dir = Dir}, Name) ->
    %% most recently posted in first
    Sql = <<
        "SELECT p.thread, count(*), max(p.id),"
        %% a titled thread is listed by its title
        " (SELECT coalesce(title, body) FROM post WHERE id = p.thread)"
        " FROM shown p JOIN thread t ON t.root = p.thread"
        " JOIN board b ON b.id = t.board"
        " WHERE b.name = ?1 GROUP BY p.thread ORDER BY 3 DESC LIMIT ?2"
    >>,
    case {boards(Conn, <<" WHERE name = ?1">>, [Name]), ike_db:q(Conn, Sql, [Name, ?INDEX])} of
        {{ok, [Board]}, {ok, Rows}} ->
            Threads = [
                #{root => Root, posts => Posts, body => Body}
             || [Root, Posts, _Last, Body] <- Rows,
                is_integer(Root),
                is_integer(Posts),
                is_binary(Body)
            ],
            write(Dir, <<"board/", Name/binary, ".html">>, ike_view:board(Board, Threads));
        Other ->
            error({render, Name, Other})
    end.

%% a booru entry's page: its versions, newest first, the posts that show
%% it and those that point at it. one not to be shown has no page; the
%% writer unlinks it
-spec render_entry(#state{}, integer()) -> ok | none.
render_entry(#state{conn = Conn, dir = Dir}, Entry) ->
    Versions = <<
        "SELECT v.position, x.hash, x.filetype, coalesce(x.width, 0), coalesce(x.height, 0),"
        " x.family, x.axes FROM booru_version v"
        " LEFT JOIN asset x ON x.hash = v.asset WHERE v.booru = ?1 ORDER BY v.position DESC"
    >>,
    Shown = <<
        "SELECT DISTINCT pi.post FROM booru_version v JOIN post_image pi ON pi.asset = v.asset"
        " JOIN shown s ON s.id = pi.post WHERE v.booru = ?1 ORDER BY pi.post"
    >>,
    Linked = <<
        "SELECT l.source FROM link l JOIN shown s ON s.id = l.source"
        " WHERE l.booru = ?1 ORDER BY l.source"
    >>,
    Tags = <<
        "SELECT t.name FROM booru_tag bt JOIN tag t ON t.id = bt.tag WHERE bt.booru = ?1"
        " ORDER BY t.name"
    >>,
    %% what was changed, and when; not who
    Changes = <<
        "SELECT time, added, removed FROM tag_change WHERE booru = ?1 ORDER BY id DESC LIMIT 20"
    >>,
    case ike_db:q(Conn, <<"SELECT time FROM shown_entry WHERE id = ?1">>, [Entry]) of
        {ok, [[Time]]} when is_integer(Time) ->
            case
                {
                    ike_db:q(Conn, Versions, [Entry]),
                    ike_db:q(Conn, Shown, [Entry]),
                    ike_db:q(Conn, Linked, [Entry]),
                    ike_db:q(Conn, Tags, [Entry]),
                    ike_db:q(Conn, Changes, [Entry])
                }
            of
                {{ok, Vs}, {ok, Ps}, {ok, Ls}, {ok, Ts}, {ok, Cs}} ->
                    Page = ike_view:entry(#{
                        id => Entry,
                        time => Time,
                        versions => [
                            {Position,
                                case image(Hash, Type, W, H) of
                                    #{} = Image when is_binary(Family) ->
                                        %% a font: tried out on its page
                                        Image#{axes => ike_reader:axes(Axes)};
                                    #{} = Image ->
                                        Image;
                                    none ->
                                        gone
                                end}
                         || [Position, Hash, Type, W, H, Family, Axes] <- Vs,
                            is_integer(Position),
                            is_binary(Axes) orelse Axes =:= undefined
                        ],
                        shown_in => [P || [P] <- Ps, is_integer(P)],
                        linked_from => [L || [L] <- Ls, is_integer(L)],
                        tags => [T || [T] <- Ts, is_binary(T)],
                        changes => [
                            {W, A, R}
                         || [W, A, R] <- Cs, is_integer(W), is_binary(A), is_binary(R)
                        ]
                    }),
                    write(Dir, <<"booru/", (integer_to_binary(Entry))/binary, ".html">>, Page);
                Other ->
                    error({render, {booru, Entry}, Other})
            end;
        {ok, _} ->
            none;
        {error, Reason} ->
            error({render, {booru, Entry}, Reason})
    end.

%% the booru's page: the newest entries, as thumbnails
-spec render_entries(#state{}) -> ok.
render_entries(#state{conn = Conn, dir = Dir}) ->
    Sql = <<
        "SELECT e.id, x.hash, x.filetype, coalesce(x.width, 0), coalesce(x.height, 0) FROM shown_entry e"
        " LEFT JOIN asset x ON x.hash = e.asset ORDER BY e.id DESC LIMIT ?1"
    >>,
    case ike_db:q(Conn, Sql, [?INDEX]) of
        {ok, Rows} ->
            Entries = [
                {Id,
                    case image(Hash, Type, W, H) of
                        #{} = Image -> Image;
                        none -> gone
                    end}
             || [Id, Hash, Type, W, H] <- Rows, is_integer(Id)
            ],
            write(Dir, <<"booru.html">>, ike_view:entries(Entries));
        {error, Reason} ->
            error({render, booru, Reason})
    end.

%% the list of boards, and the page in front of everything
-spec render_lists(#state{}) -> ok.
render_lists(#state{conn = Conn, dir = Dir}) ->
    case boards(Conn, <<>>, []) of
        {ok, Boards} ->
            ok = write(Dir, <<"board.html">>, ike_view:boards(Boards)),
            ok = written(Dir, <<"style.css">>, ike_view:style()),
            ok = written(Dir, <<"ike.js">>, ike_view:script()),
            write(Dir, <<"index.html">>, ike_view:index());
        {error, Reason} ->
            error({render, lists, Reason})
    end.

-spec boards(ike_db:reader(), binary(), [term()]) -> {ok, [ike_view:board()]} | ike_db:error().
boards(Conn, Where, Args) ->
    Sql = <<"SELECT name, title, log FROM board", Where/binary, " ORDER BY name">>,
    case ike_db:q(Conn, Sql, Args) of
        {ok, Rows} ->
            {ok, [
                #{name => Name, title => Title, log => Log =:= 1}
             || [Name, Title, Log] <- Rows, is_binary(Name), is_binary(Title)
            ]};
        {error, _} = Error ->
            Error
    end.

%% the stylesheet, whole, as a page is
-spec written(binary(), binary(), iodata()) -> ok.
written(Dir, Name, Bytes) ->
    Path = <<Dir/binary, "/", Name/binary>>,
    Tmp = <<Path/binary, ".tmp">>,
    ok = file:write_file(Tmp, Bytes),
    ok = file:rename(Tmp, Path).

%% a reader of the page sees the old file or the new one, never part of
%% either
-spec write(binary(), binary(), ike_html:html()) -> ok.
write(Dir, Name, Html) ->
    Path = <<Dir/binary, "/", Name/binary>>,
    Tmp = <<Path/binary, ".tmp">>,
    Written =
        case filelib:ensure_path(filename:dirname(Path)) of
            ok -> file:write_file(Tmp, ike_html:to_iodata(Html));
            {error, _} = Error -> Error
        end,
    case Written of
        ok ->
            case file:rename(Tmp, Path) of
                ok -> ok;
                {error, Reason} -> error({page, Name, Reason})
            end;
        {error, Reason} ->
            error({page, Name, Reason})
    end.
