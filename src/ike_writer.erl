%% The single writer (invariant 3): the one process that holds a writable
%% connection. Whatever changes the database is a message to it, and one
%% transaction. It also brings the schema up to date, before it answers
%% anything.
-module(ike_writer).
-behaviour(gen_server).

-export([start_link/0, local_actor/2, post/1]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).
-export_type([new_post/0]).

-type new_post() :: #{
    actor := ike_id:actor(),
    %% a reply's thread, or new for an op
    thread := new | ike_id:post(),
    body := binary()
}.

-type error() :: {error, term()}.

%% long enough for a write queued behind a few others; a caller that gives
%% up does not undo what was committed
-define(CALL_TIMEOUT, 15000).
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
    {ok, ike_id:post()} | {error, bad_text | no_such_thread} | error().
post(#{actor := Actor, thread := Thread, body := Body}) ->
    Home =
        case Thread of
            new -> new;
            _ -> ike_id:to_integer(Thread)
        end,
    case call({post, ike_id:to_integer(Actor), Home, Body}) of
        {ok, Id} when is_integer(Id), Id > 0 -> {ok, ike_id:post(Id)};
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
                    case ike_migrate:run(Conn) of
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
handle_call(_Request, _From, Conn) ->
    {reply, {error, bad_request}, Conn}.

-spec handle_cast(term(), ike_db:writer()) -> {noreply, ike_db:writer()}.
handle_cast(_Request, Conn) ->
    {noreply, Conn}.

-spec terminate(term(), ike_db:writer()) -> ok.
terminate(_Reason, Conn) ->
    _ = ike_db:close(Conn),
    ok.

%% the renderer follows each commit, never a transaction still open
-spec committed(Result) -> Result when Result :: {ok, {integer(), integer()}} | term().
committed({ok, {Id, Thread}}) when is_integer(Id), is_integer(Thread) ->
    ike_render:dirty(Thread),
    {ok, Id};
committed(Other) ->
    Other.

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
post(Conn, Actor, new, Time, Body) ->
    %% an op's home thread is its own number, which autoincrement will hand
    %% out next; nobody else can take it, since nobody else writes
    Next = <<
        "SELECT coalesce((SELECT seq FROM sqlite_sequence"
        " WHERE name = 'post'), 0) + 1"
    >>,
    case ike_db:q(Conn, Next, []) of
        {ok, [[Id]]} when is_integer(Id) ->
            Thread = <<"INSERT INTO thread (root) VALUES (?1)">>,
            case ike_db:q(Conn, Thread, [Id]) of
                {ok, _} -> insert(Conn, Actor, Id, Time, Body);
                {error, _} = Error -> Error
            end;
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
