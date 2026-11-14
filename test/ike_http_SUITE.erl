%% Black-box: starts the application and speaks HTTP to it, nothing else.
-module(ike_http_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("proper/include/proper.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([health/1, unknown_paths/1]).

all() -> [health, unknown_paths].

init_per_suite(Config) ->
    _ = application:load(ike),
    ok = application:set_env(
        ike, data_dir, list_to_binary(?config(priv_dir, Config))
    ),
    {ok, _} = application:ensure_all_started([inets, ike]),
    #{port := Port} = application:get_env(ike, listen, #{}),
    [{base, "http://127.0.0.1:" ++ integer_to_list(Port)} | Config].

end_per_suite(_Config) ->
    ok = application:stop(ike).

health(Config) ->
    {200, "ok\n"} = get(Config, "/health").

%% nothing but the routes answers, whatever the path
unknown_paths(Config) ->
    Prop = ?FORALL(
        Segments,
        non_empty(list(non_empty(list(range($a, $z))))),
        begin
            Path = lists:append([[$/ | S] || S <- Segments]),
            Path =:= "/health" orelse element(1, get(Config, Path)) =:= 404
        end
    ),
    true = proper:quickcheck(Prop, [{numtests, 50}, {to_file, user}]).

get(Config, Path) ->
    Url = ?config(base, Config) ++ Path,
    %% plain http; without this httpc looks for the system's ca certificates
    Options = [{ssl, [{verify, verify_none}]}],
    {ok, {{_, Status, _}, _, Body}} = httpc:request(get, {Url, []}, Options, []),
    {Status, Body}.
