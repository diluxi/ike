-module(ike_migrate).

-export([run/1]).
-export_type([error/0]).

-type version() :: pos_integer().
-type migration() :: {version(), Name :: binary(), Sql :: binary()}.
-type error() ::
    {error,
        {bad_migration_file, string()}
        | {missing_migration, version()}
        %% the database has a migration this release doesn't know
        | {database_newer, version()}
        %% an applied migration's file is no longer what was applied
        | {migration_changed, version()}
        | {migration_failed, version(), term()}
        | term()}.

%% brings the schema up to what priv/migrations holds. a migration is
%% applied once, in its own transaction, and never edited afterwards: its
%% hash is kept and compared on every start
-spec run(ike_db:writer()) -> ok | error().
run(Conn) ->
    case read() of
        {ok, Migrations} ->
            case applied(Conn) of
                {ok, Applied} ->
                    case pending(Migrations, Applied) of
                        {ok, Pending} -> apply_all(Conn, Pending);
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec applied(ike_db:writer()) -> {ok, [ike_db:row()]} | error().
applied(Conn) ->
    Create = <<
        "CREATE TABLE IF NOT EXISTS migration ("
        "version INTEGER PRIMARY KEY, name TEXT NOT NULL,"
        "sha256 BLOB NOT NULL) STRICT"
    >>,
    case ike_db:exec(Conn, Create) of
        ok ->
            ike_db:q(
                Conn,
                <<"SELECT version, sha256 FROM migration ORDER BY version">>,
                []
            );
        {error, _} = Error ->
            Error
    end.

-spec read() -> {ok, [migration()]} | error().
read() ->
    case code:priv_dir(ike) of
        {error, _} = Error ->
            Error;
        Priv ->
            Dir = Priv ++ "/migrations",
            %% wildcard returns its matches sorted
            read(Dir, filelib:wildcard("*.sql", Dir), 1)
    end.

-spec read(string(), [string()], version()) -> {ok, [migration()]} | error().
read(_Dir, [], _Next) ->
    {ok, []};
read(Dir, [File | Files], Next) ->
    case string:to_integer(File) of
        {Next, [$_ | _]} ->
            case file:read_file(Dir ++ "/" ++ File) of
                {ok, Sql} ->
                    case read(Dir, Files, Next + 1) of
                        {ok, Rest} ->
                            {ok, [{Next, list_to_binary(File), Sql} | Rest]};
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {Version, [$_ | _]} when is_integer(Version), Version > Next ->
            {error, {missing_migration, Next}};
        _ ->
            {error, {bad_migration_file, File}}
    end.

%% what was applied has to be a prefix of what the files say
-spec pending([migration()], [ike_db:row()]) -> {ok, [migration()]} | error().
pending(Migrations, []) ->
    {ok, Migrations};
pending([], [[Version | _] | _]) when is_integer(Version) ->
    {error, {database_newer, Version}};
pending([{Version, _Name, Sql} | Migrations], [[Version, Hash] | Applied]) ->
    case crypto:hash(sha256, Sql) of
        Hash -> pending(Migrations, Applied);
        _ -> {error, {migration_changed, Version}}
    end;
pending([{Version, _Name, _Sql} | _], _Applied) ->
    {error, {migration_changed, Version}}.

-spec apply_all(ike_db:writer(), [migration()]) -> ok | error().
apply_all(_Conn, []) ->
    ok;
apply_all(Conn, [{Version, Name, Sql} | Migrations]) ->
    case ike_db:transaction(Conn, fun() -> apply_one(Conn, Version, Name, Sql) end) of
        {error, Reason} -> {error, {migration_failed, Version, Reason}};
        _ -> apply_all(Conn, Migrations)
    end.

-spec apply_one(ike_db:writer(), version(), binary(), binary()) ->
    ok | ike_db:error().
apply_one(Conn, Version, Name, Sql) ->
    Record = <<"INSERT INTO migration VALUES (?1, ?2, ?3)">>,
    Hash = {blob, crypto:hash(sha256, Sql)},
    case ike_db:exec(Conn, Sql) of
        ok ->
            case ike_db:q(Conn, Record, [Version, Name, Hash]) of
                {ok, _} ->
                    case ike_db:q(Conn, <<"PRAGMA foreign_key_check">>, []) of
                        {ok, []} -> ok;
                        {ok, Rows} -> {error, {foreign_key_check, Rows}};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.
