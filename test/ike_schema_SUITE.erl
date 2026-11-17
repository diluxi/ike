%% Black-box: starts the application on an empty directory, then looks only
%% at the database file it leaves behind. Constraints are tried on a copy,
%% so nothing here writes to a database ike owns.
-module(ike_schema_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("proper/include/proper.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    wal/1,
    one_anonymous_actor/1,
    actor_kinds_carry_their_columns/1,
    asset_hash_is_32_bytes/1,
    op_is_its_own_thread/1,
    post_numbers_are_never_reused/1,
    link_has_exactly_one_target/1,
    links_go_with_their_source/1,
    reachability_covers_every_asset_column/1,
    restart_applies_nothing_twice/1,
    changed_migration_is_refused/1,
    newer_database_is_refused/1
]).

all() ->
    [
        wal,
        one_anonymous_actor,
        actor_kinds_carry_their_columns,
        asset_hash_is_32_bytes,
        op_is_its_own_thread,
        post_numbers_are_never_reused,
        link_has_exactly_one_target,
        links_go_with_their_source,
        reachability_covers_every_asset_column,
        restart_applies_nothing_twice,
        changed_migration_is_refused,
        newer_database_is_refused
    ].

%% each case gets its own data directory, migrated by a start and a stop
init_per_testcase(Case, Config) ->
    Dir = filename:join(?config(priv_dir, Config), atom_to_list(Case)),
    _ = application:load(ike),
    ok = application:set_env(ike, data_dir, list_to_binary(Dir)),
    {ok, _} = application:ensure_all_started(ike),
    ok = application:stop(ike),
    Db = filename:join(Dir, "ike.db"),
    Copy = filename:join(Dir, "copy.db"),
    {ok, _} = file:copy(Db, Copy),
    {ok, Conn} = esqlite3:open(Copy),
    ok = esqlite3:exec(Conn, "PRAGMA foreign_keys = ON"),
    [{db, Db}, {conn, Conn} | Config].

end_per_testcase(_Case, Config) ->
    _ = application:stop(ike),
    esqlite3:close(?config(conn, Config)).

wal(Config) ->
    {ok, Conn} = esqlite3:open(?config(db, Config)),
    [[<<"wal">>]] = esqlite3:q(Conn, "PRAGMA journal_mode"),
    ok = esqlite3:close(Conn).

one_anonymous_actor(Config) ->
    Conn = ?config(conn, Config),
    [[1, <<"anonymous">>]] = esqlite3:q(Conn, "SELECT id, kind FROM actor"),
    {error, _} = esqlite3:exec(
        Conn, "INSERT INTO actor (kind) VALUES ('anonymous')"
    ).

actor_kinds_carry_their_columns(Config) ->
    Conn = ?config(conn, Config),
    Insert = "INSERT INTO actor (kind, issuer, subject) VALUES (?1, ?2, ?3)",
    Iss = <<"https://id.example">>,
    [] = esqlite3:q(Conn, Insert, [<<"local">>, Iss, <<"a">>]),
    [] = esqlite3:q(Conn, Insert, [<<"local">>, Iss, <<"b">>]),
    %% the same account twice
    {error, _} = esqlite3:q(Conn, Insert, [<<"local">>, Iss, <<"a">>]),
    %% a local account without its subject, or issuer
    {error, _} = esqlite3:q(Conn, Insert, [<<"local">>, Iss, undefined]),
    {error, _} = esqlite3:q(Conn, Insert, [<<"local">>, undefined, <<"a">>]),
    %% anything else with one
    {error, _} = esqlite3:q(Conn, Insert, [<<"board">>, Iss, <<"c">>]),
    {error, _} = esqlite3:q(Conn, Insert, [<<"nobody">>, undefined, undefined]).

asset_hash_is_32_bytes(Config) ->
    Conn = ?config(conn, Config),
    Insert = "INSERT INTO asset (hash) VALUES (?1)",
    Prop = ?FORALL(
        Hash,
        binary(),
        begin
            _ = esqlite3:exec(Conn, "DELETE FROM asset"),
            Stored = esqlite3:q(Conn, Insert, [{blob, Hash}]) =:= [],
            Stored =:= (byte_size(Hash) =:= 32)
        end
    ),
    true = proper:quickcheck(Prop, [{numtests, 200}, {to_file, user}]),
    [] = esqlite3:q(Conn, Insert, [{blob, <<0:256>>}]).

