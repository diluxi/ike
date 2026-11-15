%% What the environment says, checked where it is read.
-module(ike_config).

-export([data_dir/0, db_path/0, pages_dir/0, session_seconds/0, oidc/0]).
-export([backup_dir/0, backup_seconds/0, backup_keep/0, boards/0]).
-export([board_name/1]).
-export_type([oidc/0]).

-type oidc() :: #{
    issuer := binary(),
    client_id := binary(),
    redirect_uri := binary(),
    %% absent for a public client
    client_secret => binary()
}.

%% the boards there are to be, as name and title. one that is no longer
%% named here stays as it is: threads are not lost to a typo
-spec boards() -> [{Name :: binary(), Title :: binary()}].
boards() ->
    case application:get_env(ike, boards) of
        {ok, Boards} when is_list(Boards) ->
            [
                case board_name(Name) of
                    true -> {Name, Title};
                    false -> error({badenv, {boards, Name}})
                end
             || {Name, Title} <- Boards, is_binary(Name), is_binary(Title)
            ];
        _ ->
            []
    end.

%% a to z and digits, at most sixteen
-spec board_name(binary()) -> boolean().
board_name(Name) when byte_size(Name) >= 1, byte_size(Name) =< 16 ->
    lower(Name);
board_name(_) ->
    false.

-spec lower(binary()) -> boolean().
lower(<<C, Rest/binary>>) when C >= $a, C =< $z; C >= $0, C =< $9 -> lower(Rest);
lower(<<>>) -> true;
lower(_) -> false.

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

%% snapshots of the database. where they go from here is the host's affair
-spec backup_dir() -> binary().
backup_dir() ->
    <<(data_dir())/binary, "/backups">>.

%% seconds between snapshots
-spec backup_seconds() -> pos_integer().
backup_seconds() ->
    case application:get_env(ike, backup_seconds) of
        {ok, Seconds} when is_integer(Seconds), Seconds > 0 -> Seconds;
        _ -> 86400
    end.

%% how many snapshots are kept. a stand-in for the retention window, which
%% is lux's to decide (hazard d7, questions.md)
-spec backup_keep() -> pos_integer().
backup_keep() ->
    case application:get_env(ike, backup_keep) of
        {ok, Count} when is_integer(Count), Count > 0 -> Count;
        _ -> 7
    end.

-spec session_seconds() -> pos_integer().
session_seconds() ->
    case application:get_env(ike, session_seconds) of
        {ok, Seconds} when is_integer(Seconds), Seconds > 0 -> Seconds;
        _ -> 8 * 3600
    end.

%% the issuer and this client. without it there is no login. the secret is
%% read from a file, so that it need not be in the configuration
-spec oidc() -> {ok, oidc()} | error.
oidc() ->
    case application:get_env(ike, oidc) of
        {ok, #{issuer := Issuer, client_id := ClientId, redirect_uri := RedirectUri} = Env} when
            is_binary(Issuer), is_binary(ClientId), is_binary(RedirectUri)
        ->
            Config = #{issuer => Issuer, client_id => ClientId, redirect_uri => RedirectUri},
            case Env of
                #{client_secret_file := File} when is_binary(File) ->
                    case file:read_file(File) of
                        {ok, Secret} -> {ok, Config#{client_secret => first_line(Secret)}};
                        {error, Reason} -> error({badenv, {client_secret_file, Reason}})
                    end;
                _ ->
                    {ok, Config}
            end;
        _ ->
            error
    end.

%% a secret file usually ends in a newline that is not part of the secret
-spec first_line(binary()) -> binary().
first_line(Bin) ->
    [Line | _] = binary:split(Bin, [<<"\n">>, <<"\r">>]),
    Line.
