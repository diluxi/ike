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
    Render = #{id => ike_render, start => {ike_render, start_link, []}},
    Session = #{id => ike_session, start => {ike_session, start_link, []}},
    Oidc = #{id => ike_oidc, start => {ike_oidc, start_link, []}},
    Children = [Writer, Render, Session, Oidc, ike_http:child_spec()],
    {ok, {#{strategy => rest_for_one}, Children}}.
