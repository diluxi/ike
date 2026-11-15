-module(ike_app).
-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_Type, _Args) ->
    ok = ike_staged:start(),
    case ike_sup:start_link() of
        {ok, Pid} ->
            {ok, Pid};
        ignore ->
            {error, ignore};
        %% a schema that cannot be brought up to date is the writer
        %% refusing to start; say why, without the supervisor's wrapping
        {error, {shutdown, {failed_to_start_child, ike_writer, Reason}}} ->
            {error, Reason};
        {error, Reason} ->
            {error, Reason}
    end.

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
