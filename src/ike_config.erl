%% What the environment says, checked where it is read.
-module(ike_config).

-export([data_dir/0, db_path/0, pages_dir/0]).

-spec data_dir() -> binary().
data_dir() ->
    case application:get_env(ike, data_dir) of
        {ok, Dir} when is_binary(Dir) -> Dir;
        _ -> error({badenv, data_dir})
    end.

-spec db_path() -> binary().
db_path() ->
    <<(data_dir())/binary, "/ike.db">>.

%% the rendered pages: derived, so they may live apart from the database
-spec pages_dir() -> binary().
pages_dir() ->
    case application:get_env(ike, pages_dir) of
        {ok, Dir} when is_binary(Dir) -> Dir;
        _ -> <<(data_dir())/binary, "/pages">>
    end.
