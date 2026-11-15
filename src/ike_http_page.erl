%% Serves the rendered pages when no web server in front does (Caddy
%% answers these paths from the same files before a request gets here).
-module(ike_http_page).
-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), State) -> {ok, cowboy_req:req(), State}.
init(Req, missing = State) ->
    {ok, ike_http:not_found(Req), State};
init(Req, State) ->
    Name =
        case cowboy_req:binding(thread, Req) of
            undefined -> <<"index.html">>;
            N when is_integer(N) -> <<"t/", (integer_to_binary(N))/binary, ".html">>
        end,
    Path = <<(ike_config:pages_dir())/binary, "/", Name/binary>>,
    case cowboy_req:method(Req) of
        Method when Method =:= <<"GET">>; Method =:= <<"HEAD">> ->
            case file:read_file(Path) of
                {ok, Page} -> {ok, ike_http:html(200, Page, Req), State};
                {error, _} -> {ok, ike_http:not_found(Req), State}
            end;
        _ ->
            {ok, ike_http:reply(405, Req), State}
    end.
