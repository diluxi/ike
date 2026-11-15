%% The single writer (invariant 3): the one process that holds a writable
%% connection. Whatever changes the database is a message to it, and one
%% transaction. It also brings the schema up to date, before it answers
%% anything.
-module(ike_writer).
-behaviour(gen_server).

-export([start_link/0, local_actor/3, post/1, moderate/1, snapshot/0]).
-export([open_session/5, close_session/1, expire_sessions/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export_type([new_post/0, action/0]).

-type new_post() :: #{
    actor := ike_id:actor(),
    %% a reply's thread, or the board an op starts one on
    thread := {new, Board :: binary()} | ike_id:post(),
    body := binary()
}.

%% what a moderator does, and to what: a post by its number, an account
%% by a post it signed or by its own number, a board by its name
-type action() :: #{
    by := ike_id:actor(),
    role := ike_role:role(),
    kind := ike_role:kind(),
    target := ike_id:post() | ike_id:actor() | binary(),
    reason := binary()
}.

-type error() :: {error, term()}.

%% who acts: an account in a role, or ike itself
-type who() :: {Actor :: integer(), ike_role:role()} | system.
%% what follows a commit, outside the database
-type effects() :: #{
    threads := [term()],
    gone := [{Board :: binary(), Root :: integer()}],
    boards := [binary()],
    drop := [integer()],
    scrub := boolean()
}.

%% long enough for a write queued behind a few others; a caller that gives
%% up does not undo what was committed
-define(CALL_TIMEOUT, 15000).
-define(SNAPSHOT_TIMEOUT, 120000).
%% bytes
-define(MAX_BODY, 16384).
-define(MAX_REASON, 1000).
%% the one actor shared by everyone who is nobody; the log is written
%% as it, and the row beside each entry says who it was
-define(NOBODY, 1).
-define(LOG, <<"mod">>).
%% how often held posts are looked at, at most; milliseconds
-define(HOLD_TICK, 60000).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% the actor of an account, made on its first login, and called what the
%% provider calls it now
-spec local_actor(Issuer :: binary(), Subject :: binary(), Nick :: binary() | none) ->
    {ok, ike_id:actor()} | error().
local_actor(Issuer, Subject, Nick) ->
    case call({local_actor, Issuer, Subject, Nick}) of
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

%% one rung of the ladder, and its entry in the log, or neither
-spec moderate(action()) ->
    ok
    | {error, not_allowed | bad_text | no_such_post | no_such_account | no_such_board | not_now}
    | error().
moderate(#{by := By, role := Role, kind := Kind, target := Target, reason := Reason}) ->
    Subject =
        case Target of
            _ when is_binary(Target) -> Target;
            _ -> ike_id:to_integer(Target)
        end,
    done(
        call(
            {moderate, ike_id:to_integer(By), ike_role:to_binary(Role), ike_role:to_binary(Kind),
                Subject, Reason}
        )
    ).

%% a session is a row, so that it outlives a restart. Hash is the sha-256
%% of what the cookie holds, Expires in unix seconds
-spec open_session(
    Hash :: binary(),
    ike_id:actor(),
    Csrf :: binary(),
    Expires :: integer(),
    Role :: binary() | undefined
) ->
    ok | error().
open_session(Hash, Actor, Csrf, Expires, Role) ->
    done(call({open_session, Hash, ike_id:to_integer(Actor), Csrf, Expires, Role})).

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
                            ok = swept(Conn),
                            _ = erlang:send_after(tick(), self(), held),
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
handle_call({local_actor, Issuer, Subject, Nick}, _From, Conn) when
    is_binary(Issuer), is_binary(Subject), is_binary(Nick) orelse Nick =:= none
->
    Reply =
        case
            ike_db:transaction(Conn, fun() ->
                local_actor(Conn, Issuer, Subject, Nick)
            end)
        of
            {ok, {Id, Threads}} when is_integer(Id), is_list(Threads) ->
                %% a new name is on every page that showed the old one
                [ike_render:dirty(Thread) || Thread <- Threads, is_integer(Thread)],
                {ok, Id};
            Other ->
                Other
        end,
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
                        case open(Conn, Home) of
                            ok -> post(Conn, Actor, Home, Time, Body);
                            {error, _} = Error -> Error
                        end
                    end)
                );
            false ->
                {error, bad_text}
        end,
    {reply, Reply, Conn};
handle_call({moderate, By, Role, Kind, Target, Reason}, _From, Conn) when
    is_integer(By), is_binary(Kind), is_binary(Reason)
