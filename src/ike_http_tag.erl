%% /booru/N/tags: an account changes a curation's tags and commentary, a
%% revision in its thread, signed if asked (lux). The form is on the
%% entry's page, the same for everyone, so it is guarded as the thread
%% form is; accounts tag directly until proposals (M4, Q34).
-module(ike_http_tag).
-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), State) -> {ok, cowboy_req:req(), State}.
init(Req0, State) ->
    Reply =
        case {cowboy_req:method(Req0), cowboy_req:binding(booru, Req0)} of
            {<<"POST">>, N} when is_integer(N), N > 0 ->
                case {ike_http:guarded(Req0), ike_http_login:session(Req0)} of
                    {true, {ok, _, #{actor := Actor, name := Name}}} -> tag(N, {Actor, Name}, Req0);
                    _ -> ike_http:forbidden(Req0)
                end;
            {<<"POST">>, _} ->
                ike_http:not_found(Req0);
            _ ->
                ike_http:reply(405, Req0)
        end,
    {ok, Reply, State}.

-spec tag(pos_integer(), {ike_id:actor(), binary() | none}, cowboy_req:req()) -> cowboy_req:req().
tag(N, {Actor, Name}, Req0) ->
    Back = <<"/booru/", (integer_to_binary(N))/binary>>,
    case ike_http:form(Req0) of
        {ok, Form, Req} ->
            %% the box is the whole of the entry's tags (lux); a form
            %% without one keeps them
            Box =
                case Form of
                    #{<<"tags">> := Text} -> element(1, ike_tag:layout(Text));
                    _ -> keep
                end,
            %% the box's text as it was sent; a form without one keeps it
            Commentary =
                case Form of
                    #{<<"commentary">> := C} -> ike_http_wiki:trimmed(C);
                    _ -> keep
                end,
            Signed = is_binary(Name) andalso maps:get(<<"signed">>, Form, <<>>) =:= <<"1">>,
            case ike_writer:revise(N, Actor, Signed, Box, Commentary) of
                ok ->
                    _ = ike_render:sync(),
                    ike_http:see_other(Back, Req);
                {error, nothing} ->
                    ike_http:see_other(Back, Req);
                {error, no_such_entry} ->
                    ike_http:not_found(Req);
                {error, bad_text} ->
                    Html = ike_view:message(
                        <<"not saved">>,
                        <<"commentary is text: not too long, no control characters.">>
                    ),
                    ike_http:page(400, Html, Req);
                {error, _} ->
                    ike_http:reply(500, Req)
            end;
        {error, Status, Req} ->
            ike_http:reply(Status, Req)
    end.
