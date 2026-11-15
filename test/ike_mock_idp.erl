%% An OpenID provider for the tests, as small as one can be: discovery,
%% keys, and a token endpoint that hands out what the test told it to.
%% The test plays the browser and the login page itself.
-module(ike_mock_idp).
-behaviour(cowboy_handler).

-export([start/1, stop/0, expect/1, token/3]).
-export([init/2]).

-define(PORT, 8972).

start(Key) ->
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/.well-known/openid-configuration", ?MODULE, discovery},
            {"/jwks", ?MODULE, {jwks, Key}},
            {"/token", ?MODULE, token}
        ]}
    ]),
    {ok, _} = cowboy:start_clear(
        ?MODULE, [{ip, {127, 0, 0, 1}}, {port, ?PORT}], #{env => #{dispatch => Dispatch}}
    ),
    issuer().

stop() ->
    cowboy:stop_listener(?MODULE).

issuer() ->
    <<"http://127.0.0.1:", (integer_to_binary(?PORT))/binary>>.

%% what the next token request must bring, and what it gets back
expect(#{code := _, challenge := _, id_token := _} = Expected) ->
    persistent_term:put(?MODULE, Expected).

%% a compact jws. Alg is what the header claims, Sign makes the signature
token(Alg, Claims, Sign) ->
    Header = b64(json:encode(#{alg => Alg, typ => <<"JWT">>, kid => <<"k1">>})),
    Payload = b64(json:encode(Claims)),
    Input = <<Header/binary, ".", Payload/binary>>,
    <<Input/binary, ".", (b64(Sign(Input)))/binary>>.

init(Req, discovery) ->
    Issuer = issuer(),
    json(Req, discovery, #{
        issuer => Issuer,
        authorization_endpoint => <<Issuer/binary, "/authorize">>,
        token_endpoint => <<Issuer/binary, "/token">>,
        jwks_uri => <<Issuer/binary, "/jwks">>
    });
init(Req, {jwks, {E, N}} = State) ->
    Jwk = #{
        kty => <<"RSA">>,
        use => <<"sig">>,
        alg => <<"RS256">>,
        kid => <<"k1">>,
        e => b64(binary:encode_unsigned(E)),
        n => b64(binary:encode_unsigned(N))
    },
    json(Req, State, #{keys => [Jwk]});
init(Req0, token) ->
    {ok, Form, Req} = cowboy_req:read_urlencoded_body(Req0),
    #{code := Code, challenge := Challenge, id_token := IdToken} =
        persistent_term:get(?MODULE),
    Verifier = proplists:get_value(<<"code_verifier">>, Form, <<>>),
    Proven = b64(crypto:hash(sha256, Verifier)) =:= Challenge,
    case proplists:get_value(<<"code">>, Form) of
        Code when Proven ->
            json(Req, token, #{
                access_token => <<"unused">>, token_type => <<"Bearer">>, id_token => IdToken
            });
        _ ->
            Body = json:encode(#{error => <<"invalid_grant">>}),
            {ok, cowboy_req:reply(400, #{}, Body, Req), token}
    end.

json(Req, State, Term) ->
    Headers = #{<<"content-type">> => <<"application/json">>},
    {ok, cowboy_req:reply(200, Headers, json:encode(Term), Req), State}.

b64(Bin) ->
    base64:encode(iolist_to_binary(Bin), #{mode => urlsafe, padding => false}).
