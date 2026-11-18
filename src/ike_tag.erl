%% Tag names, and what a tagging form or a search says. A name's ascii
%% is a closed set of characters (the schema says the same); beyond ascii
%% any character but a space (lux: copyright:ガールズバンドクライ), which
%% a link carries percent-encoded (path/1).
-module(ike_tag).

-export([name/1, edit/1, query/1, layout/1, inherent/2, quoted/1]).
-export([revision/2, revised/1]).

-define(MOST, 64).

%% a name as typed, made a name, or not one
-spec name(binary()) -> {ok, binary()} | error.
name(Typed) ->
    Name = <<<<(lower(C))>> || <<C>> <= Typed>>,
    case
        byte_size(Name) >= 1 andalso byte_size(Name) =< 256 andalso
            unicode:characters_to_binary(Name) =:= Name andalso
            string:length(Name) =< 64 andalso
            plain(Name) andalso not lists:member(binary:first(Name), [$-, $~, $*])
    of
        true -> {ok, Name};
        false -> error
    end.

-spec lower(byte()) -> byte().
lower(C) when C >= $A, C =< $Z -> C + 32;
lower(C) -> C.

-spec plain(binary()) -> boolean().
plain(<<C, Rest/binary>>) when C >= $a, C =< $z; C >= $0, C =< $9 -> plain(Rest);
%% beyond ascii: any character but the spaces unicode has
plain(<<C/utf8, Rest/binary>>) when C >= 128 -> not wide_space(C) andalso plain(Rest);
plain(<<C, Rest/binary>>) -> lists:member(C, "_()!?:.'-") andalso plain(Rest);
plain(<<>>) -> true.

