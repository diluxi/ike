%% The single writer (invariant 3): the one process that holds a writable
%% connection. Whatever changes the database is a message to it, and one
%% transaction. It also brings the schema up to date, before it answers
%% anything.
-module(ike_writer).
-behaviour(gen_server).

-export([start_link/0, local_actor/2, post/1, snapshot/0]).
-export([open_session/4, close_session/1, expire_sessions/1]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).
-export_type([new_post/0]).

-type new_post() :: #{
    actor := ike_id:actor(),
    %% a reply's thread, or the board an op starts one on
    thread := {new, Board :: binary()} | ike_id:post(),
    body := binary()
}.

-type error() :: {error, term()}.

%% long enough for a write queued behind a few others; a caller that gives
%% up does not undo what was committed
-define(CALL_TIMEOUT, 15000).
-define(SNAPSHOT_TIMEOUT, 120000).
%% bytes
-define(MAX_BODY, 16384).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% the actor of an account, made on its first login
-spec local_actor(Issuer :: binary(), Subject :: binary()) ->
    {ok, ike_id:actor()} | error().
local_actor(Issuer, Subject) ->
    case call({local_actor, Issuer, Subject}) of
        {ok, Id} when is_integer(Id), Id > 0 -> {ok, ike_id:actor(Id)};
        Other -> failed(Other)
    end.

-spec post(new_post()) ->
    {ok, ike_id:post()} | {error, bad_text | no_such_thread | no_such_board} | error().
