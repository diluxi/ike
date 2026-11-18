%% A stand-in for X, for the suites: the endpoint X's embeds read a tweet
%% from, and its media, on 127.0.0.1; and a canary on another port, which
%% counts whoever reaches it. Some tweets say what an attacker would:
%% media at a link-local or private address, on a host not X's, or a
%% redirect to the canary. This module is the tests', not ike's.
-module(ike_fake_x).
-behaviour(cowboy_handler).

-export([start/1, stop/0, port/0, canary_port/0, hits/0]).
-export([init/2]).

%% Png: the bytes its media is
start(Png) ->
    persistent_term:put({?MODULE, png}, Png),
    persistent_term:put({?MODULE, hits}, counters:new(1, [])),
    X = cowboy_router:compile([
        {'_', [
            {"/tweet-result", ?MODULE, tweet},
            {"/media/:name", ?MODULE, media}
        ]}
    ]),
    Canary = cowboy_router:compile([{'_', [{'_', ?MODULE, canary}]}]),
    {ok, _} = cowboy:start_clear(?MODULE, [{ip, {127, 0, 0, 1}}, {port, 0}], #{
        env => #{dispatch => X}
    }),
    {ok, _} = cowboy:start_clear({?MODULE, canary}, [{ip, {127, 0, 0, 1}}, {port, 0}], #{
        env => #{dispatch => Canary}
    }),
    ok.

stop() ->
    _ = cowboy:stop_listener(?MODULE),
    _ = cowboy:stop_listener({?MODULE, canary}),
    ok.

port() -> ranch:get_port(?MODULE).
canary_port() -> ranch:get_port({?MODULE, canary}).

hits() ->
    counters:get(persistent_term:get({?MODULE, hits}), 1).

init(Req, canary) ->
    counters:add(persistent_term:get({?MODULE, hits}), 1, 1),
    {ok, cowboy_req:reply(200, #{}, <<"reached\n">>, Req), canary};
init(Req, media) ->
    Png = persistent_term:get({?MODULE, png}),
    {ok, cowboy_req:reply(200, #{<<"content-type">> => <<"image/png">>}, Png, Req), media};
init(Req, tweet) ->
    #{id := Id} = cowboy_req:match_qs([id], Req),
    Here = "http://127.0.0.1:" ++ integer_to_list(port()),
    Canary = "http://127.0.0.1:" ++ integer_to_list(canary_port()),
    Media =
        case Id of
            <<"1">> -> Here ++ "/media/AAAA.png";
            <<"2">> -> "https://169.254.169.254/latest/meta-data.png";
            <<"3">> -> "https://10.0.0.1/media/BBBB.png";
            <<"4">> -> "https://pbs.twimg.com.example/media/CCCC.png";
            <<"5">> -> Canary ++ "/media/DDDD.png";
            _ -> none
        end,
    case {Id, Media} of
        {<<"6">>, _} ->
            %% a redirect to the canary, not a host the fetcher may reach
            {ok,
                cowboy_req:reply(
                    302, #{<<"location">> => list_to_binary(Canary ++ "/x")}, <<>>, Req
                ),
                tweet};
        {_, none} ->
            {ok, cowboy_req:reply(404, #{}, <<>>, Req), tweet};
        _ ->
            Tweet = #{
                <<"__typename">> => <<"Tweet">>,
                <<"id_str">> => Id,
                <<"text">> =>
                    <<"a drawing #oc &amp; more, for @friend https://t.co/abc https://t.co/media"/utf8>>,
                <<"created_at">> => <<"2026-03-30T03:29:26.000Z">>,
                <<"entities">> => #{
                    <<"hashtags">> => [#{<<"text">> => <<"oc">>, <<"indices">> => [10, 13]}],
                    <<"user_mentions">> => [
                        #{<<"screen_name">> => <<"friend">>, <<"indices">> => [30, 37]}
                    ],
                    <<"urls">> => [
                        #{
                            <<"url">> => <<"https://t.co/abc">>,
                            <<"expanded_url">> => <<"https://example.org/more">>,
                            <<"indices">> => [38, 54]
                        }
                    ],
                    <<"media">> => [#{<<"indices">> => [55, 73]}]
                },
                <<"user">> => #{
                    <<"name">> => <<"An Artist">>, <<"screen_name">> => <<"an_artist">>
                },
                <<"mediaDetails">> => [
                    #{<<"type">> => <<"photo">>, <<"media_url_https">> => list_to_binary(Media)}
                ]
            },
            {ok,
                cowboy_req:reply(
                    200, #{<<"content-type">> => <<"application/json">>}, json:encode(Tweet), Req
                ),
                tweet}
    end.