-spec wide_space(char()) -> boolean().
wide_space(C) ->
    lists:member(C, [16#85, 16#a0, 16#1680, 16#2028, 16#2029, 16#202f, 16#205f, 16#3000, 16#feff]) orelse
        (C >= 16#2000 andalso C =< 16#200b).

%% a name in a link: its ascii as it is (a closed set, nothing in it that
%% ends a query or an attribute), every other byte as %XX
-spec quoted(binary()) -> binary().
quoted(Name) ->
    <<
        <<
            (case C < 128 of
                true -> <<C>>;
                false -> list_to_binary(io_lib:format("%~2.16.0B", [C]))
            end)/binary
        >>
     || <<C>> <= Name
    >>.

%% a tag box (lux): a line of names, or several, as a curator lays them
%% out, and -name to take one off. the box is the whole of an entry's
%% tags: what it names is on, and nothing else. kept as laid out, but
%% tidied: a name twice stays where it was first, a name taken off goes
%% from every line, the minus with it, and a line left empty goes
-spec layout(binary()) -> {Lines :: [[binary()]], Tags :: [binary()]}.
layout(Text) ->
    Lines0 = [
        [W || W <- binary:split(L, [<<" ">>, <<"\t">>, <<"\r">>], [global]), W =/= <<>>]
     || L <- binary:split(Text, <<"\n">>, [global])
    ],
    Off = #{N => [] || L <- Lines0, <<"-", W/binary>> <- L, {ok, N} <- [name(W)]},
    {Lines, _} = laid(Lines0, Off, #{}, [], ?MOST * 4),
    {Lines, [N || L <- Lines, N <- L]}.

-spec laid([[binary()]], #{binary() => []}, #{binary() => []}, [[binary()]], non_neg_integer()) ->
    {[[binary()]], #{binary() => []}}.
laid([Line | Rest], Off, Seen, Acc, Left) ->
    {Kept, Seen1, Left1} = kept(Line, Off, Seen, [], Left),
    case Kept of
        [] -> laid(Rest, Off, Seen1, Acc, Left1);
        _ -> laid(Rest, Off, Seen1, [Kept | Acc], Left1)
    end;
laid([], _Off, Seen, Acc, _Left) ->
    {rev(Acc), Seen}.

-spec kept([binary()], #{binary() => []}, #{binary() => []}, [binary()], non_neg_integer()) ->
    {[binary()], #{binary() => []}, non_neg_integer()}.
kept([W | Ws], Off, Seen, Acc, Left) when Left > 0 ->
    case name(W) of
        {ok, N} when not is_map_key(N, Off), not is_map_key(N, Seen) ->
            kept(Ws, Off, Seen#{N => []}, [N | Acc], Left - 1);
        _ ->
            kept(Ws, Off, Seen, Acc, Left)
    end;
kept(_, _Off, Seen, Acc, Left) ->
    {rev(Acc), Seen, Left}.

-spec rev([T]) -> [T].
rev(L) -> rev(L, []).

-spec rev([T], [T]) -> [T].
rev([X | Xs], Acc) -> rev(Xs, [X | Acc]);
rev([], Acc) -> Acc.

%% a curation's revision as its post keeps it: its tags as laid out, a
%% line of "--" (which no name can be: none starts with a minus), and its
%% commentary
-spec revision([[binary()]], binary()) -> binary().
revision(Lines, Commentary) ->
    <<(joined([spaced(L) || L <- Lines], <<"\n">>))/binary, "\n--\n", Commentary/binary>>.

%% a revision read back: its box as laid out, its tags, its commentary. a
%% revision kept before the box (one line of tags, then the commentary)
%% reads too
-spec revised(binary()) -> {Box :: binary(), Tags :: [binary()], Commentary :: binary()}.
revised(Body) ->
    {Box, Commentary} =
        case binary:split(Body, <<"\n--\n">>) of
            [B, C] ->
                {B, C};
            [_] ->
                case binary:split(Body, <<"\n">>) of
                    [B, C] -> {B, C};
                    [B] -> {B, <<>>}
                end
        end,
    Tags = [
        W
     || W <- binary:split(Box, [<<" ">>, <<"\n">>], [global]), W =/= <<>>
    ],
    {Box, Tags, Commentary}.

-spec spaced([binary()]) -> binary().
spaced(Words) -> joined(Words, <<" ">>).

-spec joined([binary()], binary()) -> binary().
joined([W], _) -> W;
joined([W | Ws], Sep) -> <<W/binary, Sep/binary, (joined(Ws, Sep))/binary>>;
joined([], _) -> <<>>.

%% the tags an entry has by what its asset is (lux): image and raster,
%% animation, video, audio, font. never one for what it lacks
-spec inherent(binary(), binary()) -> [binary()].
inherent(Format, Traits) ->
    Words = binary:split(Traits, <<" ">>, [global, trim_all]),
    case Format of
        _ when Format =:= <<"webm">>; Format =:= <<"mp4">> ->
            [<<"video">>] ++ [<<"audio">> || lists:member(<<"audio">>, Words)];
        _ when
            Format =:= <<"ttf">>;
            Format =:= <<"otf">>;
            Format =:= <<"woff">>;
            Format =:= <<"woff2">>
        ->
            [<<"font">>];
        _ ->
            [<<"image">>, <<"raster">>] ++ [<<"animation">> || lists:member(<<"animated">>, Words)]
    end.

%% a tagging form's words: names to add, and those after a minus to take
%% away. what is not a name is dropped
-spec edit(binary()) -> {Add :: [binary()], Remove :: [binary()]}.
edit(Text) ->
    Words = first(?MOST, words(Text)),
    {
        [N || W <- Words, {ok, N} <- [name(W)]],
        [N || <<"-", W/binary>> <- Words, {ok, N} <- [name(W)]]
    }.

%% a search's words: names an entry must have, names it must not, and
%% prefixes of names (foo*), of which it must have one each
-spec query(binary()) -> {[binary()], [binary()], [binary()]}.
query(Text) ->
    Words = first(16, words(Text)),
    {
        [N || W <- Words, {ok, N} <- [name(W)]],
        [N || <<"-", W/binary>> <- Words, {ok, N} <- [name(W)]],
        [
            N
         || W <- Words,
            byte_size(W) > 1,
            binary:last(W) =:= $*,
            {ok, N} <- [name(binary:part(W, 0, byte_size(W) - 1))]
        ]
    }.

-spec first(non_neg_integer(), [binary()]) -> [binary()].
first(N, [W | Ws]) when N > 0 -> [W | first(N - 1, Ws)];
first(_, _) -> [].

-spec words(binary()) -> [binary()].
words(Text) ->
    [
        W
     || W <- binary:split(Text, [<<" ">>, <<"\t">>, <<"\r">>, <<"\n">>, <<"+">>], [global]),
        W =/= <<>>
    ].
