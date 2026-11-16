%% The names of the media origin's files, and their addresses: an asset
%% is <hash>.<ext> with the extension from the type the stripper found
%% (hazard P3), and its thumbnail <hash>.thumb.webp.
-module(ike_media).

-export([file/2, thumb/1, url/2, thumb_url/1, parse/1]).

-spec file(Hex :: binary(), Type :: binary()) -> binary().
file(Hex, Type) ->
    <<Hex/binary, ".", (ext(Type))/binary>>.

-spec thumb(Hex :: binary()) -> binary().
thumb(Hex) ->
    <<Hex/binary, ".thumb.webp">>.

-spec url(Hex :: binary(), Type :: binary()) -> binary().
url(Hex, Type) ->
    <<(ike_config:media_origin())/binary, "/", (file(Hex, Type))/binary>>.

-spec thumb_url(Hex :: binary()) -> binary().
thumb_url(Hex) ->
    <<(ike_config:media_origin())/binary, "/", (thumb(Hex))/binary>>.

-spec ext(binary()) -> binary().
ext(<<"jpeg">>) -> <<"jpg">>;
ext(<<"png">>) -> <<"png">>;
ext(<<"webp">>) -> <<"webp">>;
ext(_) -> <<"bin">>.

%% a file's name back to its asset and what it is served as; nothing
%% else is a name of the media origin's
-spec parse(binary()) -> {ok, Hex :: binary(), Mime :: binary()} | error.
parse(<<Hex:64/binary, ".thumb.webp">>) -> hex(Hex, <<"image/webp">>);
parse(<<Hex:64/binary, ".jpg">>) -> hex(Hex, <<"image/jpeg">>);
parse(<<Hex:64/binary, ".png">>) -> hex(Hex, <<"image/png">>);
parse(<<Hex:64/binary, ".webp">>) -> hex(Hex, <<"image/webp">>);
parse(_) -> error.

-spec hex(binary(), binary()) -> {ok, binary(), binary()} | error.
hex(Hex, Mime) ->
    case <<<<C>> || <<C>> <= Hex, (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f)>> of
        Hex -> {ok, Hex, Mime};
        _ -> error
    end.
