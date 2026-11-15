%% SQLite, behind two kinds of connection. A reader cannot write: SQLite
%% refuses it (query_only), and so do the types. Only ike_writer opens a
%% writer, which is what invariant 3 rests on.
-module(ike_db).

-export([open_reader/1, open_writer/1, close/1]).
-export([q/3, q/4, exec/2, transaction/2, snapshot/2]).
-export_type([reader/0, writer/0, conn/0, row/0, error/0]).

-opaque reader() :: {reader, esqlite3:esqlite3()}.
-opaque writer() :: {writer, esqlite3:esqlite3()}.
-type conn() :: reader() | writer().
-type row() :: esqlite3:row().
-type error() :: {error, term()}.

%% foreign keys, the busy timeout and secure_delete are per connection in
%% sqlite, so none may be skipped
-define(WRITER, <<
    "PRAGMA journal_mode = WAL;"
    "PRAGMA synchronous = FULL;"
    "PRAGMA foreign_keys = ON;"
    "PRAGMA busy_timeout = 5000;"
    "PRAGMA secure_delete = ON;"
    "PRAGMA trusted_schema = OFF;"
>>).
-define(READER, <<
    "PRAGMA query_only = ON;"
    "PRAGMA busy_timeout = 5000;"
    "PRAGMA trusted_schema = OFF;"
>>).

%% hazard d5: no query runs longer than this, whoever wrote it
-define(TIMEOUT, 5000).
%% pages a snapshot copies between giving the scheduler back
-define(PAGES, 256).
%% what a snapshot is taken without: who was logged in is no part of a
%% backup, and a restore revives no session
-define(SCRUB, <<
    "PRAGMA secure_delete = ON;"
    "DELETE FROM session;"
>>).

-spec open_reader(binary()) -> {ok, reader()} | error().
open_reader(Path) ->
    case open(Path, ?READER) of
        {ok, Raw} -> {ok, {reader, Raw}};
        {error, _} = Error -> Error
    end.

-spec open_writer(binary()) -> {ok, writer()} | error().
open_writer(Path) ->
    case open(Path, ?WRITER) of
        {ok, Raw} -> {ok, {writer, Raw}};
        {error, _} = Error -> Error
    end.

-spec open(binary(), binary()) -> {ok, esqlite3:esqlite3()} | error().
open(Path, Pragmas) ->
    case esqlite3:open(binary_to_list(Path)) of
        {ok, Raw} ->
            case esqlite3:exec(Raw, Pragmas) of
                ok ->
                    {ok, Raw};
                {error, _} = Error ->
                    _ = esqlite3:close(Raw),
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec close(conn()) -> ok | error().
close({_, Raw}) ->
    esqlite3:close(Raw).

-spec q(conn(), iodata(), [term()]) -> {ok, [row()]} | error().
q(Conn, Sql, Args) ->
    q(Conn, Sql, Args, ?TIMEOUT).

%% every esqlite call runs on a dirty scheduler; the timer interrupts a
%% query that is still running when its time is up, which then fails
-spec q(conn(), iodata(), [term()], non_neg_integer()) -> {ok, [row()]} | error().
q({_, Raw}, Sql, Args, Timeout) ->
    Timer = timer:apply_after(Timeout, esqlite3, interrupt, [Raw]),
    try esqlite3:q(Raw, Sql, Args) of
        {error, _} = Error -> Error;
        Rows -> {ok, Rows}
    after
        case Timer of
            {ok, Ref} -> timer:cancel(Ref);
            {error, _} -> ok
        end
    end.

%% unbounded, for migrations and for the ends of a transaction
-spec exec(writer(), iodata()) -> ok | error().
exec({writer, Raw}, Sql) ->
    esqlite3:exec(Raw, Sql).

%% commits when Fun returns ok or {ok, _}, rolls back when it returns an
%% error or doesn't return at all
-spec transaction(writer(), fun(() -> Result)) -> Result | error() when
    Result :: ok | {ok, term()} | error().
transaction({writer, Raw} = Conn, Fun) ->
    case exec(Conn, <<"BEGIN IMMEDIATE">>) of
        ok ->
            try
                case Fun() of
                    {error, _} = Error ->
                        Error;
                    Result ->
                        case exec(Conn, <<"COMMIT">>) of
                            ok -> Result;
                            {error, _} = Error -> Error
                        end
                end
            after
                %% still inside the transaction: nothing was committed
                case esqlite3:get_autocommit(Raw) of
                    true -> ok;
                    false -> exec(Conn, <<"ROLLBACK">>)
                end
            end;
        {error, _} = Error ->
            Error
    end.

%% a consistent copy of the whole database at Path, through sqlite's
%% backup api (hazard d6). taken from the writer's own connection, so that
%% no write can land halfway through it. the copy is scrubbed and checked
-spec snapshot(writer(), binary()) -> ok | error().
snapshot({writer, Raw}, Path) ->
    case esqlite3:open(binary_to_list(Path)) of
        {ok, Copy} ->
            try
                case esqlite3:backup_init(Copy, "main", Raw, "main") of
                    {ok, Backup} ->
                        case copy(Backup) of
                            ok ->
                                case esqlite3:exec(Copy, ?SCRUB) of
                                    ok -> sound(Copy);
                                    {error, _} = Error -> Error
                                end;
                            {error, _} = Error ->
                                Error
                        end;
                    {error, _} = Error ->
                        Error
                end
            after
                esqlite3:close(Copy)
            end;
        {error, _} = Error ->
            Error
    end.

-spec copy(esqlite3:esqlite3_backup()) -> ok | error().
copy(Backup) ->
    case esqlite3:backup_step(Backup, ?PAGES) of
        ok ->
            copy(Backup);
        '$done' ->
            esqlite3:backup_finish(Backup);
        {error, _} = Error ->
            _ = esqlite3:backup_finish(Backup),
            Error
    end.

%% a snapshot that sqlite itself would not trust is not kept
-spec sound(esqlite3:esqlite3()) -> ok | error().
sound(Copy) ->
    case esqlite3:q(Copy, <<"PRAGMA integrity_check">>) of
        [[<<"ok">>]] -> ok;
        Other -> {error, {unsound, Other}}
    end.
