%% The media origin, as far as ike answers it: staged uploads, to whoever
%% holds a link the uploader's page made (invariant 10), and the files of
%% shown posts when no web server in front serves them from disk. Never
%% reached by ike's own host: the router gives this handler the media
%% host alone, so no byte of an upload is ever served from the main
%% origin (invariant 5).
-module(ike_http_media).
-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), State) -> {ok, cowboy_req:req(), State}.
init(Req, public = State) ->
    Reply =
        case {cowboy_req:method(Req), cowboy_req:binding(file, Req)} of
            {Method, Name} when
                (Method =:= <<"GET">> orelse Method =:= <<"HEAD">>), is_binary(Name)
            ->
                case ike_media:parse(Name) of
                    {ok, _, Mime} ->
                        case
                            file:read_file(<<(ike_config:media_dir())/binary, "/", Name/binary>>)
                        of
                            {ok, Bytes} ->
                                Headers = (headers())#{
                                    <<"content-type">> => Mime,
                                    <<"cache-control">> => <<"public, max-age=31536000, immutable">>
                                },
                                cowboy_req:reply(200, Headers, Bytes, Req);
                            {error, _} ->
                                missing(Req)
                        end;
                    error ->
                        missing(Req)
                end;
            _ ->
                missing(Req)
        end,
    {ok, Reply, State};
init(Req, State) ->
    Reply =
        case
            {
                cowboy_req:method(Req),
                cowboy_req:binding(upload, Req),
                cowboy_req:binding(expires, Req),
                cowboy_req:binding(sig, Req),
                cowboy_req:binding(part, Req)
            }
        of
            {Method, Upload, Expires, Sig, Part0} when
                (Method =:= <<"GET">> orelse Method =:= <<"HEAD">>),
                is_integer(Upload),
                is_integer(Expires),
                is_binary(Sig)
            ->
                case part(Part0) of
                    {ok, Part} -> serve(Upload, Expires, Sig, Part, Req);
                    error -> missing(Req)
                end;
            _ ->
                missing(Req)
        end,
    {ok, Reply, State}.

-spec part(term()) -> {ok, ike_staged:part()} | error.
part(undefined) -> {ok, file};
part(<<"thumb">>) -> {ok, thumb};
part(_) -> error.

-spec serve(integer(), integer(), binary(), ike_staged:part(), cowboy_req:req()) ->
    cowboy_req:req().
serve(Upload, Expires, Sig, Part, Req) ->
    case ike_staged:check(Upload, Expires, Sig, Part) andalso ike_reader:staged_file(Upload) of
        {ok, Hex, Type} ->
            {File, Mime} =
                case Part of
                    file -> {Hex, ike_media:mime(Type)};
                    thumb -> {<<Hex/binary, ".thumb">>, <<"image/webp">>}
                end,
            case file:read_file(<<(ike_config:assets_dir())/binary, "/", File/binary>>) of
                {ok, Bytes} ->
                    cowboy_req:reply(200, (headers())#{<<"content-type">> => Mime}, Bytes, Req);
                {error, _} ->
                    missing(Req)
            end;
        _ ->
            missing(Req)
    end.

%% one answer for a link that is wrong, old, or to nothing
-spec missing(cowboy_req:req()) -> cowboy_req:req().
missing(Req) ->
    cowboy_req:reply(404, (headers())#{<<"content-type">> => <<"text/plain">>}, <<>>, Req).

%% the bytes are someone's, typed as the stripper found them, and may
%% neither run nor be sniffed into something that does (hazard P3)
-spec headers() -> cowboy:http_headers().
headers() ->
    #{
        <<"content-security-policy">> => <<"default-src 'none'; sandbox">>,
        <<"x-content-type-options">> => <<"nosniff">>,
        <<"cache-control">> => <<"private, no-store">>,
        <<"referrer-policy">> => <<"no-referrer">>
    }.
