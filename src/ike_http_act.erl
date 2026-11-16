%% /act: the form at the foot of every thread, as vichan and tinyboard
%% have it. Ticked posts, and one button: retract them with a password,
%% report them with a reason, or, for whoever has a role, take them down.
%% The form is on pages that are the same for everyone, so it carries no
%% session's token; guard/1 is what stands in for one, and the one place
%% to change should the form carry a token later.
-module(ike_http_act).
-behaviour(cowboy_handler).

-export([init/2]).

%% most posts one form acts on
-define(MOST, 50).
-define(PASSWORD, <<"__Host-ike-password">>).

-spec init(cowboy_req:req(), State) -> {ok, cowboy_req:req(), State}.
init(Req0, State) ->
    Reply =
        case cowboy_req:method(Req0) of
            <<"POST">> ->
                case guard(Req0) of
                    true -> read(Req0);
                    false -> ike_http:forbidden(Req0)
                end;
            _ ->
                ike_http:reply(405, Req0)
        end,
    {ok, Reply, State}.

%% that the form was sent from one of this site's pages: the browser's
%% Origin (missing or "null" is no)
-spec guard(cowboy_req:req()) -> boolean().
guard(Req) ->
    ike_http:guarded(Req).

-spec read(cowboy_req:req()) -> cowboy_req:req().
read(Req0) ->
    case ike_http:pairs(Req0) of
        {ok, Pairs, Req} ->
            Form = maps:from_list(Pairs),
            Posts = numbers(Pairs, []),
            Back =
                case Form of
                    #{<<"back">> := <<"/board/", _/binary>> = B} -> B;
                    _ -> <<"/board">>
                end,
            case {Posts, maps:get(<<"kind">>, Form, <<>>)} of
                {[], _} ->
                    answer([<<"no post was ticked.">>], Back, Req);
                {_, _} when length(Posts) > ?MOST ->
                    ike_http:reply(400, Req);
                {_, <<"retract">>} ->
                    answer([retract(N, Form, Req) || N <- Posts], Back, Req);
                {_, <<"report">>} ->
                    Reason = maps:get(<<"reason">>, Form, <<>>),
                    answer([report(N, Reason) || N <- Posts], Back, Req);
                {_, Kind} ->
                    case ike_role:kind(Kind) of
                        {ok, K} when K =:= hide; K =:= trash; K =:= purge; K =:= ban ->
                            moderate(K, Posts, maps:get(<<"reason">>, Form, <<>>), Back, Req);
                        _ ->
                            ike_http:reply(400, Req)
                    end
            end;
        {error, Status, Req} ->
            ike_http:reply(Status, Req)
    end.

%% by the password typed, or the one this browser posted with, or by
%% being the account that signed it
-spec retract(pos_integer(), #{binary() => binary()}, cowboy_req:req()) -> binary().
retract(N, Form, Req) ->
    Typed = maps:get(<<"password">>, Form, <<>>),
    Password =
        case {Typed, ike_http_login:cookie(?PASSWORD, Req)} of
            {<<>>, {ok, Kept}} -> Kept;
            _ -> Typed
        end,
    Tries =
        [{password, Password} || Password =/= <<>>] ++
            [{account, A} || {ok, _, #{actor := A}} <- [ike_http_login:session(Req)]],
    case ike_limit:retraction(N) of
        limited -> said(N, <<"too many tries; later">>);
        ok -> said(N, tried(ike_id:post(N), Tries))
    end.

-spec tried(ike_id:post(), [{password, binary()} | {account, ike_id:actor()}]) -> binary().
tried(_Post, []) ->
    <<"not yours">>;
tried(Post, [By | Rest]) ->
    case ike_writer:retract(Post, By) of
        ok -> <<"retracted">>;
        {error, not_yours} -> tried(Post, Rest);
        {error, not_now} -> <<"already out of view">>;
        {error, no_such_post} -> <<"no such post">>;
        {error, _} -> <<"not done, try again">>
    end.

-spec report(pos_integer(), binary()) -> binary().
report(N, Reason) ->
    case ike_writer:report(ike_id:post(N), Reason) of
        ok -> said(N, <<"reported">>);
        {error, bad_text} -> said(N, <<"give a reason">>);
        {error, no_such_post} -> said(N, <<"no such post">>);
        {error, _} -> said(N, <<"not done, try again">>)
    end.

%% the same rungs as /mod/post/N, for whoever has a role; to anyone else
%% the buttons do nothing
-spec moderate(ike_role:kind(), [pos_integer()], binary(), binary(), cowboy_req:req()) ->
    cowboy_req:req().
moderate(Kind, Posts, Reason, Back, Req) ->
    case ike_http_login:session(Req) of
        {ok, _, #{actor := Actor, role := Role}} when
            Role =:= admin; Role =:= moderator; element(1, Role) =:= janitor
        ->
            Done = [
                said(
                    N,
                    case
                        ike_writer:moderate(#{
                            by => Actor,
                            role => Role,
                            kind => Kind,
                            target => ike_id:post(N),
                            reason => Reason
                        })
                    of
                        ok -> atom_to_binary(Kind);
                        {error, not_allowed} -> <<"not your role's to do">>;
                        {error, bad_text} -> <<"give a reason">>;
                        {error, not_now} -> <<"not in a state for that">>;
                        {error, no_such_post} -> <<"no such post">>;
                        {error, no_such_account} -> <<"no account to ban">>;
                        {error, _} -> <<"not done, try again">>
                    end
                )
             || N <- Posts
            ],
            _ = ike_render:sync(),
            answer(Done, Back, Req);
        _ ->
            ike_http:forbidden(Req)
    end.

%% the ticked posts' numbers, once each
-spec numbers([{binary(), binary()}], [pos_integer()]) -> [pos_integer()].
numbers([{<<"post">>, V} | Rest], Acc) ->
    case string:to_integer(V) of
        {N, <<>>} when is_integer(N), N > 0 -> numbers(Rest, Acc ++ [N]);
        _ -> numbers(Rest, Acc)
    end;
numbers([_ | Rest], Acc) ->
    numbers(Rest, Acc);
numbers([], Acc) ->
    unique(Acc, []).

-spec unique([pos_integer()], [pos_integer()]) -> [pos_integer()].
unique([N | Rest], Seen) ->
    case lists:member(N, Seen) of
        true -> unique(Rest, Seen);
        false -> [N | unique(Rest, [N | Seen])]
    end;
unique([], _Seen) ->
    [].

-spec said(pos_integer(), binary()) -> binary().
said(N, What) ->
    <<">>", (integer_to_binary(N))/binary, ": ", What/binary>>.

-spec answer([binary()], binary(), cowboy_req:req()) -> cowboy_req:req().
answer(Lines, Back, Req) ->
    _ = ike_render:sync(),
    ike_http:page(200, ike_view:acted(Lines, Back), Req).
