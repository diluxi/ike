%% The Cowboy listener: everything Caddy does not serve from disk.
-module(ike_http).

-export([child_spec/0]).

-spec child_spec() -> supervisor:child_spec().
child_spec() ->
    #{ip := Ip, port := Port} = application:get_env(ike, listen, #{}),
    ranch:child_spec(
        ?MODULE,
        ranch_tcp,
        #{socket_opts => [{ip, Ip}, {port, Port}]},
        cowboy_clear,
        #{env => #{dispatch => dispatch()}}
    ).

-spec dispatch() -> cowboy_router:dispatch_rules().
dispatch() ->
    cowboy_router:compile([
        {'_', [
            {"/health", ike_http_health, []}
        ]}
    ]).
