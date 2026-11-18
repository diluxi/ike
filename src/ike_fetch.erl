%% The fetcher, asked over a unix socket (invariant 7, hazards N1, N7).
%% ike never connects to a link a user gave: it hands the link to the
%% fetcher, a unit of its own that reaches public addresses only, and
%% reads back what the link is and its files. What comes back is believed
%% no further than it has to be: JSON in a known shape, each file's
%% length within the stripper's cap, and every file then stripped as any
%% upload (invariant 6).
-module(ike_fetch).

-export([run/1]).
-export_type([fetched/0]).

%% what a link was: where it is, who made it, what they said (ikext), and
%% its files' bytes, in order
-type fetched() :: #{
    source := binary(),
    artist := binary(),
    artist_url := binary(),
    commentary := binary(),
    files := [binary(), ...]
}.

%% milliseconds, for the whole exchange
-define(TIMEOUT, 120000).
-define(MAX_JSON, 1048576).

-spec run(binary()) -> {ok, fetched()} | {no, binary()} | {error, unavailable}.
run(Link) when byte_size(Link) =< 4096 ->
    #{socket := Path} = ike_config:fetch(),
    #{max_bytes := Max, files := Most} = ike_config:strip(),
    case gen_tcp:connect({local, Path}, 0, [binary, {active, false}], ?TIMEOUT) of
        {ok, Socket} ->
            try exchange(Socket, Link, Max * Most + ?MAX_JSON) of
                {ok, Bytes} -> parse(Bytes, Max, Most);
                error -> {error, unavailable}
            after
                gen_tcp:close(Socket)
            end;
        {error, _} ->
            {error, unavailable}
    end;
run(_) ->
    {no, <<"too-long">>}.

-spec exchange(gen_tcp:socket(), binary(), pos_integer()) -> {ok, binary()} | error.
exchange(Socket, Link, Most) ->
    Deadline = erlang:monotonic_time(millisecond) + ?TIMEOUT,
    case gen_tcp:send(Socket, <<Link/binary, "\n">>) of
        ok ->
            ok = gen_tcp:shutdown(Socket, write),
            answer(Socket, Deadline, Most, <<>>);
        {error, _} ->
            error
    end.

-spec answer(gen_tcp:socket(), integer(), integer(), binary()) -> {ok, binary()} | error.
answer(Socket, Deadline, Left, Acc) ->
    Wait = Deadline - erlang:monotonic_time(millisecond),
    case Wait > 0 andalso gen_tcp:recv(Socket, 0, Wait) of
        {ok, Data} when is_binary(Data), byte_size(Data) =< Left ->
            answer(Socket, Deadline, Left - byte_size(Data), <<Acc/binary, Data/binary>>);
        {error, closed} ->
            {ok, Acc};
        _ ->
            error
    end.

-spec parse(binary(), pos_integer(), pos_integer()) ->
    {ok, fetched()} | {no, binary()} | {error, unavailable}.
parse(Bytes, Max, Most) ->
    case binary:split(Bytes, <<"\n">>) of
        [<<"no ", Reason/binary>>, <<>>] when byte_size(Reason) =< 32 ->
            {no, Reason};
        [<<"ok ", Length0/binary>>, Rest] ->
            case string:to_integer(Length0) of
                {Length, <<>>} when
                    is_integer(Length), Length > 0, Length =< ?MAX_JSON, Length =< byte_size(Rest)
                ->
                    <<Head:Length/binary, Files/binary>> = Rest,
                    said(json(Head), Files, Max, Most);
                _ ->
                    {error, unavailable}
            end;
        _ ->
            {error, unavailable}
    end.

-spec json(binary()) -> term().
json(Head) ->
    try json:decode(Head) of
        Term -> Term
    catch
        _:_ -> error
    end.

%% the JSON's fields, text each, and its files' lengths summing to what
%% came after it, each within the cap
-spec said(term(), binary(), pos_integer(), pos_integer()) ->
    {ok, fetched()} | {error, unavailable}.
said(
    #{
        <<"source">> := Source,
        <<"artist">> := Artist,
        <<"artist_url">> := ArtistUrl,
        <<"commentary">> := Commentary,
        <<"files">> := [_ | _] = Files
    },
    Bytes,
    Max,
    Most
) when
    is_binary(Source),
    is_binary(Artist),
    is_binary(ArtistUrl),
    is_binary(Commentary),
    byte_size(Source) =< 1024,
    byte_size(Artist) =< 1024,
    byte_size(ArtistUrl) =< 1024,
    byte_size(Commentary) =< 65536,
    length(Files) =< Most
->
    Lengths = [L || #{<<"length">> := L} <- Files, is_integer(L), L > 0, L =< Max],
    case length(Lengths) =:= length(Files) andalso lists:sum(Lengths) =:= byte_size(Bytes) of
        true ->
            {ok, #{
                source => Source,
                artist => Artist,
                artist_url => ArtistUrl,
                commentary => Commentary,
                files => cut(Lengths, Bytes)
            }};
        false ->
            {error, unavailable}
    end;
said(_, _, _, _) ->
    {error, unavailable}.

-spec cut([pos_integer()], binary()) -> [binary()].
cut([L | Ls], Bytes) ->
    <<File:L/binary, Rest/binary>> = Bytes,
    [File | cut(Ls, Rest)];
cut([], _) ->
    [].
