%% What a post's text says beyond its letters: the links in it. The
%% writer keeps the reverse links from the same reading the renderer
%% shows, so the two cannot disagree about what is a link (hazard d1).
-module(ike_text).

-export([parse/1, targets/1, entries/1, pages/1]).
-export_type([piece/0]).

%% a post may point at this many others; what comes after is only text.
%% each link is a row, and a page to make again when its target changes
-define(MAX_LINKS, 32).
%% a number of at most this many digits is one sqlite can hold
-define(MAX_DIGITS, 18).

-type piece() ::
    {text, binary()}
    %% >>N
    | {post, pos_integer()}
    %% >>>/board/N
    | {post, Board :: binary(), pos_integer()}
    %% ##N, a booru entry
    | {booru, pos_integer()}
    %% [[name]], a wiki page, or a tag; [[name|label]] with its own words
    | {page, binary()}
    | {page, binary(), Label :: binary()}.

%% the text as lines, each as its pieces
-spec parse(binary()) -> [[piece()]].
parse(Body) ->
    lines(binary:split(Body, <<"\n">>, [global]), ?MAX_LINKS).

-spec lines([binary()], non_neg_integer()) -> [[piece()]].
lines([], _Left) ->
    [];
lines([Line | Rest], Left0) ->
    {Pieces, Left} = line(Line, <<>>, [], Left0),
    [Pieces | lines(Rest, Left)].

