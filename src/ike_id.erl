%% Identifiers that must not be mistaken for one another, or for a number
%% somebody typed: each is made only here.
-module(ike_id).

-export([post/1, actor/1, anonymous/0, to_integer/1]).
-export_type([post/0, actor/0]).

%% >>N. a thread is named by its root's
-opaque post() :: {post, pos_integer()}.
-opaque actor() :: {actor, pos_integer()}.

-spec post(pos_integer()) -> post().
post(N) when is_integer(N), N > 0 -> {post, N}.

-spec actor(pos_integer()) -> actor().
actor(N) when is_integer(N), N > 0 -> {actor, N}.

%% the one actor shared by everyone who is nobody; migration 0001 makes it
-spec anonymous() -> actor().
anonymous() -> {actor, 1}.

-spec to_integer(post() | actor()) -> pos_integer().
to_integer({post, N}) -> N;
to_integer({actor, N}) -> N.
