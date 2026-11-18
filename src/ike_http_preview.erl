%% /preview: what a form's ikext text will look like, posted to it by the
%% form's preview button in a tab of its own (formaction, formtarget), so
%% the form keeps what was typed and no script is needed. The button sends
%% the form urlencoded, so a post form's files are never sent here, only
%% their names. Nothing is written; anyone may ask.
-module(ike_http_preview).
-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), State) -> {ok, cowboy_req:req(), State}.
init(Req0, State) ->
    Reply =
        case cowboy_req:method(Req0) of
            <<"POST">> ->
                case ike_http:form(Req0) of
                    {ok, Form, Req} ->
                        Field = fun(Name) -> ike_http_wiki:trimmed(maps:get(Name, Form, <<>>)) end,
                        Title = Field(<<"title">>),
                        Body = Field(<<"body">>),
                        Said = Field(<<"commentary">>),
                        Html = ike_view:preview(
                            Title,
                            {Body, ike_reader:links(Body)},
                            {Said, ike_reader:links(Said)}
                        ),
                        ike_http:page(200, Html, Req);
                    {error, Status, Req} ->
                        ike_http:reply(Status, Req)
                end;
            _ ->
                ike_http:reply(405, Req0)
        end,
    {ok, Reply, State}.
