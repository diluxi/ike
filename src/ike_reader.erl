%% What a request may ask the database: one connection that cannot
%% write, behind one process. The pages are files and need none of this;
%% it is for the few answers that are made per request.
-module(ike_reader).
-behaviour(gen_server).

-export([start_link/0, whereabouts/1, board/1, boards/0, suspended/0, post/1]).
-export([staged/1, staged_file/1, posted/1, out_of_sight/0, password/1, reports/0]).
-export([entry_state/1, search/1, page/1, revisions/1, pages/0, links/1, signed/1]).
-export([metas/1, meta/2, known/2, axes/1, comments/1, attached/1, trunk/0]).
-export_type([staged/0, meta/0, viewer/0]).

%% who looks at the trunk: an account or nobody, and whether a moderator
%% (or above), who sees every meta (invariant 10)
-type viewer() :: #{actor := integer() | none, moderator := boolean()}.
%% a meta as the trunk shows it. upload: its owner's newest upload of
%% the asset (else anyone's), which a link to its files names when they
%% are not public. name: its owner's, if signed, else none (anonymous;
%% lux, Q42). state: as a moderator left it; a meta not shown is seen
%% by moderators, and a trashed one by its owner too (lux, Q40)
-type meta() :: #{
    id := pos_integer(),
    hash := binary(),
    type := binary(),
    %% 0 for a font, which has none
    width := non_neg_integer(),
    height := non_neg_integer(),
    traits := binary(),
    time := integer(),
    private := boolean(),
    mine := boolean(),
    upload := pos_integer(),
    name := binary() | none,
    state := shown | hidden | trashed,
    %% the shown booru entry with this asset, if there is one
    entry := pos_integer() | none,
    %% a font's: its family, its variable axes (tag, least, default,
    %% most), and what its owner's upload of it said of itself
    family := binary() | none,
    axes := [{binary(), float(), float(), float()}],
    commentary := [{binary(), binary()}],
    %% its comment thread, and the curation made of it, if shown
    thread := pos_integer() | none,
    curation := pos_integer() | none
}.

%% a staged upload as its uploader is shown it
-type staged() :: #{
    id := pos_integer(),
    type := binary(),
    %% 0 for a font, which has none
    width := non_neg_integer(),
    height := non_neg_integer(),
    time := integer()
}.
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% the board and thread a post is shown in
-spec whereabouts(Post :: integer()) -> {ok, Board :: binary(), Thread :: integer()} | none.
whereabouts(Post) ->
    case gen_server:call(?MODULE, {whereabouts, Post}) of
        {ok, Board, Thread} when is_binary(Board), is_integer(Thread) -> {ok, Board, Thread};
        _ -> none
    end.

%% whether a board takes posts from nobody, if there is such a board;
%% the log takes none from anyone
-spec board(Name :: binary()) -> open | locked | log | none.
board(Name) ->
    case gen_server:call(?MODULE, {board, Name}) of
        open -> open;
        locked -> locked;
        log -> log;
        _ -> none
    end.

%% the boards that take posts, and whether only from accounts
-spec boards() -> [{Name :: binary(), Title :: binary(), Locked :: boolean()}].
boards() ->
    case gen_server:call(?MODULE, boards) of
        {ok, Rows} when is_list(Rows) ->
            [
                {Name, Title, Locked =:= 1}
             || [Name, Title, Locked] <- Rows, is_binary(Name), is_binary(Title)
            ];
        _ ->
            []
    end.

%% the accounts that may not log in, and their rank when they last did
-spec suspended() -> [{Account :: integer(), Name :: binary(), Rank :: 0..3}].
suspended() ->
    case gen_server:call(?MODULE, suspended) of
        {ok, Rows} when is_list(Rows) ->
            [
                {Id,
                    case Name of
                        _ when is_binary(Name) -> Name;
                        _ -> <<"(no name)">>
                    end,
                    Rank}
             || [Id, Name, Rank] <- Rows, is_integer(Id), is_integer(Rank), Rank >= 0, Rank =< 3
            ];
        _ ->
            []
    end.

