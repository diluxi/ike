%% Links to staged uploads (hazard G7, invariant 10). The media origin
%% has no session to tell who asks, so a link is its own credential: it
%% names the upload, the part and when it stops working, signed under a
%% key that lives in memory and dies with the node. Only the uploader's
%% own page is ever given one.
-module(ike_staged).

-export([start/0, url/2, check/4]).
-export_type([part/0]).

-type part() :: file | thumb.

-define(KEY, {?MODULE, key}).
%% characters of the signature: 132 bits
-define(SIG, 22).

-spec start() -> ok.
start() ->
    persistent_term:put(?KEY, crypto:strong_rand_bytes(32)).

%% where on the media origin the uploader finds it, for a while
-spec url(Upload :: pos_integer(), part()) -> binary().
url(Upload, Part) ->
    Expires = erlang:system_time(second) + ike_config:staged_seconds(),
    U = integer_to_binary(Upload),
    E = integer_to_binary(Expires),
    Path = <<"/staged/", U/binary, "/", E/binary, "/", (sign(Upload, Expires, Part))/binary>>,
    Tail =
        case Part of
            file -> <<>>;
            thumb -> <<"/thumb">>
        end,
    <<(ike_config:media_origin())/binary, Path/binary, Tail/binary>>.

-spec check(Upload :: integer(), Expires :: integer(), Sig :: binary(), part()) -> boolean().
check(Upload, Expires, Sig, Part) ->
    Expected = sign(Upload, Expires, Part),
    Expires > erlang:system_time(second) andalso byte_size(Sig) =:= byte_size(Expected) andalso
        crypto:hash_equals(Sig, Expected).

-spec sign(integer(), integer(), part()) -> binary().
sign(Upload, Expires, Part) ->
    Key =
        case persistent_term:get(?KEY) of
            K when is_binary(K) -> K
        end,
    Text = iolist_to_binary([
        "staged:",
        integer_to_binary(Upload),
        ":",
        integer_to_binary(Expires),
        ":",
        atom_to_binary(Part)
    ]),
    Mac = base64:encode(crypto:mac(hmac, sha256, Key, Text), #{mode => urlsafe, padding => false}),
    binary:part(Mac, 0, ?SIG).