->
    Reply =
        case {ike_role:of_binary(Role), ike_role:kind(Kind)} of
            {none, _} -> {error, not_allowed};
            {_, error} -> {error, bad_request};
            {Held, {ok, Rung}} -> moderated(Conn, {By, Held}, Rung, Target, Reason)
        end,
    {reply, Reply, Conn};
handle_call({open_session, Hash, Actor, Csrf, Expires, Role}, _From, Conn) when
    is_binary(Hash),
    is_integer(Actor),
    is_binary(Csrf),
    is_integer(Expires),
    is_binary(Role) orelse Role =:= undefined
->
    %% an account suspended while it was logging in gets no session
    Insert = <<
        "INSERT INTO session (hash, actor, csrf, expires, role)"
        " SELECT ?1, id, ?3, ?4, ?5 FROM actor WHERE id = ?2 AND banned = 0"
        " RETURNING actor"
    >>,
    Reply =
        case
            ike_db:transaction(Conn, fun() ->
                case ike_db:q(Conn, Insert, [{blob, Hash}, Actor, Csrf, Expires, Role]) of
                    {ok, [_]} -> ok;
                    {ok, _} -> {error, suspended};
                    {error, _} = Error -> Error
                end
            end)
        of
            ok -> ok;
            {error, _} = Error -> Error;
            Other -> {error, {unexpected, Other}}
        end,
    {reply, Reply, Conn};
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

%% a deleted post is held for a while and then purged, by nobody
-spec handle_info(term(), ike_db:writer()) -> {noreply, ike_db:writer()}.
handle_info(held, Conn) ->
    Due = <<"SELECT id FROM post WHERE state = 2 AND purge_at <= ?1 ORDER BY id LIMIT 20">>,
    case ike_db:q(Conn, Due, [erlang:system_time(second)]) of
        {ok, Rows} ->
            %% one that went with its thread a moment ago is no longer there
            [
                moderated(Conn, system, purge, Id, <<"its hold ended">>)
             || [Id] <- Rows, is_integer(Id)
            ];
        {error, _} ->
            ok
    end,
    %% what a purge overwrote is in the write-ahead log until the log
    %% is folded back, and a reader can hold that up: so again, here
    _ = ike_db:exec(Conn, <<"PRAGMA wal_checkpoint(TRUNCATE)">>),
    _ = erlang:send_after(tick(), self(), held),
    {noreply, Conn};
handle_info(_Info, Conn) ->
    {noreply, Conn}.

-spec tick() -> pos_integer().
tick() ->
    min(?HOLD_TICK, ike_config:hold_seconds() * 1000).

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
-spec committed(term()) -> term().
committed({ok, {Id, Threads}}) when is_integer(Id), is_list(Threads) ->
    [ike_render:dirty(Thread) || Thread <- Threads, is_integer(Thread)],
    {ok, Id};
committed(Other) ->
    Other.

