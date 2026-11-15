%% Who may do what (planning.md, Moderation). A role is what the
%% provider's groups made of an account when it logged in; it lives as
%% long as the session and no longer (hazard i5).
-module(ike_role).

-export([of_groups/1, may/2, kinds/0, kind/1, to_binary/1, of_binary/1]).
-export_type([role/0, kind/0]).

-type role() :: admin | moderator | janitor.
%% the rungs of the ladder, and their way back down
-type kind() :: hide | unhide | delete | restore | purge | ban | unban | lock | unlock.

%% the highest role any of the groups gives
-spec of_groups([binary()]) -> role() | none.
of_groups(Groups) ->
    #{admin := Admin, moderator := Moderator, janitor := Janitor} = ike_config:roles(),
    case {member(Admin, Groups), member(Moderator, Groups), member(Janitor, Groups)} of
        {true, _, _} -> admin;
        {_, true, _} -> moderator;
        {_, _, true} -> janitor;
        _ -> none
    end.

-spec member(binary(), [binary()]) -> boolean().
member(Group, [Group | _]) -> true;
member(Group, [_ | Groups]) -> member(Group, Groups);
member(_, []) -> false.

%% a janitor takes out of sight, a moderator takes down, suspends and
%% locks, and only an admin destroys. ike itself only ends a hold
-spec may(role() | system, kind()) -> boolean().
may(admin, _) -> true;
may(moderator, purge) -> false;
may(moderator, _) -> true;
may(janitor, Kind) -> Kind =:= hide orelse Kind =:= unhide;
may(system, Kind) -> Kind =:= purge.

-spec kinds() -> [kind()].
kinds() -> [hide, unhide, delete, restore, purge, ban, unban, lock, unlock].

-spec kind(binary()) -> {ok, kind()} | error.
kind(<<"hide">>) -> {ok, hide};
kind(<<"unhide">>) -> {ok, unhide};
kind(<<"delete">>) -> {ok, delete};
kind(<<"restore">>) -> {ok, restore};
kind(<<"purge">>) -> {ok, purge};
kind(<<"ban">>) -> {ok, ban};
kind(<<"unban">>) -> {ok, unban};
kind(<<"lock">>) -> {ok, lock};
kind(<<"unlock">>) -> {ok, unlock};
kind(_) -> error.

-spec to_binary(role() | system | kind()) -> binary().
to_binary(Atom) -> atom_to_binary(Atom).

-spec of_binary(term()) -> role() | none.
of_binary(<<"admin">>) -> admin;
of_binary(<<"moderator">>) -> moderator;
of_binary(<<"janitor">>) -> janitor;
of_binary(_) -> none.