%% a post as a moderator sees it: in whatever state, so long as it has
%% not been purged. nothing on the log is one
-spec post(Post :: integer()) -> {ok, ike_view:held()} | none.
post(Post) ->
    case gen_server:call(?MODULE, {post, Post}) of
        {
            {ok, [
                [
                    Thread,
                    Board,
                    State,
                    Time,
                    Body,
                    Name,
                    Local,
                    Banned,
                    Author,
                    Rank,
                    Undo,
                    Retracted
                ]
            ]},
            {ok, Images}
        } when
            is_list(Images),
            is_integer(Thread),
            is_binary(Board),
            is_integer(Time),
            is_binary(Body),
            is_integer(Author),
            is_integer(Rank),
            Rank >= 0,
            Rank =< 3
        ->
            {ok, #{
                id => Post,
                thread => Thread,
                board => Board,
                state =>
                    case State of
                        0 -> shown;
                        1 -> hidden;
                        _ -> trashed
                    end,
                time => Time,
                body => Body,
                name =>
                    case Name of
                        _ when is_binary(Name) -> Name;
                        _ -> none
                    end,
                account =>
                    case {Local, Banned} of
                        {1, 0} -> local;
                        {1, _} -> suspended;
                        _ -> none
                    end,
                author => Author,
                retracted => Retracted =:= 1,
                images => [
                    {Position,
                        case {Gone, Blocked} of
                            {1, _} -> gone;
                            {_, 1} -> blocked;
                            _ -> shown
                        end}
                 || [Position, Gone, Blocked] <- Images, is_integer(Position), Position >= 0
                ],
                rank => Rank,
                undo => ike_role:rank_of(Undo)
            }};
        _ ->
            none
    end.

%% entries with every name in Must, none in Not, and for each prefix a
%% name that starts with it; newest first, at most a hundred
-spec search({[binary()], [binary()], [binary()]}) ->
    [
        {
            pos_integer(),
            binary() | undefined,
            binary() | undefined,
            integer() | undefined,
            integer() | undefined
        }
    ].
search(Query) ->
    case gen_server:call(?MODULE, {search, Query}) of
        {ok, Rows} when is_list(Rows) ->
            [
                {Id, Hash, Type, W, H}
             || [Id, Hash, Type, W, H] <- Rows,
                is_integer(Id),
                Id > 0,
                is_binary(Hash) orelse Hash =:= undefined,
                is_binary(Type) orelse Type =:= undefined,
                is_integer(W) orelse W =:= undefined,
                is_integer(H) orelse H =:= undefined
            ];
        _ ->
            []
    end.

%% the metas a viewer may see, newest first: public ones, their own, and
%% to a moderator every one
-spec metas(viewer()) -> [meta()].
metas(Viewer) ->
    case gen_server:call(?MODULE, {metas, who(Viewer), none}) of
        {ok, Rows} when is_list(Rows) -> metas_of(Rows);
        _ -> []
    end.

