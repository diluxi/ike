%% What a post's text says beyond its letters: the links in it. The
%% writer keeps the reverse links from the same reading the renderer
%% shows, so the two cannot disagree about what is a link (hazard d1).
-module(ike_text).

-export([parse/1, targets/1, entries/1, pages/1, metas/1, outlink/2]).
-export_type([piece/0]).

%% a post may point at this many others; what comes after is only text.
%% each link is a row, and a page to make again when its target changes
-define(MAX_LINKS, 32).
%% a number of at most this many digits is one sqlite can hold
-define(MAX_DIGITS, 18).
%% prefix:what (lux), the prefix as typed and the site it is; a longer
%% prefix before one it starts with
-define(PREFIXES, [
    {<<"meta">>, <<"meta">>},
    {<<"card">>, <<"card">>},
    {<<"twitter">>, <<"twitter">>},
    {<<"pixiv">>, <<"pixiv">>},
    {<<"tumblr">>, <<"tumblr">>},
    {<<"danbooru">>, <<"danbooru">>},
    {<<"gelbooru">>, <<"gelbooru">>},
    {<<"e621">>, <<"e621">>},
    {<<"github">>, <<"github">>},
    {<<"codeberg">>, <<"codeberg">>},
    {<<"sourcehut">>, <<"sourcehut">>},
    {<<"4chan">>, <<"4chan">>},
    {<<"xdnmb">>, <<"xdnmb">>},
    {<<"A岛匿名版"/utf8>>, <<"xdnmb">>},
    {<<"komica">>, <<"komica">>},
    {<<"糟糕岛"/utf8>>, <<"komica">>}
]).

