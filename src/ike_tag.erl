%% Tag names, and what a tagging form or a search says. A name's ascii
%% is a closed set of characters (the schema says the same); beyond ascii
%% any character but a space (lux: copyright:ガールズバンドクライ), which
%% a link carries percent-encoded (path/1).
%%
%% A tag is a kind and a name (lux, 2026-11-19), written kind/name; no
%% name has a slash, and the kinds are a closed set, so there is no
%% hierarchy. A name alone is the tag by that name while there is one.
-module(ike_tag).

-export([name/1, edit/1, query/1, layout/1, inherent/2, quoted/1]).
-export([kinds/0, typed/1, word/1, split/1, inherent_names/0]).
-export_type([typed/0]).

%% a word as written: a kind and a name, or a name alone (any kind)
-type typed() :: {binary() | any, binary()}.
-export([revision/2, revised/1]).
-export([said/1, with/2, without/2, search_href/1, query_string/1]).

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

%% the kinds a tag is (lux): danbooru's artist, character, copyright (here
%% canon), general (here description) and meta. the wiki's info is none
-spec kinds() -> [binary()].
kinds() ->
    [<<"artist">>, <<"character">>, <<"canon">>, <<"description">>, <<"meta">>].

%% a word as typed: kind/name, or a name alone
-spec typed(binary()) -> {ok, typed()} | error.
typed(Word) ->
    case split(Word) of
        {any, Name0} ->
            case name(Name0) of
                {ok, Name} -> {ok, {any, Name}};
                error -> error
            end;
        {Kind, Name0} ->
            case lists:member(Kind, kinds()) andalso name(Name0) of
                {ok, Name} -> {ok, {Kind, Name}};
                _ -> error
            end
    end.

%% a word's kind, lowercased, if it names one, and the rest
-spec split(binary()) -> {binary() | any, binary()}.
split(Word) ->
    case binary:split(Word, <<"/">>) of
        [Kind, Name] -> {<<<<(lower(C))>> || <<C>> <= Kind>>, Name};
        [Name] -> {any, Name}
    end.

