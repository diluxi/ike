%% The rate limiter (hazards a2, n3 to n5). The one place in ike that
%% sees where a request came from, and it keeps none of it: an address
%% becomes a keyed hash of its network, the hash lives in a table in
%% memory, and the key lives beside it and is thrown away with the
%% table's rows every so often. Nothing here is logged, sent to another
%% process or written anywhere (invariant 1): the counting is done by
%% the caller, in the table, so that no message and no process state
%% ever holds a key.
-module(ike_limit).
-behaviour(gen_server).

-export([start_link/0, charge/2, board/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, ?MODULE).
%% rows past this and everyone waits: the table is memory
-define(MAX_ROWS, 200000).
-define(SWEEP, 30000).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% one more post from wherever this came from. Peer is the connection's
%% other end; Forwarded is what a proxy in front said of the client, and
%% is believed only when the proxy is one of ours (hazard n3)
-spec charge(Peer :: term(), Forwarded :: term()) -> ok | limited.
charge(Peer, Forwarded) ->
    #{posts := Max, seconds := Period, proxies := Proxies, v6_prefix := Bits} =
        ike_config:limit(),
    Address =
        case lists:member(Peer, Proxies) of
            true -> last(Forwarded);
            false -> Peer
        end,
    spend({address, key(network(Address, Bits))}, Max, Period).

%% one more post by nobody on this board, wherever from: what holds when
%% every request comes from somewhere new (hazard a2)
-spec board(binary()) -> ok | limited.
board(Name) ->
    #{board_posts := Max, board_seconds := Period} = ike_config:limit(),
    spend({board, Name}, Max, Period).

%% at most Max in each stretch of Period seconds
-spec spend(term(), pos_integer(), pos_integer()) -> ok | limited.
spend(Bucket, Max, Period) ->
    Now = erlang:monotonic_time(second),
    Window = Now div Period,
    Key = {Bucket, Window},
    case ets:info(?TABLE, size) of
        Size when is_integer(Size), Size < ?MAX_ROWS ->
            Count = ets:update_counter(
                ?TABLE, Key, {2, 1, Max + 1, Max + 1}, {Key, 0, (Window + 1) * Period}
            ),
            case Count =< Max of
                true -> ok;
                false -> limited
            end;
        _ ->
            limited
    end.

%% the last address of an x-forwarded-for: the one our proxy wrote,
%% whatever the client put before it
-spec last(term()) -> term().
last(Forwarded) when is_binary(Forwarded) ->
    Last = final(binary:split(Forwarded, <<",">>, [global]), <<>>),
    Bare = binary:replace(Last, [<<" ">>, <<"\t">>], <<>>, [global]),
    case inet:parse_strict_address(binary_to_list(Bare)) of
        {ok, Address} -> Address;
        {error, _} -> unknown
    end;
last(_) ->
    unknown.

-spec final([binary()], binary()) -> binary().
final([], Last) -> Last;
final([Next | Rest], _Last) -> final(Rest, Next).

%% what is counted together: an ipv4 address, or the network an ipv6
%% address is in, since whoever has one has all of that (hazard n4)
-spec network(term(), 48 | 56 | 64) -> binary().
network({0, 0, 0, 0, 0, 16#ffff, A, B}, _Bits) when is_integer(A), is_integer(B) ->
    <<4, A:16, B:16>>;
network({A, B, C, D}, _Bits) when
    is_integer(A), is_integer(B), is_integer(C), is_integer(D)
->
    <<4, A, B, C, D>>;
network({A, B, C, D, _, _, _, _}, Bits) when
    is_integer(A), is_integer(B), is_integer(C), is_integer(D)
->
    <<Network:Bits/bitstring, _/bitstring>> = <<A:16, B:16, C:16, D:16>>,
    <<6, Network/bitstring>>;
network(_, _) ->
    %% a proxy that said nothing we can read: everyone it speaks for
    %% shares one count
    <<0>>.

-spec key(binary()) -> binary().
key(Network) ->
    case ets:lookup(?TABLE, salt) of
        [{salt, Salt}] when is_binary(Salt) -> crypto:mac(hmac, sha256, Salt, Network)
    end.

%% the process owns the table and the clock, and holds nothing

-spec init([]) -> {ok, []}.
init([]) ->
    ?TABLE = ets:new(?TABLE, [named_table, public, {write_concurrency, true}]),
    salt(),
    _ = erlang:send_after(?SWEEP, self(), sweep),
    {ok, []}.

-spec handle_call(term(), gen_server:from(), []) -> {reply, {error, bad_request}, []}.
handle_call(_Request, _From, []) ->
    {reply, {error, bad_request}, []}.

-spec handle_cast(term(), []) -> {noreply, []}.
handle_cast(_Request, []) ->
    {noreply, []}.

-spec handle_info(term(), []) -> {noreply, []}.
handle_info(sweep, []) ->
    Now = erlang:monotonic_time(second),
    _ = ets:select_delete(?TABLE, [{{'_', '_', '$1'}, [{'=<', '$1', Now}], [true]}]),
    _ = erlang:send_after(?SWEEP, self(), sweep),
    {noreply, []};
handle_info(salt, []) ->
    salt(),
    {noreply, []};
handle_info(_Info, []) ->
    {noreply, []}.

%% a new key, and with it nothing counted under the old one means
%% anything: those rows go (hazard n5)
-spec salt() -> ok.
salt() ->
    #{salt_seconds := Seconds} = ike_config:limit(),
    true = ets:insert(?TABLE, {salt, crypto:strong_rand_bytes(32)}),
    _ = ets:match_delete(?TABLE, {{{address, '_'}, '_'}, '_', '_'}),
    _ = erlang:send_after(Seconds * 1000, self(), salt),
    ok.
