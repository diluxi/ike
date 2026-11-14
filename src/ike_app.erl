-module(ike_app).
-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_Type, _Args) ->
    case ike_sup:start_link() of
        {ok, Pid} -> {ok, Pid};
        ignore -> {error, ignore};
        {error, Reason} -> {error, Reason}
    end.

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