%% a typed word written out again
-spec word(typed()) -> binary().
word({any, Name}) -> Name;
word({Kind, Name}) -> <<Kind/binary, "/", Name/binary>>.

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
%% from every line, the minus with it, and a line left empty goes. a
%% word is kind/name or a name alone (which the writer finds the kind
%% of); -name takes a name off whatever its kind, -kind/name that kind's
-spec layout(binary()) -> {Lines :: [[binary()]], Tags :: [binary()]}.
layout(Text) ->
    Lines0 = [
        [W || W <- binary:split(L, [<<" ">>, <<"\t">>, <<"\r">>], [global]), W =/= <<>>]
     || L <- binary:split(Text, <<"\n">>, [global])
    ],
    Off = offs([T || L <- Lines0, <<"-", W/binary>> <- L, {ok, T} <- [typed(W)]], #{}),
    {Lines, _} = laid(Lines0, Off, #{}, [], ?MOST * 4),
    {Lines, [N || L <- Lines, N <- L]}.

%% what a box takes off: each name, with the kinds it is taken off as
-spec offs([typed()], #{binary() => [binary() | any]}) -> #{binary() => [binary() | any]}.
offs([{K, N} | Rest], Acc) -> offs(Rest, Acc#{N => [K | maps:get(N, Acc, [])]});
offs([], Acc) -> Acc.

%% whether a word is taken off: by its name alone, or by its kind
-spec off(typed(), #{binary() => [binary() | any]}) -> boolean().
off({Kind, Name}, Off) ->
    case Off of
        #{Name := Kinds} ->
            Kind =:= any orelse lists:member(any, Kinds) orelse lists:member(Kind, Kinds);
        _ ->
            false
    end.

-spec laid(
    [[binary()]],
    #{binary() => [binary() | any]},
    #{binary() => []},
    [[binary()]],
    non_neg_integer()
) ->
    {[[binary()]], #{binary() => []}}.
laid([Line | Rest], Off, Seen, Acc, Left) ->
    {Kept, Seen1, Left1} = kept(Line, Off, Seen, [], Left),
    case Kept of
        [] -> laid(Rest, Off, Seen1, Acc, Left1);
        _ -> laid(Rest, Off, Seen1, [Kept | Acc], Left1)
    end;
laid([], _Off, Seen, Acc, _Left) ->
    {rev(Acc), Seen}.

-spec kept(
    [binary()], #{binary() => [binary() | any]}, #{binary() => []}, [binary()], non_neg_integer()
) ->
    {[binary()], #{binary() => []}, non_neg_integer()}.
kept([W | Ws], Off, Seen, Acc, Left) when Left > 0 ->
    case typed(W) of
        {ok, T} ->
            N = word(T),
            case off(T, Off) orelse is_map_key(N, Seen) of
                false -> kept(Ws, Off, Seen#{N => []}, [N | Acc], Left - 1);
                true -> kept(Ws, Off, Seen, Acc, Left)
            end;
        error ->
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
%% vector, animation, video, audio, font. never one for what it lacks
-spec inherent(binary(), binary()) -> [binary()].
inherent(Format, Traits) ->
    Words = binary:split(Traits, <<" ">>, [global, trim_all]),
    case Format of
        _ when Format =:= <<"webm">>; Format =:= <<"mp4">> ->
            [<<"video">>] ++ [<<"audio">> || lists:member(<<"audio">>, Words)];
        <<"svg">> ->
            [<<"image">>, <<"vector">>];
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

%% every name inherent/2 gives, which are meta's
-spec inherent_names() -> [binary()].
inherent_names() ->
    [
        <<"image">>,
        <<"raster">>,
        <<"vector">>,
        <<"animation">>,
        <<"video">>,
        <<"audio">>,
        <<"font">>
    ].

%% a tagging form's words: names to add, and those after a minus to take
%% away. what is not a name is dropped
-spec edit(binary()) -> {Add :: [binary()], Remove :: [binary()]}.
edit(Text) ->
    Words = first(?MOST, words(Text)),
    {
        [N || W <- Words, {ok, N} <- [name(W)]],
        [N || <<"-", W/binary>> <- Words, {ok, N} <- [name(W)]]
    }.

%% a search's words: tags an entry must have, tags it must not, and
%% prefixes of names (foo*), of which it must have one each. each is of
%% a kind, or of any kind for a name alone
-spec query(binary()) -> {[typed()], [typed()], [typed()]}.
query(Text) ->
    Words = first(16, words(Text)),
    {
        [T || W <- Words, {ok, T} <- [typed(W)]],
        [T || <<"-", W/binary>> <- Words, {ok, T} <- [typed(W)]],
        [
            T
         || W <- Words,
            byte_size(W) > 1,
            binary:last(W) =:= $*,
            {ok, T} <- [typed(binary:part(W, 0, byte_size(W) - 1))]
        ]
    }.

%% a search as the bar keeps it (lux): its words, each as query/1 read
%% it, in the order typed
-spec said(binary()) -> [binary()].
said(Text) ->
    {Must, Not, Prefixes} = query(Text),
    [word(T) || T <- Must] ++ [<<"-", (word(T))/binary>> || T <- Not] ++
        [<<(word(T))/binary, "*">> || T <- Prefixes].

%% a search with a name added: on, if it was taken off
-spec with([binary()], binary()) -> [binary()].
with(Said, Name) ->
    case lists:member(Name, Said) of
        true -> Said;
        false -> [W || W <- Said, W =/= <<"-", Name/binary>>] ++ [Name]
    end.

%% a search with a name removed, if it is in it; else with entries that
%% have it left out, as a minus does
-spec without([binary()], binary()) -> [binary()].
without(Said, Name) ->
    case lists:member(Name, Said) of
        true -> [W || W <- Said, W =/= Name];
        false -> with_off(Said, <<"-", Name/binary>>)
    end.

-spec with_off([binary()], binary()) -> [binary()].
with_off(Said, Off) ->
    case lists:member(Off, Said) of
        true -> Said;
        false -> Said ++ [Off]
    end.

%% a search's words as a query's value: a + between them, which no name
%% has; beyond ascii as %XX
-spec query_string([binary()]) -> binary().
query_string(Said) -> joined([quoted(W) || W <- Said], <<"+">>).

-spec search_href([binary()]) -> binary().
search_href([]) -> <<"/booru/search">>;
search_href(Said) -> <<"/booru/search?tags=", (query_string(Said))/binary>>.

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
