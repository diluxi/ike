%% What a request may ask the database: one connection that cannot
%% write, behind one process. The pages are files and need none of this;
%% it is for the few answers that are made per request.
-module(ike_reader).
-behaviour(gen_server).

-export([start_link/0, whereabouts/1, board/1, boards/0, suspended/0, post/1]).
-export([staged/1, staged_file/1, posted/1]).
-export_type([staged/0]).

%% a staged upload as its uploader is shown it
-type staged() :: #{
    id := pos_integer(),
    type := binary(),
    width := pos_integer(),
    height := pos_integer(),
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
            {ok, [[Thread, Board, State, Time, Body, Name, Local, Banned, Author, Rank, Undo]]},
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
                        _ -> deleted
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
                W > 0,
                is_integer(H),
                H > 0,
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
        "SELECT u.id, a.type, a.width, a.height, u.time FROM upload u"
        " JOIN asset a ON a.hash = u.asset"
        " WHERE u.actor = ?1 AND u.posted IS NULL ORDER BY u.id DESC"
    >>,
    {reply, ike_db:q(Conn, Sql, [Actor]), Conn};
handle_call({posted, Actor}, _From, Conn) when is_integer(Actor) ->
    Sql = <<
        "SELECT id, post FROM upload WHERE actor = ?1 AND post IS NOT NULL"
        " ORDER BY id DESC LIMIT 200"
    >>,
    {reply, ike_db:q(Conn, Sql, [Actor]), Conn};
handle_call({staged_file, Upload}, _From, Conn) when is_integer(Upload) ->
    Sql = <<
        "SELECT a.hash, a.type FROM upload u JOIN asset a ON a.hash = u.asset"
        " WHERE u.id = ?1 AND u.posted IS NULL"
    >>,
    {reply, ike_db:q(Conn, Sql, [Upload]), Conn};
handle_call(boards, _From, Conn) ->
    Sql = <<"SELECT name, title, locked FROM board WHERE log = 0 ORDER BY name">>,
    {reply, ike_db:q(Conn, Sql, []), Conn};
handle_call(suspended, _From, Conn) ->
    Sql = <<"SELECT id, name, rank FROM actor WHERE banned = 1 ORDER BY id">>,
    {reply, ike_db:q(Conn, Sql, []), Conn};
handle_call({post, Post}, _From, Conn) when is_integer(Post) ->
    Sql = <<
        "SELECT p.thread, b.name, p.state, p.time, p.body, a.name, t.kind = 'local', t.banned,"
        " t.id, t.rank, (SELECT role FROM action WHERE post = p.id"
        " AND kind IN ('hide', 'delete') ORDER BY entry DESC LIMIT 1)"
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

-spec handle_cast(term(), ike_db:reader()) -> {noreply, ike_db:reader()}.
handle_cast(_Request, Conn) ->
    {noreply, Conn}.

-spec terminate(term(), ike_db:reader()) -> ok.
terminate(_Reason, Conn) ->
    _ = ike_db:close(Conn),
    ok.
