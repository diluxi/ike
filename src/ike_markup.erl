%% What a post's text looks like: a subset of Danbooru's DText (Albert
%% Yi and others, Danbooru, from 2005), parsed into a tree the views turn
%% into elements, every leaf still text. The links in it (>>N, ##N,
%% [[name]]) are ike_text's to find, so that the writer and the pages
%% read them alike (hazard D1).
%%
%% Blocks: h1. to h6. headings, "* " list items, [quote] and [code]
%% between lines of their own, paragraphs between empty lines.
%% Inline: [b] [i] [s] [u] [spoiler] [code], "label":[https://url],
%% bare http(s) urls, {{tag query}}, and ike_text's links.
-module(ike_markup).

-export([parse/1]).
-export_type([block/0, inline/0]).

-type block() ::
    {para, [[inline()]]}
    | {heading, 1..6, [inline()]}
    | {list, [[inline()]]}
    | {quote, [block()]}
    | {code, binary()}.

-type inline() ::
    ike_text:piece()
    | {bold | italic | strike | under | spoiler, [inline()]}
    | {mono, binary()}
    | {url, Url :: binary(), Label :: [inline()]}
    | {search, Query :: binary()}.

-define(TAGS, [
    {<<"b">>, bold},
    {<<"i">>, italic},
    {<<"s">>, strike},
    {<<"u">>, under},
    {<<"spoiler">>, spoiler}
]).

-spec parse(binary()) -> [block()].
parse(Body) ->
    blocks(binary:split(Body, <<"\n">>, [global]), [], []).

%% lines into blocks; Para gathers the lines of the paragraph under way
-spec blocks([binary()], [binary()], [block()]) -> [block()].
blocks([], Para, Acc) ->
    rev(para(Para, Acc));
blocks([Line | Rest], Para, Acc) ->
    case Line of
        <<"[quote]">> ->
            {Inside, After} = until(<<"[/quote]">>, Rest, []),
            blocks(After, [], [{quote, blocks(Inside, [], [])} | para(Para, Acc)]);
        <<"[code]">> ->
            {Inside, After} = until(<<"[/code]">>, Rest, []),
            blocks(After, [], [{code, joined(Inside)} | para(Para, Acc)]);
        <<"h", L, ". ", Text/binary>> when L >= $1, L =< $6 ->
            blocks(Rest, [], [{heading, L - $0, inline(Text)} | para(Para, Acc)]);
        <<"* ", _/binary>> ->
            {Items, After} = items([Line | Rest], []),
            blocks(After, [], [{list, Items} | para(Para, Acc)]);
        <<>> ->
            blocks(Rest, [], para(Para, Acc));
        _ ->
            blocks(Rest, [Line | Para], Acc)
    end.

-spec para([binary()], [block()]) -> [block()].
para([], Acc) -> Acc;
para(Lines, Acc) -> [{para, [inline(L) || L <- rev(Lines)]} | Acc].

-spec until(binary(), [binary()], [binary()]) -> {[binary()], [binary()]}.
until(End, [End | Rest], Acc) -> {rev(Acc), Rest};
until(End, [Line | Rest], Acc) -> until(End, Rest, [Line | Acc]);
until(_End, [], Acc) -> {rev(Acc), []}.

-spec items([binary()], [[inline()]]) -> {[[inline()]], [binary()]}.
items([<<"* ", Text/binary>> | Rest], Acc) -> items(Rest, [inline(Text) | Acc]);
items(Rest, Acc) -> {rev(Acc), Rest}.

-spec joined([binary()]) -> binary().
joined([L]) -> L;
joined([L | Ls]) -> <<L/binary, "\n", (joined(Ls))/binary>>;
joined([]) -> <<>>.

%% one line's inline markup: tokens, then a tree, unmatched tags as text
-spec inline(binary()) -> [inline()].
inline(Line) ->
    tree(tokens(Line, <<>>, []), []).

-type token() ::
    {open, bold | italic | strike | under | spoiler, binary()}
    | {close, bold | italic | strike | under | spoiler, binary()}
    | {mono, binary()}
    | {url, binary(), binary()}
    | {search, binary()}
    | {text, binary()}.

-spec tokens(binary(), binary(), [token()]) -> [token()].
tokens(<<>>, Text, Acc) ->
    rev(text(Text, Acc));
tokens(<<"[code]", Rest/binary>> = All, Text, Acc) ->
    case binary:split(Rest, <<"[/code]">>) of
        [Code, After] -> tokens(After, <<>>, [{mono, Code} | text(Text, Acc)]);
        _ -> skip(All, Text, Acc)
    end;
tokens(<<"[/", Rest/binary>> = All, Text, Acc) ->
    case tag(Rest) of
        {Kind, Raw, After} ->
            tokens(After, <<>>, [{close, Kind, <<"[/", Raw/binary>>} | text(Text, Acc)]);
        none ->
            skip(All, Text, Acc)
    end;
tokens(<<"[", Rest/binary>> = All, Text, Acc) ->
    case tag(Rest) of
        {Kind, Raw, After} ->
            tokens(After, <<>>, [{open, Kind, <<"[", Raw/binary>>} | text(Text, Acc)]);
        none ->
            skip(All, Text, Acc)
    end;
tokens(<<"{{", Rest/binary>> = All, Text, Acc) ->
    case binary:split(Rest, <<"}}">>) of
        [Query, After] when byte_size(Query) > 0, byte_size(Query) =< 200 ->
            tokens(After, <<>>, [{search, Query} | text(Text, Acc)]);
        _ ->
            skip(All, Text, Acc)
    end;
tokens(<<"\"", Rest/binary>> = All, Text, Acc) ->
    %% "label":[url]
    case binary:split(Rest, <<"\":[">>) of
        [Label, After0] when byte_size(Label) > 0, byte_size(Label) =< 200 ->
            case {binary:match(Label, <<"\"">>), binary:split(After0, <<"]">>)} of
                {nomatch, [Url, After]} ->
                    case url(Url) of
                        true -> tokens(After, <<>>, [{url, Url, Label} | text(Text, Acc)]);
                        false -> skip(All, Text, Acc)
                    end;
                _ ->
                    skip(All, Text, Acc)
            end;
        _ ->
            skip(All, Text, Acc)
    end;
tokens(<<"http", _/binary>> = All, Text, Acc) ->
    %% a bare url, up to a space, less what ends a sentence
    [Url0 | _] = binary:split(All, [<<" ">>, <<"\t">>]),
    Url = untrailed(Url0),
    case url(Url) of
        true ->
            After = binary:part(All, byte_size(Url), byte_size(All) - byte_size(Url)),
            tokens(After, <<>>, [{url, Url, Url} | text(Text, Acc)]);
        false ->
            skip(All, Text, Acc)
    end;
tokens(All, Text, Acc) ->
    skip(All, Text, Acc).

-spec skip(binary(), binary(), [token()]) -> [token()].
skip(<<C, Rest/binary>>, Text, Acc) -> tokens(Rest, <<Text/binary, C>>, Acc);
skip(<<>>, Text, Acc) -> tokens(<<>>, Text, Acc).

-spec text(binary(), [token()]) -> [token()].
text(<<>>, Acc) -> Acc;
text(Text, Acc) -> [{text, Text} | Acc].

-spec tag(binary()) -> {bold | italic | strike | under | spoiler, binary(), binary()} | none.
tag(Rest) ->
    tag(Rest, ?TAGS).

-spec tag(binary(), [{binary(), bold | italic | strike | under | spoiler}]) ->
    {bold | italic | strike | under | spoiler, binary(), binary()} | none.
tag(Rest, [{Name, Kind} | Tags]) ->
    Size = byte_size(Name),
    case Rest of
        <<Name:Size/binary, "]", After/binary>> -> {Kind, <<Name/binary, "]">>, After};
        _ -> tag(Rest, Tags)
    end;
tag(_Rest, []) ->
    none.

%% an address a reader may follow: http or https, printable, nothing
%% that ends an attribute or starts markup
-spec url(binary()) -> boolean().
url(<<"https://", Rest/binary>>) -> byte_size(Rest) > 0 andalso safe(Rest);
url(<<"http://", Rest/binary>>) -> byte_size(Rest) > 0 andalso safe(Rest);
url(_) -> false.

-spec safe(binary()) -> boolean().
safe(<<C, Rest/binary>>) when C > 32, C < 127, C =/= $", C =/= $<, C =/= $>, C =/= $\\, C =/= $` ->
    safe(Rest);
safe(<<>>) ->
    true;
safe(_) ->
    false.

-spec untrailed(binary()) -> binary().
untrailed(<<>>) ->
    <<>>;
untrailed(Url) ->
    case binary:last(Url) of
        C when C =:= $.; C =:= $,; C =:= $); C =:= $!; C =:= $?; C =:= $:; C =:= $; ->
            untrailed(binary:part(Url, 0, byte_size(Url) - 1));
        _ ->
            Url
    end.

