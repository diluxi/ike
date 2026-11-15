%% The OIDC client (hazard i1): authorization code with PKCE, state and
%% nonce checked, the id token's signature verified against the issuer's
%% keys, issuer and audience pinned. What it learns about a person is
%% their subject, and nothing else is kept.
-module(ike_oidc).
-behaviour(gen_server).

-export([start_link/0, authorize_url/1, subject/2]).
-export([init/1, handle_call/3, handle_cast/2]).

-type provider() :: #{
    authorization_endpoint := binary(),
    token_endpoint := binary(),
    jwks_uri := binary()
}.
-type key() :: {Kid :: term(), E :: binary(), N :: binary()}.
-type error() :: {error, term()}.

-record(state, {
    provider = none :: none | provider(),
    keys = [] :: [key()],
    %% monotonic seconds; keys are asked for again after a while, and at
    %% most this often when a token names one that isn't known
    fetched = none :: none | integer()
}).

-define(KEYS_FRESH, 3600).
-define(KEYS_RETRY, 60).
-define(HTTP_TIMEOUT, 5000).
%% seconds a clock may be off by
-define(LEEWAY, 60).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% where to send the browser
-spec authorize_url(ike_session:login()) -> {ok, binary()} | error().
authorize_url(#{state := State, nonce := Nonce, verifier := Verifier}) ->
    case ike_config:oidc() of
        {ok, #{client_id := ClientId, redirect_uri := RedirectUri}} ->
            case provider() of
                {ok, #{authorization_endpoint := Endpoint}} ->
                    Challenge = base64:encode(
                        crypto:hash(sha256, Verifier),
                        #{mode => urlsafe, padding => false}
                    ),
                    Query = uri_string:compose_query([
                        {<<"response_type">>, <<"code">>},
                        {<<"client_id">>, ClientId},
                        {<<"redirect_uri">>, RedirectUri},
                        {<<"scope">>, <<"openid profile">>},
                        {<<"state">>, State},
                        {<<"nonce">>, Nonce},
                        {<<"code_challenge">>, Challenge},
                        {<<"code_challenge_method">>, <<"S256">>}
                    ]),
                    case Query of
                        Q when is_binary(Q) -> {ok, <<Endpoint/binary, "?", Q/binary>>};
                        _ -> {error, bad_query}
                    end;
                {error, _} = Error ->
                    Error
            end;
        error ->
            {error, not_configured}
    end.

%% trades the code for an id token and returns who it is about
-spec subject(Code :: binary(), ike_session:login()) ->
    {ok, Issuer :: binary(), Subject :: binary(), Nick :: binary() | none} | error().
subject(Code, #{nonce := Nonce, verifier := Verifier}) ->
    case ike_config:oidc() of
        {ok, #{issuer := Issuer, client_id := ClientId} = Config} ->
            case provider() of
                {ok, #{token_endpoint := Endpoint}} ->
                    case token(Endpoint, Code, Verifier, Config) of
                        {ok, IdToken} ->
                            case verify(IdToken, Issuer, ClientId, Nonce) of
                                {ok, Subject, Nick} -> {ok, Issuer, Subject, Nick};
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        error ->
            {error, not_configured}
    end.

-spec provider() -> {ok, provider()} | error().
provider() ->
    case gen_server:call(?MODULE, provider, 3 * ?HTTP_TIMEOUT) of
        {ok, #{authorization_endpoint := A, token_endpoint := T, jwks_uri := J}} when
            is_binary(A), is_binary(T), is_binary(J)
        ->
            {ok, #{authorization_endpoint => A, token_endpoint => T, jwks_uri => J}};
        {error, Reason} ->
            {error, Reason};
        Other ->
            {error, Other}
    end.

-spec key(Kid :: term()) -> {ok, E :: binary(), N :: binary()} | error().
key(Kid) ->
    case gen_server:call(?MODULE, {key, Kid}, 3 * ?HTTP_TIMEOUT) of
        {ok, E, N} when is_binary(E), is_binary(N) -> {ok, E, N};
        {error, Reason} -> {error, Reason};
        Other -> {error, Other}
    end.

%% the token request

-spec token(binary(), binary(), binary(), ike_config:oidc()) ->
    {ok, binary()} | error().
token(Endpoint, Code, Verifier, #{client_id := ClientId, redirect_uri := RedirectUri} = Config) ->
    Form = [
        {<<"grant_type">>, <<"authorization_code">>},
        {<<"code">>, Code},
        {<<"redirect_uri">>, RedirectUri},
        {<<"code_verifier">>, Verifier}
    ],
    %% a confidential client authenticates with its secret, a public one
    %% only names itself and relies on pkce
    Client =
        case maps:get(client_secret, Config, none) of
            none ->
                {ok, [], [{<<"client_id">>, ClientId}]};
            Secret when is_binary(Secret) ->
                Pair = <<(quote(ClientId))/binary, ":", (quote(Secret))/binary>>,
                Basic = "Basic " ++ binary_to_list(base64:encode(Pair)),
                {ok, [{"authorization", Basic}], []}
        end,
    case Client of
        {ok, Headers, Extra} ->
            case uri_string:compose_query(Form ++ Extra) of
                Body when is_binary(Body) ->
                    case submit(Endpoint, Headers, Body) of
                        {ok, #{<<"id_token">> := IdToken}} when is_binary(IdToken) ->
                            {ok, IdToken};
                        {ok, _} ->
                            {error, no_id_token};
                        {error, _} = Error ->
                            Error
                    end;
                _ ->
                    {error, bad_form}
            end
    end.

-spec quote(binary()) -> binary().
quote(Value) ->
    case uri_string:quote(Value) of
        Quoted when is_binary(Quoted) -> Quoted;
        _ -> <<>>
    end.

%% the id token (a jws in compact form)

-spec verify(binary(), binary(), binary(), binary()) ->
    {ok, Subject :: binary(), Nick :: binary() | none} | error().
verify(IdToken, Issuer, ClientId, Nonce) ->
    case binary:split(IdToken, <<".">>, [global]) of
        [Header64, Claims64, Signature64] ->
            case {decode(Header64), decode(Claims64), unbase64(Signature64)} of
                {{ok, Header}, {ok, Claims}, {ok, Signature}} ->
                    Signed = <<Header64/binary, ".", Claims64/binary>>,
                    case signed(Header, Signed, Signature) of
                        ok -> claims(Claims, Issuer, ClientId, Nonce);
                        {error, _} = Error -> Error
                    end;
                _ ->
                    {error, bad_token}
            end;
        _ ->
            {error, bad_token}
    end.

%% rs256 and nothing else: what the header says only picks the key, never
%% the algorithm
-spec signed(map(), binary(), binary()) -> ok | error().
signed(#{<<"alg">> := <<"RS256">>} = Header, Signed, Signature) ->
    case key(maps:get(<<"kid">>, Header, none)) of
        {ok, E, N} ->
            try crypto:verify(rsa, sha256, Signed, Signature, [E, N]) of
                true -> ok;
                false -> {error, bad_signature}
            catch
                error:_ -> {error, bad_signature}
            end;
        {error, _} = Error ->
            Error
    end;
signed(_Header, _Signed, _Signature) ->
    {error, bad_algorithm}.

-spec claims(map(), binary(), binary(), binary()) ->
    {ok, Subject :: binary(), Nick :: binary() | none} | error().
claims(Claims, Issuer, ClientId, Nonce) ->
    Now = erlang:system_time(second),
    Checks = [
        {issuer, maps:get(<<"iss">>, Claims, none) =:= Issuer},
        {audience, audience(Claims, ClientId)},
        {nonce, maps:get(<<"nonce">>, Claims, none) =:= Nonce},
        {expired,
            case maps:get(<<"exp">>, Claims, none) of
                Exp when is_integer(Exp) -> Exp + ?LEEWAY > Now;
                _ -> false
            end},
        {not_yet,
            case maps:get(<<"iat">>, Claims, none) of
                Iat when is_integer(Iat) -> Iat - ?LEEWAY =< Now;
                _ -> false
            end}
    ],
    case [Name || {Name, false} <- Checks] of
        [] ->
            case maps:get(<<"sub">>, Claims, none) of
                Subject when is_binary(Subject), byte_size(Subject) > 0 ->
                    {ok, Subject, nick(maps:get(<<"preferred_username">>, Claims, none))};
                _ ->
                    {error, {bad_claim, subject}}
            end;
        [Name | _] ->
            {error, {bad_claim, Name}}
    end.

%% what the account is called, if the provider says and it is a name
%% that can stand in a path: letters, digits, dot, dash and underscore.
%% anything else is no name, and the login goes on without one
-spec nick(term()) -> binary() | none.
nick(Name) when is_binary(Name), byte_size(Name) >= 1, byte_size(Name) =< 32 ->
    case plain(Name) of
        true -> Name;
        false -> none
    end;
nick(_) ->
    none.

-spec plain(binary()) -> boolean().
plain(<<C, Rest/binary>>) when
    C >= $a, C =< $z; C >= $A, C =< $Z; C >= $0, C =< $9; C =:= $_; C =:= $-
->
    plain(Rest);
plain(<<$., Rest/binary>>) when byte_size(Rest) > 0 ->
    plain(Rest);
plain(<<>>) ->
    true;
plain(_) ->
    false.

%% the token is for this client: alone, or among others with azp saying so
-spec audience(map(), binary()) -> boolean().
audience(Claims, ClientId) ->
    case maps:get(<<"aud">>, Claims, none) of
        ClientId ->
            true;
        [ClientId] ->
            true;
        Audiences when is_list(Audiences) ->
            lists:member(ClientId, Audiences) andalso
                maps:get(<<"azp">>, Claims, none) =:= ClientId;
        _ ->
            false
    end.

-spec decode(binary()) -> {ok, map()} | error.
decode(Part) ->
    case unbase64(Part) of
        {ok, Json} -> json_object(Json);
        error -> error
    end.

-spec unbase64(binary()) -> {ok, binary()} | error.
unbase64(Part) ->
    try base64:decode(Part, #{mode => urlsafe, padding => false}) of
        Decoded -> {ok, Decoded}
    catch
        error:_ -> error
    end.

-spec json_object(binary()) -> {ok, map()} | error.
json_object(Json) ->
    try json:decode(Json) of
        Object when is_map(Object) -> {ok, Object};
        _ -> error
    catch
        error:_ -> error
    end.

%% gen_server: remembers what the issuer published

-spec init([]) -> {ok, #state{}}.
init([]) ->
    {ok, #state{}}.

-spec handle_call(term(), gen_server:from(), #state{}) -> {reply, term(), #state{}}.
handle_call(provider, _From, State0) ->
    case discovered(State0) of
        {ok, #state{provider = Provider} = State} -> {reply, {ok, Provider}, State};
        {error, _} = Error -> {reply, Error, State0}
    end;
handle_call({key, Kid}, _From, State0) ->
    case discovered(State0) of
        {ok, State1} ->
            State = refreshed(State1, Kid),
            {reply, find(Kid, State#state.keys), State};
        {error, _} = Error ->
            {reply, Error, State0}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, bad_request}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_Request, State) ->
    {noreply, State}.

-spec discovered(#state{}) -> {ok, #state{}} | error().
discovered(#state{provider = none} = State) ->
    case ike_config:oidc() of
        {ok, #{issuer := Issuer}} ->
            Url = <<Issuer/binary, "/.well-known/openid-configuration">>,
            case fetch(Url) of
                {ok, #{
                    <<"issuer">> := Issuer,
                    <<"authorization_endpoint">> := A,
                    <<"token_endpoint">> := T,
                    <<"jwks_uri">> := J
                }} when is_binary(A), is_binary(T), is_binary(J) ->
                    Provider = #{
                        authorization_endpoint => A,
                        token_endpoint => T,
                        jwks_uri => J
                    },
                    {ok, State#state{provider = Provider}};
                {ok, _} ->
                    %% not a discovery document, or one for another issuer
                    {error, bad_discovery};
                {error, _} = Error ->
                    Error
            end;
        error ->
            {error, not_configured}
    end;
discovered(State) ->
    {ok, State}.

%% fetch the keys when there are none, when they are old, or when a token
%% names one that isn't among them (the issuer rotated)
-spec refreshed(#state{}, term()) -> #state{}.
refreshed(#state{provider = #{jwks_uri := Url}, keys = Keys, fetched = Fetched} = State, Kid) ->
    Now = erlang:monotonic_time(second),
    Age =
        case Fetched of
            none -> infinity;
            _ -> Now - Fetched
        end,
    Known =
        case find(Kid, Keys) of
            {ok, _, _} -> true;
            _ -> false
        end,
    Due =
        Age =:= infinity orelse Age > ?KEYS_FRESH orelse
            (not Known andalso Age > ?KEYS_RETRY),
    case Due of
        true ->
            case fetch(Url) of
                {ok, #{<<"keys">> := Jwks}} when is_list(Jwks) ->
                    State#state{keys = rsa_keys(Jwks), fetched = Now};
                _ ->
                    State#state{fetched = Now}
            end;
        false ->
            State
    end;
refreshed(State, _Kid) ->
    State.

-spec rsa_keys([term()]) -> [key()].
rsa_keys([#{<<"kty">> := <<"RSA">>, <<"n">> := N64, <<"e">> := E64} = Jwk | Rest]) when
    is_binary(N64), is_binary(E64)
->
    case {unbase64(E64), unbase64(N64), maps:get(<<"use">>, Jwk, <<"sig">>)} of
        {{ok, E}, {ok, N}, <<"sig">>} ->
            [{maps:get(<<"kid">>, Jwk, none), E, N} | rsa_keys(Rest)];
        _ ->
            rsa_keys(Rest)
    end;
rsa_keys([_ | Rest]) ->
    rsa_keys(Rest);
rsa_keys([]) ->
    [].

%% a token without a kid is fine while the issuer has exactly one key
-spec find(term(), [key()]) -> {ok, binary(), binary()} | error().
find(none, [{_, E, N}]) ->
    {ok, E, N};
find(none, _) ->
    {error, unknown_key};
find(Kid, Keys) ->
    case lists:keyfind(Kid, 1, Keys) of
        {_, E, N} when is_binary(E), is_binary(N) -> {ok, E, N};
        _ -> {error, unknown_key}
    end.

%% http, to the issuer only

-spec fetch(binary()) -> {ok, map()} | error().
fetch(Url) ->
    response(httpc:request(get, {binary_to_list(Url), []}, http_options(Url), options())).

-spec submit(binary(), [{string(), string()}], binary()) -> {ok, map()} | error().
submit(Url, Headers, Body) ->
    Request = {binary_to_list(Url), Headers, "application/x-www-form-urlencoded", Body},
    response(httpc:request(post, Request, http_options(Url), options())).

-spec options() -> [{body_format, binary}].
options() ->
    [{body_format, binary}].

-spec http_options(binary()) ->
    [
        {timeout, timeout()}
        | {connect_timeout, timeout()}
        | {autoredirect, boolean()}
        | {ssl, [ssl:tls_option()]}
    ].
http_options(Url) ->
    Common = [{timeout, ?HTTP_TIMEOUT}, {connect_timeout, ?HTTP_TIMEOUT}, {autoredirect, false}],
    case Url of
        <<"https://", _/binary>> ->
            Tls = [
                {verify, verify_peer},
                {cacerts, public_key:cacerts_get()},
                {customize_hostname_check, [
                    {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
                ]}
            ],
            [{ssl, Tls} | Common];
        _ ->
            %% plain http: a test's issuer, or one on this host. no tls
            %% happens, but without the option httpc goes looking for the
            %% system's certificates and falls over where there are none
            [{ssl, [{verify, verify_none}]} | Common]
    end.

-spec response(term()) -> {ok, map()} | error().
response({ok, {{_, 200, _}, _Headers, Body}}) when is_binary(Body) ->
    case json_object(Body) of
        {ok, Object} -> {ok, Object};
        error -> {error, bad_json}
    end;
response({ok, {{_, Status, _}, _Headers, _Body}}) ->
    {error, {http, Status}};
response({error, _Reason}) ->
    %% the reason can hold addresses and request bodies; neither is for
    %% the caller, who would log it
    {error, unreachable};
response(_) ->
    {error, unreachable}.
