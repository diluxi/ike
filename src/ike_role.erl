%% Who may do what (planning.md, Moderation). A role is what the
%% provider's groups made of an account when it logged in; it lives as
%% long as the session and no longer (hazard i5). Roles are ranked:
%% janitor < moderator < admin. A janitor looks after some boards, a
%% moderator after all of them.
-module(ike_role).

-export([of_groups/1, may/2, permits/3, rank/1, rank_of/1]).
-export([kinds/0, kind/1, to_binary/1, encode/1, decode/2, check/1]).
-export_type([role/0, kind/0, facts/0]).

-type role() :: admin | moderator | {janitor, [binary()]}.
%% the rungs of the ladder, and their way back down
-type kind() ::
    hide
    | unhide
    | trash
    | restore
    | purge
    | ban
    | unban
    | lock
    | unlock
    %% a post's image: its hashes refused from now on, or that undone;
    %% or destroyed wherever it is used, and refused for good
    | block
    | unblock
    | purge_image.
%% what is known of the target: the board it is on (any for an account
%% or a board), whether the account is the actor's own, the account's
%% rank, and the rank of whoever put it in the state it is in
-type facts() :: #{
    board := binary() | any,
    self := boolean(),
    account := 0..3,
    undo := 0..4
}.

%% the highest role any of the groups gives
-spec of_groups([binary()]) -> role() | none.
of_groups(Groups) ->
    #{admin := Admin, moderator := Moderator, janitor := Janitor} = ike_config:roles(),
    case {member(Admin, Groups), member(Moderator, Groups), boards(Janitor, Groups)} of
        {true, _, _} -> admin;
        {_, true, _} -> moderator;
        {_, _, [_ | _] = Boards} -> {janitor, [B || B <- lists:usort(Boards), is_binary(B)]};
        _ -> none
    end.

-spec member(binary(), [binary()]) -> boolean().
member(Group, [Group | _]) -> true;
member(Group, [_ | Groups]) -> member(Group, Groups);
member(_, []) -> false.

%% a janitor's group is the prefix and a board's name
-spec boards(binary(), [binary()]) -> [binary()].
boards(Prefix, [Group | Groups]) ->
    Size = byte_size(Prefix),
    case Group of
        <<Prefix:Size/binary, Board/binary>> ->
            case ike_config:board_name(Board) of
                true -> [Board | boards(Prefix, Groups)];
                false -> boards(Prefix, Groups)
            end;
        _ ->
            boards(Prefix, Groups)
    end;
boards(_, []) ->
    [].

%% a janitor takes out of sight, a moderator takes down, suspends and
%% locks, and only an admin destroys. ike itself only ends a hold
-spec may(role() | system, kind()) -> boolean().
may(admin, _) -> true;
may(moderator, purge) -> false;
may(moderator, purge_image) -> false;
may(moderator, _) -> true;
may({janitor, _}, Kind) -> Kind =:= hide orelse Kind =:= unhide;
may(system, Kind) -> Kind =:= purge.

%% may, and on this target: a janitor only on its boards; nobody against
%% an account of their own rank or above, their own included; nobody
%% undoes what a higher rank did
-spec permits(role() | system, kind(), facts()) -> boolean().
permits(system, Kind, _Facts) ->
    may(system, Kind);
permits(Role, Kind, #{board := Board, self := Self, account := Account, undo := Undo}) ->
    may(Role, Kind) andalso covers(Role, Board) andalso
        case Kind of
            _ when Kind =:= ban; Kind =:= unban -> not Self andalso rank(Role) > Account;
            _ when Kind =:= unhide; Kind =:= restore; Kind =:= unblock -> rank(Role) >= Undo;
            _ -> true
        end.

-spec covers(role(), binary() | any) -> boolean().
covers({janitor, Boards}, Board) when is_binary(Board) -> lists:member(Board, Boards);
covers(_, _) -> true.

-spec rank(role() | none) -> 0..3.
rank(admin) -> 3;
rank(moderator) -> 2;
rank({janitor, _}) -> 1;
rank(none) -> 0.

%% the rank behind a role as the log stores it; ike itself above all
-spec rank_of(term()) -> 0..4.
rank_of(<<"system">>) -> 4;
rank_of(<<"admin">>) -> 3;
rank_of(<<"moderator">>) -> 2;
rank_of(<<"janitor">>) -> 1;
rank_of(_) -> 0.

-spec kinds() -> [kind()].
kinds() ->
    [hide, unhide, trash, restore, purge, ban, unban, lock, unlock, block, unblock, purge_image].

-spec kind(binary()) -> {ok, kind()} | error.
kind(<<"hide">>) -> {ok, hide};
kind(<<"unhide">>) -> {ok, unhide};
kind(<<"trash">>) -> {ok, trash};
kind(<<"restore">>) -> {ok, restore};
kind(<<"purge">>) -> {ok, purge};
kind(<<"ban">>) -> {ok, ban};
kind(<<"unban">>) -> {ok, unban};
kind(<<"lock">>) -> {ok, lock};
kind(<<"unlock">>) -> {ok, unlock};
kind(<<"block">>) -> {ok, block};
kind(<<"unblock">>) -> {ok, unblock};
kind(<<"purge_image">>) -> {ok, purge_image};
kind(_) -> error.

%% a role's name, and a kind's, as the log stores them
-spec to_binary(role() | system | kind()) -> binary().
to_binary({janitor, _}) -> <<"janitor">>;
to_binary(Atom) when is_atom(Atom) -> atom_to_binary(Atom).

%% a role as a session row holds it: the role, and a janitor's boards
-spec encode(role() | none) -> {binary() | undefined, binary() | undefined}.
encode(none) -> {undefined, undefined};
encode({janitor, Boards}) -> {<<"janitor">>, join(Boards)};
encode(Role) -> {to_binary(Role), undefined}.

-spec join([binary()]) -> binary().
join([Board]) -> Board;
join([Board | Boards]) -> <<Board/binary, " ", (join(Boards))/binary>>;
join([]) -> <<>>.

-spec decode(term(), term()) -> role() | none.
decode(<<"admin">>, _) ->
    admin;
decode(<<"moderator">>, _) ->
    moderator;
decode(<<"janitor">>, Boards) when is_binary(Boards) ->
    case binary:split(Boards, <<" ">>, [global, trim_all]) of
        [] -> none;
        Names -> {janitor, Names}
    end;
decode(_, _) ->
    none.

%% a role read back from memory
-spec check(term()) -> role() | none.
check(admin) -> admin;
check(moderator) -> moderator;
check({janitor, [_ | _] = Boards}) -> {janitor, [B || B <- Boards, is_binary(B)]};
check(_) -> none.