-spec moderated(ike_db:writer(), who(), ike_role:kind(), term(), binary()) -> ok | error().
moderated(Conn, Who, Kind, Target, Reason) ->
    Role =
        case Who of
            system -> system;
            {_, Held} -> Held
        end,
    case {ike_role:may(Role, Kind), byte_size(Reason) =< ?MAX_REASON andalso text(Reason)} of
        {false, _} ->
            {error, not_allowed};
        {true, false} ->
            {error, bad_text};
        {true, true} ->
            Time = erlang:system_time(second),
            case
                ike_db:transaction(Conn, fun() ->
                    act(Conn, Who, Kind, Target, Reason, Time)
                end)
            of
                {ok, #{threads := T, gone := G, boards := B, drop := D, scrub := S}} when
                    is_list(T), is_list(G), is_list(B), is_list(D), is_boolean(S)
                ->
                    followed(Conn, T, G, B, D, S);
                {error, _} = Error ->
                    Error;
                Other ->
                    {error, {unexpected, Other}}
            end
    end.

%% after the commit. a page that is to go is taken from the renderer's
%% list first, so that nothing it read before the commit can land after
%% the unlink; whatever it renders from here on, it reads the new state
-spec followed(ike_db:writer(), [term()], [term()], [term()], [term()], boolean()) -> ok.
followed(Conn, Threads, Gone, Boards, Drop, Scrub) ->
    Pages = ike_config:pages_dir(),
    [
        begin
            _ =
                try
                    ike_render:settle(Root)
                catch
                    exit:_ -> ok
                end,
            file:delete(page(Pages, Board, integer_to_binary(Root)))
        end
     || {Board, Root} <- Gone, is_binary(Board), is_integer(Root)
    ],
    [ike_render:dirty(Thread) || Thread <- Threads, is_integer(Thread)],
    [ike_render:dirty_board(Board) || Board <- Boards, is_binary(Board)],
    [ike_session:drop(Actor) || Actor <- Drop, is_integer(Actor)],
    case Scrub of
        true -> _ = ike_db:exec(Conn, <<"PRAGMA wal_checkpoint(TRUNCATE)">>);
        false -> ok
    end,
    ok.

-spec page(binary(), binary(), binary()) -> binary().
page(Pages, Board, Root) ->
    <<Pages/binary, "/board/", Board/binary, "/", Root/binary, ".html">>.

%% at start: a thread's page that no shown thread stands behind is
%% unlinked. it is what a stop between a commit and its unlink leaves
-spec swept(ike_db:writer()) -> ok.
swept(Conn) ->
    Pages = ike_config:pages_dir(),
    Sql = <<
        "SELECT b.name, s.id FROM shown s JOIN thread t ON t.root = s.id"
        " JOIN board b ON b.id = t.board WHERE s.id = s.thread"
    >>,
    case ike_db:q(Conn, Sql, []) of
        {ok, Rows} ->
            Kept =
                #{
                    page(Pages, Board, integer_to_binary(Root)) => true
                 || [Board, Root] <- Rows, is_binary(Board), is_integer(Root)
                },
            Found = filelib:wildcard(binary_to_list(<<Pages/binary, "/board/*/*.html">>)),
            [
                file:delete(File)
             || File <- Found, not maps:is_key(unicode:characters_to_binary(File), Kept)
            ],
            ok;
        {error, _} ->
            ok
    end.

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

%% whether the place takes posts from outside: a board that is not the
%% log, or a thread on one that is there to be seen
-spec open(ike_db:writer(), term()) -> ok | error().
open(Conn, {new, Name}) when is_binary(Name) ->
    case ike_db:q(Conn, <<"SELECT 1 FROM board WHERE name = ?1 AND log = 0">>, [Name]) of
        {ok, [_]} -> ok;
        {ok, []} -> {error, no_such_board};
        {error, _} = Error -> Error
    end;
open(Conn, Home) when is_integer(Home) ->
    Sql = <<
        "SELECT 1 FROM shown s JOIN thread t ON t.root = s.id"
        " JOIN board b ON b.id = t.board WHERE s.id = ?1 AND s.thread = ?1 AND b.log = 0"
    >>,
    case ike_db:q(Conn, Sql, [Home]) of
        {ok, [_]} -> ok;
        {ok, []} -> {error, no_such_thread};
        {error, _} = Error -> Error
    end;
open(_Conn, _Home) ->
    {error, bad_request}.

-spec act(ike_db:writer(), who(), ike_role:kind(), term(), binary(), integer()) ->
    {ok, effects()} | error().
act(Conn, Who, Kind, Name, Reason, Time) when
    Kind =:= lock orelse Kind =:= unlock, is_binary(Name)
->
    Locked =
        case Kind of
            lock -> 1;
            unlock -> 0
        end,
    Update = <<
        "UPDATE board SET locked = ?2 WHERE name = ?1 AND log = 0 AND locked <> ?2"
        " RETURNING id"
    >>,
    case ike_db:q(Conn, Update, [Name, Locked]) of
        {ok, [[Board]]} when is_integer(Board) ->
            Text = <<(ike_role:to_binary(Kind))/binary, " /", Name/binary, "/">>,
            logged(
                log(Conn, Who, Kind, Text, Reason, Time, {undefined, undefined, Board}),
                effects()
            );
        {ok, _} ->
            %% there, and already so
            there(Conn, <<"SELECT 1 FROM board WHERE name = ?1 AND log = 0">>, Name, no_such_board);
        {error, _} = Error ->
            Error
    end;
act(Conn, Who, unban, Account, Reason, Time) when is_integer(Account) ->
    Update = <<"UPDATE actor SET banned = 0 WHERE id = ?1 AND banned = 1 RETURNING id">>,
    case ike_db:q(Conn, Update, [Account]) of
        {ok, [_]} ->
            logged(
                log(Conn, Who, unban, <<"unban">>, Reason, Time, {undefined, Account, undefined}),
                effects()
            );
        {ok, _} ->
            there(Conn, <<"SELECT 1 FROM actor WHERE id = ?1">>, Account, no_such_account);
        {error, _} = Error ->
            Error
    end;