post(#{actor := Actor, thread := Thread, body := Body}) ->
    Home =
        case Thread of
            {new, Board} -> {new, Board};
            _ -> ike_id:to_integer(Thread)
        end,
    case call({post, ike_id:to_integer(Actor), Home, Body}) of
        {ok, Id} when is_integer(Id), Id > 0 -> {ok, ike_id:post(Id)};
        Other -> failed(Other)
    end.

%% a session is a row, so that it outlives a restart. Hash is the sha-256
%% of what the cookie holds, Expires in unix seconds
-spec open_session(Hash :: binary(), ike_id:actor(), Csrf :: binary(), Expires :: integer()) ->
    ok | error().
open_session(Hash, Actor, Csrf, Expires) ->
    done(call({open_session, Hash, ike_id:to_integer(Actor), Csrf, Expires})).

-spec close_session(Hash :: binary()) -> ok | error().
close_session(Hash) ->
    done(call({close_session, Hash})).

%% forgets every session that ended at Now or before
-spec expire_sessions(Now :: integer()) -> ok | error().
expire_sessions(Now) ->
    done(call({expire_sessions, Now})).

-spec done(term()) -> ok | error().
done(ok) -> ok;
done(Other) -> failed(Other).

%% a snapshot of the database among the backups, and the oldest ones
%% beyond what is kept unlinked: both here, since nobody else deletes
-spec snapshot() -> {ok, Path :: binary()} | error().
snapshot() ->
    case gen_server:call(?MODULE, snapshot, ?SNAPSHOT_TIMEOUT) of
        {ok, Path} when is_binary(Path) -> {ok, Path};
        Other -> failed(Other)
    end.

-spec call(term()) -> term().
call(Request) ->
    gen_server:call(?MODULE, Request, ?CALL_TIMEOUT).

-spec failed(term()) -> error().
failed({error, Reason}) -> {error, Reason};
failed(Other) -> {error, {unexpected, Other}}.

%% gen_server

-spec init([]) -> {ok, ike_db:writer()} | {stop, term()}.
init([]) ->
    process_flag(trap_exit, true),
    Dir = ike_config:data_dir(),
    case filelib:ensure_path(Dir) of
        ok ->
            case ike_db:open_writer(ike_config:db_path()) of
                {ok, Conn} ->
                    case migrated(Conn) of
                        ok ->
                            {ok, Conn};
                        {error, Reason} ->
                            _ = ike_db:close(Conn),
                            {stop, Reason}
                    end;
                {error, Reason} ->
                    {stop, Reason}
            end;
        {error, Reason} ->
            {stop, {data_dir, Reason}}
    end.

-spec migrated(ike_db:writer()) -> ok | error().
migrated(Conn) ->
    case ike_migrate:run(Conn) of
        ok -> settled(ike_db:transaction(Conn, fun() -> boards(Conn, ike_config:boards()) end));
        {error, _} = Error -> Error
    end.

%% the configured boards exist, under the titles given
-spec boards(ike_db:writer(), [{binary(), binary()}]) -> ok | error().
boards(Conn, [{Name, Title} | Boards]) ->
    Upsert = <<
        "INSERT INTO board (name, title) VALUES (?1, ?2)"
        " ON CONFLICT (name) DO UPDATE SET title = excluded.title"
    >>,
    case ike_db:q(Conn, Upsert, [Name, Title]) of
        {ok, _} -> boards(Conn, Boards);
        {error, _} = Error -> Error
    end;
boards(_Conn, []) ->
    ok.

-spec handle_call(term(), gen_server:from(), ike_db:writer()) ->
    {reply, term(), ike_db:writer()}.
handle_call({local_actor, Issuer, Subject}, _From, Conn) when
    is_binary(Issuer), is_binary(Subject)
->
    Reply = ike_db:transaction(Conn, fun() ->
        local_actor(Conn, Issuer, Subject)
    end),
    {reply, Reply, Conn};
handle_call({post, Actor, Home, Body}, _From, Conn) when
    is_integer(Actor), is_binary(Body)
->
    Reply =
        case text(Body) of
            true ->
                Time = erlang:system_time(second),
                committed(
                    ike_db:transaction(Conn, fun() ->
                        post(Conn, Actor, Home, Time, Body)
                    end)
                );
            false ->
                {error, bad_text}
        end,
    {reply, Reply, Conn};
handle_call({open_session, Hash, Actor, Csrf, Expires}, _From, Conn) when
    is_binary(Hash), is_integer(Actor), is_binary(Csrf), is_integer(Expires)
->
    Insert = <<"INSERT INTO session (hash, actor, csrf, expires) VALUES (?1, ?2, ?3, ?4)">>,
    {reply, change(Conn, Insert, [{blob, Hash}, Actor, Csrf, Expires]), Conn};
handle_call({close_session, Hash}, _From, Conn) when is_binary(Hash) ->
    {reply, change(Conn, <<"DELETE FROM session WHERE hash = ?1">>, [{blob, Hash}]), Conn};
handle_call({expire_sessions, Now}, _From, Conn) when is_integer(Now) ->
    {reply, change(Conn, <<"DELETE FROM session WHERE expires <= ?1">>, [Now]), Conn};
handle_call(snapshot, _From, Conn) ->
    {reply, snapshot(Conn), Conn};
handle_call(_Request, _From, Conn) ->
    {reply, {error, bad_request}, Conn}.

-spec handle_cast(term(), ike_db:writer()) -> {noreply, ike_db:writer()}.
handle_cast(_Request, Conn) ->
    {noreply, Conn}.

-spec terminate(term(), ike_db:writer()) -> ok.
terminate(_Reason, Conn) ->
    _ = ike_db:close(Conn),
    ok.

%% one statement as one transaction
-spec change(ike_db:writer(), binary(), [term()]) -> ok | error().
change(Conn, Sql, Args) ->
    settled(
        ike_db:transaction(Conn, fun() ->
            case ike_db:q(Conn, Sql, Args) of
                {ok, _} -> ok;
                {error, _} = Error -> Error
            end
        end)
    ).

%% of a transaction that had nothing to say but whether it went through
-spec settled(term()) -> ok | error().
settled({error, _} = Error) -> Error;
settled(_) -> ok.

%% the renderer follows each commit, never a transaction still open
-spec committed(Result) -> Result when Result :: {ok, {integer(), integer()}} | term().
committed({ok, {Id, Thread}}) when is_integer(Id), is_integer(Thread) ->
    ike_render:dirty(Thread),
    {ok, Id};
committed(Other) ->
    Other.

%% written under another name and renamed, so that whatever is among the
%% backups under a snapshot's name is a whole one
-spec snapshot(ike_db:writer()) -> {ok, binary()} | error().
snapshot(Conn) ->
    Dir = ike_config:backup_dir(),
    Name = ike_backup:name(erlang:system_time(second)),
    Path = <<Dir/binary, "/", Name/binary>>,
    Tmp = <<Path/binary, ".tmp">>,
    case filelib:ensure_path(Dir) of
        ok ->
            _ = file:delete(Tmp),
            case ike_db:snapshot(Conn, Tmp) of
                ok ->
                    case file:rename(Tmp, Path) of
                        ok ->
                            prune(Dir, ike_config:backup_keep()),
                            {ok, Path};
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    _ = file:delete(Tmp),
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec prune(binary(), pos_integer()) -> ok.
prune(Dir, Keep) ->
    Names = ike_backup:list(Dir),
    case length(Names) - Keep of
        Extra when Extra > 0 ->
            [Oldest | _] = Names,
            _ = file:delete(<<Dir/binary, "/", Oldest/binary>>),
            prune(Dir, Keep);
        _ ->
            ok
    end.

%% inside a transaction

-spec local_actor(ike_db:writer(), binary(), binary()) ->
    {ok, integer()} | error().
local_actor(Conn, Issuer, Subject) ->
    Insert = <<
        "INSERT INTO actor (kind, issuer, subject) VALUES ('local', ?1, ?2)"
        " ON CONFLICT DO NOTHING"
    >>,
    Select = <<
        "SELECT id FROM actor"
        " WHERE kind = 'local' AND issuer = ?1 AND subject = ?2"
    >>,
    case ike_db:q(Conn, Insert, [Issuer, Subject]) of
        {ok, _} ->
            case ike_db:q(Conn, Select, [Issuer, Subject]) of
                {ok, [[Id]]} when is_integer(Id) -> {ok, Id};
                {ok, Rows} -> {error, {unexpected, Rows}};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec post(ike_db:writer(), integer(), term(), integer(), binary()) ->
    {ok, {Id :: integer(), Thread :: integer()}} | error().
post(Conn, Actor, {new, Name}, Time, Body) when is_binary(Name) ->
    %% an op's home thread is its own number, which autoincrement will hand
    %% out next; nobody else can take it, since nobody else writes
    Next = <<
        "SELECT coalesce((SELECT seq FROM sqlite_sequence"
        " WHERE name = 'post'), 0) + 1,"
        " (SELECT id FROM board WHERE name = ?1)"
    >>,
    case ike_db:q(Conn, Next, [Name]) of
        {ok, [[Id, Board]]} when is_integer(Id), is_integer(Board) ->
            Thread = <<"INSERT INTO thread (root, board) VALUES (?1, ?2)">>,
            case ike_db:q(Conn, Thread, [Id, Board]) of
                {ok, _} -> insert(Conn, Actor, Id, Time, Body);
                {error, _} = Error -> Error
            end;
        {ok, [[_, _]]} ->
            {error, no_such_board};
        {ok, Rows} ->
            {error, {unexpected, Rows}};
        {error, _} = Error ->
            Error
    end;
post(Conn, Actor, Home, Time, Body) when is_integer(Home) ->
    case ike_db:q(Conn, <<"SELECT 1 FROM thread WHERE root = ?1">>, [Home]) of
        {ok, [_]} -> insert(Conn, Actor, Home, Time, Body);
        {ok, []} -> {error, no_such_thread};
        {error, _} = Error -> Error
    end;
post(_Conn, _Actor, _Home, _Time, _Body) ->
    {error, bad_request}.

-spec insert(ike_db:writer(), integer(), integer(), integer(), binary()) ->
    {ok, {Id :: integer(), Thread :: integer()}} | error().
insert(Conn, Actor, Home, Time, Body) ->
    Insert = <<
        "INSERT INTO post (thread, actor, time, body)"
        " VALUES (?1, ?2, ?3, ?4) RETURNING id"
    >>,
    case ike_db:q(Conn, Insert, [Home, Actor, Time, Body]) of
        {ok, [[Id]]} when is_integer(Id) -> {ok, {Id, Home}};
        {ok, Rows} -> {error, {unexpected, Rows}};
        {error, _} = Error -> Error
    end.

%% what a post may hold: utf-8, not empty, not huge, and no control
%% characters but newline and tab
-spec text(binary()) -> boolean().
text(Body) when byte_size(Body) =:= 0; byte_size(Body) > ?MAX_BODY ->
    false;
text(Body) ->
    printable(Body).

-spec printable(binary()) -> boolean().
printable(<<>>) -> true;
printable(<<$\n, Rest/binary>>) -> printable(Rest);
printable(<<$\t, Rest/binary>>) -> printable(Rest);
printable(<<C/utf8, Rest/binary>>) when C >= 16#20, C =/= 16#7F -> printable(Rest);
printable(_) -> false.
