%% /booru/search?tags=a b -c d*: entries by their tags, made per request.
%% What the query says of itself is shown only as the names it parsed
%% into, each from the closed set a tag name is.
-module(ike_http_search).
-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), State) -> {ok, cowboy_req:req(), State}.
init(Req, State) ->
    Reply =
        case cowboy_req:method(Req) of
            Method when Method =:= <<"GET">>; Method =:= <<"HEAD">> ->
                Text =
                    try cowboy_req:match_qs([{tags, [], <<>>}], Req) of
                        #{tags := T} when is_binary(T) -> T;
                        _ -> <<>>
                    catch
                        _:_ -> <<>>
                    end,
                Query = ike_tag:query(Text),
                Found =
                    case Query of
                        {[], [], []} -> [];
                        _ -> ike_reader:search(Query)
                    end,
                ike_http:page(200, ike_view:search(ike_tag:said(Text), Found), Req);
            _ ->
                ike_http:reply(405, Req)
        end,
    {ok, Reply, State}.
