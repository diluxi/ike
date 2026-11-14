-module(ike_app).
-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_Type, _Args) ->
    case migrate() of
        ok ->
            case ike_sup:start_link() of
                {ok, Pid} -> {ok, Pid};
                ignore -> {error, ignore};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% the schema is brought up to date before anything that reads it starts
-spec migrate() -> ok | {error, term()}.
migrate() ->
    Dir = data_dir(),
    case filelib:ensure_path(Dir) of
        ok ->
            case ike_db:open(<<Dir/binary, "/ike.db">>) of
                {ok, Conn} ->
                    Result = ike_migrate:run(Conn),
                    _ = ike_db:close(Conn),
                    Result;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, {data_dir, Reason}}
    end.

-spec data_dir() -> binary().
data_dir() ->
    case application:get_env(ike, data_dir) of
        {ok, Dir} when is_binary(Dir) -> Dir;
        _ -> error({badenv, data_dir})
    end.

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
