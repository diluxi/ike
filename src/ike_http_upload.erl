%% /upload: an account brings images, which wait, staged, for a post
%% (planning, Upload; hazard G7). The form is multipart, the one form
%% that is; each file goes to the stripper before anything is kept, and
%% what is kept is what the stripper made of it (invariant 6). Staged
%% uploads are listed here for their uploader, and each asset's meta in
%% the trunk: public unless the private box is ticked (invariant 10).
-module(ike_http_upload).
-behaviour(cowboy_handler).

-export([init/2]).

%% bytes and milliseconds for reading a part
-define(CHUNK, 1048576).
-define(PERIOD, 15000).
-define(FIELD, 1024).

-spec init(cowboy_req:req(), State) -> {ok, cowboy_req:req(), State}.
init(Req, State) ->
    Reply =
        case {cowboy_req:method(Req), ike_http_login:session(Req)} of
            {<<"GET">>, {ok, _, #{actor := Actor, csrf := Csrf, name := Name}}} ->
                page(200, {Actor, Name}, Csrf, [], Req);
            {<<"GET">>, error} ->
                ike_http:page(200, ike_view:upload_locked(), Req);
            {<<"POST">>, {ok, _, #{actor := Actor, csrf := Csrf, name := Name}}} ->
                submit({Actor, Name}, Csrf, Req);
            {<<"POST">>, error} ->
                ike_http:forbidden(Req);
            _ ->
                ike_http:reply(405, Req)
        end,
    {ok, Reply, State}.

%% an account, and its name if it has one to sign with
-type who() :: {ike_id:actor(), binary() | none}.

-spec page(cowboy:http_status(), who(), binary(), [binary()], cowboy_req:req()) ->
    cowboy_req:req().
page(Status, {Actor, Name}, Csrf, Refused, Req) ->
    Staged = [
        S#{
            file => ike_staged:url(Id, file),
            thumb => ike_staged:url(Id, thumb)
        }
     || #{id := Id} = S <- ike_reader:staged(ike_id:to_integer(Actor))
    ],
    Posted = ike_reader:posted(ike_id:to_integer(Actor)),
    ike_http:page(
        Status,
        ike_view:upload(
            {Csrf, Name, maps:get(enabled, ike_config:fetch())}, Refused, Staged, Posted
        ),
        Req
    ).

-spec submit(who(), binary(), cowboy_req:req()) -> cowboy_req:req().
submit(Actor, Csrf, Req0) ->
    case multipart(Req0) of
        true ->
            %% the token comes first, as the form puts it: no file is read,
            %% let alone stripped, for a form from anywhere else
            case field(Req0) of
                {ok, <<"csrf">>, Token, Req1} ->
                    case same(Token, Csrf) of
                        true ->
                            files(Actor, Csrf, Req1, 0, [], #{
                                private => false, signed => false, found => none
                            });
                        false ->
                            ike_http:forbidden(Req1)
                    end;
                {_, Req1} ->
                    ike_http:forbidden(Req1)
            end;
        false ->
            ike_http:reply(415, Req0)
    end.

-spec multipart(cowboy_req:req()) -> boolean().
multipart(Req) ->
    try cowboy_req:parse_header(<<"content-type">>, Req) of
        {<<"multipart">>, <<"form-data">>, _} -> true;
        _ -> false
    catch
        _:_ -> false
    end.

%% the next part, if it is a plain field
-spec field(cowboy_req:req()) ->
    {ok, binary(), binary(), cowboy_req:req()} | {other, cowboy_req:req()}.
field(Req0) ->
    try cowboy_req:read_part(Req0, #{length => ?FIELD, period => ?PERIOD}) of
        {ok, Headers, Req1} ->
            case form_data(Headers) of
                {data, Name} ->
                    case cowboy_req:read_part_body(Req1, #{length => ?FIELD, period => ?PERIOD}) of
                        {ok, Value, Req2} -> {ok, Name, Value, Req2};
                        {more, _, Req2} -> {other, Req2}
                    end;
                _ ->
                    {other, Req1}
            end;
        {done, Req1} ->
            {other, Req1}
    catch
        _:_ -> {other, Req0}
    end.

%% each file part in turn, stripped and kept, or refused with a reason
%% Opts: what the boxes ticked, which the form puts before the files so
%% that they hold for every one of them (private, sign), and the meta an
%% upload of known bytes found (lux, Q41: the uploader is sent to it)
-type opts() :: #{private := boolean(), signed := boolean(), found := none | binary()}.

-spec files(who(), binary(), cowboy_req:req(), non_neg_integer(), [binary()], opts()) ->
    cowboy_req:req().
files(Actor, Csrf, Req0, Count, Refused, Opts) ->
    #{max_bytes := Max, files := Most} = ike_config:strip(),
    try cowboy_req:read_part(Req0, #{length => ?FIELD, period => ?PERIOD}) of
        {ok, Headers, Req1} ->
            case form_data(Headers) of
                {file, <<"file">>, _Filename, _Type} when Count < Most ->
                    case body(Req1, Max, <<>>) of
                        {ok, <<>>, Req2} ->
                            files(Actor, Csrf, Req2, Count, Refused, Opts);
                        {ok, Bytes, Req2} ->
                            {Lines, Opts1} = kept(Actor, Count + 1, Bytes, Opts),
                            files(Actor, Csrf, Req2, Count + 1, Refused ++ Lines, Opts1);
                        {too_large, Req2} ->
                            Html = ike_view:message(
                                <<"too large">>, <<"a file was larger than this site takes.">>
                            ),
                            ike_http:page(413, Html, Req2)
                    end;
                {data, Box} when Count =:= 0, (Box =:= <<"private">> orelse Box =:= <<"signed">>) ->
                    case cowboy_req:read_part_body(Req1, #{length => ?FIELD, period => ?PERIOD}) of
                        {ok, Value, Req2} ->
                            Key =
                                case Box of
                                    <<"private">> -> private;
                                    <<"signed">> -> signed
                                end,
                            files(Actor, Csrf, Req2, Count, Refused, Opts#{Key := Value =:= <<"1">>});
                        {more, _, Req2} ->
                            ike_http:reply(400, Req2)
                    end;
                _ ->
                    ike_http:reply(400, Req1)
            end;
        {done, Req1} ->
            case {Refused, Opts} of
                %% one file, whose bytes were here before: to what is known
                %% of them, its entry if it has one
                {[], #{found := Found}} when Count =:= 1, is_binary(Found) ->
                    ike_http:see_other(Found, Req1);
                {[], _} ->
                    ike_http:see_other(<<"/upload">>, Req1);
                _ ->
                    page(422, Actor, Csrf, Refused, Req1)
            end
    catch
        _:_ -> ike_http:reply(400, Req0)
    end.

-spec form_data(cowboy:http_headers()) ->
    {data, binary()} | {file, binary(), binary(), binary()}.
form_data(Headers) ->
    cow_multipart:form_data(#{K => V || K := V <- Headers, is_binary(V)}).

-spec body(cowboy_req:req(), integer(), binary()) ->
    {ok, binary(), cowboy_req:req()} | {too_large, cowboy_req:req()}.
body(Req0, Left, Acc) ->
    case cowboy_req:read_part_body(Req0, #{length => ?CHUNK, period => ?PERIOD}) of
        {_, Data, Req} when byte_size(Data) > Left ->
            {too_large, Req};
        {ok, Data, Req} ->
            {ok, <<Acc/binary, Data/binary>>, Req};
        {more, Data, Req} ->
            body(Req, Left - byte_size(Data), <<Acc/binary, Data/binary>>)
    end.

%% one file: what the stripper made of it, kept; or not taken, said the
%% same way whatever the reason, so that a refused hash reads like a
%% file that is no image (hazard P6). bytes already in the trunk, where
%% the uploader may see them, are noted, to be sent there
-spec kept(who(), pos_integer(), binary(), opts()) -> {[binary()], opts()}.
kept({Actor, Name}, N, Bytes, #{private := Private, signed := Signed0} = Opts) ->
    %% signed only with a name to sign with, as a post
    Signed = Signed0 andalso is_binary(Name),
    Which = <<"file ", (integer_to_binary(N))/binary, ": ">>,
    case ike_strip:run(Bytes) of
        {ok, #{stored := Stored} = Stripped} ->
            Hash = crypto:hash(sha256, Stored),
            Viewer = #{actor => ike_id:to_integer(Actor), moderator => false},
            Before = ike_reader:known(Hash, Viewer),
            case
                ike_writer:upload(#{
                    actor => Actor,
                    original => Bytes,
                    stripped => Stripped,
                    private => Private,
                    signed => Signed
                })
            of
                {ok, _} ->
                    Found =
                        case Before of
                            {ok, #{entry := E}} when is_integer(E) ->
                                <<"/booru/", (integer_to_binary(E))/binary>>;
                            {ok, #{id := M}} ->
                                <<"/trunk/", (integer_to_binary(M))/binary>>;
                            none ->
                                none
                        end,
                    {[], Opts#{found := Found}};
                {error, refused} ->
                    {[<<Which/binary, "not taken">>], Opts};
                {error, _} ->
                    {[<<Which/binary, "not kept, try again">>], Opts}
            end;
        {no, _Reason} ->
            {[<<Which/binary, "not taken">>], Opts};
        {error, unavailable} ->
            {[<<Which/binary, "not kept, try again">>], Opts}
    end.

-spec same(binary(), binary()) -> boolean().
same(A, B) ->
    byte_size(A) =:= byte_size(B) andalso crypto:hash_equals(A, B).
