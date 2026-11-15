-module(ike_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    Writer = #{id => ike_writer, start => {ike_writer, start_link, []}},
    %% everything after the writer reads a schema the writer has migrated
    {ok, {#{strategy => rest_for_one}, [Writer, ike_http:child_spec()]}}.