act(Conn, Who, Kind, Post, Reason, Time) when is_integer(Post) ->
    %% nothing on the log is ever taken down
    Sql = <<
        "SELECT p.thread, p.state, p.actor, a.kind = 'local', a.banned, b.name"
        " FROM post p JOIN thread t ON t.root = p.thread JOIN board b ON b.id = t.board"
        " JOIN actor a ON a.id = p.actor WHERE p.id = ?1 AND b.log = 0"
    >>,
    case ike_db:q(Conn, Sql, [Post]) of
        {ok, [[Thread, State, Actor, Local, Banned, Board]]} when
            is_integer(Thread), is_integer(State), is_integer(Actor), is_binary(Board)
        ->
            case {Kind, State, Local, Banned} of
                {ban, _, 1, 0} ->
                    suspend(Conn, Who, Post, Actor, Reason, Time);
                {ban, _, 1, _} ->
                    {error, not_now};
                {ban, _, _, _} ->
                    {error, no_such_account};
                {hide, 0, _, _} ->
                    state(Conn, Who, Kind, {Post, Thread, Board}, {1, undefined}, Reason, Time);
                {unhide, 1, _, _} ->
                    state(Conn, Who, Kind, {Post, Thread, Board}, {0, undefined}, Reason, Time);
                {delete, Shown, _, _} when Shown < 2 ->
                    Until = Time + ike_config:hold_seconds(),
                    state(Conn, Who, Kind, {Post, Thread, Board}, {2, Until}, Reason, Time);
                {restore, 2, _, _} ->
                    state(Conn, Who, Kind, {Post, Thread, Board}, {0, undefined}, Reason, Time);
                {purge, _, _, _} ->
                    state(Conn, Who, Kind, {Post, Thread, Board}, purge, Reason, Time);
                _ ->
                    {error, not_now}
            end;
        {ok, _} ->
            {error, no_such_post};
        {error, _} = Error ->
            Error
    end;
act(_Conn, _Who, _Kind, _Target, _Reason, _Time) ->
    {error, bad_request}.

%% whether a thing that is not in the state asked of it is there at all
-spec there(ike_db:writer(), binary(), term(), atom()) -> error().
there(Conn, Sql, Key, Missing) ->
    case ike_db:q(Conn, Sql, [Key]) of
        {ok, [_]} -> {error, not_now};
        {ok, _} -> {error, Missing};
        {error, _} = Error -> Error
    end.

-spec effects() -> effects().
effects() ->
    #{threads => [], gone => [], boards => [], drop => [], scrub => false}.

