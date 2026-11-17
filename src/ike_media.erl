%% The names of the media origin's files, and their addresses: an asset
%% is <hash>.<ext> with the extension from the type the stripper found
%% (hazard P3), and its thumbnail <hash>.thumb.webp.
-module(ike_media).

-export([file/2, thumb/1, url/2, thumb_url/1, parse/1, mime/1, moving/1]).

%% what a type is served as
-spec mime(binary()) -> binary().
mime(<<"webm">>) -> <<"video/webm">>;
mime(<<"mp4">>) -> <<"video/mp4">>;
mime(<<"ttf">>) -> <<"font/ttf">>;
mime(<<"otf">>) -> <<"font/otf">>;
mime(<<"woff">>) -> <<"font/woff">>;
mime(<<"woff2">>) -> <<"font/woff2">>;
mime(Type) -> <<"image/", Type/binary>>.

%% whether a type is shown as a video
-spec moving(binary()) -> boolean().
moving(Type) -> Type =:= <<"webm">> orelse Type =:= <<"mp4">>.

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
ext(<<"webm">>) -> <<"webm">>;
ext(<<"mp4">>) -> <<"mp4">>;
ext(<<"ttf">>) -> <<"ttf">>;
ext(<<"otf">>) -> <<"otf">>;
ext(<<"woff">>) -> <<"woff">>;
ext(<<"woff2">>) -> <<"woff2">>;
ext(_) -> <<"bin">>.

%% a file's name back to its asset and what it is served as; nothing
%% else is a name of the media origin's
-spec parse(binary()) -> {ok, Hex :: binary(), Mime :: binary()} | error.
parse(<<Hex:64/binary, ".thumb.webp">>) -> hex(Hex, <<"image/webp">>);
parse(<<Hex:64/binary, ".jpg">>) -> hex(Hex, <<"image/jpeg">>);
parse(<<Hex:64/binary, ".png">>) -> hex(Hex, <<"image/png">>);
parse(<<Hex:64/binary, ".webp">>) -> hex(Hex, <<"image/webp">>);
parse(<<Hex:64/binary, ".webm">>) -> hex(Hex, <<"video/webm">>);
parse(<<Hex:64/binary, ".mp4">>) -> hex(Hex, <<"video/mp4">>);
parse(<<Hex:64/binary, ".ttf">>) -> hex(Hex, <<"font/ttf">>);
parse(<<Hex:64/binary, ".otf">>) -> hex(Hex, <<"font/otf">>);
parse(<<Hex:64/binary, ".woff">>) -> hex(Hex, <<"font/woff">>);
parse(<<Hex:64/binary, ".woff2">>) -> hex(Hex, <<"font/woff2">>);
parse(_) -> error.

-spec hex(binary(), binary()) -> {ok, binary(), binary()} | error.
hex(Hex, Mime) ->
    case <<<<C>> || <<C>> <= Hex, (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f)>> of
        Hex -> {ok, Hex, Mime};
        _ -> error
    end.
