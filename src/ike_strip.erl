%% The stripper, asked over a unix socket (invariant 6, hazard P1). ike
%% never runs a decoder: it hands the upload to whatever listens on the
%% socket, a unit of its own in production, and reads back the stored
%% bytes and a thumbnail. What comes back is believed no further than it
%% has to be: the type from a closed set, the sizes within the caps, and
%% the stored hash is ike's own to compute.
-module(ike_strip).

-export([run/1]).
-export_type([stripped/0]).

-type stripped() :: #{
    type := jpeg | png | webp | webm | mp4,
    width := pos_integer(),
    height := pos_integer(),
    stored := binary(),
    thumb := binary()
}.

%% milliseconds, for the whole exchange
-define(TIMEOUT, 60000).
%% bytes; a thumbnail is small
-define(MAX_THUMB, 1048576).

-spec run(binary()) -> {ok, stripped()} | {no, binary()} | {error, unavailable}.
run(Upload) ->
    #{socket := Path, max_bytes := Max} = ike_config:strip(),
    case byte_size(Upload) =< Max of
        false ->
            {no, <<"too-large">>};
        true ->
            case gen_tcp:connect({local, Path}, 0, [binary, {active, false}], ?TIMEOUT) of
                {ok, Socket} ->
                    try exchange(Socket, Upload, Max) of
                        Answer -> Answer
                    after
                        gen_tcp:close(Socket)
                    end;
                {error, _} ->
                    {error, unavailable}
            end
    end.

-spec exchange(gen_tcp:socket(), binary(), pos_integer()) ->
    {ok, stripped()} | {no, binary()} | {error, unavailable}.
exchange(Socket, Upload, Max) ->
    Deadline = erlang:monotonic_time(millisecond) + ?TIMEOUT,
    case gen_tcp:send(Socket, Upload) of
        ok ->
            ok = gen_tcp:shutdown(Socket, write),
            case answer(Socket, Deadline, Max + ?MAX_THUMB + 256, <<>>) of
                {ok, Bytes} -> parse(Bytes, Max);
                error -> {error, unavailable}
            end;
        {error, _} ->
            {error, unavailable}
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

-spec parse(binary(), pos_integer()) -> {ok, stripped()} | {no, binary()} | {error, unavailable}.
parse(Bytes, Max) ->
    #{max_side := Side} = ike_config:strip(),
    case binary:split(Bytes, <<"\n">>) of
        [Line, Rest] ->
            case binary:split(Line, <<" ">>, [global]) of
                [<<"ok">>, Type0, W0, H0, S0, T0] ->
                    case {type(Type0), int(W0), int(H0), int(S0), int(T0)} of
                        {{ok, Type}, W, H, S, T} when
                            W > 0,
                            W =< Side,
                            H > 0,
                            H =< Side,
                            S > 0,
                            S =< Max,
                            T > 0,
                            T =< ?MAX_THUMB,
                            S + T =:= byte_size(Rest)
                        ->
                            <<Stored:S/binary, Thumb:T/binary>> = Rest,
                            {ok, #{
                                type => Type,
                                width => W,
                                height => H,
                                stored => Stored,
                                thumb => Thumb
                            }};
                        _ ->
                            {error, unavailable}
                    end;
                [<<"no">>, Reason] when byte_size(Reason) =< 32, Rest =:= <<>> ->
                    {no, Reason};
                _ ->
                    {error, unavailable}
            end;
        _ ->
            {error, unavailable}
    end.

-spec type(binary()) -> {ok, jpeg | png | webp | webm | mp4} | error.
type(<<"webm">>) -> {ok, webm};
type(<<"mp4">>) -> {ok, mp4};
type(<<"jpeg">>) -> {ok, jpeg};
type(<<"png">>) -> {ok, png};
type(<<"webp">>) -> {ok, webp};
type(_) -> error.

-spec int(binary()) -> integer().
int(Bin) ->
    try binary_to_integer(Bin) of
        N -> N
    catch
        _:_ -> -1
    end.
