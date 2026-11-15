%% What the black-box suites share: ike started beside a mock OpenID
%% provider, and a browser to walk through it with. Nothing here calls
%% into ike; the database and the pages are read as files.
-module(ike_browser).

-include_lib("common_test/include/ct.hrl").
-include_lib("public_key/include/public_key.hrl").

-export([start/2, stop/0, restart/0]).
-export([login/2, login/3, begin_login/1, expect/3, callback/3, claims/3, id_token/4]).
-export([post/4, sign/4, cookies/1, request/5, set_cookie/2, cookie_attributes/2]).
-export([query/3, posts/1, page_file/2]).

-define(CLIENT, <<"ike-test">>).

%% Env is ike's application environment beyond the data directory and the
%% provider, and is taken back by stop/0
start(Config, Env) ->
    %% a data directory of its own for each start: suites share priv_dir
    Stamp = integer_to_list(erlang:system_time(microsecond)),
    Dir = list_to_binary(filename:join(?config(priv_dir, Config), "ike-" ++ Stamp)),
    Key = public_key:generate_key({rsa, 2048, 65537}),
    Other = public_key:generate_key({rsa, 2048, 65537}),
    #'RSAPrivateKey'{publicExponent = E, modulus = N} = Key,
    {ok, _} = application:ensure_all_started([inets, cowboy]),
    Issuer = ike_mock_idp:start({E, N}),
    _ = application:load(ike),
    #{port := Port} = application:get_env(ike, listen, #{}),
    Base = "http://127.0.0.1:" ++ integer_to_list(Port),
    Oidc = #{
        issuer => Issuer,
        client_id => ?CLIENT,
        redirect_uri => list_to_binary(Base ++ "/login/callback")
    },
    Boards = [{<<"b">>, <<"random">>}, {<<"meta">>, <<"about ike">>}],
    All = [{data_dir, Dir}, {oidc, Oidc}, {boards, Boards} | Env],
    [ok = application:set_env(ike, K, V) || {K, V} <- All],
    persistent_term:put(?MODULE, [K || {K, _} <- All]),
    {ok, _} = application:ensure_all_started(ike),
    [{base, Base}, {dir, Dir}, {issuer, Issuer}, {key, Key}, {other_key, Other} | Config].

stop() ->
    _ = application:stop(ike),
    [ok = application:unset_env(ike, K) || K <- persistent_term:get(?MODULE)],
    ike_mock_idp:stop().

%% as systemd would: everything in memory is gone
restart() ->
    _ = application:stop(ike),
    {ok, _} = application:ensure_all_started(ike),
    ok.

%% the browser

%% a whole login; returns the session cookie and the form token
login(Config, Subject) ->
    login(Config, Subject, #{}).

%% More is claims over the usual ones
login(Config, Subject, More) ->
    Login = begin_login(Config),
    Code = "code-" ++ binary_to_list(Subject),
    ok = expect(Login, Code, fun(Nonce) -> id_token(Config, Nonce, Subject, More) end),
    {303, Headers, _} = callback(Config, Login, Code),
    "/" = proplists:get_value("location", Headers),
    Id = set_cookie("__Host-ike", Headers),
    Attributes = string:lowercase(cookie_attributes("__Host-ike", Headers)),
    [true = string:find(Attributes, A) =/= nomatch || A <- ["secure", "httponly", "samesite=lax"]],
    Session = #{id => Id},
    {200, _, Form} = request(Config, get, "/board/b/new", cookies(Session), none),
    {match, [Csrf]} = re:run(
        Form, "name=\"csrf\" value=\"([^\"]+)\"", [{capture, all_but_first, list}]
    ),
    Session#{csrf => Csrf}.

begin_login(Config) ->
    {303, Headers, _} = request(Config, get, "/login", [], none),
    #{query := Query} = uri_string:parse(proplists:get_value("location", Headers)),
    Params = uri_string:dissect_query(Query),
    #{
        state => proplists:get_value("state", Params),
        nonce => proplists:get_value("nonce", Params),
        challenge => proplists:get_value("code_challenge", Params),
        binding => set_cookie("__Host-ike-login", Headers)
    }.

