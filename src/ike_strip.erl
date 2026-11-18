%% The stripper, asked over a unix socket (invariant 6, hazard P1). ike
%% never runs a decoder: it hands the upload to whatever listens on the
%% socket, a unit of its own in production, and reads back the stored
%% bytes and a thumbnail. What comes back is believed no further than it
%% has to be: the type from a closed set, the sizes within the caps, and
%% the stored hash is ike's own to compute.
-module(ike_strip).

-export([run/1, unescaped/1]).
-export_type([stripped/0]).

-type stripped() :: #{
    type := type(),
    %% none for a font
    width := non_neg_integer(),
    height := non_neg_integer(),
    stored := binary(),
    thumb := binary(),
    %% a video with sound, an animated png, a font, a variable one
    traits := [audio | animated | font | variable],
    %% what a font says of itself, beyond the names its file keeps
    font => font()
}.
-type type() :: jpeg | png | webp | svg | webm | mp4 | ttf | otf | woff | woff2.
%% axes: tag, least, default, most. commentary: each a name record's
%% number (or vendor, or meta for a woff's block) and its text
-type font() :: #{
    family := binary(),
    axes := [{binary(), float(), float(), float()}],
    commentary := [{binary(), binary()}]
}.
-export_type([type/0, font/0]).

%% milliseconds, for the whole exchange
-define(TIMEOUT, 60000).
%% bytes; a thumbnail is small
-define(MAX_THUMB, 1048576).
%% bytes; what a font says of itself
-define(MAX_INFO, 262144).

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
            case answer(Socket, Deadline, Max + ?MAX_THUMB + ?MAX_INFO + 256, <<>>) of
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
                [<<"ok">>, Type0, W0, H0, S0, T0, Traits0] ->
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
                            Animated =
                                Type =:= png andalso binary:match(Stored, <<"acTL">>) =/= nomatch,
                            {ok, #{
                                type => Type,
                                width => W,
                                height => H,
                                stored => Stored,
                                thumb => Thumb,
                                traits =>
                                    [audio || Traits0 =:= <<"audio">>] ++ [animated || Animated]
                            }};
                        _ ->
                            {error, unavailable}
                    end;
                [<<"ok">>, Type0, <<"-">>, <<"-">>, S0, T0, Traits0, I0] ->
                    font(type(Type0), int(S0), int(T0), int(I0), Traits0, Rest, Max);
                [<<"no">>, Reason] when byte_size(Reason) =< 32, Rest =:= <<>> ->
                    {no, Reason};
                _ ->
                    {error, unavailable}
            end;
        _ ->
            {error, unavailable}
    end.

%% a font's answer: no size, its info after its thumbnail
-spec font(
    {ok, type()} | error, integer(), integer(), integer(), binary(), binary(), pos_integer()
) ->
    {ok, stripped()} | {error, unavailable}.
font({ok, Type}, S, T, I, Traits, Rest, Max) when
    (Type =:= ttf orelse Type =:= otf orelse Type =:= woff orelse Type =:= woff2),
    S > 0,
    S =< Max,
    T > 0,
    T =< ?MAX_THUMB,
    I > 0,
    I =< ?MAX_INFO,
    S + T + I =:= byte_size(Rest),
    (Traits =:= <<"font">> orelse Traits =:= <<"font,variable">>)
->
    <<Stored:S/binary, Thumb:T/binary, Info:I/binary>> = Rest,
    case info(Info) of
        {ok, Font} ->
            {ok, #{
                type => Type,
                width => 0,
                height => 0,
                stored => Stored,
                thumb => Thumb,
                traits => [font] ++ [variable || Traits =:= <<"font,variable">>],
                font => Font
            }};
        error ->
            {error, unavailable}
    end;
font(_, _, _, _, _, _, _) ->
    {error, unavailable}.