%% one meta, if the viewer may see it, and the shown posts that show it
-spec meta(Id :: pos_integer(), viewer()) -> {ok, meta(), [pos_integer()]} | none.
meta(Id, Viewer) when is_integer(Id), Id > 0 ->
    case gen_server:call(?MODULE, {metas, who(Viewer), {id, Id}}) of
        {ok, [_] = Rows} ->
            case metas_of(Rows) of
                [#{hash := Hash} = M] ->
                    case gen_server:call(?MODULE, {tacks, Hash}) of
                        {ok, Posts} when is_list(Posts) ->
                            {ok, M, [P || [P] <- Posts, is_integer(P), P > 0]};
                        _ ->
                            none
                    end;
                _ ->
                    none
            end;
        _ ->
            none
    end;
meta(_, _) ->
    none.

%% the meta of these bytes a viewer may see, if any: their own first,
%% else the public one (another's private meta is never found here)
-spec known(Hash :: binary(), viewer()) -> {ok, meta()} | none.
known(Hash, Viewer) when byte_size(Hash) =:= 32 ->
    case gen_server:call(?MODULE, {metas, who(Viewer), {asset, Hash}}) of
        {ok, Rows} when is_list(Rows) ->
            case metas_of(Rows) of
                [#{mine := true} = M | _] -> {ok, M};
                Ms -> first_public(Ms)
            end;
        _ ->
            none
    end;
known(_, _) ->
    none.

-spec first_public([meta()]) -> {ok, meta()} | none.
first_public([#{private := false} = M | _]) -> {ok, M};
first_public([_ | Ms]) -> first_public(Ms);
first_public([]) -> none.

%% a meta's comments, in the order they came: its thread's posts that are
%% not taken down, whether or not the thread is shown to everyone (a
%% private meta's is not). who may read them is the asker's to have
%% checked, by the meta (invariant 10)
-spec comments(Thread :: pos_integer()) -> [ike_view:post()].
comments(Thread) ->
    case gen_server:call(?MODULE, {comments, Thread}) of
        {ok, Rows} when is_list(Rows) ->
            Names = ike_config:anonymous_names(),
            [
                #{
                    id => Id,
                    time => Time,
                    body => Body,
                    name =>
                        case Name of
                            _ when is_binary(Name) -> {account, Name};
                            _ -> {nobody, anonymous(Id, Names)}
                        end,
                    links => links(Body),
                    replies => [],
                    revision => Revision =:= 1
                }
             || [Id, Time, Body, Name, Revision] <- Rows,
                is_integer(Id),
                is_integer(Time),
                is_binary(Body)
            ];
        _ ->
            []
    end.

%% the trunk as a board an admin opens and shuts
-spec trunk() -> [{binary(), binary(), boolean()}].
trunk() ->
    case gen_server:call(?MODULE, trunk) of
        {ok, [[Title, Locked]]} when is_binary(Title) -> [{<<"trunk">>, Title, Locked =:= 1}];
        _ -> []
    end.

%% what an attached thread belongs to: a curation, or else a meta
-spec attached(term()) -> {booru, pos_integer()} | {meta, pos_integer()} | none.
attached(Thread) when is_integer(Thread), Thread > 0 ->
    case gen_server:call(?MODULE, {attached, Thread}) of
        {ok, [[E, _]]} when is_integer(E), E > 0 -> {booru, E};
        {ok, [[_, M]]} when is_integer(M), M > 0 -> {meta, M};
        _ -> none
    end;
attached(_) ->
    none.

-spec anonymous(integer(), [binary(), ...]) -> binary().
anonymous(Id, [First | _] = Names) ->
    case lists:nth(Id rem length(Names) + 1, Names) of
        Name when is_binary(Name) -> Name;
        _ -> First
    end.

%% a font's axes as the writer kept them, one a line
-spec axes(binary() | undefined) -> [{binary(), float(), float(), float()}].
axes(Axes) when is_binary(Axes) ->
    [
        {Tag, binary_to_float(A), binary_to_float(B), binary_to_float(C)}
     || Line <- binary:split(Axes, <<"\n">>, [global, trim_all]),
        [Tag, A, B, C] <- [binary:split(Line, <<" ">>, [global])],
        float_text(A),
        float_text(B),
        float_text(C)
    ];
axes(undefined) ->
    [].

-spec float_text(binary()) -> boolean().
float_text(Bin) ->
    try binary_to_float(Bin) of
        _ -> true
    catch
        _:_ -> false
    end.

%% a font's commentary as the writer kept it: kind, tab, escaped text
-spec commentary(binary() | undefined) -> [{binary(), binary()}].
commentary(Said) when is_binary(Said) ->
    [
        {Kind, ike_strip:unescaped(Text)}
     || Line <- binary:split(Said, <<"\n">>, [global, trim_all]),
        [Kind, Text] <- [binary:split(Line, <<"\t">>)]
    ];
commentary(undefined) ->
    [].

-spec who(viewer()) -> {integer(), 0 | 1}.
who(#{actor := Actor, moderator := Moderator}) ->
    {
        case Actor of
            A when is_integer(A) -> A;
            none -> -1
        end,
        case Moderator of
            true -> 1;
            false -> 0
        end
    }.

-spec metas_of([term()]) -> [meta()].
metas_of([
    [
        Id,
        Hash,
        Type,
        W,
        H,
        Traits,
        Time,
        Private,
        Mine,
        Upload,
        Name,
        State,
        Entry,
        Family,
        Axes,
        Said,
        Thread,
        Curation
    ]
    | Rows
]) when
    is_integer(Id),
    Id > 0,
    is_binary(Hash),
    is_binary(Type),
    is_integer(W),
    W >= 0,
    is_integer(H),
    H >= 0,
    is_binary(Traits),
    is_integer(Time),
    is_integer(Upload),
    Upload > 0,
    (is_binary(Name) orelse Name =:= undefined),
    (State =:= 0 orelse State =:= 1 orelse State =:= 2),
    (is_integer(Entry) orelse Entry =:= undefined),
    (is_binary(Family) orelse Family =:= undefined),
    (is_binary(Axes) orelse Axes =:= undefined),
    (is_binary(Said) orelse Said =:= undefined),
    (is_integer(Thread) orelse Thread =:= undefined),
    (is_integer(Curation) orelse Curation =:= undefined)
->
    [
        #{
            id => Id,
            hash => Hash,
            type => Type,
            width => W,
            height => H,
            traits => Traits,
            time => Time,
            private => Private =:= 1,
            mine => Mine =:= 1,
            upload => Upload,
            name =>
                case Name of
                    _ when is_binary(Name) -> Name;
                    undefined -> none
                end,
            state =>
                case State of
                    0 -> shown;
                    1 -> hidden;
                    2 -> trashed
                end,
            entry =>
                case Entry of
                    E when is_integer(E), E > 0 -> E;
                    _ -> none
                end,
            family =>
                case Family of
                    _ when is_binary(Family) -> Family;
                    undefined -> none
                end,
            axes => axes(Axes),
            commentary => commentary(Said),
            thread =>
                case Thread of
                    T when is_integer(T), T > 0 -> T;
                    _ -> none
                end,
            curation =>
                case Curation of
                    C when is_integer(C), C > 0 -> C;
                    _ -> none
                end
        }
        | metas_of(Rows)
    ];
metas_of([_ | Rows]) ->
    metas_of(Rows);
metas_of([]) ->
    [].

%% the shown posts an account signed, by its name, newest first
-spec signed(Name :: binary()) -> {ok, [{pos_integer(), binary(), integer(), binary()}]} | none.
signed(Name) ->
    case gen_server:call(?MODULE, {signed, Name}) of
        {ok, [_ | _] = Rows} ->
            {ok, [
                {Id, B, T, Body}
             || [Id, B, T, Body] <- Rows,
                is_integer(Id),
                Id > 0,
                is_binary(B),
                is_integer(T),
                is_binary(Body)
            ]};
        {ok, []} ->
            case gen_server:call(?MODULE, {named, Name}) of
                {ok, [_]} -> {ok, []};
                _ -> none
            end;
        _ ->
            none
    end.

%% a wiki page as it now reads: its thread, its newest shown revision
-spec page(Name :: binary()) ->
    {ok, #{thread := pos_integer(), revision := pos_integer(), time := integer(), body := binary()}}
    | none.
page(Name) ->
    case gen_server:call(?MODULE, {page, Name}) of
        {ok, [[Thread, Revision, Time, Body]]} when
            is_integer(Thread),
            Thread > 0,
            is_integer(Revision),
            Revision > 0,
            is_integer(Time),
            is_binary(Body)
        ->
            {ok, #{thread => Thread, revision => Revision, time => Time, body => Body}};
        _ ->
            none
    end.

%% a page's shown revisions, oldest first
-spec revisions(Name :: binary()) -> [{pos_integer(), integer(), binary()}].
revisions(Name) ->
    case gen_server:call(?MODULE, {revisions, Name}) of
        {ok, Rows} when is_list(Rows) ->
            [{Id, T, B} || [Id, T, B] <- Rows, is_integer(Id), Id > 0, is_integer(T), is_binary(B)];
        _ ->
            []
    end.

%% the pages there are to read, by name
-spec pages() -> [binary()].
pages() ->
    case gen_server:call(?MODULE, pages) of
        {ok, Rows} when is_list(Rows) -> [N || [N] <- Rows, is_binary(N)];
        _ -> []
    end.

%% for a text shown per request: which of its links lead somewhere, as
%% the renderer's map has them
-spec links(binary()) ->
    #{integer() | {booru, integer()} | {page, binary()} | {meta, integer()} => binary()}.
links(Body) ->
    Posts = ike_text:targets(Body),
    Entries = ike_text:entries(Body),
    Names = ike_text:pages(Body),
    Metas = ike_text:metas(Body),
    case gen_server:call(?MODULE, {links, Posts, Entries, Names, Metas}) of
        {ok, Map} when is_map(Map) -> maps:from_list(narrow(maps:to_list(Map)));
        _ -> #{}
    end.

%% an entry's state, for a moderator
-spec entry_state(Entry :: integer()) -> {ok, shown | hidden | trashed} | none.
entry_state(Entry) ->
    case gen_server:call(?MODULE, {entry_state, Entry}) of
        {ok, [[0]]} -> {ok, shown};
        {ok, [[1]]} -> {ok, hidden};
        {ok, [[2]]} -> {ok, trashed};
        _ -> none
    end.

%% reports not yet looked at, oldest first, with the board each is on
-spec reports() ->
    [{Id :: pos_integer(), Post :: pos_integer(), Board :: binary(), Reason :: binary()}].
reports() ->
    case gen_server:call(?MODULE, reports) of
        {ok, Rows} when is_list(Rows) ->
            [
                {Id, Post, Board, Reason}
             || [Id, Post, Board, Reason] <- Rows,
                is_integer(Id),
                Id > 0,
                is_integer(Post),
                Post > 0,
                is_binary(Board),
                is_binary(Reason)
            ];
        _ ->
            []
    end.

%% what a post keeps of its password, if it was given one
-spec password(Post :: integer()) -> {ok, binary()} | none.
password(Post) ->
    case gen_server:call(?MODULE, {password, Post}) of
        {ok, [[Sealed]]} when is_binary(Sealed) -> {ok, Sealed};
        _ -> none
    end.

%% posts taken out of sight and kept: hidden or trashed, newest first
-spec out_of_sight() -> [{Post :: pos_integer(), Board :: binary(), hidden | trashed}].
out_of_sight() ->
    case gen_server:call(?MODULE, out_of_sight) of
        {ok, Rows} when is_list(Rows) ->
            [
                {Id, Board,
                    case State of
                        1 -> hidden;
                        _ -> trashed
                    end}
             || [Id, Board, State] <- Rows, is_integer(Id), Id > 0, is_binary(Board)
            ];
        _ ->
            []
    end.

%% an account's uploads that went into posts, newest first, and where
-spec posted(Actor :: integer()) -> [{Upload :: pos_integer(), Post :: pos_integer()}].
posted(Actor) ->
    case gen_server:call(?MODULE, {posted, Actor}) of
        {ok, Rows} when is_list(Rows) ->
            [{U, P} || [U, P] <- Rows, is_integer(U), U > 0, is_integer(P), P > 0];
        _ ->
            []
    end.

%% an account's uploads that are not posted yet, newest first
-spec staged(Actor :: integer()) -> [staged()].
staged(Actor) ->
    case gen_server:call(?MODULE, {staged, Actor}) of
        {ok, Rows} when is_list(Rows) ->
            [
                #{id => Id, type => Type, width => W, height => H, time => Time}
             || [Id, Type, W, H, Time] <- Rows,
                is_integer(Id),
                Id > 0,
                is_binary(Type),
                is_integer(W),
                W >= 0,
                is_integer(H),
                H >= 0,
                is_integer(Time)
            ];
        _ ->
            []
    end.

%% the file behind a staged upload, by its asset's hash, and its type
-spec staged_file(Upload :: integer()) -> {ok, Hex :: binary(), Type :: binary()} | none.
staged_file(Upload) ->
    case gen_server:call(?MODULE, {staged_file, Upload}) of
        {ok, [[Hash, Type]]} when is_binary(Hash), byte_size(Hash) =:= 32, is_binary(Type) ->
            {ok, binary:encode_hex(Hash, lowercase), Type};
        _ ->
            none
    end.

-spec init([]) -> {ok, ike_db:reader()} | {stop, term()}.
init([]) ->
    case ike_db:open_reader(ike_config:db_path()) of
        {ok, Conn} -> {ok, Conn};
        {error, Reason} -> {stop, Reason}
    end.

-spec handle_call(term(), gen_server:from(), ike_db:reader()) ->
    {reply, term(), ike_db:reader()}.
handle_call({whereabouts, Post}, _From, Conn) when is_integer(Post) ->
    Sql = <<
        "SELECT b.name, p.thread FROM shown p"
        " JOIN thread t ON t.root = p.thread JOIN board b ON b.id = t.board"
        " WHERE p.id = ?1"
    >>,
    Reply =
        case ike_db:q(Conn, Sql, [Post]) of
            {ok, [[Board, Thread]]} -> {ok, Board, Thread};
            _ -> none
        end,
    {reply, Reply, Conn};
handle_call({board, Name}, _From, Conn) when is_binary(Name) ->
    Reply =
        case ike_db:q(Conn, <<"SELECT locked, log FROM board WHERE name = ?1">>, [Name]) of
            {ok, [[_, 1]]} -> log;
            {ok, [[0, _]]} -> open;
            {ok, [[1, _]]} -> locked;
            _ -> none
        end,
    {reply, Reply, Conn};
handle_call({staged, Actor}, _From, Conn) when is_integer(Actor) ->
    Sql = <<
        "SELECT u.id, a.filetype, coalesce(a.width, 0), coalesce(a.height, 0), u.time FROM upload u"
        " JOIN asset a ON a.hash = u.asset"
        " WHERE u.actor = ?1 AND u.posted IS NULL ORDER BY u.id DESC"
    >>,
    {reply, ike_db:q(Conn, Sql, [Actor]), Conn};
handle_call({search, {Must, Not, Prefixes}}, _From, Conn) when
    is_list(Must), is_list(Not), is_list(Prefixes)
->
    Has = <<
        " AND EXISTS (SELECT 1 FROM booru_tag bt JOIN tag t ON t.id = bt.tag"
        " WHERE bt.booru = e.id AND t.name = ?)"
    >>,
    Lacks = <<
        " AND NOT EXISTS (SELECT 1 FROM booru_tag bt JOIN tag t ON t.id = bt.tag"
        " WHERE bt.booru = e.id AND t.name = ?)"
    >>,
    Starts = <<
        " AND EXISTS (SELECT 1 FROM booru_tag bt JOIN tag_search s ON s.rowid = bt.tag"
        " WHERE bt.booru = e.id AND tag_search MATCH ?)"
    >>,
    Sql = iolist_to_binary([
        <<
            "SELECT e.id, x.hash, x.filetype, coalesce(x.width, 0), coalesce(x.height, 0) FROM shown_entry e"
            " LEFT JOIN asset x ON x.hash = e.asset WHERE 1"
        >>,
        [Has || _ <- Must],
        [Lacks || _ <- Not],
        [Starts || _ <- Prefixes],
        <<" ORDER BY e.id DESC LIMIT 100">>
    ]),
    %% a name is from a closed set without quotes, so a quoted prefix is
    %% only ever itself
    Args = Must ++ Not ++ [<<"\"", P/binary, "\"*">> || P <- Prefixes, is_binary(P)],
    {reply, ike_db:q(Conn, Sql, Args), Conn};
handle_call({signed, Name}, _From, Conn) when is_binary(Name) ->
    Sql = <<
        "SELECT s.id, b.name, s.time, s.body FROM actor a JOIN shown s ON s.actor = a.id"
        " JOIN thread t ON t.root = s.thread JOIN board b ON b.id = t.board"
        " WHERE a.kind = 'local' AND a.name = ?1 AND b.log = 0 ORDER BY s.id DESC LIMIT 100"
    >>,
    {reply, ike_db:q(Conn, Sql, [Name]), Conn};
handle_call({named, Name}, _From, Conn) when is_binary(Name) ->
    {reply, ike_db:q(Conn, <<"SELECT 1 FROM actor WHERE kind = 'local' AND name = ?1">>, [Name]),
        Conn};
handle_call({page, Name}, _From, Conn) when is_binary(Name) ->
    Sql = <<
        "SELECT pg.thread, p.id, p.time, p.body FROM page pg JOIN shown s ON s.thread = pg.thread"
        " JOIN post p ON p.id = s.id WHERE pg.name = ?1 AND p.revision = 1"
        " ORDER BY p.id DESC LIMIT 1"
    >>,
    {reply, ike_db:q(Conn, Sql, [Name]), Conn};
handle_call({revisions, Name}, _From, Conn) when is_binary(Name) ->
    Sql = <<
        "SELECT p.id, p.time, p.body FROM page pg JOIN shown s ON s.thread = pg.thread"
        " JOIN post p ON p.id = s.id WHERE pg.name = ?1 AND p.revision = 1 ORDER BY p.id"
    >>,
    {reply, ike_db:q(Conn, Sql, [Name]), Conn};
handle_call(pages, _From, Conn) ->
    Sql = <<
        "SELECT pg.name FROM page pg WHERE EXISTS (SELECT 1 FROM shown s JOIN post p ON p.id = s.id"
        " WHERE s.thread = pg.thread AND p.revision = 1) ORDER BY pg.name"
    >>,
    {reply, ike_db:q(Conn, Sql, []), Conn};
handle_call({links, Posts, Entries, Names, Metas}, _From, Conn) when
    is_list(Posts), is_list(Entries), is_list(Names), is_list(Metas)
->
    Where = <<
        "SELECT b.name FROM shown p JOIN thread t ON t.root = p.thread"
        " JOIN board b ON b.id = t.board WHERE p.id = ?1"
    >>,
    Map = maps:from_list(
        [
            {P, B}
         || P <- Posts, {ok, [[B]]} <- [ike_db:q(Conn, Where, [P])], is_binary(B)
        ] ++
            [
                {{booru, E}, <<>>}
             || E <- Entries,
                {ok, [_]} <- [ike_db:q(Conn, <<"SELECT 1 FROM shown_entry WHERE id = ?1">>, [E])]
            ] ++
            [{{page, N}, kind_of_name(Conn, N)} || N <- Names] ++
            %% a meta, if everyone may see it
            [
                {{meta, M}, <<"meta">>}
             || M <- Metas,
                {ok, [_]} <- [
                    ike_db:q(
                        Conn,
                        <<"SELECT 1 FROM meta WHERE id = ?1 AND private = 0 AND state = 0">>,
                        [M]
                    )
                ]
            ]
    ),
    {reply, {ok, Map}, Conn};
handle_call({entry_state, Entry}, _From, Conn) when is_integer(Entry) ->
    {reply, ike_db:q(Conn, <<"SELECT state FROM booru WHERE id = ?1">>, [Entry]), Conn};
handle_call(reports, _From, Conn) ->
    Sql = <<
        "SELECT r.id, r.post, b.name, r.reason FROM report r JOIN post p ON p.id = r.post"
        " JOIN thread t ON t.root = p.thread JOIN board b ON b.id = t.board"
        " WHERE r.done = 0 ORDER BY r.id LIMIT 200"
    >>,
    {reply, ike_db:q(Conn, Sql, []), Conn};
handle_call({password, Post}, _From, Conn) when is_integer(Post) ->
    {reply, ike_db:q(Conn, <<"SELECT password FROM post WHERE id = ?1">>, [Post]), Conn};
handle_call(out_of_sight, _From, Conn) ->
    Sql = <<
        "SELECT p.id, b.name, p.state FROM post p JOIN thread t ON t.root = p.thread"
        " JOIN board b ON b.id = t.board WHERE p.state IN (1, 2) AND b.log = 0"
        " ORDER BY p.id DESC LIMIT 200"
    >>,
    {reply, ike_db:q(Conn, Sql, []), Conn};
handle_call({posted, Actor}, _From, Conn) when is_integer(Actor) ->
    Sql = <<
        "SELECT id, post FROM upload WHERE actor = ?1 AND post IS NOT NULL"
        " ORDER BY id DESC LIMIT 200"
    >>,
    {reply, ike_db:q(Conn, Sql, [Actor]), Conn};
handle_call({metas, {Actor, Moderator}, Which}, _From, Conn) when
    is_integer(Actor), is_integer(Moderator)
->
    Sql = <<
        "SELECT m.id, m.asset, x.filetype, coalesce(x.width, 0), coalesce(x.height, 0), x.traits, m.time, m.private,"
        " m.owner = ?1, coalesce((SELECT max(u.id) FROM upload u WHERE u.asset = m.asset"
        " AND u.actor = m.owner), (SELECT max(u.id) FROM upload u WHERE u.asset = m.asset)),"
        " CASE WHEN m.signed = 1 THEN a.name END, m.state,"
        " (SELECT min(e.id) FROM shown_entry e WHERE e.asset = m.asset),"
        " x.family, x.axes, (SELECT u.commentary FROM upload u WHERE u.asset = m.asset"
        " AND u.actor = m.owner ORDER BY u.id DESC LIMIT 1), m.thread,"
        " (SELECT e.id FROM booru b JOIN shown_entry e ON e.id = b.id WHERE b.meta = m.id)"
        " FROM meta m JOIN asset x ON x.hash = m.asset JOIN actor a ON a.id = m.owner"
        " WHERE ((m.state = 0 AND (m.private = 0 OR m.owner = ?1))"
        " OR (m.state = 2 AND m.owner = ?1) OR ?2 = 1)"
        " AND (?3 IS NULL OR m.id = ?3) AND (?4 IS NULL OR m.asset = ?4)"
        " ORDER BY m.time DESC, m.id DESC LIMIT 200"
    >>,
    {Id, Asset} =
        case Which of
            none -> {undefined, undefined};
            {id, I} when is_integer(I) -> {I, undefined};
            {asset, H} when is_binary(H) -> {undefined, {blob, H}}
        end,
    {reply, ike_db:q(Conn, Sql, [Actor, Moderator, Id, Asset]), Conn};
handle_call(trunk, _From, Conn) ->
    {reply, ike_db:q(Conn, <<"SELECT title, locked FROM board WHERE name = 'trunk'">>, []), Conn};
handle_call({attached, Thread}, _From, Conn) when is_integer(Thread) ->
    Sql = <<
        "SELECT (SELECT id FROM booru WHERE thread = ?1), (SELECT id FROM meta WHERE thread = ?1)"
    >>,
    {reply, ike_db:q(Conn, Sql, [Thread]), Conn};
handle_call({comments, Thread}, _From, Conn) when is_integer(Thread) ->
    Sql = <<
        "SELECT p.id, p.time, p.body, a.name, p.revision FROM post p"
        " JOIN actor a ON a.id = p.actor WHERE p.thread = ?1 AND p.state = 0 ORDER BY p.id"
    >>,
    {reply, ike_db:q(Conn, Sql, [Thread]), Conn};
handle_call({tacks, Hash}, _From, Conn) when is_binary(Hash) ->
    Sql = <<
        "SELECT DISTINCT pa.post FROM post_image pa JOIN shown s ON s.id = pa.post"
        " WHERE pa.asset = ?1 ORDER BY pa.post"
    >>,
    {reply, ike_db:q(Conn, Sql, [{blob, Hash}]), Conn};
handle_call({staged_file, Upload}, _From, Conn) when is_integer(Upload) ->
    %% any upload: a link names one only on a page that may show it
    Sql = <<
        "SELECT a.hash, a.filetype FROM upload u JOIN asset a ON a.hash = u.asset"
        " WHERE u.id = ?1"
    >>,
    {reply, ike_db:q(Conn, Sql, [Upload]), Conn};
handle_call(boards, _From, Conn) ->
    Sql = <<"SELECT name, title, locked FROM board WHERE log = 0 AND attached = 0 ORDER BY name">>,
    {reply, ike_db:q(Conn, Sql, []), Conn};
handle_call(suspended, _From, Conn) ->
    Sql = <<"SELECT id, name, rank FROM actor WHERE banned = 1 ORDER BY id">>,
    {reply, ike_db:q(Conn, Sql, []), Conn};
handle_call({post, Post}, _From, Conn) when is_integer(Post) ->
    Sql = <<
        "SELECT p.thread, b.name, p.state, p.time, p.body, a.name, t.kind = 'local', t.banned,"
        " t.id, t.rank, (SELECT role FROM action WHERE post = p.id"
        " AND kind IN ('hide', 'trash') ORDER BY entry DESC LIMIT 1), p.retracted"
        " FROM post p JOIN thread h ON h.root = p.thread JOIN board b ON b.id = h.board"
        " JOIN actor a ON a.id = p.actor"
        %% the account a ban would reach, as the writer finds it
        " JOIN actor t ON t.id = CASE WHEN a.kind = 'local' THEN p.actor ELSE coalesce("
        "(SELECT u.actor FROM upload u WHERE u.post = p.id ORDER BY u.id LIMIT 1), p.actor) END"
        " WHERE p.id = ?1 AND b.log = 0"
    >>,
    %% and its images: whether each is there, and blocked
    Images = <<
        "SELECT position, gone, EXISTS (SELECT 1 FROM blocklist WHERE hash = asset)"
        " FROM post_image WHERE post = ?1 ORDER BY position"
    >>,
    {reply, {ike_db:q(Conn, Sql, [Post]), ike_db:q(Conn, Images, [Post])}, Conn};
handle_call(_Request, _From, Conn) ->
    {reply, {error, bad_request}, Conn}.

-spec narrow([{term(), term()}]) ->
    [{integer() | {booru, integer()} | {page, binary()} | {meta, integer()}, binary()}].
narrow([{K, V} | Rest]) when is_integer(K), is_binary(V) -> [{K, V} | narrow(Rest)];
narrow([{{booru, E}, V} | Rest]) when is_integer(E), is_binary(V) ->
    [{{booru, E}, V} | narrow(Rest)];
narrow([{{page, N}, V} | Rest]) when is_binary(N), is_binary(V) -> [{{page, N}, V} | narrow(Rest)];
narrow([{{meta, M}, V} | Rest]) when is_integer(M), is_binary(V) -> [{{meta, M}, V} | narrow(Rest)];
narrow([_ | Rest]) ->
    narrow(Rest);
narrow([]) ->
    [].

%% what [[name]] leads to: a page, else a tag, else nothing
-spec kind_of_name(ike_db:reader(), term()) -> binary() | none.
kind_of_name(Conn, Name) ->
    Page = <<
        "SELECT 1 FROM page pg JOIN shown s ON s.thread = pg.thread JOIN post p ON p.id = s.id"
        " WHERE pg.name = ?1 AND p.revision = 1 LIMIT 1"
    >>,
    case ike_db:q(Conn, Page, [Name]) of
        {ok, [_]} ->
            <<"page">>;
        _ ->
            case ike_db:q(Conn, <<"SELECT 1 FROM tag WHERE name = ?1">>, [Name]) of
                {ok, [_]} -> <<"tag">>;
                _ -> none
            end
    end.

-spec handle_cast(term(), ike_db:reader()) -> {noreply, ike_db:reader()}.
handle_cast(_Request, Conn) ->
    {noreply, Conn}.

-spec terminate(term(), ike_db:reader()) -> ok.
terminate(_Reason, Conn) ->
    _ = ike_db:close(Conn),
    ok.