%% the provider's login page, played by hand
expect(#{nonce := Nonce, challenge := Challenge}, Code, Token) ->
    ike_mock_idp:expect(#{
        code => list_to_binary(Code),
        challenge => list_to_binary(Challenge),
        id_token => Token(list_to_binary(Nonce))
    }).

callback(Config, #{state := State, binding := Binding}, Code) ->
    Path = "/login/callback?" ++ uri_string:compose_query([{"code", Code}, {"state", State}]),
    request(Config, get, Path, [{"cookie", "__Host-ike-login=" ++ Binding}], none).

claims(Config, Nonce, Subject) ->
    Now = erlang:system_time(second),
    #{
        iss => ?config(issuer, Config),
        aud => ?CLIENT,
        sub => Subject,
        nonce => Nonce,
        iat => Now,
        exp => Now + 300,
        preferred_username => Subject,
        %% a provider says more than is asked for; none of it may be kept
        email => <<Subject/binary, "@example.org">>,
        name => <<"A Person">>
    }.

id_token(Config, Nonce, Subject, More) ->
    Key = ?config(key, Config),
    Claims = maps:merge(claims(Config, Nonce, Subject), More),
    ike_mock_idp:token(<<"RS256">>, Claims, fun(Input) ->
        public_key:sign(Input, sha256, Key)
    end).

post(Config, Path, Session, Text) ->
    post(Config, Path, Session, Text, []).

%% a post with the box ticked that puts the account's name on it
sign(Config, Path, Session, Text) ->
    post(Config, Path, Session, Text, [{<<"signed">>, <<"1">>}]).

post(Config, Path, #{csrf := Csrf} = Session, Text, More) ->
    Form = uri_string:compose_query(
        [{<<"csrf">>, list_to_binary(Csrf)}, {<<"body">>, Text} | More]
    ),
    request(Config, post, Path, cookies(Session), {form, Form}).

cookies(#{id := Id}) ->
    [{"cookie", "__Host-ike=" ++ Id}].

request(Config, Method, Path, Headers, Body) ->
    Url = ?config(base, Config) ++ Path,
    Request =
        case Body of
            none -> {Url, Headers};
            {form, Form} -> {Url, Headers, "application/x-www-form-urlencoded", Form};
            {Type, Bytes} -> {Url, Headers, Type, Bytes}
        end,
    Options = [{autoredirect, false}, {ssl, [{verify, verify_none}]}],
    {ok, {{_, Status, _}, ResponseHeaders, ResponseBody}} =
        httpc:request(Method, Request, Options, [{body_format, binary}]),
    {Status, ResponseHeaders, ResponseBody}.

%% the value a response sets a cookie to, or none
set_cookie(Name, Headers) ->
    case cookie_line(Name, Headers) of
        none -> none;
        Line -> hd(string:split(tl(string:find(Line, "=")), ";"))
    end.

cookie_attributes(Name, Headers) ->
    case cookie_line(Name, Headers) of
        none -> "";
        Line -> Line
    end.

cookie_line(Name, Headers) ->
    Lines = [V || {"set-cookie", V} <- Headers, lists:prefix(Name ++ "=", V)],
    case Lines of
        [] -> none;
        [Line | _] -> Line
    end.

%% the database and the pages, as files

query(Config, Sql, Args) ->
    {ok, Conn} = esqlite3:open(binary_to_list(filename:join(?config(dir, Config), "ike.db"))),
    try
        esqlite3:q(Conn, Sql, Args)
    after
        esqlite3:close(Conn)
    end.

posts(Config) ->
    query(Config, "SELECT count(*) FROM post", []).

page_file(Config, N) ->
    filename:join([?config(dir, Config), "pages", "board", "b", integer_to_list(N) ++ ".html"]).