-spec logged({ok, [term()]} | error(), effects()) -> {ok, effects()} | error().
logged({ok, Threads}, #{threads := Others} = Effects) ->
    {ok, Effects#{threads := Threads ++ Others}};
logged({error, _} = Error, _Effects) ->
    Error.

%% the account behind a post it signed: no more sessions, and no new ones
-spec suspend(ike_db:writer(), who(), integer(), integer(), binary(), integer()) ->
    {ok, effects()} | error().
suspend(Conn, Who, Post, Actor, Reason, Time) ->
    Text = <<"ban, for >>", (integer_to_binary(Post))/binary>>,
    case log(Conn, Who, ban, Text, Reason, Time, {Post, Actor, undefined}) of
        {ok, Threads} ->
            case ike_db:q(Conn, <<"UPDATE actor SET banned = 1 WHERE id = ?1">>, [Actor]) of
                {ok, _} ->
                    case ike_db:q(Conn, <<"DELETE FROM session WHERE actor = ?1">>, [Actor]) of
                        {ok, _} -> {ok, (effects())#{threads := Threads, drop := [Actor]}};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%% a post out of sight, back in it, or gone for good; a thread's first
%% post takes the thread with it
-spec state(
    ike_db:writer(),
    who(),
    ike_role:kind(),
    {Post :: integer(), Thread :: integer(), Board :: binary()},
    {0 | 1 | 2, integer() | undefined} | purge,
    binary(),
    integer()
) ->
    {ok, effects()} | error().
state(Conn, Who, Kind, {Post, Thread, Board}, To, Reason, Time) ->
    %% every page that shows a link to or from what changes
    Around = <<
        "WITH these AS (SELECT id FROM post WHERE id = ?1 OR (?1 = ?2 AND thread = ?2))"
        " SELECT s.thread FROM link l JOIN post s ON s.id = l.source"
        " WHERE l.post IN (SELECT id FROM these)"
        " UNION SELECT p.thread FROM link l JOIN post p ON p.id = l.post"
        " WHERE l.source IN (SELECT id FROM these)"
    >>,
    Text = <<(ike_role:to_binary(Kind))/binary, " >>", (integer_to_binary(Post))/binary>>,
    case ike_db:q(Conn, Around, [Post, Thread]) of
        {ok, Rows} ->
            case log(Conn, Who, Kind, Text, Reason, Time, {Post, undefined, undefined}) of
                {ok, Logged} ->
                    case changed(Conn, Post, Thread, To) of
                        ok ->
                            Gone =
                                case Post =:= Thread andalso To =/= {0, undefined} of
                                    true -> [{Board, Thread}];
                                    false -> []
                                end,
                            {ok, #{
                                threads => [Thread | Logged] ++ [T || [T] <- Rows],
                                gone => Gone,
                                boards => [Board],
                                drop => [],
                                scrub => To =:= purge
                            }};
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec changed(
    ike_db:writer(), integer(), integer(), {0 | 1 | 2, integer() | undefined} | purge
) ->
    ok | error().
changed(Conn, Post, Thread, purge) ->
    %% invariant 8: the rows, and every link to or from them. what the
    %% log says of them stays, and names them by number only
    These = <<"(SELECT id FROM post WHERE id = ?1 OR (?1 = ?2 AND thread = ?2))">>,
    each(Conn, [Post, Thread], [
        <<"DELETE FROM link WHERE post IN ", These/binary>>,
        <<"DELETE FROM link WHERE source IN ", These/binary>>,
        <<"UPDATE post SET parent = NULL WHERE parent IN ", These/binary>>,
        <<"DELETE FROM post WHERE id = ?1 OR (?1 = ?2 AND thread = ?2)">>,
        <<"DELETE FROM thread WHERE root = ?1 AND ?1 = ?2">>
    ]);
changed(Conn, Post, _Thread, {State, Until}) ->
    Update = <<"UPDATE post SET state = ?2, purge_at = ?3 WHERE id = ?1">>,
    case ike_db:q(Conn, Update, [Post, State, Until]) of
        {ok, _} -> ok;
        {error, _} = Error -> Error
    end.

-spec each(ike_db:writer(), [term()], [binary()]) -> ok | error().
each(Conn, Args, [Sql | Rest]) ->
    case ike_db:q(Conn, Sql, Args) of
        {ok, _} -> each(Conn, Args, Rest);
        {error, _} = Error -> Error
    end;
each(_Conn, _Args, []) ->
    ok.

%% an entry in the log: a post in this month's thread on the log's
%% board, saying what was done, and a row beside it saying who did
-spec log(
    ike_db:writer(),
    who(),
    ike_role:kind(),
    Text :: binary(),
    Reason :: binary(),
    integer(),
    {
        Post :: integer() | undefined,
        Account :: integer() | undefined,
        Board :: integer() | undefined
    }
) ->
    {ok, Threads :: [term()]} | error().
log(Conn, Who, Kind, Text, Reason, Time, {Post, Account, Board}) ->
    {Actor, Role} =
        case Who of
            system -> {undefined, system};
            {By, Held} -> {By, Held}
        end,
    Insert = <<
        "INSERT INTO action (entry, actor, role, kind, post, account, board)"
        " VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)"
    >>,
    case month(Conn, Time) of
        {ok, Root} ->
            case insert(Conn, ?NOBODY, Root, Time, <<Text/binary, "\n", Reason/binary>>) of
                {ok, {Entry, Threads}} ->
                    Row = [
                        Entry,
                        Actor,
                        ike_role:to_binary(Role),
                        ike_role:to_binary(Kind),
                        Post,
                        Account,
                        Board
                    ],
                    case ike_db:q(Conn, Insert, Row) of
                        {ok, _} -> {ok, Threads};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%% the log's thread for the month Time is in, started if need be
-spec month(ike_db:writer(), integer()) -> {ok, integer()} | error().
month(Conn, Time) ->
    {{Year, Month, _}, _} = calendar:system_time_to_universal_time(Time, second),
    Name = iolist_to_binary(io_lib:format("~4..0B-~2..0B", [Year, Month])),
    Find = <<
        "SELECT t.root FROM thread t JOIN board b ON b.id = t.board"
        " JOIN post p ON p.id = t.root WHERE b.name = ?1 AND b.log = 1 AND p.body = ?2"
    >>,
    case ike_db:q(Conn, Find, [?LOG, Name]) of
        {ok, [[Root] | _]} when is_integer(Root) ->
            {ok, Root};
        {ok, []} ->
            case post(Conn, ?NOBODY, {new, ?LOG}, Time, Name) of
                {ok, {Root, _}} -> {ok, Root};
                {error, _} = Error -> Error
            end;
        {ok, Rows} ->
            {error, {unexpected, Rows}};
        {error, _} = Error ->
            Error
    end.

-spec local_actor(ike_db:writer(), binary(), binary(), binary() | none) ->
    {ok, {Id :: integer(), Renamed :: [term()]}} | error().
local_actor(Conn, Issuer, Subject, Nick) ->
    Insert = <<
        "INSERT INTO actor (kind, issuer, subject) VALUES ('local', ?1, ?2)"
        " ON CONFLICT DO NOTHING"
    >>,
    %% whether the name is the one given, null and none being the same
    Select = <<
        "SELECT id, name IS ?3, banned FROM actor"
        " WHERE kind = 'local' AND issuer = ?1 AND subject = ?2"
    >>,
    Name =
        case Nick of
            none -> undefined;
            _ -> Nick
        end,
    case ike_db:q(Conn, Insert, [Issuer, Subject]) of
        {ok, _} ->
            case ike_db:q(Conn, Select, [Issuer, Subject, Name]) of
                {ok, [[_, _, 1]]} -> {error, suspended};
                {ok, [[Id, 1, _]]} when is_integer(Id) -> {ok, {Id, []}};
                {ok, [[Id, 0, _]]} when is_integer(Id) -> rename(Conn, Id, Name);
                {ok, Rows} -> {error, {unexpected, Rows}};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec rename(ike_db:writer(), integer(), binary() | undefined) ->
    {ok, {Id :: integer(), Renamed :: [term()]}} | error().
rename(Conn, Id, Name) ->
    case ike_db:q(Conn, <<"UPDATE actor SET name = ?2 WHERE id = ?1">>, [Id, Name]) of
        {ok, _} ->
            case ike_db:q(Conn, <<"SELECT DISTINCT thread FROM post WHERE actor = ?1">>, [Id]) of
                {ok, Rows} -> {ok, {Id, [Thread || [Thread] <- Rows]}};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec post(ike_db:writer(), integer(), term(), integer(), binary()) ->
    {ok, {Id :: integer(), Threads :: [term()]}} | error().
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
    {ok, {Id :: integer(), Threads :: [term()]}} | error().
insert(Conn, Actor, Home, Time, Body) ->
    Insert = <<
        "INSERT INTO post (thread, actor, time, body)"
        " VALUES (?1, ?2, ?3, ?4) RETURNING id"
    >>,
    case ike_db:q(Conn, Insert, [Home, Actor, Time, Body]) of
        {ok, [[Id]]} when is_integer(Id) ->
            case link(Conn, Id, ike_text:targets(Body)) of
                ok -> touched(Conn, Id, Home);
                {error, _} = Error -> Error
            end;
        {ok, Rows} ->
            {error, {unexpected, Rows}};
        {error, _} = Error ->
            Error
    end.

%% the reverse links, with the post they are read from (hazard d1). a
%% target need not be there: the link is weak, and waits for it
-spec link(ike_db:writer(), integer(), [pos_integer()]) -> ok | error().
link(_Conn, _Source, []) ->
    ok;
link(Conn, Source, [Target | Targets]) ->
    case ike_db:q(Conn, <<"INSERT INTO link (source, post) VALUES (?1, ?2)">>, [Source, Target]) of
        {ok, _} -> link(Conn, Source, Targets);
        {error, _} = Error -> Error
    end.

%% every thread whose page a new post changes: its own, those of the
%% posts it points at, which now show who points at them, and those of
%% the posts that pointed at its number before it was there
-spec touched(ike_db:writer(), integer(), integer()) ->
    {ok, {Id :: integer(), Threads :: [term()]}} | error().
touched(Conn, Id, Home) ->
    Sql = <<
        "SELECT p.thread FROM link l JOIN post p ON p.id = l.post WHERE l.source = ?1"
        " UNION"
        " SELECT p.thread FROM link l JOIN post p ON p.id = l.source WHERE l.post = ?1"
    >>,
    case ike_db:q(Conn, Sql, [Id]) of
        {ok, Rows} -> {ok, {Id, [Home | [Thread || [Thread] <- Rows, Thread =/= Home]]}};
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
