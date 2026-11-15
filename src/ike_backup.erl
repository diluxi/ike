%% Backups (hazard d6): asks the writer for a snapshot of the database
%% every so often. The snapshots are files named for when they were taken,
%% and a restore is a copy of one back into place (docs/deploying.md).
-module(ike_backup).
-behaviour(gen_server).

-export([start_link/0, name/1, list/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% 1970 in calendar's seconds
-define(EPOCH, 62167219200).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% what a snapshot taken at Seconds is called: utc, sorting by age
-spec name(Seconds :: integer()) -> binary().
name(Seconds) ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:gregorian_seconds_to_datetime(Seconds + ?EPOCH),
    iolist_to_binary(
        io_lib:format("~4..0B~2..0B~2..0BT~2..0B~2..0B~2..0BZ.db", [Y, Mo, D, H, Mi, S])
    ).

-spec taken(Name :: binary()) -> {ok, Seconds :: integer()} | error.
taken(
    <<Y:4/binary, Mo:2/binary, D:2/binary, "T", H:2/binary, Mi:2/binary, S:2/binary, "Z.db">>
) ->
    try
        Date = {binary_to_integer(Y), binary_to_integer(Mo), binary_to_integer(D)},
        Time = {binary_to_integer(H), binary_to_integer(Mi), binary_to_integer(S)},
        {ok, calendar:datetime_to_gregorian_seconds({Date, Time}) - ?EPOCH}
    catch
        _:_ -> error
    end;
taken(_) ->
    error.

%% the snapshots in Dir, oldest first; anything else there is not ike's
-spec list(Dir :: binary()) -> [binary()].
list(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            ordsets:from_list(stamped(Names));
        {error, _} ->
            []
    end.

-spec stamped([file:filename()]) -> [binary()].
stamped([Name | Rest]) ->
    Bin = iolist_to_binary(Name),
    case taken(Bin) of
        {ok, _} -> [Bin | stamped(Rest)];
        error -> stamped(Rest)
    end;
stamped([]) ->
    [].

%% gen_server

-spec init([]) -> {ok, []}.
init([]) ->
    %% a restart does not take a snapshot of its own: a crash loop would
    %% otherwise push every good one out
    Now = erlang:system_time(second),
    schedule(due(list(ike_config:backup_dir()), Now)),
    {ok, []}.

%% seconds until the next snapshot, given the ones there are
-spec due([binary()], integer()) -> non_neg_integer().
due([], _Now) ->
    0;
due([Newest], Now) ->
    case taken(Newest) of
        {ok, Last} ->
            case Last + ike_config:backup_seconds() - Now of
                Wait when Wait > 0 -> Wait;
                _ -> 0
            end;
        error ->
            0
    end;
due([_ | Newer], Now) ->
    due(Newer, Now).

-spec handle_call(term(), gen_server:from(), []) -> {reply, term(), []}.
handle_call(_Request, _From, []) ->
    {reply, {error, bad_request}, []}.

-spec handle_cast(term(), []) -> {noreply, []}.
handle_cast(_Request, []) ->
    {noreply, []}.

-spec handle_info(term(), []) -> {noreply, []}.
handle_info(snapshot, []) ->
    case ike_writer:snapshot() of
        {ok, _Path} -> ok;
        {error, Reason} -> logger:error("no snapshot was taken: ~0p", [Reason])
    end,
    schedule(ike_config:backup_seconds()),
    {noreply, []};
handle_info(_Info, []) ->
    {noreply, []}.

-spec schedule(Seconds :: non_neg_integer()) -> ok.
schedule(Seconds) ->
    _ = erlang:send_after(Seconds * 1000, self(), snapshot),
    ok.
