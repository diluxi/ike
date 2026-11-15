%% Black-box: M0's last sentence. A logged-in post writes a row and a
%% page; a snapshot is taken; everything is lost; and a restore from the
%% snapshot reproduces both (hazard d6).
-module(ike_backup_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([restore_reproduces/1, only_so_many_are_kept/1]).

all() -> [restore_reproduces, only_so_many_are_kept].

-define(KEEP, 3).

init_per_suite(Config) ->
    %% a snapshot a second, so that the suite need not wait a day
    ike_browser:start(Config, [{backup_seconds, 1}, {backup_keep, ?KEEP}]).

end_per_suite(_Config) ->
    ike_browser:stop().

restore_reproduces(Config) ->
    Dir = ?config(dir, Config),
    Session = ike_browser:login(Config, <<"alice">>),
    {303, Headers, _} = ike_browser:post(Config, "/new", Session, <<"what must survive">>),
    {N, _} = string:to_integer(proplists:get_value("location", Headers) -- "/t/"),
    Thread = "/t/" ++ integer_to_list(N),
    {303, _, _} = ike_browser:post(
        Config, Thread ++ "/reply", Session, <<"and a reply & its <markup>">>
    ),
    Rows = dump(Config),
    {ok, Page} = file:read_file(ike_browser:page_file(Config, N)),
    {ok, Index} = file:read_file(filename:join([Dir, "pages", "index.html"])),
    {_, _} = binary:match(Page, <<"what must survive">>),

    %% a snapshot taken after the reply, found as a file
    Snapshot = wait_for_snapshot(Dir, Rows, 20),
    %% whole, and never a half-written one beside it
    {ok, Conn} = esqlite3:open(Snapshot),
    [[<<"ok">>]] = esqlite3:q(Conn, "PRAGMA integrity_check"),
    ok = esqlite3:close(Conn),
    [] = filelib:wildcard(binary_to_list(filename:join([Dir, "backups", "*.tmp"]))),

    %% posted after the snapshot: the restore will not know of it
    {303, _, _} = ike_browser:post(Config, "/new", Session, <<"too late for the snapshot">>),

    %% lose everything but the snapshot, then restore as deploying.md says
    Kept = filename:join(?config(priv_dir, Config), "kept.db"),
    {ok, _} = file:copy(Snapshot, Kept),
    _ = application:stop(ike),
    Db = filename:join(Dir, "ike.db"),
    [ok = file:delete(F) || F <- filelib:wildcard(binary_to_list(Db) ++ "*")],
    ok = file:del_dir_r(filename:join(Dir, "pages")),
    ok = file:del_dir_r(filename:join(Dir, "backups")),
    {ok, _} = file:copy(Kept, Db),
    ok = ike_browser:restart(),

    %% the rows, and the pages byte for byte, from disk and over http
    Rows = dump(Config),
    {ok, Page} = file:read_file(ike_browser:page_file(Config, N)),
    {ok, Index} = file:read_file(filename:join([Dir, "pages", "index.html"])),
    {200, _, Page} = ike_browser:request(Config, get, Thread, [], none),
    {200, _, Index} = ike_browser:request(Config, get, "/", [], none),
    nomatch = binary:match(Index, <<"too late">>),

    %% and it goes on from there: sessions are gone, accounts are not
    {403, _, _} = ike_browser:post(Config, "/new", Session, <<"an old session">>),
    Again = ike_browser:login(Config, <<"alice">>),
    {303, Headers2, _} = ike_browser:post(Config, Thread ++ "/reply", Again, <<"after">>),
    true = lists:prefix(Thread ++ "#p", proplists:get_value("location", Headers2)),
    [[1]] = ike_browser:query(Config, "SELECT count(*) FROM actor WHERE subject = 'alice'", []).

%% the stand-in for the retention window (hazard d7): old snapshots go
only_so_many_are_kept(Config) ->
    Dir = ?config(dir, Config),
    First = wait_for_count(Dir, ?KEEP, 20),
    timer:sleep(2500),
    Later = snapshots(Dir),
    ?KEEP = length(Later),
    true = hd(Later) > hd(First),
    [] = filelib:wildcard(binary_to_list(filename:join([Dir, "backups", "*.tmp"]))).

snapshots(Dir) ->
    lists:sort(filelib:wildcard(binary_to_list(filename:join([Dir, "backups", "*.db"])))).

wait_for_count(Dir, Count, Tries) when Tries > 0 ->
    case snapshots(Dir) of
        Names when length(Names) >= Count -> Names;
        _ ->
            timer:sleep(500),
            wait_for_count(Dir, Count, Tries - 1)
    end.

%% the newest snapshot, once one holds Rows
wait_for_snapshot(Dir, Rows, Tries) when Tries > 0 ->
    Holds =
        case snapshots(Dir) of
            [] ->
                false;
            Names ->
                Newest = lists:last(Names),
                {ok, Conn} = esqlite3:open(Newest),
                try
                    esqlite3:q(Conn, "SELECT id, thread, actor, time, body FROM post ORDER BY id")
                of
                    Rows -> {true, Newest};
                    _ -> false
                after
                    esqlite3:close(Conn)
                end
        end,
    case Holds of
        {true, Path} ->
            Path;
        false ->
            timer:sleep(500),
            wait_for_snapshot(Dir, Rows, Tries - 1)
    end.

dump(Config) ->
    ike_browser:query(Config, "SELECT id, thread, actor, time, body FROM post ORDER BY id", []).
