%% Wiki page names, and the difference between two revisions. A name is
%% a tag's name that does not start with a dot, since a page's name is
%% also a file's. A page is of a kind, as a tag is, or info, the kind of
%% every page that is no tag's (lux, 2026-11-19), and is written
%% kind/name; a name alone is whichever page or tag has it, while one
%% does. The difference is by lines, the longest common
%% subsequence of the two (as diff(1) has done since 1974, Hunt and
%% McIlroy), computed when a page is shown (planning: diffs at render).
-module(ike_wiki).

-export([name/1, typed/1, kinds/0, path/1, diff/2]).
-export_type([change/0]).

-type change() :: {same | added | removed, binary()}.

%% beyond this many lines a side, the whole is shown as taken and given
-define(MOST, 1000).

%% a page's name as written: kind/name, or a name alone
-spec name(binary()) -> {ok, binary()} | error.
name(Typed) ->
    case typed(Typed) of
        {ok, T} -> {ok, ike_tag:word(T)};
        error -> error
    end.

-spec typed(binary()) -> {ok, ike_tag:typed()} | error.
typed(Typed) ->
    case ike_tag:split(binary:replace(Typed, <<" ">>, <<"_">>, [global])) of
        {Kind, Name0} when Kind =:= any; is_binary(Kind) ->
            case (Kind =:= any orelse lists:member(Kind, kinds())) andalso ike_tag:name(Name0) of
                {ok, <<".", _/binary>>} -> error;
                {ok, Name} -> {ok, {Kind, Name}};
                _ -> error
            end
    end.

%% the kinds of page: a tag's, or info
-spec kinds() -> [binary()].
kinds() -> ike_tag:kinds() ++ [<<"info">>].

%% where a page is, as an href or a Location: a name may hold a ? that
%% would start a query, and a ' that is no use escaped in an href
-spec path(binary()) -> binary().
path(Name) ->
    <<"/wiki/", <<<<(path_byte(B))/binary>> || <<B>> <= Name>>/binary>>.

-spec path_byte(byte()) -> binary().
path_byte($?) -> <<"%3F">>;
path_byte($') -> <<"%27">>;
%% beyond ascii, as %XX: a page's name may be a tag's of any script
path_byte(B) when B >= 128 -> list_to_binary(io_lib:format("%~2.16.0B", [B]));
path_byte(B) -> <<B>>.

-spec diff(Before :: binary(), After :: binary()) -> [change()].
diff(Before, After) ->
    A = lines(Before),
    B = lines(After),
    case length(A) =< ?MOST andalso length(B) =< ?MOST of
        true -> walk(A, B, table(list_to_tuple(A), list_to_tuple(B)));
        false -> [{removed, L} || L <- A] ++ [{added, L} || L <- B]
    end.

%% no text is no lines, not one empty one
-spec lines(binary()) -> [binary()].
lines(<<>>) -> [];
lines(Text) -> binary:split(Text, <<"\n">>, [global]).

%% the lengths of the longest common subsequences of every pair of
%% suffixes, as a map from {I, J}
-spec table(tuple(), tuple()) -> #{{non_neg_integer(), non_neg_integer()} => non_neg_integer()}.
table(A, B) ->
    N = tuple_size(A),
    M = tuple_size(B),
    rows(N, M, A, B, #{}).

-spec rows(non_neg_integer(), non_neg_integer(), tuple(), tuple(), map()) -> map().
rows(0, _M, _A, _B, T) ->
    T;
rows(I, M, A, B, T) ->
    rows(I - 1, M, A, B, cols(I, M, A, B, T)).

-spec cols(pos_integer(), non_neg_integer(), tuple(), tuple(), map()) -> map().
cols(_I, 0, _A, _B, T) ->
    T;
cols(I, J, A, B, T) ->
    L =
        case element(I, A) =:= element(J, B) of
            true -> 1 + maps:get({I + 1, J + 1}, T, 0);
            false -> max(maps:get({I + 1, J}, T, 0), maps:get({I, J + 1}, T, 0))
        end,
    cols(I, J - 1, A, B, T#{{I, J} => L}).

-spec walk([binary()], [binary()], map()) -> [change()].
walk(A, B, T) ->
    walk(A, B, 1, 1, T).

-spec walk([binary()], [binary()], pos_integer(), pos_integer(), map()) -> [change()].
walk([X | As], [X | Bs], I, J, T) ->
    [{same, X} | walk(As, Bs, I + 1, J + 1, T)];
walk([X | As], [Y | Bs], I, J, T) ->
    case maps:get({I + 1, J}, T, 0) >= maps:get({I, J + 1}, T, 0) of
        true -> [{removed, X} | walk(As, [Y | Bs], I + 1, J, T)];
        false -> [{added, Y} | walk([X | As], Bs, I, J + 1, T)]
    end;
walk(As, [], _I, _J, _T) ->
    [{removed, X} || X <- As];
walk([], Bs, _I, _J, _T) ->
    [{added, X} || X <- Bs].
