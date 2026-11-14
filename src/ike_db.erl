-module(ike_db).

-export([open/1, close/1, exec/2, q/3, transaction/2]).
-export_type([conn/0, row/0, error/0]).

-opaque conn() :: esqlite3:esqlite3().
-type row() :: esqlite3:row().
-type error() :: {error, term()}.

%% every connection gets the same settings; foreign keys, the busy timeout
%% and secure_delete are per connection in sqlite, so none may be skipped
-define(PRAGMAS, <<
    "PRAGMA journal_mode = WAL;"
    "PRAGMA synchronous = FULL;"
    "PRAGMA foreign_keys = ON;"
    "PRAGMA busy_timeout = 5000;"
    "PRAGMA secure_delete = ON;"
    "PRAGMA trusted_schema = OFF;"
>>).

-spec open(binary()) -> {ok, conn()} | error().
open(Path) ->
    case esqlite3:open(binary_to_list(Path)) of
        {ok, Conn} ->
            case esqlite3:exec(Conn, ?PRAGMAS) of
                ok ->
                    {ok, Conn};
                {error, _} = Error ->
                    _ = esqlite3:close(Conn),
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec close(conn()) -> ok | error().
close(Conn) ->
    esqlite3:close(Conn).

-spec exec(conn(), iodata()) -> ok | error().
exec(Conn, Sql) ->
    esqlite3:exec(Conn, Sql).

-spec q(conn(), iodata(), [term()]) -> {ok, [row()]} | error().
q(Conn, Sql, Args) ->
    case esqlite3:q(Conn, Sql, Args) of
        {error, _} = Error -> Error;
        Rows -> {ok, Rows}
    end.

%% commits when Fun returns ok or {ok, _}, rolls back when it returns an
%% error or doesn't return at all
-spec transaction(conn(), fun(() -> Result)) -> Result | error() when
    Result :: ok | {ok, term()} | error().
transaction(Conn, Fun) ->
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
                case esqlite3:get_autocommit(Conn) of
                    true -> ok;
                    false -> exec(Conn, <<"ROLLBACK">>)
                end
            end;
        {error, _} = Error ->
            Error
    end.