%% every post the text points at, once each
-spec targets(binary()) -> [pos_integer()].
targets(Body) ->
    maps:keys(targets(parse(Body), #{})).

-spec targets([[piece()]], #{pos_integer() => []}) -> #{pos_integer() => []}.
targets([], Seen) -> Seen;
targets([[] | Lines], Seen) -> targets(Lines, Seen);
targets([[{post, N} | Line] | Lines], Seen) -> targets([Line | Lines], Seen#{N => []});
targets([[{post, _, N} | Line] | Lines], Seen) -> targets([Line | Lines], Seen#{N => []});
targets([[{text, _} | Line] | Lines], Seen) -> targets([Line | Lines], Seen);
targets([[{booru, _} | Line] | Lines], Seen) -> targets([Line | Lines], Seen);
targets([[{page, _} | Line] | Lines], Seen) -> targets([Line | Lines], Seen);
targets([[{page, _, _} | Line] | Lines], Seen) -> targets([Line | Lines], Seen).

%% every page name the text points at, once each
-spec pages(binary()) -> [binary()].
pages(Body) ->
    maps:keys(
        maps:merge(
            #{N => [] || Line <- parse(Body), {page, N} <- Line, is_binary(N)},
            #{N => [] || Line <- parse(Body), {page, N, _} <- Line, is_binary(N)}
        )
    ).

%% every booru entry the text points at, once each
-spec entries(binary()) -> [pos_integer()].
entries(Body) ->
    maps:keys(entries(parse(Body), #{})).

-spec entries([[piece()]], #{pos_integer() => []}) -> #{pos_integer() => []}.
entries([], Seen) -> Seen;
entries([[] | Lines], Seen) -> entries(Lines, Seen);
entries([[{booru, N} | Line] | Lines], Seen) -> entries([Line | Lines], Seen#{N => []});
entries([[_ | Line] | Lines], Seen) -> entries([Line | Lines], Seen).

-spec line(binary(), binary(), [piece()], non_neg_integer()) -> {[piece()], non_neg_integer()}.
line(<<>>, Text, Pieces, Left) ->
    {turned(text(Text, Pieces), []), Left};
line(<<">>>/", Rest/binary>> = All, Text, Pieces, Left) when Left > 0 ->
    case board(Rest, <<>>) of
        {Board, Rest1} ->
            case number(Rest1) of
                {N, Rest2} -> line(Rest2, <<>>, [{post, Board, N} | text(Text, Pieces)], Left - 1);
                none -> skip(All, Text, Pieces, Left)
            end;
        none ->
            skip(All, Text, Pieces, Left)
    end;
line(<<"[[", Rest/binary>> = All, Text, Pieces, Left) when Left > 0 ->
    case binary:split(Rest, <<"]]">>) of
        [Inside, Rest1] when byte_size(Inside) =< 200 ->
            {Target, Label} =
                case binary:split(Inside, <<"|">>) of
                    [T, L] when byte_size(L) > 0 -> {T, L};
                    _ -> {Inside, none}
                end,
            case {byte_size(Target) =< 64 andalso ike_wiki:name(Target), Label} of
                {{ok, Name}, none} ->
                    line(Rest1, <<>>, [{page, Name} | text(Text, Pieces)], Left - 1);
                {{ok, Name}, _} ->
                    line(Rest1, <<>>, [{page, Name, Label} | text(Text, Pieces)], Left - 1);
                _ ->
                    skip(All, Text, Pieces, Left)
            end;
        _ ->
            skip(All, Text, Pieces, Left)
    end;
line(<<"##", Rest/binary>> = All, Text, Pieces, Left) when Left > 0 ->
    case number(Rest) of
        {N, Rest1} -> line(Rest1, <<>>, [{booru, N} | text(Text, Pieces)], Left - 1);
        none -> skip(All, Text, Pieces, Left)
    end;
line(<<">>", Rest/binary>> = All, Text, Pieces, Left) when Left > 0 ->
    case number(Rest) of
        {N, Rest1} -> line(Rest1, <<>>, [{post, N} | text(Text, Pieces)], Left - 1);
        none -> skip(All, Text, Pieces, Left)
    end;
line(All, Text, Pieces, Left) ->
    skip(All, Text, Pieces, Left).

%% one byte on, as text. a byte and not a character: the bytes looked for
%% above are ascii, which is never part of a longer utf-8 sequence
-spec skip(binary(), binary(), [piece()], non_neg_integer()) -> {[piece()], non_neg_integer()}.
skip(<<C, Rest/binary>>, Text, Pieces, Left) ->
    line(Rest, <<Text/binary, C>>, Pieces, Left);
skip(<<>>, Text, Pieces, Left) ->
    line(<<>>, Text, Pieces, Left).

-spec turned([piece()], [piece()]) -> [piece()].
turned([], Acc) -> Acc;
turned([Piece | Pieces], Acc) -> turned(Pieces, [Piece | Acc]).

-spec text(binary(), [piece()]) -> [piece()].
text(<<>>, Pieces) -> Pieces;
text(Text, Pieces) -> [{text, Text} | Pieces].

%% a board's name and the slash that ends it
-spec board(binary(), binary()) -> {binary(), binary()} | none.
board(<<$/, Rest/binary>>, Name) ->
    case ike_config:board_name(Name) of
        true -> {Name, Rest};
        false -> none
    end;
board(<<C, Rest/binary>>, Name) when byte_size(Name) < 16 ->
    board(Rest, <<Name/binary, C>>);
board(_, _) ->
    none.

%% a post's number as ike writes one: no sign, no leading zero, and not
%% the start of a longer run of digits
-spec number(binary()) -> {pos_integer(), binary()} | none.
number(<<C, _/binary>> = Bin) when C >= $1, C =< $9 ->
    digits(Bin, 0, 0);
number(_) ->
    none.

-spec digits(binary(), non_neg_integer(), non_neg_integer()) -> {pos_integer(), binary()} | none.
digits(<<C, Rest/binary>>, N, Count) when C >= $0, C =< $9, Count < ?MAX_DIGITS ->
    digits(Rest, N * 10 + (C - $0), Count + 1);
digits(<<C, _/binary>>, _N, _Count) when C >= $0, C =< $9 ->
    none;
digits(Rest, N, _Count) when N > 0 ->
    {N, Rest};
digits(_, _, _) ->
    none.
