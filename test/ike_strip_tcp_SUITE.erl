%% The stripper over tcp, as a microvm's or a host of its own's is reached
%% (lux, 2026-11-18): ike sends the upload to an address and port, and
%% what comes back is taken as from a unix socket.
-module(ike_strip_tcp_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([uploads_go_over_tcp/1]).

all() ->
    [uploads_go_over_tcp].

%% ike as the browser harness starts it, its stripper moved to tcp: a
%% second stub, on 127.0.0.1, in place of the unix one
init_per_suite(Config) ->
    Started = ike_browser:start(Config, []),
    ok = application:stop(ike),
    ok = ike_strip_stub:stop(),
    Port = ike_strip_stub:start_tcp(
        filename:join(?config(priv_dir, Config), "strip-tcp"),
        ["2000000", "4096", "16000000", "128"]
    ),
    ok = application:set_env(ike, strip, #{
        socket => {tcp, "127.0.0.1", Port},
        max_bytes => 2000000,
        max_side => 4096,
        max_pixels => 16000000,
        thumb => 128,
        files => 5
    }),
    {ok, _} = application:ensure_all_started(ike),
    Started.

end_per_suite(_Config) ->
    ike_browser:stop().

uploads_go_over_tcp(Config) ->
    {ok, Png} = file:read_file(filename:join(?config(data_dir, Config), "base.png")),
    Session = ike_browser:login(Config, <<"over-tcp">>),
    {303, Sent, _} = ike_browser:upload(Config, Session, [{<<"t.png">>, Png}]),
    "/upload" = proplists:get_value("location", Sent),
    [[1]] = ike_browser:query(
        Config,
        "SELECT count(*) FROM upload u JOIN actor a ON a.id = u.actor WHERE a.subject = 'over-tcp'",
        []
    ),
    %% and nothing listens, nothing is taken, and ike says so
    ok = ike_strip_stub:stop(),
    {422, _, Said} = ike_browser:upload(Config, Session, [{<<"u.png">>, Png}]),
    {_, _} = binary:match(Said, <<"not kept, try again">>).
