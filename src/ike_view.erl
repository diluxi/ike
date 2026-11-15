%% What the pages say. Pure: rows in, a tree out; ike_render and the
%% handlers decide where it goes.
-module(ike_view).

-export([thread/2, index/1, message/2, layout/2]).
-export_type([post/0, summary/0]).

-type post() :: #{id := integer(), time := integer(), body := binary()}.
%% a thread as the index lists it
-type summary() :: #{root := integer(), posts := integer(), body := binary()}.

-define(EXCERPT, 120).

-spec thread(Root :: integer(), [post()]) -> ike_html:html().
thread(Root, Posts) ->
    N = integer_to_binary(Root),
    layout(<<">>", N/binary>>, [
        ike_html:el(h1, [ike_html:text(<<">>", N/binary>>)]),
        ike_html:el(ol, [ike_html:el(li, [post(P)]) || P <- Posts]),
        ike_html:el(p, [anchor(<<"/t/", N/binary, "/reply">>, <<"reply">>)])
    ]).

-spec post(post()) -> ike_html:html().
post(#{id := Id, time := Time, body := Body}) ->
    N = integer_to_binary(Id),
    Anchor = <<"p", N/binary>>,
    Stamp = stamp(Time),
    ike_html:el(article, [{id, Anchor}], [
        ike_html:el(header, [
            anchor(<<"#", Anchor/binary>>, <<">>", N/binary>>),
            ike_html:text(<<" ">>),
            ike_html:el(time, [{datetime, Stamp}], [ike_html:text(Stamp)])
        ]),
        ike_html:el(p, lines(Body))
    ]).

-spec index([summary()]) -> ike_html:html().
index(Threads) ->
    layout(<<"ike">>, [
        ike_html:el(h1, [ike_html:text(<<"ike">>)]),
        ike_html:el(p, [anchor(<<"/new">>, <<"new thread">>)]),
        ike_html:el(ul, [ike_html:el(li, summary(T)) || T <- Threads])
    ]).

-spec summary(summary()) -> [ike_html:html()].
summary(#{root := Root, posts := Posts, body := Body}) ->
    N = integer_to_binary(Root),
    [
        anchor(<<"/t/", N/binary>>, <<">>", N/binary>>),
        ike_html:text(<<" ">>),
        ike_html:text(excerpt(Body)),
        ike_html:text(<<" (", (integer_to_binary(Posts))/binary, ")">>)
    ].

%% a page that only says something
-spec message(Title :: binary(), Text :: binary()) -> ike_html:html().
message(Title, Text) ->
    layout(Title, [
        ike_html:el(h1, [ike_html:text(Title)]),
        ike_html:el(p, [ike_html:text(Text)])
    ]).

-spec layout(Title :: binary(), [ike_html:html()]) -> ike_html:html().
layout(Title, Content) ->
    ike_html:document(Title, [
        ike_html:el(nav, [anchor(<<"/">>, <<"ike">>)]),
        ike_html:el(main, Content)
    ]).

-spec anchor(Href :: binary(), Text :: binary()) -> ike_html:html().
anchor(Href, Text) ->
    ike_html:el(a, [{href, Href}], [ike_html:text(Text)]).

%% text nodes with a br between lines
-spec lines(binary()) -> [ike_html:html()].
lines(Body) ->
    case binary:split(Body, <<"\n">>) of
        [Line] -> [ike_html:text(Line)];
        [Line, Rest] -> [ike_html:text(Line), ike_html:el(br, []) | lines(Rest)]
    end.

%% the first line, cut at a character boundary
-spec excerpt(binary()) -> binary().
excerpt(Body) ->
    [Line | _] = binary:split(Body, <<"\n">>),
    cut(Line, ?EXCERPT, <<>>).

-spec cut(binary(), non_neg_integer(), binary()) -> binary().
cut(<<C/utf8, Rest/binary>>, N, Acc) when N > 0 ->
    cut(Rest, N - 1, <<Acc/binary, C/utf8>>);
cut(<<>>, _N, Acc) ->
    Acc;
cut(_Rest, _N, Acc) ->
    <<Acc/binary, "…"/utf8>>.

-spec stamp(integer()) -> binary().
stamp(Time) ->
    case calendar:system_time_to_rfc3339(Time, [{offset, "Z"}, {return, binary}]) of
        Stamp when is_binary(Stamp) -> Stamp;
        _ -> <<>>
    end.
