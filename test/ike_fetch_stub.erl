%% What the ike-fetch socket unit is in production, for the suites: a
%% listener on an abstract unix socket that runs the built ike-fetch once
%% per connection, pointed at ike_fake_x and let reach it (the test-only
%% variables the module never sets). This module is the tests', not ike's.
-module(ike_fetch_stub).

-export([start/2, stop/0]).

%% Allowed: whether the fetcher is told it may reach the fake X
start(Work, Allowed) ->
    ok = filelib:ensure_path(Work),
    Name = <<0, "ike-fetch-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Exe = os:find_executable("ike-fetch"),
    true = is_list(Exe),
    Port = integer_to_list(ike_fake_x:port()),
    Env =
        ["IKE_FETCH_TWITTER=http://127.0.0.1:" ++ Port] ++
            ["IKE_FETCH_ALLOW=127.0.0.1:" ++ Port || Allowed],
    Self = self(),
    Pid = spawn(fun() ->
        {ok, Listen} = gen_tcp:listen(0, [
            binary, {ifaddr, {local, Name}}, {active, false}, {exit_on_close, false}
        ]),
        Self ! {self(), listening},
        accept(Listen, Work, Env ++ [Exe, "2000000"])
    end),
    receive
        {Pid, listening} -> ok
    after 5000 -> error(stub_not_listening)
    end,
    true = register(?MODULE, Pid),
    Name.

stop() ->
    case whereis(?MODULE) of
        undefined -> ok;
        Pid -> exit(Pid, kill)
    end,
    ok.

accept(Listen, Work, Command) ->
    {ok, Socket} = gen_tcp:accept(Listen),
    Pid = spawn(fun() -> serve(Socket, Work, Command) end),
    ok = gen_tcp:controlling_process(Socket, Pid),
    Pid ! go,
    accept(Listen, Work, Command).

serve(Socket, Work, Command) ->
    receive
        go -> ok
    end,
    N = integer_to_list(erlang:unique_integer([positive])),
    In = filename:join(Work, "in-" ++ N),
    Out = filename:join(Work, "out-" ++ N),
    ok = file:write_file(In, read(Socket, <<>>)),
    _ = os:cmd(
        lists:flatten([
            "env ", lists:join(" ", [quote(A) || A <- Command]), " <", quote(In), " >", quote(Out)
        ])
    ),
    {ok, Answer} = file:read_file(Out),
    ok = gen_tcp:send(Socket, Answer),
    gen_tcp:close(Socket).

read(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, Data} -> read(Socket, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.

quote(Arg) ->
    "'" ++ lists:flatten(string:replace(Arg, "'", "'\\''", all)) ++ "'".
