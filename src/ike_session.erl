%% Sessions and half-finished logins. A session is also a row, written
%% by the writer and read back at start, so that a restart logs nobody
%% out; the table here answers every request without asking the
%% database. Neither holds what the cookie holds, only its sha-256. A
%% half-finished login lives in memory only.
-module(ike_session).
-behaviour(gen_server).

-export([start_link/0]).
-export([create/2, lookup/1, delete/1, begin_login/0, take_login/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export_type([session/0, login/0]).

%% name: what the account was called when it logged in, if anything
-type session() :: #{actor := ike_id:actor(), csrf := binary(), name := binary() | none}.
%% what a login needs to remember between the redirect and the callback
-type login() :: #{
    state := binary(),
    nonce := binary(),
    verifier := binary(),
    %% also set as a cookie: the callback must come from the browser that
    %% started the login
    binding := binary()
}.

-define(SESSIONS, ike_session).
-define(LOGINS, ike_session_login).
%% seconds
-define(LOGIN_LIFETIME, 600).
-define(SWEEP, 60000).
%% logins nobody finished are capped, so that asking for them fills nothing
-define(MAX_LOGINS, 10000).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec create(ike_id:actor(), Name :: binary() | none) ->
    {ok, Id :: binary(), session()} | {error, term()}.
create(Actor, Name) ->
    case gen_server:call(?MODULE, {create, ike_id:to_integer(Actor), Name}) of
        {ok, Id, Csrf} when is_binary(Id), is_binary(Csrf) ->
            {ok, Id, #{actor => Actor, csrf => Csrf, name => Name}};
        Other ->
            {error, Other}
    end.

-spec lookup(Id :: binary()) -> {ok, session()} | error.
lookup(Id) ->
    Now = clock(),
    case ets:lookup(?SESSIONS, hash(Id)) of
        [{_, Actor, Csrf, Expires, Name}] when
            is_integer(Actor),
            Actor > 0,
            is_binary(Csrf),
            is_integer(Expires),
            Expires > Now,
            is_binary(Name) orelse Name =:= none
        ->
            {ok, #{actor => ike_id:actor(Actor), csrf => Csrf, name => Name}};
        _ ->
            error
    end.

-spec delete(Id :: binary()) -> ok.
delete(Id) ->
    %% a call: the session is gone before logout answers
    _ = gen_server:call(?MODULE, {delete, Id}),
    ok.

-spec begin_login() -> {ok, login()} | {error, term()}.
begin_login() ->
    case gen_server:call(?MODULE, begin_login) of
        {ok, #{state := S, nonce := N, verifier := V, binding := B}} when
            is_binary(S), is_binary(N), is_binary(V), is_binary(B)
        ->
            {ok, #{state => S, nonce => N, verifier => V, binding => B}};
        {error, Reason} ->
            {error, Reason};
        Other ->
            {error, Other}
    end.

%% a login can be finished once
-spec take_login(State :: binary()) -> {ok, login()} | error.
take_login(State) ->
    case gen_server:call(?MODULE, {take_login, State}) of
        {ok, #{state := S, nonce := N, verifier := V, binding := B}} when
            is_binary(S), is_binary(N), is_binary(V), is_binary(B)
        ->
            {ok, #{state => S, nonce => N, verifier => V, binding => B}};
        _ ->
            error
    end.

-spec init([]) -> {ok, []} | {stop, term()}.
init([]) ->
    _ = ets:new(?SESSIONS, [named_table, protected, {read_concurrency, true}]),
    _ = ets:new(?LOGINS, [named_table, private]),
    _ = erlang:send_after(?SWEEP, self(), sweep),
    Now = clock(),
    _ = ike_writer:expire_sessions(Now),
    case ike_db:open_reader(ike_config:db_path()) of
        {ok, Conn} ->
            Select = <<
                "SELECT s.hash, s.actor, s.csrf, s.expires, a.name"
                " FROM session s JOIN actor a ON a.id = s.actor WHERE s.expires > ?1"
            >>,
            Result = ike_db:q(Conn, Select, [Now]),
            _ = ike_db:close(Conn),
            case Result of
                {ok, Rows} ->
                    ok = restore(Rows),
                    {ok, []};
                {error, Reason} ->
                    {stop, Reason}
            end;
        {error, Reason} ->
            {stop, Reason}
    end.

-spec restore([ike_db:row()]) -> ok.
restore([[Hash, Actor, Csrf, Expires, Name0] | Rows]) when
    is_binary(Hash), is_integer(Actor), is_binary(Csrf), is_integer(Expires)
->
    Name =
        case Name0 of
            _ when is_binary(Name0) -> Name0;
            _ -> none
        end,
    true = ets:insert(?SESSIONS, {Hash, Actor, Csrf, Expires, Name}),
    restore(Rows);
restore([_ | Rows]) ->
    restore(Rows);
restore([]) ->
    ok.

-spec handle_call(term(), gen_server:from(), []) -> {reply, term(), []}.
handle_call({create, Actor, Name}, _From, []) when is_integer(Actor), Actor > 0 ->
    Id = token(),
    Csrf = token(),
    Hash = hash(Id),
    Expires = clock() + lifetime(),
    %% the row first: a session that would not outlive a restart is none
    case ike_writer:open_session(Hash, ike_id:actor(Actor), Csrf, Expires) of
        ok ->
            true = ets:insert(?SESSIONS, {Hash, Actor, Csrf, Expires, Name}),
            {reply, {ok, Id, Csrf}, []};
        {error, Reason} ->
            {reply, {error, Reason}, []}
    end;
handle_call(begin_login, _From, []) ->
    case ets:info(?LOGINS, size) of
        Size when is_integer(Size), Size < ?MAX_LOGINS ->
            Login = #{
                state => token(),
                nonce => token(),
                verifier => token(),
                binding => token()
            },
            true = ets:insert(
                ?LOGINS, {maps:get(state, Login), Login, now_s() + ?LOGIN_LIFETIME}
            ),
            {reply, {ok, Login}, []};
        _ ->
            {reply, {error, busy}, []}
    end;
handle_call({take_login, State}, _From, []) ->
    Now = now_s(),
    case ets:take(?LOGINS, State) of
        [{_, Login, Expires}] when is_integer(Expires), Expires > Now ->
            {reply, {ok, Login}, []};
        _ ->
            {reply, error, []}
    end;
handle_call({delete, Id}, _From, []) when is_binary(Id) ->
    Hash = hash(Id),
    %% gone from memory whatever the writer says: a restart could bring it
    %% back then, for what is left of its eight hours
    true = ets:delete(?SESSIONS, Hash),
    {reply, ike_writer:close_session(Hash), []};
handle_call(_Request, _From, []) ->
    {reply, {error, bad_request}, []}.

-spec handle_cast(term(), []) -> {noreply, []}.
handle_cast(_Request, []) ->
    {noreply, []}.

-spec handle_info(term(), []) -> {noreply, []}.
handle_info(sweep, []) ->
    Clock = clock(),
    Ended = [{{'_', '_', '_', '$1', '_'}, [{'=<', '$1', Clock}], [true]}],
    case ets:select_delete(?SESSIONS, Ended) of
        0 -> ok;
        _ -> ike_writer:expire_sessions(Clock)
    end,
    Now = now_s(),
    _ = ets:select_delete(?LOGINS, [{{'_', '_', '$1'}, [{'=<', '$1', Now}], [true]}]),
    _ = erlang:send_after(?SWEEP, self(), sweep),
    {noreply, []};
handle_info(_Info, []) ->
    {noreply, []}.

%% 256 bits from the system's generator, as base64url
-spec token() -> binary().
token() ->
    base64:encode(crypto:strong_rand_bytes(32), #{mode => urlsafe, padding => false}).

-spec hash(binary()) -> binary().
hash(Id) ->
    crypto:hash(sha256, Id).

%% for what lives in memory only
-spec now_s() -> integer().
now_s() ->
    erlang:monotonic_time(second).

%% for what outlives a restart
-spec clock() -> integer().
clock() ->
    erlang:system_time(second).

%% hazard i5: short, so that what a login decided does not outlive it long
-spec lifetime() -> pos_integer().
lifetime() ->
    ike_config:session_seconds().