op_is_its_own_thread(Config) ->
    Conn = ?config(conn, Config),
    1 = op(Conn),
    2 = reply(Conn, 1),
    %% a thread without its root, and a post without its thread, both fail
    %% when the transaction ends
    ok = esqlite3:exec(Conn, "BEGIN; INSERT INTO thread (root) VALUES (9)"),
    {error, _} = esqlite3:exec(Conn, "COMMIT"),
    ok = esqlite3:exec(Conn, "ROLLBACK"),
    ok = esqlite3:exec(
        Conn,
        "BEGIN; INSERT INTO post (thread, actor, time, body)"
        " VALUES (9, 1, 0, 'x')"
    ),
    {error, _} = esqlite3:exec(Conn, "COMMIT"),
    ok = esqlite3:exec(Conn, "ROLLBACK"),
    %% a promoted reply roots a second thread and stays in its first
    [] = esqlite3:q(Conn, "INSERT INTO thread (root) VALUES (2)"),
    [[1]] = esqlite3:q(Conn, "SELECT thread FROM post WHERE id = 2").

%% >>N never changes meaning: whatever is deleted, a new post's number is
%% above every number there ever was
post_numbers_are_never_reused(Config) ->
    Conn = ?config(conn, Config),
    Root = op(Conn),
    Prop = ?FORALL(
        Steps,
        list(oneof([post, delete_last, delete_all])),
        begin
            High = lists:foldl(
                fun
                    (post, Max) ->
                        Id = reply(Conn, Root),
                        true = Id > Max,
                        Id;
                    (delete_last, Max) ->
                        [] = esqlite3:q(
                            Conn,
                            "DELETE FROM post WHERE id ="
                            " (SELECT max(id) FROM post WHERE id != ?1)",
                            [Root]
                        ),
                        Max;
                    (delete_all, Max) ->
                        [] = esqlite3:q(
                            Conn, "DELETE FROM post WHERE id != ?1", [Root]
                        ),
                        Max
                end,
                reply(Conn, Root),
                Steps
            ),
            reply(Conn, Root) > High
        end
    ),
    true = proper:quickcheck(Prop, [{numtests, 100}, {to_file, user}]).

link_has_exactly_one_target(Config) ->
    Conn = ?config(conn, Config),
    Root = op(Conn),
    Insert = "INSERT INTO link (source, post, booru, name) VALUES (?1, ?2, ?3, ?4)",
    Prop = ?FORALL(
        {Post, Booru, Name},
        {target(pos_integer()), target(pos_integer()), target(<<"name">>)},
        begin
            _ = esqlite3:exec(Conn, "DELETE FROM link"),
            Targets = length([T || T <- [Post, Booru, Name], T =/= undefined]),
            Stored = esqlite3:q(Conn, Insert, [Root, Post, Booru, Name]) =:= [],
            Stored =:= (Targets =:= 1)
        end
    ),
    true = proper:quickcheck(Prop, [{numtests, 200}, {to_file, user}]),
    %% the same mention twice
    _ = esqlite3:exec(Conn, "DELETE FROM link"),
    [] = esqlite3:q(Conn, Insert, [Root, 7, undefined, undefined]),
    {error, _} = esqlite3:q(Conn, Insert, [Root, 7, undefined, undefined]).

%% invariant 8, as far as the schema can hold it: a post's row cannot go
%% and leave its reverse links
links_go_with_their_source(Config) ->
    Conn = ?config(conn, Config),
    Root = op(Conn),
    Reply = reply(Conn, Root),
    [] = esqlite3:q(
        Conn, "INSERT INTO link (source, post) VALUES (?1, ?2)", [Reply, Root]
    ),
    [] = esqlite3:q(Conn, "DELETE FROM post WHERE id = ?1", [Reply]),
    [[0]] = esqlite3:q(Conn, "SELECT count(*) FROM link").