%% ike-font's lines, each a kind and its fields, tab-separated, text
%% escaped; believed only in shape
-spec info(binary()) -> {ok, font()} | error.
info(Info) ->
    case unicode:characters_to_binary(Info) of
        Info ->
            Lines = [L || L <- binary:split(Info, <<"\n">>, [global]), L =/= <<>>],
            lines(Lines, #{family => <<>>, axes => [], commentary => []});
        _ ->
            error
    end.

-spec lines([binary()], font()) -> {ok, font()} | error.
lines([], #{axes := Axes, commentary := Said} = Font) ->
    {ok, Font#{axes := rev(Axes, []), commentary := rev(Said, [])}};
lines([Line | Rest], #{axes := Axes, commentary := Said} = Font) ->
    case binary:split(Line, <<"\t">>, [global]) of
        [<<"family">>, Family] when byte_size(Family) =< 256 ->
            lines(Rest, Font#{family := unescaped(Family)});
        [<<"axis">>, Tag, Min, Default, Most] when byte_size(Tag) =:= 4 ->
            %% a tag goes into css as a slider moves it: letters, digits
            %% and spaces only
            Plain = re:run(Tag, "^[A-Za-z0-9 ]{4}$", [{capture, none}]) =:= match,
            case {Plain, number(Min), number(Default), number(Most)} of
                {true, {ok, A}, {ok, B}, {ok, C}} when A =< B, B =< C ->
                    lines(Rest, Font#{axes := [{Tag, A, B, C} | Axes]});
                _ ->
                    error
            end;
        [<<"name">>, Id, Text] when byte_size(Text) =< 65536 ->
            case int(Id) of
                N when N >= 0, N < 256 ->
                    lines(Rest, Font#{commentary := [{Id, unescaped(Text)} | Said]});
                _ ->
                    error
            end;
        [Kind, Text] when
            (Kind =:= <<"vendor">> orelse Kind =:= <<"meta">>), byte_size(Text) =< 65536
        ->
            lines(Rest, Font#{commentary := [{Kind, unescaped(Text)} | Said]});
        _ ->
            error
    end.

-spec rev([T], [T]) -> [T].
rev([X | Xs], Acc) -> rev(Xs, [X | Acc]);
rev([], Acc) -> Acc.

-spec number(binary()) -> {ok, float()} | error.
number(Bin) ->
    try binary_to_float(Bin) of
        F -> {ok, F}
    catch
        _:_ ->
            case int(Bin) of
                -1 when Bin =/= <<"-1">> -> error;
                N -> {ok, float(N)}
            end
    end.

-spec unescaped(binary()) -> binary().
unescaped(<<"\\\\", Rest/binary>>) -> <<"\\", (unescaped(Rest))/binary>>;
unescaped(<<"\\t", Rest/binary>>) -> <<"\t", (unescaped(Rest))/binary>>;
unescaped(<<"\\n", Rest/binary>>) -> <<"\n", (unescaped(Rest))/binary>>;
unescaped(<<"\\r", Rest/binary>>) -> <<"\r", (unescaped(Rest))/binary>>;
unescaped(<<C, Rest/binary>>) -> <<C, (unescaped(Rest))/binary>>;
unescaped(<<>>) -> <<>>.

-spec type(binary()) -> {ok, type()} | error.
type(<<"webm">>) -> {ok, webm};
type(<<"mp4">>) -> {ok, mp4};
type(<<"jpeg">>) -> {ok, jpeg};
type(<<"png">>) -> {ok, png};
type(<<"webp">>) -> {ok, webp};
type(<<"svg">>) -> {ok, svg};
type(<<"ttf">>) -> {ok, ttf};
type(<<"otf">>) -> {ok, otf};
type(<<"woff">>) -> {ok, woff};
type(<<"woff2">>) -> {ok, woff2};
type(_) -> error.

-spec int(binary()) -> integer().
int(Bin) ->
    try binary_to_integer(Bin) of
        N -> N
    catch
        _:_ -> -1
    end.
