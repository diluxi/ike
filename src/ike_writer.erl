%% The single writer (invariant 3): the one process that holds a writable
%% connection. Whatever changes the database is a message to it, and one
%% transaction. It also brings the schema up to date, before it answers
%% anything.
-module(ike_writer).
-behaviour(gen_server).

-export([start_link/0, local_actor/3, post/1, moderate/1, upload/1, retract/2, snapshot/0]).
-export([report/2, dismiss/1, tag/3, wiki/1, privacy/3, sign_meta/2]).
-export([curate/4, revise/5, comment/3]).
-export([open_session/5, close_session/1, expire_sessions/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export_type([new_post/0, action/0]).

-type new_post() :: #{
    actor := ike_id:actor(),
    %% a reply's thread, or the board an op starts one on
    thread := {new, Board :: binary()} | ike_id:post(),
    body := binary(),
    %% staged uploads of the account's, which the post shows in this
    %% order; the post may then have no text
    upload => {Account :: ike_id:actor(), Uploads :: [pos_integer(), ...]},
    %% what the poster may retract it with later, as given
    password => binary(),
    %% a title, one line
    title => binary()
}.

%% what a moderator does, and to what: a post by its number, an account
%% by a post it signed or by its own number, a board by its name
-type action() :: #{
    by := ike_id:actor(),
    role := ike_role:role(),
    kind := ike_role:kind(),
    %% an image is its post and its place among the post's images, from 0
    target :=
        ike_id:post()
        | {image, ike_id:post(), non_neg_integer()}
        | {entry, ike_id:booru()}
        | {meta, pos_integer()}
        | ike_id:actor()
        | binary(),
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
    scrub := boolean(),
    %% assets whose being shown may have changed
    assets := [binary()],
    %% assets purged, by hex: their files go
    unlinked := [binary()],
    %% booru entries whose pages change, and those whose pages go
    entries := [integer()],
    gone_entries := [integer()]
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
%% how often the write-ahead log is folded back; milliseconds
-define(CHECKPOINT, 60000).

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
    {ok, ike_id:post()}
    | {error, bad_text | no_such_thread | no_such_board | no_such_upload}
    | error().
post(#{actor := Actor, thread := Thread, body := Body} = Post) ->
    Home =
        case Thread of
            {new, Board} -> {new, Board};
            _ -> ike_id:to_integer(Thread)
        end,
    Upload =
        case Post of
            #{upload := {Account, [_ | _] = Staged}} -> {ike_id:to_integer(Account), Staged};
            _ -> none
        end,
    Password =
        case Post of
            #{password := Given} when byte_size(Given) > 0 -> sealed(Given);
            _ -> undefined
        end,
    Title =
        case Post of
            #{title := Given0} when byte_size(Given0) > 0 -> Given0;
            _ -> undefined
        end,
    case call({post, ike_id:to_integer(Actor), Home, Body, Upload, Password, Title}) of
        {ok, Id} when is_integer(Id), Id > 0 -> {ok, ike_id:post(Id)};
        Other -> failed(Other)
    end.

%% an upload, stripped: its asset (once, whoever brought it before) and
%% the upload itself, staged. Original is the upload as it came
%% and a meta of the asset for the uploader, unless they have one or it
%% has a public one: private if an account asked, else public
-spec upload(#{
    actor := ike_id:actor(),
    original := binary(),
    stripped := ike_strip:stripped(),
    private => boolean(),
    signed => boolean()
}) ->
    {ok, Upload :: pos_integer()} | error().
upload(#{actor := Actor, original := Original, stripped := Stripped} = Given) ->
    Private =
        case Given of
            #{private := true} -> 1;
            _ -> 0
        end,
    Signed =
        case Given of
            #{signed := true} -> 1;
            _ -> 0
        end,
    #{type := Type, width := W, height := H, stored := Stored, thumb := Thumb} = Stripped,
    Traits = spaced([atom_to_binary(T) || T <- maps:get(traits, Stripped, [])]),
    %% a font's family and axes are the asset's; what else it said of
    %% itself is this upload's commentary
    Font =
        case Stripped of
            #{font := #{family := Family, axes := Axes, commentary := Said}} ->
                {Family, axes(Axes), commentary(Said)};
            _ ->
                {undefined, undefined, undefined}
        end,
    Request =
        {upload, ike_id:to_integer(Actor), crypto:hash(sha256, Original), atom_to_binary(Type), W,
            H, Stored, Thumb, Traits, Private, Signed, Font},
    case call(Request) of
        {ok, Id} when is_integer(Id), Id > 0 -> {ok, Id};
        Other -> failed(Other)
    end.

%% a font's axes as kept, one a line: tag, least, default, most
-spec axes([{binary(), float(), float(), float()}]) -> binary().
axes(Axes) ->
    iolist_to_binary([
        [Tag, $\s, number(Min), $\s, number(Default), $\s, number(Most), $\n]
     || {Tag, Min, Default, Most} <- Axes
    ]).

-spec number(float()) -> binary().
number(F) ->
    float_to_binary(F, [short]).

%% a font's commentary as kept: one record a line, its kind and its text
%% with backslashes, tabs and line ends escaped, as ike-font wrote them
-spec commentary([{binary(), binary()}]) -> binary().
commentary(Said) ->
    iolist_to_binary([[Kind, $\t, escaped(Text), $\n] || {Kind, Text} <- Said]).

-spec escaped(binary()) -> binary().
escaped(Text) ->
    <<
        <<
            (case C of
                $\\ -> <<"\\\\">>;
                $\t -> <<"\\t">>;
                $\n -> <<"\\n">>;
                $\r -> <<"\\r">>;
                _ -> <<C>>
            end)/binary
        >>
     || <<C>> <= Text
    >>.

%% a password as a post keeps it: a salt of its own and a slow hash
%% under it, so that two posts with one password have nothing in common
-define(ROUNDS, 100000).

-spec sealed(binary()) -> binary().
sealed(Password) ->
    Salt = crypto:strong_rand_bytes(16),
    <<Salt/binary, (crypto:pbkdf2_hmac(sha256, Password, Salt, ?ROUNDS, 32))/binary>>.

-spec opens(binary(), term()) -> boolean().
opens(Password, <<Salt:16/binary, Hash:32/binary>>) ->
    crypto:hash_equals(Hash, crypto:pbkdf2_hmac(sha256, Password, Salt, ?ROUNDS, 32));
opens(_, _) ->
    false.

%% a poster trashes their own post: with the password they gave, or, for
%% a post their account signed, by being that account. not a moderation,
%% and not in the log; the post says it was retracted
-spec retract(ike_id:post(), {password, binary()} | {account, ike_id:actor()}) ->
    ok | {error, not_yours | no_such_post | not_now} | error().
retract(Post, By) ->
    N = ike_id:to_integer(Post),
    %% the slow part outside the writer: whether the password opens it
    Allowed =
        case {By, ike_reader:password(N)} of
            {{password, Given}, {ok, Sealed}} -> opens(Given, Sealed);
            {{account, _}, _} -> true;
            _ -> false
        end,
    Who =
        case By of
            {account, Actor} -> ike_id:to_integer(Actor);
            _ -> none
        end,
    case Allowed of
        true -> done(call({retract, N, Who}));
        false -> {error, not_yours}
    end.

%% a wiki page written: made, if there is none by the name, else a new
%% revision on top of the newest, whatever revision the edit was opened
%% on (lux: the first to save is the first edit, the rest stack on it,
%% and a poster retracts one that undid another's). An account's edit
%% right after its own revision, with nothing posted between, is folded
%% into that revision instead, as git's amend does (lux: batching)
-spec wiki(#{
    name := binary(), actor := ike_id:actor(), body := binary(), password => binary()
}) ->
    {ok, ike_id:post()} | {error, bad_text} | error().
wiki(#{name := Name, actor := Actor, body := Body} = Edit) ->
    Password =
        case Edit of
            #{password := Given} when byte_size(Given) > 0 -> sealed(Given);
            _ -> undefined
        end,
    case call({wiki, Name, ike_id:to_integer(Actor), Body, Password}) of
        {ok, Id} when is_integer(Id), Id > 0 -> {ok, ike_id:post(Id)};
        Other -> failed(Other)
    end.

%% an account makes a meta it owns private, or public again; an asset
%% has one public meta, and one made public first keeps it
-spec privacy(Meta :: pos_integer(), ike_id:actor(), boolean()) ->
    ok | {error, not_yours | {taken, pos_integer()}} | error().
privacy(Meta, Owner, Private) when is_integer(Meta), Meta > 0 ->
    Flag =
        case Private of
            true -> 1;
            false -> 0
        end,
    case call({privacy, Meta, ike_id:to_integer(Owner), Flag}) of
        {error, {taken, Other}} when is_integer(Other), Other > 0 -> {error, {taken, Other}};
        Reply -> done(Reply)
    end.

%% an account puts its name on a meta it owns that bore none (lux, Q42)
-spec sign_meta(Meta :: pos_integer(), ike_id:actor()) -> ok | {error, not_yours} | error().
sign_meta(Meta, Owner) when is_integer(Meta), Meta > 0 ->
    done(call({sign_meta, Meta, ike_id:to_integer(Owner)})).

%% a public meta tagged and posted to the booru (lux): its curation, an
%% entry, whose thread is the meta's, with the curation's first revision
%% in it. bytes with an entry already are not curated again
%% Box: the tag box's lines (ike_tag:layout/1), the whole of its tags
-spec curate(Meta :: pos_integer(), ike_id:actor(), Signed :: boolean(), Box :: [[binary()]]) ->
    {ok, pos_integer()} | {error, not_public | no_such_meta | {curated, pos_integer()}} | error().
curate(Meta, Account, Signed, Box) when is_integer(Meta), Meta > 0 ->
    case call({curate, Meta, ike_id:to_integer(Account), Signed, Box}) of
        {ok, Entry} when is_integer(Entry), Entry > 0 -> {ok, Entry};
        {error, {curated, Entry}} when is_integer(Entry), Entry > 0 -> {error, {curated, Entry}};
        Other -> failed(Other)
    end.

%% a curation's tags and commentary changed: a revision in its thread,
%% signed or not as the account asks, folded into the account's own if
%% that is the thread's newest post (lux: amend, Q37). the box is the
%% whole of its tags (lux): what it names is on, nothing else; keep, for
%% either, leaves it as it is. the history keeps who, as for tags before
-spec revise(
    pos_integer(), ike_id:actor(), Signed :: boolean(), [[binary()]] | keep, binary() | keep
) ->
    ok | {error, nothing | no_such_entry | bad_text} | error().
revise(Entry, Account, Signed, Box, Commentary) ->
    done(call({revise, Entry, ike_id:to_integer(Account), Signed, Box, Commentary})).

%% a comment on a meta: in its thread, started by it if it has none. who
%% may see the meta is the asker's to have checked
-spec comment(pos_integer(), ike_id:actor(), binary()) ->
    {ok, ike_id:post()} | {error, bad_text | no_such_meta} | error().
comment(Meta, Actor, Body) ->
    case call({comment, Meta, ike_id:to_integer(Actor), Body}) of
        {ok, Id} when is_integer(Id), Id > 0 -> {ok, ike_id:post(Id)};
        Other -> failed(Other)
    end.

%% an account adds and takes away an entry's tags; the history keeps who
-spec tag(ike_id:booru(), ike_id:actor(), {[binary()], [binary()]}) ->
    ok | {error, no_such_entry | nothing} | error().
tag(Entry, Actor, {Add, Remove}) ->
    done(call({tag, ike_id:to_integer(Entry), ike_id:to_integer(Actor), Add, Remove})).

%% a reader's word that a post needs a moderator's eye. nothing of who
%% said it is kept
-spec report(ike_id:post(), Reason :: binary()) -> ok | {error, bad_text | no_such_post} | error().
report(Post, Reason) ->
    done(call({report, ike_id:to_integer(Post), Reason})).

%% a report looked at
-spec dismiss(Report :: pos_integer()) -> ok | {error, no_such_report} | error().
dismiss(Report) ->
    done(call({dismiss, Report})).

%% one rung of the ladder, and its entry in the log, or neither
-spec moderate(action()) ->
    ok
    | {error,
        not_allowed
        | bad_text
        | no_such_post
        | no_such_account
        | no_such_board
        | no_such_meta
        | not_now}
    | error().
moderate(#{by := By, role := Role, kind := Kind, target := Target, reason := Reason}) ->
    Subject =
        case Target of
            _ when is_binary(Target) -> Target;
            {image, Post, Image} -> {ike_id:to_integer(Post), Image};
            {entry, Entry} -> {entry, ike_id:to_integer(Entry)};
            {meta, Meta} -> {meta, Meta};
            _ -> ike_id:to_integer(Target)
        end,
    done(call({moderate, ike_id:to_integer(By), Role, ike_role:to_binary(Kind), Subject, Reason})).

%% a session is a row, so that it outlives a restart. Hash is the sha-256
%% of what the cookie holds, Expires in unix seconds
-spec open_session(
    Hash :: binary(),
    ike_id:actor(),
    Csrf :: binary(),
    Expires :: integer(),
    ike_role:role() | none
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
                            ok = unkept(Conn),
                            ok = backfilled(Conn),
                            ok = inherited(Conn),
                            ok = republished(Conn),
                            _ = erlang:send_after(?CHECKPOINT, self(), checkpoint),
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
handle_call({post, Actor, Home, Body, Upload, Password, Title}, _From, Conn) when
    is_integer(Actor),
    is_binary(Body),
    (is_binary(Password) orelse Password =:= undefined),
    (is_binary(Title) orelse Title =:= undefined)
->
    %% a post with an image may say nothing else
    Fits =
        (text(Body) orelse (Upload =/= none andalso Body =:= <<>>)) andalso
            (Title =:= undefined orelse titled(Title)),
    Reply =
        case Fits of
            true ->
                Time = erlang:system_time(second),
                Result = ike_db:transaction(Conn, fun() ->
                    case open(Conn, Home) of
                        ok ->
                            case post(Conn, Actor, Home, Time, Body) of
                                {ok, {Id, Threads}} when is_integer(Id) ->
                                    Sealed = <<"UPDATE post SET password = ?2 WHERE id = ?1">>,
                                    _ =
                                        case Password of
                                            undefined -> ok;
                                            _ -> ike_db:q(Conn, Sealed, [Id, {blob, Password}])
                                        end,
                                    _ =
                                        case Title of
                                            undefined ->
                                                ok;
                                            _ ->
                                                ike_db:q(
                                                    Conn,
                                                    <<"UPDATE post SET title = ?2 WHERE id = ?1">>,
                                                    [Id, Title]
                                                )
                                        end,
                                    case attach(Conn, Id, Upload, Time) of
                                        {ok, Assets} ->
                                            case entered(Conn, Assets, Time) of
                                                {ok, Entries} ->
                                                    {ok,
                                                        {Id,
                                                            Threads ++ [{booru, E} || E <- Entries],
                                                            Assets}};
                                                {error, _} = Error ->
                                                    Error
                                            end;
                                        {error, _} = Error ->
                                            Error
                                    end;
                                Other ->
                                    Other
                            end;
                        {error, _} = Error ->
                            Error
                    end
                end),
                case Result of
                    {ok, {Id, Threads, Assets}} when is_list(Assets) ->
                        ok = published(Conn, [A || A <- Assets, is_binary(A)]),
                        committed({ok, {Id, Threads}});
                    Other ->
                        Other
                end;
            false ->
                {error, bad_text}
        end,
    {reply, Reply, Conn};
handle_call({wiki, Name, Actor, Body, Password}, _From, Conn) when
    is_binary(Name),
    is_integer(Actor),
    is_binary(Body),
    (is_binary(Password) orelse Password =:= undefined)
->
    Reply =
        case text(Body) of
            false ->
                {error, bad_text};
            true ->
                Time = erlang:system_time(second),
                committed(
                    ike_db:transaction(Conn, fun() ->
                        revised(Conn, Name, Actor, Body, Password, Time)
                    end)
                )
        end,
    {reply, Reply, Conn};
handle_call({privacy, Meta, Owner, Flag}, _From, Conn) when
    is_integer(Meta), is_integer(Owner), Owner =/= ?NOBODY, (Flag =:= 0 orelse Flag =:= 1)
->
    Mine = <<"SELECT asset FROM meta WHERE id = ?1 AND owner = ?2">>,
    Public = <<"SELECT id FROM meta WHERE asset = ?1 AND private = 0 AND id <> ?2">>,
    Reply =
        case ike_db:q(Conn, Mine, [Meta, Owner]) of
            {ok, [[Asset]]} when is_binary(Asset) ->
                case {Flag, ike_db:q(Conn, Public, [{blob, Asset}, Meta])} of
                    {0, {ok, [[Other]]}} ->
                        {error, {taken, Other}};
                    {_, {ok, _}} ->
                        Set = <<"UPDATE meta SET private = ?2 WHERE id = ?1">>,
                        case ike_db:q(Conn, Set, [Meta, Flag]) of
                            {ok, _} ->
                                ok = published(Conn, [Asset]),
                                ok;
                            {error, _} = Error ->
                                Error
                        end;
                    {_, {error, _} = Error} ->
                        Error
                end;
            {ok, []} ->
                {error, not_yours};
            {ok, Other} ->
                {error, {unexpected, Other}};
            {error, _} = Error ->
                Error
        end,
    {reply, Reply, Conn};
handle_call({sign_meta, Meta, Owner}, _From, Conn) when
    is_integer(Meta), is_integer(Owner), Owner =/= ?NOBODY
->
    Sql = <<"UPDATE meta SET signed = 1 WHERE id = ?1 AND owner = ?2 RETURNING 1">>,
    Reply =
        case ike_db:q(Conn, Sql, [Meta, Owner]) of
            {ok, [_]} -> ok;
            {ok, []} -> {error, not_yours};
            {ok, Other} -> {error, {unexpected, Other}};
            {error, _} = Error -> Error
        end,
    {reply, Reply, Conn};
handle_call({curate, Meta, Account, Signed, Box}, _From, Conn) when
    is_integer(Meta), is_integer(Account), is_boolean(Signed), is_list(Box)
->
    Time = erlang:system_time(second),
    Reply = committed(
        ike_db:transaction(Conn, fun() ->
            curated(Conn, Meta, Account, shown_as(Account, Signed), boxed(Box), Time)
        end)
    ),
    {reply, Reply, Conn};
handle_call({revise, Entry, Account, Signed, Box, Commentary}, _From, Conn) when
    is_integer(Entry),
    is_integer(Account),
    is_boolean(Signed),
    (is_list(Box) orelse Box =:= keep),
    (is_binary(Commentary) orelse Commentary =:= keep)
->
    Time = erlang:system_time(second),
    Reply =
        case Commentary =:= keep orelse Commentary =:= <<>> orelse text(Commentary) of
            false ->
                {error, bad_text};
            true ->
                Result = ike_db:transaction(Conn, fun() ->
                    revised_entry(
                        Conn,
                        Entry,
                        Account,
                        shown_as(Account, Signed),
                        case Box of
                            keep -> keep;
                            _ -> boxed(Box)
                        end,
                        Commentary,
                        Time
                    )
                end),
                case committed(Result) of
                    {ok, _} -> ok;
                    Other -> Other
                end
        end,
    {reply, Reply, Conn};
handle_call({comment, Meta, Actor, Body}, _From, Conn) when
    is_integer(Meta), is_integer(Actor), is_binary(Body)
->
    Time = erlang:system_time(second),
    Reply =
        case text(Body) of
            false ->
                {error, bad_text};
            true ->
                committed(
                    ike_db:transaction(Conn, fun() -> commented(Conn, Meta, Actor, Body, Time) end)
                )
        end,
    {reply, Reply, Conn};
handle_call({tag, Entry, Actor, Add, Remove}, _From, Conn) when
    is_integer(Entry), is_integer(Actor), is_list(Add), is_list(Remove)
->
    Result = ike_db:transaction(Conn, fun() -> tagged(Conn, Entry, Actor, Add, Remove) end),
    Reply =
        case Result of
            {ok, changed} ->
                ike_render:dirty_booru(Entry),
                ok;
            {error, _} = Error ->
                Error;
            Other ->
                {error, {unexpected, Other}}
        end,
    {reply, Reply, Conn};
handle_call({report, Post, Reason}, _From, Conn) when is_integer(Post), is_binary(Reason) ->
    Insert = <<
        "INSERT INTO report (post, reason, time)"
        " SELECT s.id, ?2, ?3 FROM shown s JOIN thread t ON t.root = s.thread"
        " JOIN board b ON b.id = t.board WHERE s.id = ?1 AND b.log = 0 RETURNING id"
    >>,
    Reply =
        case byte_size(Reason) =< ?MAX_REASON andalso text(Reason) of
            false ->
                {error, bad_text};
            true ->
                case ike_db:q(Conn, Insert, [Post, Reason, erlang:system_time(second)]) of
                    {ok, [_]} -> ok;
                    {ok, _} -> {error, no_such_post};
                    {error, _} = Error -> Error
                end
        end,
    {reply, Reply, Conn};
handle_call({dismiss, Report}, _From, Conn) when is_integer(Report) ->
    Update = <<"UPDATE report SET done = 1 WHERE id = ?1 AND done = 0 RETURNING id">>,
    Reply =
        case ike_db:q(Conn, Update, [Report]) of
            {ok, [_]} -> ok;
            {ok, _} -> {error, no_such_report};
            {error, _} = Error -> Error
        end,
    {reply, Reply, Conn};
handle_call({retract, Post, Who}, _From, Conn) when is_integer(Post) ->
    %% shown or hidden, not on the log; and for an account, its own
    Sql = <<
        "SELECT p.thread, p.state, b.name, p.actor FROM post p JOIN thread t ON t.root = p.thread"
        " JOIN board b ON b.id = t.board WHERE p.id = ?1 AND b.log = 0"
    >>,
    Reply =
        case ike_db:q(Conn, Sql, [Post]) of
            {ok, [[Thread, State, Board, Actor]]} when
                is_integer(Thread), is_integer(State), is_binary(Board)
            ->
                case {State < 2, Who =:= none orelse Who =:= Actor} of
                    {true, true} ->
                        Time = erlang:system_time(second),
                        Result = ike_db:transaction(Conn, fun() ->
                            retracted(Conn, Post, Thread, Board, Time)
                        end),
                        case Result of
                            {ok, #{threads := T, gone := G, boards := B, assets := A}} when
                                is_list(T), is_list(G), is_list(B), is_list(A)
                            ->
                                ok = published(Conn, [H || H <- A, is_binary(H)]),
                                followed(Conn, T, G, B, [], false);
                            {error, _} = Error ->
                                Error;
                            Other ->
                                {error, {unexpected, Other}}
                        end;
                    {false, _} ->
                        {error, not_now};
                    {_, false} ->
                        {error, not_yours}
                end;
            {ok, _} ->
                {error, no_such_post};
            {error, _} = Error ->
                Error
        end,
    {reply, Reply, Conn};
handle_call({moderate, By, Role, Kind, Target, Reason}, _From, Conn) when
    is_integer(By), is_binary(Kind), is_binary(Reason)
->
    Reply =
        case {ike_role:check(Role), ike_role:kind(Kind)} of
            {none, _} -> {error, not_allowed};
            {_, error} -> {error, bad_request};
            {Held, {ok, Rung}} -> moderated(Conn, {By, Held}, Rung, Target, Reason)
        end,
    {reply, Reply, Conn};
handle_call(
    {upload, Actor, Original, Type, W, H, Stored, Thumb, Traits, Private0, Signed,
        {Family, Axes, Commentary}},
    _From,
    Conn
) when
    is_integer(Actor),
    is_binary(Original),
    is_binary(Stored),
    is_binary(Thumb),
    is_binary(Traits),
    (Private0 =:= 0 orelse Private0 =:= 1),
    (Signed =:= 0 orelse Signed =:= 1)
->
    %% nobody's uploads are everyone's: never private
    Private =
        case Actor of
            ?NOBODY -> 0;
            _ -> Private0
        end,
    %% the name is what the bytes are, worked out here and not taken
    %% from the stripper's word
    Hash = crypto:hash(sha256, Stored),
    Name = binary:encode_hex(Hash, lowercase),
    Dir = ike_config:assets_dir(),
    Blocked = <<"SELECT 1 FROM blocklist WHERE hash IN (?1, ?2)">>,
    Reply =
        %% the files first: a row without its file would be a lie, a file
        %% without its row is swept at the next start. but nothing at all
        %% of what is blocked, as it came or as it was stripped
        case ike_db:q(Conn, Blocked, [{blob, Hash}, {blob, Original}]) of
            {ok, [_ | _]} ->
                {error, refused};
            _ ->
                case {kept(Dir, Name, Stored), kept(Dir, <<Name/binary, ".thumb">>, Thumb)} of
                    {ok, ok} ->
                        Insert = <<
                            "INSERT INTO asset (hash, type, format, filetype, width, height,"
                            " traits, family, axes) VALUES"
                            " (?1, CASE WHEN ?2 IN ('jpeg', 'png', 'webp') THEN ?2 END,"
                            " CASE WHEN ?2 IN ('jpeg', 'png', 'webp', 'webm', 'mp4') THEN ?2 END,"
                            " ?2, nullif(?3, 0), nullif(?4, 0), ?5, ?6, ?7)"
                            " ON CONFLICT (hash) DO NOTHING"
                        >>,
                        Staged = <<
                            "INSERT INTO upload (asset, original, actor, time, commentary)"
                            " VALUES (?1, ?2, ?3, ?4, ?5) RETURNING id"
                        >>,
                        %% a meta of the uploader's own, unless they have one,
                        %% or the bytes have a public one: someone else's
                        %% private meta is not seen here (lux, Q41)
                        Meta = <<
                            "INSERT INTO meta (asset, owner, time, private, signed)"
                            " SELECT ?1, ?2, ?3, ?4, ?5 WHERE NOT EXISTS (SELECT 1 FROM meta"
                            " WHERE asset = ?1 AND (owner = ?2 OR private = 0))"
                        >>,
                        Time = erlang:system_time(second),
                        Done = committed(
                            ike_db:transaction(Conn, fun() ->
                                case
                                    ike_db:q(Conn, Insert, [
                                        {blob, Hash}, Type, W, H, Traits, Family, Axes
                                    ])
                                of
                                    {ok, _} ->
                                        case
                                            {
                                                ike_db:q(Conn, Staged, [
                                                    {blob, Hash},
                                                    {blob, Original},
                                                    Actor,
                                                    Time,
                                                    Commentary
                                                ]),
                                                ike_db:q(Conn, Meta, [
                                                    {blob, Hash}, Actor, Time, Private, Signed
                                                ])
                                            }
                                        of
                                            {{ok, [[Id]]}, {ok, _}} -> {ok, {Id, []}};
                                            {{ok, Other}, {ok, _}} -> {error, {unexpected, Other}};
                                            {{error, _} = Error, _} -> Error;
                                            {_, {error, _} = Error} -> Error
                                        end;
                                    {error, _} = Error ->
                                        Error
                                end
                            end)
                        ),
                        %% a public meta's files are on the media origin
                        case Done of
                            {ok, _} -> ok = published(Conn, [Hash]);
                            _ -> ok
                        end,
                        Done;
                    _ ->
                        {error, unwritable}
                end
        end,
    {reply, Reply, Conn};
handle_call({open_session, Hash, Actor, Csrf, Expires, Role0}, _From, Conn) when
    is_binary(Hash), is_integer(Actor), is_binary(Csrf), is_integer(Expires)
->
    Role = ike_role:check(Role0),
    {Name, Boards} = ike_role:encode(Role),
    %% an account suspended while it was logging in gets no session
    Insert = <<
        "INSERT INTO session (hash, actor, csrf, expires, role, boards)"
        " SELECT ?1, id, ?3, ?4, ?5, ?6 FROM actor WHERE id = ?2 AND banned = 0"
        " RETURNING actor"
    >>,
    %% the rank the account has now, demotions included: what banning it takes
    Rank = <<"UPDATE actor SET rank = ?2 WHERE id = ?1">>,
    Reply =
        case
            ike_db:transaction(Conn, fun() ->
                case ike_db:q(Conn, Insert, [{blob, Hash}, Actor, Csrf, Expires, Name, Boards]) of
                    {ok, [_]} ->
                        case ike_db:q(Conn, Rank, [Actor, ike_role:rank(Role)]) of
                            {ok, _} -> ok;
                            {error, _} = Error -> Error
                        end;
                    {ok, _} ->
                        {error, suspended};
                    {error, _} = Error ->
                        Error
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

%% what a purge overwrote is in the write-ahead log until the log is
%% folded back, and a reader can hold that up: the purge tries at once,
%% and this tries again, every so often
-spec handle_info(term(), ike_db:writer()) -> {noreply, ike_db:writer()}.
handle_info(checkpoint, Conn) ->
    _ = ike_db:exec(Conn, <<"PRAGMA wal_checkpoint(TRUNCATE)">>),
    _ = erlang:send_after(?CHECKPOINT, self(), checkpoint),
    {noreply, Conn};
handle_info(_Info, Conn) ->
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
-spec committed(term()) -> term().
committed({ok, {Id, Threads}}) when is_integer(Id), is_list(Threads) ->
    [ike_render:dirty(Thread) || Thread <- Threads, is_integer(Thread)],
    [ike_render:dirty_booru(E) || {booru, E} <- Threads, is_integer(E)],
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
                {ok, #{
                    threads := T,
                    gone := G,
                    boards := B,
                    drop := D,
                    scrub := S,
                    assets := A,
                    unlinked := U,
                    entries := E,
                    gone_entries := GE
                }} when
                    is_list(T),
                    is_list(G),
                    is_list(B),
                    is_list(D),
                    is_boolean(S),
                    is_list(A),
                    is_list(U),
                    is_list(E),
                    is_list(GE)
                ->
                    ok = published(Conn, [H || H <- A, is_binary(H)]),
                    ok = unlinked([X || X <- U, is_binary(X)]),
                    ok = entries_followed([X || X <- E, is_integer(X)], [
                        X
                     || X <- GE, is_integer(X)
                    ]),
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
    [ike_render:dirty_booru(E) || {booru, E} <- Threads, is_integer(E)],
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
        "SELECT DISTINCT b.name, s.thread FROM shown s JOIN thread t ON t.root = s.thread"
        " JOIN board b ON b.id = t.board"
    >>,
    case ike_db:q(Conn, Sql, []) of
        {ok, Rows} ->
            Kept =
                #{
                    page(Pages, Board, integer_to_binary(Root)) => true
                 || [Board, Root] <- Rows, is_binary(Board), is_integer(Root)
                },
            Entries =
                case ike_db:q(Conn, <<"SELECT id FROM shown_entry">>, []) of
                    {ok, Es} ->
                        #{
                            <<Pages/binary, "/booru/", (integer_to_binary(E))/binary, ".html">> =>
                                true
                         || [E] <- Es, is_integer(E)
                        };
                    {error, _} ->
                        #{}
                end,
            Found =
                filelib:wildcard(binary_to_list(<<Pages/binary, "/board/*/*.html">>)) ++
                    filelib:wildcard(binary_to_list(<<Pages/binary, "/booru/*.html">>)),
            [
                file:delete(File)
             || File <- Found,
                not maps:is_key(unicode:characters_to_binary(File), maps:merge(Kept, Entries))
            ],
            ok;
        {error, _} ->
            ok
    end.

%% an asset's file, written whole under another name and renamed; one
%% that is there already is the same bytes, since its name is their hash
-spec kept(binary(), binary(), binary()) -> ok | error().
kept(Dir, Name, Bytes) ->
    Path = <<Dir/binary, "/", Name/binary>>,
    case filelib:is_regular(Path) of
        true ->
            ok;
        false ->
            Tmp = <<Path/binary, ".tmp">>,
            case filelib:ensure_path(Dir) of
                ok ->
                    case file:write_file(Tmp, Bytes) of
                        ok ->
                            file:rename(Tmp, Path);
                        {error, _} = Error ->
                            _ = file:delete(Tmp),
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end
    end.

%% at start: an asset's files with no row behind them, and any half
%% written, are unlinked. it is what a stop between rename and commit
%% leaves
-spec unkept(ike_db:writer()) -> ok.
unkept(Conn) ->
    Dir = ike_config:assets_dir(),
    case ike_db:q(Conn, <<"SELECT hash FROM asset">>, []) of
        {ok, Rows} ->
            Known = #{binary:encode_hex(H, lowercase) => true || [H] <- Rows, is_binary(H)},
            case file:list_dir(Dir) of
                {ok, Files} ->
                    [
                        file:delete(filename:join(Dir, F))
                     || F <- Files, not maps:is_key(asset_name(F), Known)
                    ],
                    ok;
                {error, _} ->
                    ok
            end;
        {error, _} ->
            ok
    end.

%% whose file a file is: <hash> or <hash>.thumb; anything else is none
-spec asset_name(file:filename()) -> binary().
asset_name(File) ->
    case unicode:characters_to_binary(File) of
        <<Hex:64/binary>> -> Hex;
        <<Hex:64/binary, ".thumb">> -> Hex;
        _ -> <<>>
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
        "SELECT 1 FROM shown s JOIN thread t ON t.root = s.thread"
        " JOIN board b ON b.id = t.board WHERE s.thread = ?1 AND b.log = 0 LIMIT 1"
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
%% the trunk is opened to nobody's comments, or shut, by an admin only
%% (lux): a moderator may not
act(_Conn, {_, Role}, Kind, <<"trunk">>, _Reason, _Time) when
    (Kind =:= lock orelse Kind =:= unlock), Role =/= admin
->
    {error, not_allowed};
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
    Rank = <<"SELECT rank FROM actor WHERE id = ?1">>,
    case ike_db:q(Conn, Rank, [Account]) of
        {ok, [[Of]]} when is_integer(Of) ->
            case permits(Who, unban, #{board => any, account => Of, undo => 0}, Account) of
                true -> unban(Conn, Who, Account, Reason, Time);
                false -> {error, not_allowed}
            end;
        {ok, _} ->
            {error, no_such_account};
        {error, _} = Error ->
            Error
    end;
act(Conn, Who, Kind, Post, Reason, Time) when is_integer(Post) ->
    act(Conn, Who, Kind, {Post, -1}, Reason, Time);
act(Conn, Who, Kind, {meta, Meta}, Reason, Time) when
    is_integer(Meta),
    (Kind =:= hide orelse Kind =:= unhide orelse Kind =:= trash orelse Kind =:= restore)
->
    %% a meta is moderated as a post is, on the trunk as a board would be
    Sql = <<
        "SELECT m.state, m.asset, (SELECT role FROM action WHERE meta = m.id"
        " AND kind IN ('hide', 'trash') ORDER BY entry DESC LIMIT 1)"
        " FROM meta m WHERE m.id = ?1"
    >>,
    case ike_db:q(Conn, Sql, [Meta]) of
        {ok, [[State, Asset, Undo]]} when is_integer(State), is_binary(Asset) ->
            Facts = #{board => <<"trunk">>, account => 0, undo => ike_role:rank_of(Undo)},
            To =
                case {Kind, State} of
                    {hide, 0} -> {ok, 1};
                    {unhide, 1} -> {ok, 0};
                    {trash, S} when S < 2 -> {ok, 2};
                    {restore, 2} -> {ok, 0};
                    _ -> not_now
                end,
            case {permits(Who, Kind, Facts, 0), To} of
                {false, _} ->
                    {error, not_allowed};
                {true, not_now} ->
                    {error, not_now};
                {true, {ok, New}} ->
                    %% by its number: nothing of its bytes
                    Text = <<
                        (ike_role:to_binary(Kind))/binary,
                        " meta #",
                        (integer_to_binary(Meta))/binary
                    >>,
                    %% the log's row just made is the newest
                    Logged =
                        <<"UPDATE action SET meta = ?1 WHERE entry = (SELECT max(entry) FROM action)">>,
                    case
                        log(Conn, Who, Kind, Text, Reason, Time, {undefined, undefined, undefined})
                    of
                        {ok, Threads} ->
                            Steps = [
                                {Logged, [Meta]},
                                {<<"UPDATE meta SET state = ?2 WHERE id = ?1">>, [Meta, New]}
                            ],
                            case steps(Conn, Steps) of
                                ok -> {ok, (effects())#{threads := Threads, assets := [Asset]}};
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error ->
                            Error
                    end
            end;
        {ok, []} ->
            {error, no_such_meta};
        {ok, Other} ->
            {error, {unexpected, Other}};
        {error, _} = Error ->
            Error
    end;
act(Conn, Who, Kind, {entry, Entry}, Reason, Time) when
    is_integer(Entry),
    (Kind =:= hide orelse Kind =:= unhide orelse Kind =:= trash orelse Kind =:= restore)
->
    %% an entry is moderated as a post is, on the booru as a board would
    %% be (a janitor of /booru/ keeps it)
    Sql = <<
        "SELECT b.state, (SELECT role FROM action WHERE booru = b.id AND kind IN ('hide', 'trash')"
        " ORDER BY entry DESC LIMIT 1),"
        " (SELECT v.asset FROM booru_version v WHERE v.booru = b.id ORDER BY v.position DESC LIMIT 1)"
        " FROM booru b WHERE b.id = ?1"
    >>,
    case ike_db:q(Conn, Sql, [Entry]) of
        {ok, [[State, Undo, Asset]]} when is_integer(State) ->
            Facts = #{board => <<"booru">>, account => 0, undo => ike_role:rank_of(Undo)},
            To =
                case {Kind, State} of
                    {hide, 0} -> {ok, 1};
                    {unhide, 1} -> {ok, 0};
                    {trash, S} when S < 2 -> {ok, 2};
                    {restore, 2} -> {ok, 0};
                    _ -> not_now
                end,
            case {permits(Who, Kind, Facts, 0), To} of
                {false, _} ->
                    {error, not_allowed};
                {true, not_now} ->
                    {error, not_now};
                {true, {ok, New}} ->
                    E = integer_to_binary(Entry),
                    Text = <<(ike_role:to_binary(Kind))/binary, " ##", E/binary>>,
                    case
                        log(
                            Conn,
                            Who,
                            Kind,
                            Text,
                            Reason,
                            Time,
                            {undefined, undefined, undefined, Entry},
                            entry
                        )
                    of
                        {ok, Logged} ->
                            case
                                ike_db:q(Conn, <<"UPDATE booru SET state = ?2 WHERE id = ?1">>, [
                                    Entry, New
                                ])
                            of
                                {ok, _} ->
                                    %% the posts that point at it show it, or not
                                    Pointing = <<
                                        "SELECT DISTINCT p.thread FROM link l JOIN post p ON p.id = l.source"
                                        " WHERE l.booru = ?1"
                                    >>,
                                    Threads =
                                        case ike_db:q(Conn, Pointing, [Entry]) of
                                            {ok, Rows} -> [T || [T] <- Rows, is_integer(T)];
                                            {error, _} -> []
                                        end,
                                    {ok, (effects())#{
                                        threads := Logged ++ Threads,
                                        assets := [A || A <- [Asset], is_binary(A)],
                                        entries := [Entry],
                                        gone_entries := [Entry || New =/= 0]
                                    }};
                                {error, _} = Error ->
                                    Error
                            end;
                        {error, _} = Error ->
                            Error
                    end
            end;
        {ok, _} ->
            {error, no_such_post};
        {error, _} = Error ->
            Error
    end;
act(Conn, Who, Kind, {Post, Position}, Reason, Time) when is_integer(Post), is_integer(Position) ->
    %% nothing on the log is ever taken down. undo: who put the post in
    %% the state it is in, by role
    Sql = <<
        "SELECT p.thread, p.state, t.id, t.kind = 'local', t.banned, b.name, t.rank,"
        " (SELECT role FROM action WHERE post = p.id AND kind IN ('hide', 'trash')"
        " ORDER BY entry DESC LIMIT 1),"
        " (SELECT role FROM action WHERE post = p.id AND kind = 'block'"
        " ORDER BY entry DESC LIMIT 1),"
        " (SELECT asset FROM post_image WHERE post = p.id AND position = ?2)"
        " FROM post p JOIN thread h ON h.root = p.thread JOIN board b ON b.id = h.board"
        " JOIN actor a ON a.id = p.actor"
        %% the account a ban reaches: the signer, or the one behind the
        %% images of an unsigned post (one account attached them all)
        " JOIN actor t ON t.id = CASE WHEN a.kind = 'local' THEN p.actor ELSE coalesce("
        "(SELECT u.actor FROM upload u WHERE u.post = p.id ORDER BY u.id LIMIT 1), p.actor) END"
        " WHERE p.id = ?1 AND b.log = 0"
    >>,
    case ike_db:q(Conn, Sql, [Post, Position]) of
        {ok, [[Thread, State, Actor, Local, Banned, Board, Rank, Undo0, Blocker, Asset]]} when
            is_integer(Thread),
            is_integer(State),
            is_integer(Actor),
            is_binary(Board),
            is_integer(Rank)
        ->
            Undo =
                case Kind of
                    unblock -> Blocker;
                    _ -> Undo0
                end,
            Facts = #{board => Board, account => Rank, undo => ike_role:rank_of(Undo)},
            case permits(Who, Kind, Facts, Actor) of
                true when Kind =:= block; Kind =:= unblock; Kind =:= purge_image ->
                    image(Conn, Who, Kind, {Post, Position, Thread, Asset}, {Reason, Time});
                true ->
                    ladder(Conn, Who, Kind, {Post, Thread, Board, Actor}, {State, Local, Banned}, {
                        Reason, Time
                    });
                false ->
                    {error, not_allowed}
            end;
        {ok, _} ->
            {error, no_such_post};
        {error, _} = Error ->
            Error
    end;
act(_Conn, _Who, _Kind, _Target, _Reason, _Time) ->
    {error, bad_request}.

%% the rules of ike_role, with the actor's own account told apart
-spec permits(who(), ike_role:kind(), map(), integer()) -> boolean().
permits(system, Kind, _Facts, _Account) ->
    ike_role:permits(system, Kind, #{board => any, self => false, account => 0, undo => 0});
permits({By, Role}, Kind, #{board := Board, account := Rank, undo := Undo}, Account) when
    is_binary(Board) orelse Board =:= any,
    is_integer(Rank),
    Rank >= 0,
    Rank =< 3,
    is_integer(Undo),
    Undo >= 0,
    Undo =< 4
->
    ike_role:permits(Role, Kind, #{
        board => Board, self => By =:= Account, account => Rank, undo => Undo
    });
permits(_Who, _Kind, _Facts, _Account) ->
    false.

-spec unban(ike_db:writer(), who(), integer(), binary(), integer()) -> {ok, effects()} | error().
unban(Conn, Who, Account, Reason, Time) ->
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
    end.

-spec ladder(
    ike_db:writer(),
    who(),
    ike_role:kind(),
    {integer(), integer(), binary(), integer()},
    {integer(), term(), term()},
    {binary(), integer()}
) -> {ok, effects()} | error().
ladder(Conn, Who, Kind, {Post, Thread, Board, Actor}, {State, Local, Banned}, {Reason, Time}) ->
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
        {trash, Shown, _, _} when Shown < 2 ->
            %% kept, and when it was trashed (purge_at, by its old name)
            state(Conn, Who, Kind, {Post, Thread, Board}, {2, Time}, Reason, Time);
        {restore, 2, _, _} ->
            state(Conn, Who, Kind, {Post, Thread, Board}, {0, undefined}, Reason, Time);
        {purge, _, _, _} ->
            state(Conn, Who, Kind, {Post, Thread, Board}, purge, Reason, Time);
        _ ->
            {error, not_now}
    end.

%% a post's image: its hashes blocked, unblocked, or the image purged
%% wherever it is used (hazard G3). nothing but the hashes is kept: the
%% stored one and every one it came as, so that it is refused when it
%% comes again, whatever metadata it brings
-spec image(
    ike_db:writer(), who(), ike_role:kind(), {integer(), term(), integer(), term()}, {
        binary(), integer()
    }
) ->
    {ok, effects()} | error().
image(Conn, Who, Kind, {Post, Position, Thread, Hash}, {Reason, Time}) when
    is_binary(Hash), is_integer(Position)
->
    Text =
        <<
            (words(Kind))/binary,
            " ",
            (integer_to_binary(Position + 1))/binary,
            " of >>",
            (integer_to_binary(Post))/binary
        >>,
    Hashes =
        case
            ike_db:q(Conn, <<"SELECT DISTINCT original FROM upload WHERE asset = ?1">>, [
                {blob, Hash}
            ])
        of
            {ok, Rows} -> [Hash | [O || [O] <- Rows, is_binary(O)]];
            {error, _} -> [Hash]
        end,
    Blocked =
        case ike_db:q(Conn, <<"SELECT 1 FROM blocklist WHERE hash = ?1">>, [{blob, Hash}]) of
            {ok, [_]} -> true;
            _ -> false
        end,
    case {Kind, Blocked} of
        {block, true} ->
            {error, not_now};
        {unblock, false} ->
            {error, not_now};
        _ ->
            case log(Conn, Who, Kind, Text, Reason, Time, {Post, undefined, undefined}) of
                {ok, Logged} ->
                    Holding =
                        case
                            ike_db:q(Conn, <<"SELECT booru FROM booru_version WHERE asset = ?1">>, [
                                {blob, Hash}
                            ])
                        of
                            {ok, Bs} -> [B || [B] <- Bs, is_integer(B)];
                            {error, _} -> []
                        end,
                    case imaged(Conn, Kind, Hash, Hashes, Time) of
                        {ok, Threads} ->
                            Purged = Kind =:= purge_image,
                            {ok, (effects())#{
                                threads := [Thread | Logged] ++ Threads,
                                scrub := Purged,
                                unlinked := [binary:encode_hex(Hash, lowercase) || Purged],
                                entries := Holding
                            }};
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end
    end;
image(_Conn, _Who, _Kind, _Post, _Why) ->
    {error, not_now}.

-spec words(ike_role:kind()) -> binary().
words(block) -> <<"block image">>;
words(unblock) -> <<"unblock image">>;
words(_) -> <<"purge image">>.

-spec imaged(ike_db:writer(), ike_role:kind(), binary(), [binary()], integer()) ->
    {ok, [term()]} | error().
imaged(Conn, block, _Hash, Hashes, Time) ->
    Insert = <<"INSERT INTO blocklist (hash, time) VALUES (?1, ?2) ON CONFLICT DO NOTHING">>,
    case each_hash(Conn, Insert, Hashes, [Time]) of
        ok -> {ok, []};
        {error, _} = Error -> Error
    end;
imaged(Conn, unblock, _Hash, Hashes, _Time) ->
    case each_hash(Conn, <<"DELETE FROM blocklist WHERE hash = ?1">>, Hashes, []) of
        ok -> {ok, []};
        {error, _} = Error -> Error
    end;
imaged(Conn, purge_image, Hash, Hashes, Time) ->
    %% every post that showed it keeps its text and says the image is
    %% gone; every upload of it goes, staged or not; then the asset
    Using = <<
        "SELECT DISTINCT p.thread FROM post_image pa JOIN post p ON p.id = pa.post"
        " WHERE pa.asset = ?1"
    >>,
    case {imaged(Conn, block, Hash, Hashes, Time), ike_db:q(Conn, Using, [{blob, Hash}])} of
        {{ok, _}, {ok, Rows}} ->
            Steps = [
                <<"UPDATE post_image SET asset = NULL, gone = 1 WHERE asset = ?1">>,
                %% an entry keeps the version, empty: a gap
                <<"UPDATE booru_version SET asset = NULL WHERE asset = ?1">>,
                <<"DELETE FROM upload WHERE asset = ?1">>,
                <<"UPDATE action SET meta = NULL WHERE meta IN (SELECT id FROM meta WHERE asset = ?1)">>,
                <<"DELETE FROM meta WHERE asset = ?1">>,
                <<"DELETE FROM asset WHERE hash = ?1">>
            ],
            case each(Conn, [{blob, Hash}], Steps) of
                ok -> {ok, [T || [T] <- Rows]};
                {error, _} = Error -> Error
            end;
        {{error, _} = Error, _} ->
            Error;
        {_, {error, _} = Error} ->
            Error
    end;
imaged(_Conn, _Kind, _Hash, _Hashes, _Time) ->
    {error, bad_request}.

-spec each_hash(ike_db:writer(), binary(), [binary()], [term()]) -> ok | error().
each_hash(Conn, Sql, [Hash | Hashes], More) ->
    case ike_db:q(Conn, Sql, [{blob, Hash} | More]) of
        {ok, _} -> each_hash(Conn, Sql, Hashes, More);
        {error, _} = Error -> Error
    end;
each_hash(_Conn, _Sql, [], _More) ->
    ok.

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
    #{
        threads => [],
        gone => [],
        boards => [],
        drop => [],
        scrub => false,
        assets => [],
        unlinked => [],
        entries => [],
        gone_entries => []
    }.

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

%% whether anything of a thread is in view: on most boards, whether its
%% first post is; on the wiki, whether any post is (0020)
-spec standing(ike_db:writer(), integer()) -> boolean().
standing(Conn, Thread) ->
    case ike_db:q(Conn, <<"SELECT 1 FROM shown WHERE thread = ?1 LIMIT 1">>, [Thread]) of
        {ok, [_]} -> true;
        _ -> false
    end.

%% a post out of sight, back in it, or gone for good; a thread's first
%% post takes the thread with it, but on the wiki only once nothing else
%% of it is in view
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
    Pictured = <<
        "SELECT pa.asset FROM post_image pa JOIN post p ON p.id = pa.post"
        " WHERE (p.id = ?1 OR (?1 = ?2 AND p.thread = ?2)) AND pa.asset IS NOT NULL"
    >>,
    case {ike_db:q(Conn, Around, [Post, Thread]), ike_db:q(Conn, Pictured, [Post, Thread])} of
        {{ok, Rows}, {ok, Assets}} ->
            case log(Conn, Who, Kind, Text, Reason, Time, {Post, undefined, undefined}) of
                {ok, Logged} ->
                    case changed(Conn, Post, Thread, To) of
                        {ok, Destroyed} ->
                            Gone = [
                                {Board, Thread}
                             || Post =:= Thread, not standing(Conn, Thread)
                            ],
                            {ok, #{
                                threads => [Thread | Logged] ++ [T || [T] <- Rows],
                                gone => Gone,
                                boards => [Board],
                                drop => [],
                                scrub => To =:= purge,
                                assets => [A || [A] <- Assets, is_binary(A)],
                                unlinked => Destroyed,
                                entries => [],
                                gone_entries => []
                            }};
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {{error, _} = Error, _} ->
            Error;
        {_, {error, _} = Error} ->
            Error
    end.

-spec revised(ike_db:writer(), binary(), integer(), binary(), binary() | undefined, integer()) ->
    {ok, {integer(), [term()]}} | error().
revised(Conn, Name, Actor, Body, Password, Time) ->
    %% the threads that point at the name: it is a page now
    Pointing = <<
        "SELECT DISTINCT p.thread FROM link l JOIN post p ON p.id = l.source WHERE l.name = ?1"
    >>,
    case ike_db:q(Conn, <<"SELECT thread FROM page WHERE name = ?1">>, [Name]) of
        {ok, []} ->
            case post(Conn, Actor, {new, <<"wiki">>}, Time, Body) of
                {ok, {Id, Threads}} ->
                    Steps = [
                        {<<"UPDATE post SET revision = 1, title = ?2 WHERE id = ?1">>, [Id, Name]},
                        {<<"INSERT INTO page (name, thread) VALUES (?1, ?2)">>, [Name, Id]}
                        | sealing(Id, Password)
                    ],
                    case {steps(Conn, Steps), ike_db:q(Conn, Pointing, [Name])} of
                        {ok, {ok, Rows}} -> {ok, {Id, Threads ++ [T || [T] <- Rows]}};
                        {{error, _} = Error, _} -> Error;
                        {_, {error, _} = Error} -> Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {ok, [[Thread]]} when is_integer(Thread) ->
            case newest(Conn, Thread) of
                {ok, {Base, Last}} when Actor =/= ?NOBODY, is_integer(Last), Base =:= Last ->
                    case ike_db:q(Conn, <<"SELECT actor FROM post WHERE id = ?1">>, [Last]) of
                        {ok, [[Actor]]} -> amended(Conn, Last, Thread, Body, Time);
                        {ok, _} -> stacked(Conn, Actor, Thread, Body, Password, Base, Time);
                        {error, _} = Error -> Error
                    end;
                {ok, {Base, _}} ->
                    stacked(Conn, Actor, Thread, Body, Password, Base, Time);
                {error, _} = Error ->
                    Error
            end;
        {ok, _} ->
            {error, no_such_page};
        {error, _} = Error ->
            Error
    end.

%% a page's newest revision there to be shown, and its thread's newest
%% post (undefined, the SQL null, where none is)
-spec newest(ike_db:writer(), integer()) ->
    {ok, {integer() | undefined, integer() | undefined}} | error().
newest(Conn, Thread) ->
    Sql = <<
        "SELECT (SELECT max(p.id) FROM shown s JOIN post p ON p.id = s.id"
        " WHERE s.thread = ?1 AND p.revision = 1),"
        " (SELECT max(s.id) FROM shown s WHERE s.thread = ?1)"
    >>,
    case ike_db:q(Conn, Sql, [Thread]) of
        {ok, [[Base, Last]]} when
            (is_integer(Base) orelse Base =:= undefined),
            (is_integer(Last) orelse Last =:= undefined)
        ->
            {ok, {Base, Last}};
        {ok, Rows} ->
            {error, {unexpected, Rows}};
        {error, _} = Error ->
            Error
    end.

%% a revision on top of Base, whatever the edit was opened on
-spec stacked(
    ike_db:writer(),
    integer(),
    integer(),
    binary(),
    binary() | undefined,
    integer() | undefined,
    integer()
) ->
    {ok, {integer(), [term()]}} | error().
stacked(Conn, Actor, Thread, Body, Password, Base, Time) ->
    case insert(Conn, Actor, Thread, Time, Body) of
        {ok, {Id, Threads}} ->
            Mark = {<<"UPDATE post SET revision = 1, base = ?2 WHERE id = ?1">>, [Id, Base]},
            case steps(Conn, [Mark | sealing(Id, Password)]) of
                ok -> {ok, {Id, Threads}};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

%% the revision Id made over with the new text: its links read again from
%% it, and the pages it pointed at before as well as those it points at
%% now made again. its time is the edit's
-spec amended(ike_db:writer(), integer(), integer(), binary(), integer()) ->
    {ok, {integer(), [term()]}} | error().
amended(Conn, Id, Thread, Body, Time) ->
    Was = <<"SELECT booru FROM link WHERE source = ?1 AND booru IS NOT NULL">>,
    case {touched(Conn, Id, Thread), ike_db:q(Conn, Was, [Id])} of
        {{ok, {Id, Before}}, {ok, Entries0}} ->
            Steps = [
                {<<"DELETE FROM link WHERE source = ?1">>, [Id]},
                {<<"UPDATE post SET body = ?2, time = ?3 WHERE id = ?1">>, [Id, Body, Time]}
            ],
            Entries = ike_text:entries(Body),
            case
                {
                    steps(Conn, Steps),
                    link(Conn, Id, ike_text:targets(Body)),
                    entry_links(Conn, Id, Entries),
                    page_links(Conn, Id, ike_text:pages(Body))
                }
            of
                {ok, ok, ok, ok} ->
                    case touched(Conn, Id, Thread) of
                        {ok, {Id, After}} ->
                            Booru = [{booru, E} || E <- Entries] ++ [{booru, E} || [E] <- Entries0],
                            {ok, {Id, Before ++ After ++ Booru}};
                        {ok, Other} ->
                            {error, {unexpected, Other}};
                        {error, _} = Error ->
                            Error
                    end;
                {{error, _} = Error, _, _, _} ->
                    Error;
                {_, {error, _} = Error, _, _} ->
                    Error;
                {_, _, {error, _} = Error, _} ->
                    Error;
                {_, _, _, {error, _} = Error} ->
                    Error
            end;
        {{ok, Other}, _} ->
            {error, {unexpected, Other}};
        {{error, _} = Error, _} ->
            Error;
        {_, {error, _} = Error} ->
            Error
    end.

%% the password a revision is retracted with, when one was given
-spec sealing(integer(), binary() | undefined) -> [{binary(), [term()]}].
sealing(_Id, undefined) ->
    [];
sealing(Id, Password) ->
    [{<<"UPDATE post SET password = ?2 WHERE id = ?1">>, [Id, {blob, Password}]}].

-spec steps(ike_db:writer(), [{binary(), [term()]}]) -> ok | error().
steps(Conn, [{Sql, Args} | Rest]) ->
    case ike_db:q(Conn, Sql, Args) of
        {ok, _} -> steps(Conn, Rest);
        {error, _} = Error -> Error
    end;
steps(_Conn, []) ->
    ok.

-spec maybe_integer(term()) -> integer() | undefined.
maybe_integer(N) when is_integer(N) -> N;
maybe_integer(_) -> undefined.

%% who a revision is posted as: the account, if it signs, else nobody
-spec shown_as(integer(), boolean()) -> integer().
shown_as(Account, true) -> Account;
shown_as(_Account, false) -> ?NOBODY.

%% a box as the writer takes it: lines of names, each a binary
-spec boxed([term()]) -> [[binary()]].
boxed(Box) ->
    [[W || W <- Line, is_binary(W)] || Line <- Box, is_list(Line)].

-spec curated(ike_db:writer(), integer(), integer(), integer(), [[binary()]], integer()) ->
    {ok, {integer(), [term()]}} | error().
curated(Conn, Meta, Account, Shown, Box, Time) ->
    Sql = <<"SELECT asset, private, state, thread, owner, signed FROM meta WHERE id = ?1">>,
    case ike_db:q(Conn, Sql, [Meta]) of
        {ok, [[Asset, 0, 0, Thread1, Owner, Signed]]} when is_binary(Asset) ->
            Thread0 = maybe_integer(Thread1),
            Has = <<"SELECT booru FROM booru_version WHERE asset = ?1 LIMIT 1">>,
            case ike_db:q(Conn, Has, [{blob, Asset}]) of
                {ok, [[Known]]} ->
                    {error, {curated, Known}};
                {ok, []} ->
                    case entered(Conn, [Asset], Time, []) of
                        {ok, [Entry]} ->
                            case boxed_tags(Conn, Entry, Account, Box, Time) of
                                ok ->
                                    Body = ike_tag:revision(Box, <<>>),
                                    case revision(Conn, Thread0, Shown, Body, Time) of
                                        {ok, {Thread, Threads}} ->
                                            Steps = [
                                                {<<"UPDATE meta SET thread = ?2 WHERE id = ?1">>, [
                                                    Meta, Thread
                                                ]},
                                                {
                                                    <<
                                                        "UPDATE booru SET thread = ?2, meta = ?3, owner = ?4,"
                                                        " signed = ?5 WHERE id = ?1"
                                                    >>,
                                                    [Entry, Thread, Meta, Owner, Signed]
                                                }
                                            ],
                                            case steps(Conn, Steps) of
                                                ok -> {ok, {Entry, Threads ++ [{booru, Entry}]}};
                                                {error, _} = Error -> Error
                                            end;
                                        {error, _} = Error ->
                                            Error
                                    end;
                                {error, _} = Error ->
                                    Error
                            end;
                        {ok, Other} ->
                            {error, {unexpected, Other}};
                        {error, _} = Error ->
                            Error
                    end;
                {ok, Other} ->
                    {error, {unexpected, Other}};
                {error, _} = Error ->
                    Error
            end;
        {ok, [_]} ->
            {error, not_public};
        {ok, []} ->
            {error, no_such_meta};
        {ok, Other} ->
            {error, {unexpected, Other}};
        {error, _} = Error ->
            Error
    end.

%% an entry's tags made what the box names, and the history told
-spec boxed_tags(ike_db:writer(), integer(), integer(), [[binary()]], integer()) -> ok | error().
boxed_tags(Conn, Entry, Account, Box, Time) ->
    Wanted = [N || L <- Box, N <- L],
    case current_tags(Conn, Entry) of
        {ok, Current} ->
            Added = [N || N <- Wanted, not lists:member(N, Current), put_tag(Conn, Entry, N)],
            Removed = [N || N <- Current, not lists:member(N, Wanted), take_tag(Conn, Entry, N)],
            history(Conn, Entry, Account, Added, Removed, Time);
        {error, _} = Error ->
            Error
    end.

-spec current_tags(ike_db:writer(), integer()) -> {ok, [binary()]} | error().
current_tags(Conn, Entry) ->
    Sql = <<
        "SELECT t.name FROM booru_tag bt JOIN tag t ON t.id = bt.tag WHERE bt.booru = ?1"
        " ORDER BY t.name"
    >>,
    case ike_db:q(Conn, Sql, [Entry]) of
        {ok, Rows} -> {ok, [N || [N] <- Rows, is_binary(N)]};
        {error, _} = Error -> Error
    end.

-spec revised_entry(
    ike_db:writer(),
    integer(),
    integer(),
    integer(),
    [[binary()]] | keep,
    binary() | keep,
    integer()
) ->
    {ok, {integer(), [term()]}} | error().
revised_entry(Conn, Entry, Account, Shown, Box0, Commentary0, Time) ->
    Sql = <<"SELECT b.thread FROM booru b JOIN shown_entry e ON e.id = b.id WHERE b.id = ?1">>,
    case {ike_db:q(Conn, Sql, [Entry]), current_tags(Conn, Entry)} of
        {{ok, [[Thread1]]}, {ok, Current}} ->
            Thread0 = maybe_integer(Thread1),
            %% the newest revision's box and commentary; an entry with none
            %% has its tags on one line
            {BeforeBox, BeforeSaid} =
                case said(Conn, Thread0) of
                    {ok, BoxText, Said} -> {BoxText, Said};
                    none -> {spaced(Current), <<>>}
                end,
            Box =
                case Box0 of
                    keep -> lines(BeforeBox);
                    _ -> Box0
                end,
            Commentary =
                case Commentary0 of
                    keep -> BeforeSaid;
                    _ -> Commentary0
                end,
            Body = ike_tag:revision(Box, Commentary),
            {After, _, _} = ike_tag:revised(Body),
            Wanted = lists:usort([N || L <- Box, N <- L]),
            %% the same tags, laid out the same, and the same commentary
            case
                Wanted =:= lists:usort(Current) andalso After =:= BeforeBox andalso
                    Commentary =:= BeforeSaid
            of
                true ->
                    {error, nothing};
                false ->
                    case boxed_tags(Conn, Entry, Account, Box, Time) of
                        ok ->
                            case revision(Conn, Thread0, Shown, Body, Time) of
                                {ok, {Thread, Threads}} ->
                                    Set = <<"UPDATE booru SET thread = ?2 WHERE id = ?1">>,
                                    case ike_db:q(Conn, Set, [Entry, Thread]) of
                                        {ok, _} -> {ok, {Entry, Threads ++ [{booru, Entry}]}};
                                        {error, _} = Error -> Error
                                    end;
                                {error, _} = Error ->
                                    Error
                            end;
                        {error, _} = Error ->
                            Error
                    end
            end;
        {{ok, []}, _} ->
            {error, no_such_entry};
        {{ok, Other}, _} ->
            {error, {unexpected, Other}};
        {{error, _} = Error, _} ->
            Error;
        {_, {error, _} = Error} ->
            Error
    end.

%% a box's text back into its lines of names
-spec lines(binary()) -> [[binary()]].
lines(Box) ->
    [
        [W || W <- binary:split(L, <<" ">>, [global]), W =/= <<>>]
     || L <- binary:split(Box, <<"\n">>, [global]), L =/= <<>>
    ].

-spec commented(ike_db:writer(), integer(), integer(), binary(), integer()) ->
    {ok, {integer(), [term()]}} | error().
commented(Conn, Meta, Actor, Body, Time) ->
    case ike_db:q(Conn, <<"SELECT thread FROM meta WHERE id = ?1">>, [Meta]) of
        {ok, [[undefined]]} ->
            case post(Conn, Actor, {new, <<"trunk">>}, Time, Body) of
                {ok, {Id, Threads}} ->
                    case
                        ike_db:q(Conn, <<"UPDATE meta SET thread = ?2 WHERE id = ?1">>, [Meta, Id])
                    of
                        {ok, _} -> {ok, {Id, Threads}};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {ok, [[Thread]]} when is_integer(Thread) ->
            insert(Conn, Actor, Thread, Time, Body);
        {ok, []} ->
            {error, no_such_meta};
        {ok, Other} ->
            {error, {unexpected, Other}};
        {error, _} = Error ->
            Error
    end.

%% a line in the tag history, when tags changed
-spec history(ike_db:writer(), integer(), integer(), [binary()], [binary()], integer()) ->
    ok | error().
history(_Conn, _Entry, _Account, [], [], _Time) ->
    ok;
history(Conn, Entry, Account, Added, Removed, Time) ->
    Line = <<
        "INSERT INTO tag_change (booru, actor, time, added, removed) VALUES (?1, ?2, ?3, ?4, ?5)"
    >>,
    case ike_db:q(Conn, Line, [Entry, Account, Time, spaced(Added), spaced(Removed)]) of
        {ok, _} -> ok;
        {error, _} = Error -> Error
    end.

%% a curation's newest revision in view: its box and its commentary
-spec said(ike_db:writer(), integer() | undefined) -> {ok, binary(), binary()} | none.
said(_Conn, undefined) ->
    none;
said(Conn, Thread) ->
    Sql = <<
        "SELECT body FROM post WHERE thread = ?1 AND state = 0 AND revision = 1"
        " ORDER BY id DESC LIMIT 1"
    >>,
    case ike_db:q(Conn, Sql, [Thread]) of
        {ok, [[Body]]} when is_binary(Body) ->
            {Box, _, Commentary} = ike_tag:revised(Body),
            {ok, Box, Commentary};
        _ ->
            none
    end.

%% a revision in an attached thread, which it starts if there is none;
%% folded into the thread's newest post instead when that is a revision
%% by the same signed account
-spec revision(ike_db:writer(), integer() | undefined, integer(), binary(), integer()) ->
    {ok, {Thread :: integer(), [term()]}} | error().
revision(Conn, undefined, Shown, Body, Time) ->
    case post(Conn, Shown, {new, <<"trunk">>}, Time, Body) of
        {ok, {Id, Threads}} ->
            case ike_db:q(Conn, <<"UPDATE post SET revision = 1 WHERE id = ?1">>, [Id]) of
                {ok, _} -> {ok, {Id, Threads}};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end;
revision(Conn, Thread, Shown, Body, Time) ->
    Newest = <<
        "SELECT id, actor, revision FROM post WHERE thread = ?1 AND state = 0"
        " ORDER BY id DESC LIMIT 1"
    >>,
    case ike_db:q(Conn, Newest, [Thread]) of
        {ok, [[Last, Shown, 1]]} when Shown =/= ?NOBODY, is_integer(Last) ->
            case amended(Conn, Last, Thread, Body, Time) of
                {ok, {_, Threads}} -> {ok, {Thread, Threads}};
                {error, _} = Error -> Error
            end;
        {ok, _} ->
            case insert(Conn, Shown, Thread, Time, Body) of
                {ok, {Id, Threads}} ->
                    case ike_db:q(Conn, <<"UPDATE post SET revision = 1 WHERE id = ?1">>, [Id]) of
                        {ok, _} -> {ok, {Thread, Threads}};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%% tags on, tags off, and a line in the history saying what changed; an
%% entry out of sight is not tagged
-spec tagged(ike_db:writer(), integer(), integer(), [term()], [term()]) ->
    {ok, changed} | error().
tagged(Conn, Entry, Actor, Add, Remove) ->
    case ike_db:q(Conn, <<"SELECT 1 FROM shown_entry WHERE id = ?1">>, [Entry]) of
        {ok, [_]} ->
            Added = [
                N
             || N <- Add, is_binary(N), not lists:member(N, Remove), put_tag(Conn, Entry, N)
            ],
            Removed = [N || N <- Remove, is_binary(N), take_tag(Conn, Entry, N)],
            case {Added, Removed} of
                {[], []} ->
                    {error, nothing};
                _ ->
                    Line = <<
                        "INSERT INTO tag_change (booru, actor, time, added, removed)"
                        " VALUES (?1, ?2, ?3, ?4, ?5)"
                    >>,
                    Join = fun(Names) -> spaced([N || N <- Names, is_binary(N)]) end,
                    case
                        ike_db:q(Conn, Line, [
                            Entry, Actor, erlang:system_time(second), Join(Added), Join(Removed)
                        ])
                    of
                        {ok, _} -> {ok, changed};
                        {error, _} = Error -> Error
                    end
            end;
        {ok, _} ->
            {error, no_such_entry};
        {error, _} = Error ->
            Error
    end.

-spec spaced([binary()]) -> binary().
spaced([N]) -> N;
spaced([N | Ns]) -> <<N/binary, " ", (spaced(Ns))/binary>>;
spaced([]) -> <<>>.

%% whether the tag went on: false if it was on already
-spec put_tag(ike_db:writer(), integer(), binary()) -> boolean().
put_tag(Conn, Entry, Name) ->
    _ = ike_db:q(Conn, <<"INSERT INTO tag (name) VALUES (?1) ON CONFLICT (name) DO NOTHING">>, [
        Name
    ]),
    Sql = <<
        "INSERT INTO booru_tag (booru, tag) SELECT ?1, id FROM tag WHERE name = ?2"
        " ON CONFLICT DO NOTHING RETURNING tag"
    >>,
    case ike_db:q(Conn, Sql, [Entry, Name]) of
        {ok, [_]} -> true;
        _ -> false
    end.

-spec take_tag(ike_db:writer(), integer(), binary()) -> boolean().
take_tag(Conn, Entry, Name) ->
    Sql = <<
        "DELETE FROM booru_tag WHERE booru = ?1 AND tag = (SELECT id FROM tag WHERE name = ?2)"
        " RETURNING tag"
    >>,
    case ike_db:q(Conn, Sql, [Entry, Name]) of
        {ok, [_]} -> true;
        _ -> false
    end.

%% trashed by its poster: what trash does, with no entry in the log
-spec retracted(ike_db:writer(), integer(), integer(), binary(), integer()) ->
    {ok, effects()} | error().
retracted(Conn, Post, Thread, Board, Time) ->
    Around = <<
        "WITH these AS (SELECT id FROM post WHERE id = ?1 OR (?1 = ?2 AND thread = ?2))"
        " SELECT s.thread FROM link l JOIN post s ON s.id = l.source"
        " WHERE l.post IN (SELECT id FROM these)"
        " UNION SELECT p.thread FROM link l JOIN post p ON p.id = l.post"
        " WHERE l.source IN (SELECT id FROM these)"
    >>,
    Pictured = <<
        "SELECT pa.asset FROM post_image pa JOIN post p ON p.id = pa.post"
        " WHERE (p.id = ?1 OR (?1 = ?2 AND p.thread = ?2)) AND pa.asset IS NOT NULL"
    >>,
    Trash = <<"UPDATE post SET state = 2, purge_at = ?2, retracted = 1 WHERE id = ?1">>,
    case
        {
            ike_db:q(Conn, Around, [Post, Thread]),
            ike_db:q(Conn, Pictured, [Post, Thread]),
            ike_db:q(Conn, Trash, [Post, Time])
        }
    of
        {{ok, Rows}, {ok, Assets}, {ok, _}} ->
            Gone = [{Board, Thread} || Post =:= Thread, not standing(Conn, Thread)],
            {ok, (effects())#{
                threads := [Thread | [T || [T] <- Rows]],
                gone := Gone,
                boards := [Board],
                assets := [A || [A] <- Assets, is_binary(A)]
            }};
        {{error, _} = Error, _, _} ->
            Error;
        {_, {error, _} = Error, _} ->
            Error;
        {_, _, {error, _} = Error} ->
            Error
    end.

%% a staged upload of the account's, given to the post: posted now, and
%% its asset the post's
-spec attach(ike_db:writer(), integer(), term(), integer()) ->
    {ok, [binary()]} | error().
attach(_Conn, _Post, none, _Time) ->
    {ok, []};
attach(Conn, Post, {Account, Uploads}, Time) when is_integer(Account), is_list(Uploads) ->
    attach(Conn, Post, Account, Uploads, 0, Time, []);
attach(_Conn, _Post, _Upload, _Time) ->
    {error, bad_request}.

%% each upload in turn, all or none: one that is not the account's,
%% posted, or named twice fails the whole post
-spec attach(ike_db:writer(), integer(), integer(), [term()], non_neg_integer(), integer(), [
    binary()
]) ->
    {ok, [binary()]} | error().
attach(Conn, Post, Account, [Upload | Uploads], Position, Time, Acc) when is_integer(Upload) ->
    Take = <<
        "UPDATE upload SET posted = ?3, post = ?4"
        " WHERE id = ?1 AND actor = ?2 AND posted IS NULL RETURNING asset"
    >>,
    Show = <<"INSERT INTO post_image (post, position, asset) VALUES (?1, ?2, ?3)">>,
    case ike_db:q(Conn, Take, [Upload, Account, Time, Post]) of
        {ok, [[Hash]]} when is_binary(Hash) ->
            case ike_db:q(Conn, Show, [Post, Position, {blob, Hash}]) of
                {ok, _} -> attach(Conn, Post, Account, Uploads, Position + 1, Time, [Hash | Acc]);
                {error, _} = Error -> Error
            end;
        {ok, _} ->
            {error, no_such_upload};
        {error, _} = Error ->
            Error
    end;
attach(_Conn, _Post, _Account, [], _Position, _Time, Acc) ->
    {ok, Acc};
attach(_Conn, _Post, _Account, _Uploads, _Position, _Time, _Acc) ->
    {error, bad_request}.

%% the entries of these images, made for each that has none, at once
%% (planning leaves
%% open whether at once or only when tagged: booru_at_once, a stub). an
%% entry says nothing of who brought its image
-spec entered(ike_db:writer(), [binary()], integer()) -> {ok, [pos_integer()]} | error().
entered(Conn, Hashes, Time) ->
    case ike_config:booru_at_once() of
        true -> entered(Conn, Hashes, Time, []);
        false -> {ok, []}
    end.

-spec entered(ike_db:writer(), [binary()], integer(), [pos_integer()]) ->
    {ok, [pos_integer()]} | error().
entered(Conn, [Hash | Hashes], Time, Acc) ->
    %% one that has an entry is shown in one more post: its page changes
    Has = <<"SELECT booru FROM booru_version WHERE asset = ?1">>,
    case ike_db:q(Conn, Has, [{blob, Hash}]) of
        {ok, [[Known] | _]} when is_integer(Known), Known > 0 ->
            entered(Conn, Hashes, Time, [Known | Acc]);
        {ok, [_ | _]} ->
            entered(Conn, Hashes, Time, Acc);
        {ok, []} ->
            case ike_db:q(Conn, <<"INSERT INTO booru (time) VALUES (?1) RETURNING id">>, [Time]) of
                {ok, [[Id]]} when is_integer(Id), Id > 0 ->
                    Version = <<
                        "INSERT INTO booru_version (booru, position, asset, time)"
                        " VALUES (?1, 0, ?2, ?3)"
                    >>,
                    case ike_db:q(Conn, Version, [Id, {blob, Hash}, Time]) of
                        {ok, _} ->
                            ok = inherent(Conn, Id, Hash),
                            entered(Conn, Hashes, Time, [Id | Acc]);
                        {error, _} = Error ->
                            Error
                    end;
                {ok, Other} ->
                    {error, {unexpected, Other}};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end;
entered(_Conn, [], _Time, Acc) ->
    {ok, Acc}.

%% the tags an entry has by what its asset is (lux): image and raster,
%% animation, video, audio. never one for what it lacks. ike puts them on,
%% so no one's history line says so
-spec inherent(ike_db:writer(), integer(), binary()) -> ok.
inherent(Conn, Entry, Hash) ->
    case ike_db:q(Conn, <<"SELECT filetype, traits FROM asset WHERE hash = ?1">>, [{blob, Hash}]) of
        {ok, [[Format, Traits]]} when is_binary(Format), is_binary(Traits) ->
            _ = [put_tag(Conn, Entry, N) || N <- ike_tag:inherent(Format, Traits)],
            ok;
        _ ->
            ok
    end.

%% at start: every entry's inherent tags, for entries made before them
-spec inherited(ike_db:writer()) -> ok.
inherited(Conn) ->
    Sql = <<
        "SELECT b.id, (SELECT v.asset FROM booru_version v WHERE v.booru = b.id"
        " ORDER BY v.position DESC LIMIT 1) FROM booru b"
    >>,
    case ike_db:q(Conn, Sql, []) of
        {ok, Rows} ->
            _ = ike_db:transaction(Conn, fun() ->
                _ = [inherent(Conn, E, H) || [E, H] <- Rows, is_integer(E), is_binary(H)],
                {ok, []}
            end),
            ok;
        {error, _} ->
            ok
    end.

%% at start: an entry for every posted image that has none, numbered in
%% the order the images were first posted
-spec backfilled(ike_db:writer()) -> ok.
backfilled(Conn) ->
    Sql = <<
        "SELECT pi.asset, min(p.time) FROM post_image pi JOIN post p ON p.id = pi.post"
        " WHERE pi.asset IS NOT NULL"
        " AND NOT EXISTS (SELECT 1 FROM booru_version v WHERE v.asset = pi.asset)"
        " GROUP BY pi.asset ORDER BY min(pi.post)"
    >>,
    case ike_db:q(Conn, Sql, []) of
        {ok, []} ->
            ok;
        {ok, Rows} ->
            _ = ike_db:transaction(Conn, fun() ->
                each_entry(Conn, [{H, T} || [H, T] <- Rows, is_binary(H), is_integer(T)])
            end),
            ok;
        {error, _} ->
            ok
    end.

-spec each_entry(ike_db:writer(), [{binary(), integer()}]) -> {ok, []} | error().
each_entry(Conn, [{Hash, Time} | Rest]) ->
    case entered(Conn, [Hash], Time) of
        {ok, _} -> each_entry(Conn, Rest);
        {error, _} = Error -> Error
    end;
each_entry(_Conn, []) ->
    {ok, []}.

%% the media origin's files are the assets some shown post or entry
%% shows, and those whose meta is public, and no others: each asset named is copied there or taken away to match.
%% derived, like the pages, and made again whole at start
-spec published(ike_db:writer(), [binary()]) -> ok.
published(Conn, [Hash | Hashes]) ->
    Sql = <<
        "SELECT x.filetype, EXISTS (SELECT 1 FROM post_image pa JOIN shown s ON s.id = pa.post"
        " WHERE pa.asset = x.hash) OR EXISTS (SELECT 1 FROM shown_entry e WHERE e.asset = x.hash)"
        " OR EXISTS (SELECT 1 FROM meta m WHERE m.asset = x.hash AND m.private = 0 AND m.state = 0)"
        " FROM asset x WHERE x.hash = ?1"
    >>,
    case ike_db:q(Conn, Sql, [{blob, Hash}]) of
        {ok, [[Type, Shown]]} when is_binary(Type) -> publish(Hash, Type, Shown =:= 1);
        {ok, _} -> publish(Hash, <<>>, false);
        {error, _} -> ok
    end,
    published(Conn, Hashes);
published(_Conn, []) ->
    ok.

-spec publish(binary(), binary(), boolean()) -> ok.
publish(Hash, Type, Shown) ->
    Hex = binary:encode_hex(Hash, lowercase),
    From = ike_config:assets_dir(),
    To = ike_config:media_dir(),
    ok = copied(From, To, Hex, ike_media:file(Hex, Type), Shown),
    copied(From, To, <<Hex/binary, ".thumb">>, ike_media:thumb(Hex), Shown).

%% one file of the media origin's, there if it is shown and not if not
-spec copied(binary(), binary(), binary(), binary(), boolean()) -> ok.
copied(From, To, Source, Name, true) ->
    Path = <<To/binary, "/", Name/binary>>,
    case filelib:is_regular(Path) of
        true ->
            ok;
        false ->
            Tmp = <<Path/binary, ".tmp">>,
            _ = filelib:ensure_path(To),
            case file:copy(<<From/binary, "/", Source/binary>>, Tmp) of
                {ok, _} -> _ = file:rename(Tmp, Path);
                {error, _} -> _ = file:delete(Tmp)
            end,
            ok
    end;
copied(_From, To, _Source, Name, false) ->
    _ = file:delete(<<To/binary, "/", Name/binary>>),
    ok.

-spec kept_name(term(), #{binary() => true}) -> boolean().
kept_name(Name, Keep) when is_binary(Name) ->
    case ike_media:parse(Name) of
        {ok, Hex, _} -> maps:is_key(Hex, Keep);
        error -> false
    end;
kept_name(_, _) ->
    false.

%% entries' pages: made again, or, for one out of sight now, unlinked
%% once the renderer has nothing of it left to write
-spec entries_followed([integer()], [integer()]) -> ok.
entries_followed(Entries, Gone) ->
    Pages = ike_config:pages_dir(),
    [
        begin
            _ =
                try
                    ike_render:settle({booru, G})
                catch
                    exit:_ -> ok
                end,
            file:delete(<<Pages/binary, "/booru/", (integer_to_binary(G))/binary, ".html">>)
        end
     || G <- Gone
    ],
    [ike_render:dirty_booru(E) || E <- Entries],
    ok.

%% a purged asset's files, wherever ike put them (invariant 8)
-spec unlinked([binary()]) -> ok.
unlinked([Hex | Rest]) ->
    Assets = ike_config:assets_dir(),
    Media = ike_config:media_dir(),
    _ = file:delete(<<Assets/binary, "/", Hex/binary>>),
    _ = file:delete(<<Assets/binary, "/", Hex/binary, ".thumb">>),
    [
        file:delete(<<Media/binary, "/", Name/binary>>)
     || Name <- [
            ike_media:thumb(Hex)
            | [
                ike_media:file(Hex, T)
             || T <- [
                    <<"jpeg">>,
                    <<"png">>,
                    <<"webp">>,
                    <<"webm">>,
                    <<"mp4">>,
                    <<"ttf">>,
                    <<"otf">>,
                    <<"woff">>,
                    <<"woff2">>
                ]
            ]
        ]
    ],
    unlinked(Rest);
unlinked([]) ->
    ok.

%% at start: the media origin's files made to match what is shown
-spec republished(ike_db:writer()) -> ok.
republished(Conn) ->
    _ = filelib:ensure_path(ike_config:media_dir()),
    Sql = <<
        "SELECT DISTINCT pa.asset FROM post_image pa JOIN shown s ON s.id = pa.post"
        " WHERE pa.asset IS NOT NULL UNION SELECT asset FROM shown_entry WHERE asset IS NOT NULL"
        " UNION SELECT asset FROM meta WHERE private = 0 AND state = 0"
    >>,
    case ike_db:q(Conn, Sql, []) of
        {ok, Rows} ->
            Shown = [H || [H] <- Rows, is_binary(H)],
            ok = published(Conn, Shown),
            Keep = #{binary:encode_hex(H, lowercase) => true || H <- Shown},
            Dir = ike_config:media_dir(),
            case file:list_dir(Dir) of
                {ok, Files} ->
                    [
                        file:delete(filename:join(Dir, F))
                     || F <- Files, not kept_name(unicode:characters_to_binary(F), Keep)
                    ],
                    ok;
                {error, _} ->
                    ok
            end;
        {error, _} ->
            ok
    end.

-spec changed(
    ike_db:writer(), integer(), integer(), {0 | 1 | 2, integer() | undefined} | purge
) ->
    {ok, Destroyed :: [binary()]} | error().
changed(Conn, Post, Thread, purge) ->
    %% invariant 8: the rows, and every link to or from them. what the
    %% log says of them stays, and names them by number only. their
    %% images are not the post's content: they stay, out of sight unless
    %% another post shows them, and only purge_image erases one (lux)
    These = <<"(SELECT id FROM post WHERE id = ?1 OR (?1 = ?2 AND thread = ?2))">>,
    Done = each(Conn, [Post, Thread], [
        <<"DELETE FROM link WHERE post IN ", These/binary>>,
        <<"DELETE FROM link WHERE source IN ", These/binary>>,
        <<"UPDATE post SET parent = NULL WHERE parent IN ", These/binary>>,
        %% a report's reason may quote what it reports
        <<"DELETE FROM report WHERE post IN ", These/binary>>,
        <<"DELETE FROM post WHERE id = ?1 OR (?1 = ?2 AND thread = ?2)">>,
        <<"DELETE FROM thread WHERE root = ?1 AND ?1 = ?2">>
    ]),
    case Done of
        ok -> {ok, []};
        {error, _} = Error -> Error
    end;
changed(Conn, Post, _Thread, {State, Until}) ->
    Update = <<"UPDATE post SET state = ?2, purge_at = ?3, retracted = 0 WHERE id = ?1">>,
    case ike_db:q(Conn, Update, [Post, State, Until]) of
        {ok, _} -> {ok, []};
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
    log(Conn, Who, Kind, Text, Reason, Time, {Post, Account, Board, undefined}, entry).

%% the same, for what a booru entry had done to it
-spec log(
    ike_db:writer(),
    who(),
    ike_role:kind(),
    binary(),
    binary(),
    integer(),
    {integer() | undefined, integer() | undefined, integer() | undefined, integer() | undefined},
    entry
) ->
    {ok, Threads :: [term()]} | error().
log(Conn, Who, Kind, Text, Reason, Time, {Post, Account, Board, Booru}, entry) ->
    {Actor, Role} =
        case Who of
            system -> {undefined, system};
            {By, Held} -> {By, Held}
        end,
    Insert = <<
        "INSERT INTO action (entry, actor, role, kind, post, account, board, booru)"
        " VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)"
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
                        Board,
                        Booru
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
            Entries = ike_text:entries(Body),
            case
                {
                    link(Conn, Id, ike_text:targets(Body)),
                    entry_links(Conn, Id, Entries),
                    page_links(Conn, Id, ike_text:pages(Body))
                }
            of
                {ok, ok, ok} ->
                    case touched(Conn, Id, Home) of
                        {ok, {Id, Threads}} -> {ok, {Id, Threads ++ [{booru, E} || E <- Entries]}};
                        Other -> Other
                    end;
                {{error, _} = Error, _, _} ->
                    Error;
                {_, {error, _} = Error, _} ->
                    Error;
                {_, _, {error, _} = Error} ->
                    Error
            end;
        {ok, Rows} ->
            {error, {unexpected, Rows}};
        {error, _} = Error ->
            Error
    end.

%% [[name]], kept as links too: a page made later is found pointed at
-spec page_links(ike_db:writer(), integer(), [binary()]) -> ok | error().
page_links(_Conn, _Source, []) ->
    ok;
page_links(Conn, Source, [Name | Names]) ->
    case ike_db:q(Conn, <<"INSERT INTO link (source, name) VALUES (?1, ?2)">>, [Source, Name]) of
        {ok, _} -> page_links(Conn, Source, Names);
        {error, _} = Error -> Error
    end.

%% ##N, kept as links too: an entry's page shows who points at it
-spec entry_links(ike_db:writer(), integer(), [pos_integer()]) -> ok | error().
entry_links(_Conn, _Source, []) ->
    ok;
entry_links(Conn, Source, [Entry | Entries]) ->
    case ike_db:q(Conn, <<"INSERT INTO link (source, booru) VALUES (?1, ?2)">>, [Source, Entry]) of
        {ok, _} -> entry_links(Conn, Source, Entries);
        {error, _} = Error -> Error
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
%% a title: one line of text, short
-spec titled(binary()) -> boolean().
titled(Title) ->
    byte_size(Title) =< 300 andalso length(string:to_graphemes(Title)) =< 100 andalso text(Title) andalso
        binary:match(Title, <<"\n">>) =:= nomatch.

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
