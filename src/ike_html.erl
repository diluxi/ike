%% HTML as a tree (invariant 4, hazard i3). There is no way to make an
%% html() out of a string of markup: text enters only through text/1 and
%% as attribute values, and both are escaped when the tree is written out.
%% Element and attribute names are a closed set, spelled out below.
-module(ike_html).

-export([text/1, el/2, el/3, document/2, to_iodata/1]).
-export_type([html/0, tag/0, attr/0]).

-type tag() ::
    a
    | article
    | body
    | br
    | button
    | del
    | details
    | footer
    | form
    | h1
    | img
    | ins
    | head
    | header
    | html
    | input
    | label
    | li
    | link
    | main
    | meta
    | nav
    | ol
    | p
    | span
    | summary
    | textarea
    | time
    | title
    | ul
    | video.

-type attr() ::
    {
        accept
        | action
        | alt
        | charset
        | class
        | content
        | datetime
        | enctype
        | for
        | height
        | href
        | id
        | lang
        | maxlength
        | method
        | name
        | poster
        | rel
        | preload
        | rows
        | src
        | type
        | value
        | width,
        binary()
    }
    | required
    | multiple
    | controls
    | reversed
    | open.

-opaque html() :: {text, binary()} | {el, tag(), [attr()], [html()]}.

-spec text(binary()) -> html().
text(Text) -> {text, Text}.

-spec el(tag(), [html()]) -> html().
el(Tag, Children) -> {el, Tag, [], Children}.

-spec el(tag(), [attr()], [html()]) -> html().
el(Tag, Attrs, Children) -> {el, Tag, Attrs, Children}.

%% a whole page
-spec document(Title :: binary(), [html()]) -> html().
document(Title, Body) ->
    el(html, [{lang, <<"en">>}], [
        el(head, [
            el(meta, [{charset, <<"utf-8">>}], []),
            el(
                meta,
                [
                    {name, <<"viewport">>},
                    {content, <<"width=device-width, initial-scale=1">>}
                ],
                []
            ),
            el(title, [text(Title)]),
            %% plain looks, from this origin; nothing depends on them
            el(link, [{rel, <<"stylesheet">>}, {href, <<"/style.css">>}], [])
        ]),
        el(body, Body)
    ]).

%% the only way out of the tree
-spec to_iodata(html()) -> iodata().
to_iodata({el, html, _, _} = Root) ->
    [<<"<!doctype html>\n">>, render(Root), $\n];
to_iodata(Node) ->
    render(Node).

-spec render(html()) -> iodata().
render({text, Text}) ->
    escape(Text);
render({el, Tag, Attrs, Children}) ->
    Name = tag(Tag),
    Open = [$<, Name, [attr(A) || A <- Attrs], $>],
    case void(Tag) of
        true -> Open;
        false -> [Open, [render(C) || C <- Children], <<"</">>, Name, $>]
    end.

-spec attr(attr()) -> iodata().
attr(required) -> <<" required">>;
attr(multiple) -> <<" multiple">>;
attr(controls) -> <<" controls">>;
attr(reversed) -> <<" reversed">>;
attr(open) -> <<" open">>;
attr({Name, Value}) -> [$\s, name(Name), <<"=\"">>, escape(Value), $"].

%% void elements have no content and no end tag; children given to one
%% are dropped
-spec void(tag()) -> boolean().
void(br) -> true;
void(img) -> true;
void(link) -> true;
void(input) -> true;
void(meta) -> true;
void(_) -> false.

-spec escape(binary()) -> binary().
escape(Text) ->
    <<<<(escape_byte(B))/binary>> || <<B>> <= Text>>.

-spec escape_byte(byte()) -> binary().
escape_byte($&) -> <<"&amp;">>;
escape_byte($<) -> <<"&lt;">>;
escape_byte($>) -> <<"&gt;">>;
escape_byte($") -> <<"&quot;">>;
escape_byte($') -> <<"&#39;">>;
escape_byte(B) -> <<B>>.

-spec tag(tag()) -> binary().
tag(a) -> <<"a">>;
tag(article) -> <<"article">>;
tag(body) -> <<"body">>;
tag(br) -> <<"br">>;
tag(button) -> <<"button">>;
tag(del) -> <<"del">>;
tag(details) -> <<"details">>;
tag(footer) -> <<"footer">>;
tag(form) -> <<"form">>;
tag(h1) -> <<"h1">>;
tag(img) -> <<"img">>;
tag(ins) -> <<"ins">>;
tag(head) -> <<"head">>;
tag(header) -> <<"header">>;
tag(html) -> <<"html">>;
tag(input) -> <<"input">>;
tag(label) -> <<"label">>;
tag(li) -> <<"li">>;
tag(link) -> <<"link">>;
tag(main) -> <<"main">>;
tag(meta) -> <<"meta">>;
tag(nav) -> <<"nav">>;
tag(ol) -> <<"ol">>;
tag(p) -> <<"p">>;
tag(span) -> <<"span">>;
tag(summary) -> <<"summary">>;
tag(textarea) -> <<"textarea">>;
tag(time) -> <<"time">>;
tag(title) -> <<"title">>;
tag(ul) -> <<"ul">>;
tag(video) -> <<"video">>.

-spec name(atom()) -> binary().
name(accept) -> <<"accept">>;
name(action) -> <<"action">>;
name(alt) -> <<"alt">>;
name(charset) -> <<"charset">>;
name(class) -> <<"class">>;
name(content) -> <<"content">>;
name(datetime) -> <<"datetime">>;
name(enctype) -> <<"enctype">>;
name(for) -> <<"for">>;
name(height) -> <<"height">>;
name(href) -> <<"href">>;
name(id) -> <<"id">>;
name(lang) -> <<"lang">>;
name(maxlength) -> <<"maxlength">>;
name(method) -> <<"method">>;
name(name) -> <<"name">>;
name(poster) -> <<"poster">>;
name(rel) -> <<"rel">>;
name(preload) -> <<"preload">>;
name(rows) -> <<"rows">>;
name(src) -> <<"src">>;
name(type) -> <<"type">>;
name(value) -> <<"value">>;
name(width) -> <<"width">>.