%% invariant 9: every column that references an asset is part of the
%% reachability view. the columns come from the foreign keys; for each, a
%% row is planted with only that column set and has to show up in the view
%% under the column's label
reachability_covers_every_asset_column(Config) ->
    Conn = ?config(conn, Config),
    Columns = [
        {Table, Column}
     || [Table] <- esqlite3:q(
            Conn, "SELECT name FROM sqlite_schema WHERE type = 'table'"
        ),
        [_Id, _Seq, <<"asset">>, Column | _] <- esqlite3:q(
            Conn, ["PRAGMA foreign_key_list(", Table, ")"]
        )
    ],
    true = lists:member({<<"post">>, <<"asset">>}, Columns),
    [[View]] = esqlite3:q(
        Conn, "SELECT sql FROM sqlite_schema WHERE name = 'asset_reference'"
    ),
    Hash = crypto:hash(sha256, <<"planted">>),
    [] = esqlite3:q(Conn, "INSERT INTO asset (hash) VALUES (?1)", [{blob, Hash}]),
    Root = op(Conn),
    [] = esqlite3:q(
        Conn, "UPDATE post SET asset = ?1 WHERE id = ?2", [{blob, Hash}, Root]
    ),
    [] = esqlite3:q(
        Conn,
        "INSERT INTO upload (asset, original, actor, time) VALUES (?1, ?2, 1, 0)",
        [{blob, Hash}, {blob, crypto:hash(sha256, <<"as it came">>)}]
    ),
    [] = esqlite3:q(
        Conn, "INSERT INTO post_image (post, position, asset) VALUES (?1, 0, ?2)", [
            Root, {blob, Hash}
        ]
    ),
    [] = esqlite3:q(Conn, "INSERT INTO booru (id, time) VALUES (1, 0)"),
    [] = esqlite3:q(
        Conn,
        "INSERT INTO booru_version (booru, position, asset, time) VALUES (1, 0, ?1, 0)",
        [{blob, Hash}]
    ),
    [] = esqlite3:q(
        Conn, "INSERT INTO meta (asset, owner, time) VALUES (?1, 1, 0)", [{blob, Hash}]
    ),
    Seen = [Via || [Via] <- esqlite3:q(Conn, "SELECT via FROM asset_reference")],
    lists:foreach(
        fun({Table, Column}) ->
            Label = <<Table/binary, ".", Column/binary>>,
            {_, _} = binary:match(View, <<"'", Label/binary, "'">>),
            %% a row is planted above for each column there is; a new
            %% column has to extend this test with a row of its own
            true = lists:member(Label, Seen)
        end,
        Columns
    ).

restart_applies_nothing_twice(Config) ->
    {ok, Conn} = esqlite3:open(?config(db, Config)),
    Before = esqlite3:q(Conn, "SELECT * FROM migration"),
    true = Before =/= [],
    ok = esqlite3:close(Conn),
    {ok, _} = application:ensure_all_started(ike),
    ok = application:stop(ike),
    {ok, Again} = esqlite3:open(?config(db, Config)),
    Before = esqlite3:q(Again, "SELECT * FROM migration"),
    ok = esqlite3:close(Again).

%% the next two tamper with ike's own database, while it is stopped, to
%% stand in for a release whose migration files differ
changed_migration_is_refused(Config) ->
    tamper(Config, "UPDATE migration SET sha256 = zeroblob(32) WHERE version = 1"),
    {error, {{migration_changed, 1}, _}} = application:start(ike).

newer_database_is_refused(Config) ->
    tamper(
        Config,
        "INSERT INTO migration VALUES (999, 'from the future', zeroblob(32))"
    ),
    {error, {{database_newer, 999}, _}} = application:start(ike).

tamper(Config, Sql) ->
    {ok, Conn} = esqlite3:open(?config(db, Config)),
    ok = esqlite3:exec(Conn, Sql),
    ok = esqlite3:close(Conn).

target(Value) ->
    oneof([undefined, Value]).

op(Conn) ->
    ok = esqlite3:exec(Conn, "BEGIN"),
    [[Next]] = esqlite3:q(
        Conn,
        "SELECT coalesce((SELECT seq FROM sqlite_sequence"
        " WHERE name = 'post'), 0) + 1"
    ),
    [] = esqlite3:q(Conn, "INSERT INTO thread (root) VALUES (?1)", [Next]),
    [[Next]] = esqlite3:q(
        Conn,
        "INSERT INTO post (thread, actor, time, body) VALUES (?1, 1, 0, 'op')"
        " RETURNING id",
        [Next]
    ),
    ok = esqlite3:exec(Conn, "COMMIT"),
    Next.

reply(Conn, Thread) ->
    [[Id]] = esqlite3:q(
        Conn,
        "INSERT INTO post (thread, actor, time, body) VALUES (?1, 1, 0, 'reply')"
        " RETURNING id",
        [Thread]
    ),
    Id.
