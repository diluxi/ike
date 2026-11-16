%% Tag names, and what a tagging form or a search says. A name is a
%% closed set of characters (the schema says the same), so that one can
%% sit in a link and a search without anything to escape there.
-module(ike_tag).

-export([name/1, edit/1, query/1]).

-define(MOST, 64).

%% a name as typed, made a name, or not one
-spec name(binary()) -> {ok, binary()} | error.
name(Typed) ->
    Name = <<<<(lower(C))>> || <<C>> <= Typed>>,
    case
        byte_size(Name) >= 1 andalso byte_size(Name) =< 64 andalso
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
plain(<<C, Rest/binary>>) -> lists:member(C, "_()!?:.'-") andalso plain(Rest);
plain(<<>>) -> true.

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
