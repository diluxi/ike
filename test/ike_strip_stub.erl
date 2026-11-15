%% What the ike-strip socket unit is in production, for the suites: a
%% listener on an abstract unix socket that runs the built ike-strip once
%% per connection, the upload on its stdin. ike only ever sees the socket
%% (invariant 6); this module is the test's, not ike's.
-module(ike_strip_stub).

-export([start/2, stop/0]).

%% Work is a directory for the uploads in flight; Caps are ike-strip's
%% arguments. Returns the socket's address, for ike's configuration
start(Work, Caps) ->
    ok = filelib:ensure_path(Work),
    Name = <<0, "ike-strip-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Exe = os:find_executable("ike-strip"),
    true = is_list(Exe),
    Self = self(),
    Pid = spawn(fun() ->
        {ok, Listen} = gen_tcp:listen(0, [
            binary, {ifaddr, {local, Name}}, {active, false}, {exit_on_close, false}
        ]),
        Self ! {self(), listening},
        accept(Listen, Work, [Exe | Caps])
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
    Line = lists:join(" ", [quote(A) || A <- Command]),
    _ = os:cmd(lists:flatten([Line, " <", quote(In), " >", quote(Out)])),
    {ok, Answer} = file:read_file(Out),
    ok = gen_tcp:send(Socket, Answer),
    _ = file:delete(In),
    _ = file:delete(Out),
    gen_tcp:close(Socket).

read(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} -> read(Socket, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.

quote(Arg) ->
    "'" ++ lists:flatten(string:replace(Arg, "'", "'\\''", all)) ++ "'".