-type piece() ::
    {text, binary()}
    %% >>N
    | {post, pos_integer()}
    %% >>>/board/N
    | {post, Board :: binary(), pos_integer()}
    %% ##N, a booru entry
    | {booru, pos_integer()}
    %% card:N, the same entry, as a card is called (lux)
    | {entry, pos_integer()}
    %% meta:N, a meta in the trunk
    | {meta, pos_integer()}
    %% site:what, somewhere else (twitter:123, github:diluxi/ike), as
    %% typed, and where it leads
    | {out, Typed :: binary(), Url :: binary()}
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
targets([[{entry, _} | Line] | Lines], Seen) -> targets([Line | Lines], Seen);
targets([[{meta, _} | Line] | Lines], Seen) -> targets([Line | Lines], Seen);
targets([[{out, _, _} | Line] | Lines], Seen) -> targets([Line | Lines], Seen);
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
entries([[{entry, N} | Line] | Lines], Seen) -> entries([Line | Lines], Seen#{N => []});
entries([[_ | Line] | Lines], Seen) -> entries([Line | Lines], Seen).

%% every meta the text points at, once each
-spec metas(binary()) -> [pos_integer()].
metas(Body) ->
    maps:keys(#{N => [] || Line <- parse(Body), {meta, N} <- Line, is_integer(N)}).

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
            case {byte_size(Target) =< 256 andalso ike_wiki:name(Target), Label} of
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
%% prefix:what (lux): meta:N, card:N, and somewhere else's, at a word's
%% start ("submeta:1" is text)
line(<<C, _/binary>> = All, Text, Pieces, Left) when
    Left > 0, (C >= $a andalso C =< $z) orelse C =:= $4 orelse C =:= $A orelse C >= 128
->
    case word_end(Text) andalso prefixed(All, ?PREFIXES) of
        {Piece, Rest} -> line(Rest, <<>>, [Piece | text(Text, Pieces)], Left - 1);
        _ -> skip(All, Text, Pieces, Left)
    end;
line(All, Text, Pieces, Left) ->
    skip(All, Text, Pieces, Left).

%% the prefix the text starts with, and what follows its colon, if that
%% is a thing the prefix names
-spec prefixed(binary(), [{binary(), binary()}]) -> {piece(), binary()} | false.
prefixed(All, [{Prefix, Site} | Prefixes]) ->
    Size = byte_size(Prefix),
    case All of
        <<Prefix:Size/binary, ":", After/binary>> ->
            case named(Site, Prefix, After) of
                {_, _} = Found -> Found;
                false -> prefixed(All, Prefixes)
            end;
        _ ->
            prefixed(All, Prefixes)
    end;
prefixed(_All, []) ->
    false.

-spec named(binary(), binary(), binary()) -> {piece(), binary()} | false.
named(<<"meta">>, _Prefix, After) ->
    case number(After) of
        {N, Rest} -> {{meta, N}, Rest};
        none -> false
    end;
named(<<"card">>, _Prefix, After) ->
    case number(After) of
        {N, Rest} -> {{entry, N}, Rest};
        none -> false
    end;
named(Site, Prefix, After) ->
    {Value, Rest} = path(After, <<>>),
    case outlink(Site, Value) of
        {ok, Url} -> {{out, <<Prefix/binary, ":", Value/binary>>, Url}, Rest};
        error -> false
    end.

%% what may follow a site's prefix: letters, digits and _ . ~ / -, up to
%% 200 bytes, less what ends a sentence
-spec path(binary(), binary()) -> {binary(), binary()}.
path(<<C, Rest/binary>>, Acc) when
    byte_size(Acc) < 200,
    ((C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse (C >= $0 andalso C =< $9) orelse
        C =:= $_ orelse C =:= $. orelse C =:= $~ orelse C =:= $/ orelse C =:= $-)
->
    path(Rest, <<Acc/binary, C>>);
path(Rest, Acc) ->
    untrailed(Acc, Rest).

-spec untrailed(binary(), binary()) -> {binary(), binary()}.
untrailed(<<>>, Rest) ->
    {<<>>, Rest};
untrailed(Acc, Rest) ->
    case binary:last(Acc) of
        C when C =:= $.; C =:= $/; C =:= $- ->
            Size = byte_size(Acc) - 1,
            <<Kept:Size/binary, Last>> = Acc,
            untrailed(Kept, <<Last, Rest/binary>>);
        _ ->
            {Acc, Rest}
    end.

%% where site:what leads (lux's sites; the addresses are ike's reading of
%% each, to be checked). what fits none of a site's shapes is no link
-spec outlink(binary(), binary()) -> {ok, binary()} | error.
outlink(_Site, <<>>) ->
    error;
outlink(Site, Value) ->
    case binary:match(Value, [<<"..">>, <<"//">>]) of
        nomatch -> site(Site, Value, digits(Value));
        _ -> error
    end.

-spec site(binary(), binary(), boolean()) -> {ok, binary()} | error.
site(<<"twitter">>, V, true) ->
    {ok, <<"https://x.com/i/status/", V/binary>>};
site(<<"twitter">>, V, false) ->
    case re:run(V, "^[A-Za-z0-9_]{1,15}$", [{capture, none}]) of
        match -> {ok, <<"https://x.com/", V/binary>>};
        nomatch -> error
    end;
site(<<"pixiv">>, V, true) ->
    {ok, <<"https://www.pixiv.net/artworks/", V/binary>>};
site(<<"pixiv">>, <<"users/", N/binary>> = V, false) ->
    case digits(N) of
        true -> {ok, <<"https://www.pixiv.net/", V/binary>>};
        false -> error
    end;
site(<<"tumblr">>, V, false) ->
    {ok, <<"https://www.tumblr.com/", V/binary>>};
site(<<"danbooru">>, V, true) ->
    {ok, <<"https://danbooru.donmai.us/posts/", V/binary>>};
site(<<"gelbooru">>, V, true) ->
    {ok, <<"https://gelbooru.com/index.php?page=post&s=view&id=", V/binary>>};
site(<<"e621">>, V, true) ->
    {ok, <<"https://e621.net/posts/", V/binary>>};
site(<<"github">>, V, false) ->
    {ok, <<"https://github.com/", V/binary>>};
site(<<"codeberg">>, V, false) ->
    {ok, <<"https://codeberg.org/", V/binary>>};
site(<<"sourcehut">>, <<"~", _/binary>> = V, false) ->
    {ok, <<"https://sr.ht/", V/binary>>};
site(<<"4chan">>, V, false) ->
    case binary:split(V, <<"/">>, [global]) of
        [Board] ->
            {ok, <<"https://boards.4chan.org/", Board/binary, "/">>};
        [Board, N] ->
            case digits(N) of
                true -> {ok, <<"https://boards.4chan.org/", Board/binary, "/thread/", N/binary>>};
                false -> error
            end;
        _ ->
            error
    end;
site(<<"xdnmb">>, V, true) ->
    {ok, <<"https://www.nmbxd1.com/t/", V/binary>>};
site(<<"komica">>, V, false) ->
    {ok, <<"https://komica1.org/", V/binary>>};
site(_, _, _) ->
    error.

-spec digits(binary()) -> boolean().
digits(<<>>) -> false;
digits(V) -> re:run(V, "^[0-9]+$", [{capture, none}]) =:= match.

-spec word_end(binary()) -> boolean().
word_end(<<>>) ->
    true;
word_end(Text) ->
    C = binary:last(Text),
    not ((C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9) orelse C =:= $_ orelse C >= 128).

%% one byte on, as text. a byte and not a character: what is looked for
%% above starts with ascii or with the first byte of a utf-8 sequence,
%% which is never the inside of another
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
