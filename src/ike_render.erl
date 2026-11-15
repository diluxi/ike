%% The static renderer: pages are files, rebuilt from the database after
%% each commit, and all of them at start, so the tree can be thrown away.
%% A page is written beside its place and renamed into it (hazard d2).
-module(ike_render).
-behaviour(gen_server).

-export([start_link/0, dirty/1, sync/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    conn :: ike_db:reader(),
    dir :: binary(),
    %% what is out of date, each once: threads by root, boards by name,
    %% and the pages that list boards
    threads = [] :: [integer()],
    boards = [] :: [binary()],
    lists = false :: boolean()
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
    case filelib:ensure_path(<<Dir/binary, "/board">>) of
        ok ->
            case ike_db:open_reader(ike_config:db_path()) of
                {ok, Conn} ->
                    case everything(Conn) of
                        {ok, Threads, Boards} ->
                            self() ! render,
                            {ok, #state{
                                conn = Conn,
                                dir = Dir,
                                threads = Threads,
                                boards = Boards,
                                lists = true
                            }};
                        {error, Reason} ->
                            _ = ike_db:close(Conn),
                            {stop, Reason}
                    end;
                {error, Reason} ->
                    {stop, Reason}
            end;
        {error, Reason} ->
            {stop, {pages_dir, Reason}}
    end.

-spec handle_call(term(), gen_server:from(), #state{}) ->
    {reply, term(), #state{}}.
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
drain(#state{threads = [], boards = [], lists = false} = State) -> State;
drain(State) -> drain(step(State)).

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
step(#state{threads = [], boards = [Board | Boards]} = State) ->
    ok = render_board(State, Board),
    self() ! render,
    State#state{boards = Boards};
step(#state{threads = [], boards = [], lists = true} = State) ->
    ok = render_lists(State),
    State#state{lists = false};
step(State) ->
    State.

-spec everything(ike_db:reader()) -> {ok, [integer()], [binary()]} | ike_db:error().
everything(Conn) ->
    case ike_db:q(Conn, <<"SELECT root FROM thread ORDER BY root">>, []) of
        {ok, Threads} ->
            case ike_db:q(Conn, <<"SELECT name FROM board ORDER BY name">>, []) of
                {ok, Boards} ->
                    {ok, [Root || [Root] <- Threads, is_integer(Root)], [
                        Name
                     || [Name] <- Boards, is_binary(Name)
                    ]};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%% a thread that is on no board has no page yet
-spec render_thread(#state{}, integer()) -> {ok, Board :: binary()} | none.
render_thread(#state{conn = Conn, dir = Dir}, Thread) ->
    Where = <<
        "SELECT b.name, b.title FROM thread t JOIN board b ON b.id = t.board"
        " WHERE t.root = ?1"
    >>,
    Sql = <<"SELECT id, time, body FROM post WHERE thread = ?1 ORDER BY id">>,
    case ike_db:q(Conn, Where, [Thread]) of
        {ok, [[Name, Title]]} when is_binary(Name), is_binary(Title) ->
            case ike_db:q(Conn, Sql, [Thread]) of
                {ok, Rows} ->
                    Posts = [
                        #{id => Id, time => Time, body => Body}
                     || [Id, Time, Body] <- Rows,
                        is_integer(Id),
                        is_integer(Time),
                        is_binary(Body)
                    ],
                    Board = #{name => Name, title => Title},
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

-spec render_board(#state{}, binary()) -> ok.
render_board(#state{conn = Conn, dir = Dir}, Name) ->
    %% most recently posted in first
    Sql = <<
        "SELECT p.thread, count(*), max(p.id),"
        " (SELECT body FROM post WHERE id = p.thread)"
        " FROM post p JOIN thread t ON t.root = p.thread"
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

%% the list of boards, and the page in front of everything
-spec render_lists(#state{}) -> ok.
render_lists(#state{conn = Conn, dir = Dir}) ->
    case boards(Conn, <<>>, []) of
        {ok, Boards} ->
            ok = write(Dir, <<"board.html">>, ike_view:boards(Boards)),
            write(Dir, <<"index.html">>, ike_view:index());
        {error, Reason} ->
            error({render, lists, Reason})
    end.

-spec boards(ike_db:reader(), binary(), [term()]) -> {ok, [ike_view:board()]} | ike_db:error().
boards(Conn, Where, Args) ->
    Sql = <<"SELECT name, title FROM board", Where/binary, " ORDER BY name">>,
    case ike_db:q(Conn, Sql, Args) of
        {ok, Rows} ->
            {ok, [
                #{name => Name, title => Title}
             || [Name, Title] <- Rows, is_binary(Name), is_binary(Title)
            ]};
        {error, _} = Error ->
            Error
    end.

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
