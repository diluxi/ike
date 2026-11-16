%% What the environment says, checked where it is read.
-module(ike_config).

-export([data_dir/0, db_path/0, pages_dir/0, session_seconds/0, oidc/0]).
-export([backup_dir/0, backup_seconds/0, backup_keep/0, boards/0]).
-export([board_name/1, anonymous_names/0, limit/0, roles/0, hold_seconds/0]).
-export([assets_dir/0, media_dir/0, strip/0, media_origin/0, media_host/0, staged_seconds/0]).
-export_type([oidc/0, limit/0, strip/0]).

%% the stripper's socket, and the caps it was started with: ike reads no
%% more than max_bytes of an upload, and believes no answer past them
-type strip() :: #{
    socket := binary(),
    max_bytes := pos_integer(),
    max_side := pos_integer(),
    max_pixels := pos_integer(),
    thumb := pos_integer(),
    files := pos_integer()
}.

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

%% what stands where a name would, on a post that carries none. more
%% than one, and each post gets one of them by its number
-spec anonymous_names() -> [binary(), ...].
anonymous_names() ->
    case application:get_env(ike, anonymous_names) of
        {ok, [First | Rest]} when is_binary(First) ->
            [First | [Name || Name <- Rest, is_binary(Name)]];
        _ ->
            [<<"anon">>]
    end.

%% posts, seconds: how often one address, or one ipv6 network of
%% v6_prefix bits, may post without an account.
%% board_posts, board_seconds: how often nobody may post on one board,
%% all addresses together.
%% salt_seconds: how long the key the addresses are hashed with lives.
%% proxies: whose x-forwarded-for is believed; anyone else's is ignored
%% and they are counted as themselves
-type limit() :: #{
    posts := pos_integer(),
    seconds := pos_integer(),
    board_posts := pos_integer(),
    board_seconds := pos_integer(),
    salt_seconds := pos_integer(),
    v6_prefix := 48 | 56 | 64,
    proxies := [term()]
}.

-spec limit() -> limit().
limit() ->
    Given =
        case application:get_env(ike, limit) of
            {ok, Map} when is_map(Map) -> Map;
            _ -> #{}
        end,
    Count = fun(Key, Default) ->
        case Given of
            #{Key := N} when is_integer(N), N > 0 -> N;
            _ -> Default
        end
    end,
    #{
        posts => Count(posts, 4),
        seconds => Count(seconds, 60),
        board_posts => Count(board_posts, 10),
        board_seconds => Count(board_seconds, 60),
        salt_seconds => Count(salt_seconds, 3600),
        v6_prefix =>
            case Given of
                #{v6_prefix := 48} -> 48;
                #{v6_prefix := 56} -> 56;
                _ -> 64
            end,
        proxies =>
            case Given of
                #{proxies := Proxies} when is_list(Proxies) -> Proxies;
                _ -> []
            end
    }.

%% the provider's group behind each role. a janitor's is a prefix, and
%% the board it looks after follows it: ike-janitor-b
-spec roles() -> #{admin := binary(), moderator := binary(), janitor := binary()}.
roles() ->
    Given =
        case application:get_env(ike, roles) of
            {ok, Map} when is_map(Map) -> Map;
            _ -> #{}
        end,
    Group = fun(Role, Default) ->
        case Given of
            #{Role := Name} when is_binary(Name), byte_size(Name) > 0 -> Name;
            _ -> Default
        end
    end,
    #{
        admin => Group(admin, <<"ike-admin">>),
        moderator => Group(moderator, <<"ike-moderator">>),
        janitor => Group(janitor, <<"ike-janitor-">>)
    }.

%% how long a deleted post is held before it is purged
-spec hold_seconds() -> pos_integer().
hold_seconds() ->
    case application:get_env(ike, hold_seconds) of
        {ok, Seconds} when is_integer(Seconds), Seconds > 0 -> Seconds;
        _ -> 14 * 86400
    end.

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

%% what was uploaded, stripped, and its thumbnails: kept with the state,
%% where the web server cannot read, since a staged upload is its
%% uploader's alone (invariant 10)
-spec assets_dir() -> binary().
assets_dir() ->
    <<(data_dir())/binary, "/assets">>.

%% what the media origin serves: copies of the assets shown, derived and
%% made again at start, so it may live apart from the state
-spec media_dir() -> binary().
media_dir() ->
    case application:get_env(ike, media_dir) of
        {ok, Dir} when is_binary(Dir) -> Dir;
        _ -> <<(data_dir())/binary, "/media">>
    end.

-spec strip() -> strip().
strip() ->
    Given =
        case application:get_env(ike, strip) of
            {ok, Map} when is_map(Map) -> Map;
            _ -> #{}
        end,
    Positive = fun(Key, Default) ->
        case Given of
            #{Key := N} when is_integer(N), N > 0 -> N;
            _ -> Default
        end
    end,
    #{
        socket =>
            case Given of
                #{socket := Path} when is_binary(Path) -> Path;
                _ -> <<"/run/ike-strip/strip.sock">>
            end,
        %% stubs for planning's open size caps
        max_bytes => Positive(max_bytes, 20 * 1024 * 1024),
        max_side => Positive(max_side, 16384),
        max_pixels => Positive(max_pixels, 50000000),
        thumb => Positive(thumb, 256),
        files => Positive(files, 20)
    }.

%% where uploads are served from: another origin than ike's own (hazard
%% p3). one value, so that moving it is a restart
-spec media_origin() -> binary().
media_origin() ->
    case application:get_env(ike, media_origin) of
        {ok, Origin} when is_binary(Origin) -> Origin;
        _ -> <<"https://cdn.amartia.online">>
    end.

-spec media_host() -> binary().
media_host() ->
    case uri_string:parse(media_origin()) of
        #{host := Host} when is_binary(Host) -> Host;
        _ -> error({badenv, media_origin})
    end.

%% how long a link to a staged upload works
-spec staged_seconds() -> pos_integer().
staged_seconds() ->
    case application:get_env(ike, staged_seconds) of
        {ok, Seconds} when is_integer(Seconds), Seconds > 0 -> Seconds;
        _ -> 600
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
