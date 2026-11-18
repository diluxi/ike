%% /upload/fetch: an account gives a link, and what the fetcher brings from
%% it is uploaded as theirs: each file stripped as any upload, its meta
%% told where it came from, who made it and what they said (lux,
%% 2026-11-18, as Danbooru's upload from a source). Accounts only, at
%% their own pace (hazard N7); the fetcher is a unit of its own that
%% reaches public addresses only (invariant 7), and ike never connects
%% to the link itself.
-module(ike_http_fetch).
-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), State) -> {ok, cowboy_req:req(), State}.
init(Req0, State) ->
    Reply =
        case {cowboy_req:method(Req0), ike_http_login:session(Req0), ike_config:fetch()} of
            {_, _, #{enabled := false}} ->
                ike_http:not_found(Req0);
            {<<"POST">>, {ok, _, #{actor := Actor, csrf := Csrf, name := Name}}, _} ->
                fetched({Actor, Name}, Csrf, Req0);
            {<<"POST">>, error, _} ->
                ike_http:forbidden(Req0);
            _ ->
                ike_http:reply(405, Req0)
        end,
    {ok, Reply, State}.

-spec fetched({ike_id:actor(), binary() | none}, binary(), cowboy_req:req()) ->
    cowboy_req:req().
fetched({Actor, Name}, Csrf, Req0) ->
    case ike_http:form(Req0) of
        {ok, #{<<"csrf">> := Token} = Form, Req} ->
            case byte_size(Token) =:= byte_size(Csrf) andalso crypto:hash_equals(Token, Csrf) of
                true ->
                    Link =
                        case string:trim(maps:get(<<"link">>, Form, <<>>)) of
                            L when is_binary(L) -> L;
                            _ -> <<>>
                        end,
                    Private = maps:get(<<"private">>, Form, <<>>) =:= <<"1">>,
                    Signed = is_binary(Name) andalso maps:get(<<"signed">>, Form, <<>>) =:= <<"1">>,
                    case Link =/= <<>> andalso ike_limit:fetch(ike_id:to_integer(Actor)) of
                        ok ->
                            brought(Actor, Link, Private, Signed, Req);
                        limited ->
                            said(
                                429,
                                <<"slow down">>,
                                <<"links are fetched only so often. try again in a while.">>,
                                Req
                            );
                        false ->
                            ike_http:reply(400, Req)
                    end;
                false ->
                    ike_http:forbidden(Req)
            end;
        {ok, _, Req} ->
            ike_http:forbidden(Req);
        {error, Status, Req} ->
            ike_http:reply(Status, Req)
    end.

-spec brought(ike_id:actor(), binary(), boolean(), boolean(), cowboy_req:req()) ->
    cowboy_req:req().
brought(Actor, Link, Private, Signed, Req) ->
    case ike_fetch:run(Link) of
        {ok, #{files := Files} = Fetched} ->
            Source = maps:with([source, artist, artist_url, commentary], Fetched),
            Results = [kept(Actor, Bytes, Private, Signed, Source) || Bytes <- Files],
            case [H || {ok, H} <- Results] of
                [] ->
                    said(422, <<"not fetched">>, <<"nothing it brought was taken.">>, Req);
                [Hash] ->
                    Viewer = #{actor => ike_id:to_integer(Actor), moderator => false},
                    case ike_reader:known(Hash, Viewer) of
                        {ok, #{id := Meta}} ->
                            ike_http:see_other(
                                <<"/trunk/", (integer_to_binary(Meta))/binary>>, Req
                            );
                        none ->
                            ike_http:see_other(<<"/upload">>, Req)
                    end;
                _ ->
                    ike_http:see_other(<<"/upload">>, Req)
            end;
        {no, Reason} ->
            said(422, <<"not fetched">>, <<"the link was not fetched: ", Reason/binary, ".">>, Req);
        {error, unavailable} ->
            said(503, <<"not fetched">>, <<"the fetcher did not answer. try again.">>, Req)
    end.

%% one file: stripped and kept as the account's upload, with where it
%% came from; its asset's hash
-spec kept(ike_id:actor(), binary(), boolean(), boolean(), map()) -> {ok, binary()} | error.
kept(Actor, Bytes, Private, Signed, Source) ->
    case ike_strip:run(Bytes) of
        {ok, #{stored := Stored} = Stripped} ->
            Upload = #{
                actor => Actor,
                original => Bytes,
                stripped => Stripped,
                private => Private,
                signed => Signed,
                source => Source
            },
            case ike_writer:upload(Upload) of
                {ok, _} -> {ok, crypto:hash(sha256, Stored)};
                {error, _} -> error
            end;
        _ ->
            error
    end.

-spec said(cowboy:http_status(), binary(), binary(), cowboy_req:req()) -> cowboy_req:req().
said(Status, Title, Text, Req) ->
    ike_http:page(Status, ike_view:message(Title, Text), Req).