%% tokens into a tree: an open tag waits for its close; one never closed,
%% or a close with nothing open, is text as typed
-spec tree([token()], [inline()]) -> [inline()].
tree(Tokens, Acc) ->
    case tree(Tokens, Acc, none) of
        {Tree, []} -> Tree;
        {Tree, Rest} -> Tree ++ tree(Rest, [])
    end.

-spec tree([token()], [inline()], none | {bold | italic | strike | under | spoiler, binary()}) ->
    {[inline()], [token()]}.
tree([], Acc, none) ->
    {rev(Acc), []};
tree([], Acc, {_Kind, Raw}) ->
    %% never closed: the tag was text
    {pieces(Raw) ++ rev(Acc), []};
tree([{close, Kind, _} | Rest], Acc, {Kind, _}) ->
    {[{Kind, rev(Acc)}], Rest};
tree([{close, _, Raw} | Rest], Acc, Open) ->
    tree(Rest, rev(pieces(Raw)) ++ Acc, Open);
tree([{open, Kind, Raw} | Rest], Acc, Open) ->
    {Inner, After} = tree(Rest, [], {Kind, Raw}),
    tree(After, rev(Inner) ++ Acc, Open);
tree([{mono, Code} | Rest], Acc, Open) ->
    tree(Rest, [{mono, Code} | Acc], Open);
tree([{url, Url, Label} | Rest], Acc, Open) ->
    tree(Rest, [{url, Url, pieces(Label)} | Acc], Open);
tree([{search, Query} | Rest], Acc, Open) ->
    tree(Rest, [{search, Query} | Acc], Open);
tree([{text, Text} | Rest], Acc, Open) ->
    tree(Rest, rev(pieces(Text)) ++ Acc, Open).

%% text, with ike_text's links in it
-spec pieces(binary()) -> [inline()].
pieces(Text) ->
    case ike_text:parse(Text) of
        [Line] -> Line;
        _ -> [{text, Text}]
    end.

-spec rev([T]) -> [T].
rev(List) ->
    rev(List, []).

-spec rev([T], [T]) -> [T].
rev([X | Xs], Acc) -> rev(Xs, [X | Acc]);
rev([], Acc) -> Acc.
