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
    %% threads whose page is out of date, each once
    threads = [] :: [integer()],
    index = false :: boolean()
}).

%% threads on the index; there are no boards to page through yet
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
    case filelib:ensure_path(<<Dir/binary, "/t">>) of
        ok ->
            case ike_db:open_reader(ike_config:db_path()) of
                {ok, Conn} ->
                    case all_threads(Conn) of
                        {ok, Threads} ->
                            self() ! render,
                            {ok, #state{
                                conn = Conn,
                                dir = Dir,
                                threads = Threads,
                                index = true
                            }};
                        {error, Reason} ->
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
    {noreply, State#state{
        threads = ordsets:add_element(Thread, Threads), index = true
    }};
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
drain(#state{threads = [], index = false} = State) -> State;
drain(State) -> drain(step(State)).

-spec step(#state{}) -> #state{}.
step(#state{threads = [Thread | Threads]} = State) ->
    ok = render_thread(State, Thread),
    self() ! render,
    State#state{threads = Threads};
step(#state{threads = [], index = true} = State) ->
    ok = render_index(State),
    State#state{index = false};
step(State) ->
    State.

-spec all_threads(ike_db:reader()) -> {ok, [integer()]} | ike_db:error().
all_threads(Conn) ->
    case ike_db:q(Conn, <<"SELECT root FROM thread ORDER BY root">>, []) of
        {ok, Rows} -> {ok, [Root || [Root] <- Rows, is_integer(Root)]};
        {error, _} = Error -> Error
    end.

-spec render_thread(#state{}, integer()) -> ok.
render_thread(#state{conn = Conn, dir = Dir}, Thread) ->
    Sql = <<"SELECT id, time, body FROM post WHERE thread = ?1 ORDER BY id">>,
    case ike_db:q(Conn, Sql, [Thread]) of
        {ok, Rows} ->
            Posts = [
                #{id => Id, time => Time, body => Body}
             || [Id, Time, Body] <- Rows,
                is_integer(Id),
                is_integer(Time),
                is_binary(Body)
            ],
            Name = <<"t/", (integer_to_binary(Thread))/binary, ".html">>,
            write(Dir, Name, ike_view:thread(Thread, Posts));
        {error, Reason} ->
            error({render, Thread, Reason})
    end.

-spec render_index(#state{}) -> ok.
render_index(#state{conn = Conn, dir = Dir}) ->
    %% most recently posted in first
    Sql = <<
        "SELECT p.thread, count(*), max(p.id),"
        " (SELECT body FROM post WHERE id = p.thread)"
        " FROM post p GROUP BY p.thread ORDER BY 3 DESC LIMIT ?1"
    >>,
    case ike_db:q(Conn, Sql, [?INDEX]) of
        {ok, Rows} ->
            Threads = [
                #{root => Root, posts => Posts, body => Body}
             || [Root, Posts, _Last, Body] <- Rows,
                is_integer(Root),
                is_integer(Posts),
                is_binary(Body)
            ],
            write(Dir, <<"index.html">>, ike_view:index(Threads));
        {error, Reason} ->
            error({render, index, Reason})
    end.

%% a reader of the page sees the old file or the new one, never part of
%% either
-spec write(binary(), binary(), ike_html:html()) -> ok.
write(Dir, Name, Html) ->
    Path = <<Dir/binary, "/", Name/binary>>,
    Tmp = <<Path/binary, ".tmp">>,
    case file:write_file(Tmp, ike_html:to_iodata(Html)) of
        ok ->
            case file:rename(Tmp, Path) of
                ok -> ok;
                {error, Reason} -> error({page, Name, Reason})
            end;
        {error, Reason} ->
            error({page, Name, Reason})
    end.
