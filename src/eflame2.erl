-module(eflame2).
-export([write_trace/6]).
-compile(export_all). %% SLF debugging

-record(state, {
          output_path="",
          pid,
          last_ts,
          count=0,
          acc=[]}). % per-process state

%% Example use, for 'all' processes in Riak for 10 seconds.  Run on a
%% moderately busy Riak server created 1GByte of trace data, beware.
%%
%% Step 0: Compile with "rebar compile", then copy eflame.beam to
%%         someplace accessible such as /tmp.  Then run:
%%
%%    code:add_pathz("/tmp").
%%
%% Step 1: Get your workload running, e.g. for Riak.  Then run:
%%
%%    eflame2:write_trace(like_fprof, "/tmp/ef.test.0", all,
%%                        timer, sleep, [10*1000]).
%%
%% Step 2: Convert the binary trace to text output.
%%
%%    Acc = eflame2:exp1_init("/tmp/ef.test.0.out").
%%    dbg:trace_client(file, "/tmp/ef.test.0", {fun eflame2:exp1/2, Acc}).
%%
%% Step 3: Convert text output to SVG.  Note that this script does *NOT*
%%         require processing by "stack_to_flame.sh".
%%
%%  Everything:
%%
%%    cat /tmp/ef.test.0.out | ./flamegraph.riak-color.pl > output.svg
%%
%%  Only pids <0.1102.0> and <0.1104.0> ... note that the "<>" characters
%%  in the PID do *not* appear in the output:
%%
%%    egrep '0\.1102\.0|0\.1104\.0' /tmp/ef.test.0.out | \
%%        ./flamegraph.riak-color.pl > output.svg
%%
%%  Only pids <0.1102.0> and <0.1104.0> and also removing sleep time:
%%
%%    egrep '0\.1102\.0|0\.1104\.0' /tmp/ef.test.0.out | \
%%        grep -v 'SLEEP ' | \
%%        ./flamegraph.riak-color.pl > output.svg

%% PidSpec = pid() | [pid()] | existing | new | all
write_trace(Mode, IntermediateFile, PidSpec, M, F, A) ->
    {ok, Tracer} = start_tracer(IntermediateFile),
    io:format(user, "Tracer ~p\n", [Tracer]),
    io:format(user, "self() ~p\n", [self()]),

    start_trace(Tracer, PidSpec, Mode),
    Return = (catch erlang:apply(M, F, A)),
    stop_trace(Tracer, PidSpec),

    %% ok = file:write_file(OutputFile, Bytes),
    Return.

start_trace(_Tracer, PidSpec, Mode) ->
    MatchSpec = [{'_',[],[{message,{process_dump}}]}],
    %% MatchSpec = [{'_',[],[{return_trace}]}],

    _X2b = dbg:tpl('_', '_', MatchSpec),
    io:format("X2b ~p\n", [_X2b]),
    if is_list(PidSpec) ->
            [dbg:p(PS, trace_flags(Mode)) || PS <- PidSpec];
       true ->
            dbg:p(PidSpec, trace_flags(Mode))
    end,
    ok.

stop_trace(Tracer, _PidSpec) ->
    _X00 = dbg:flush_trace_port(),
    (catch dbg:ctp()),
    (catch dbg:stop()),
    (catch dbg:stop_clear()),
    (exit(Tracer, normal)),
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

exp0({trace_ts, Pid, call, {M,F,A}, BIN, _TS}, _Acc) ->
    Stak = lists:filter(fun("unknown function") -> false;
                           (_)                  -> true
                        end, stak(BIN)), % Thank you, Mats!
    MFA_str = lists:flatten(io_lib:format("~w:~w/~w", [M, F, A])),
    Total0 = Stak ++ [MFA_str],
    Total = stak_trim(Total0),
    io:format("~w;~s\n", [Pid, intercalate(";", Total)]);
exp0(end_of_trace, _Acc) ->
    io:format("End of trace found, hooray!\n");
exp0(Else, _Acc) ->
    io:format("?? ~P\n", [Else, 10]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

exp1_init(OutputPath) ->
    #state{output_path=OutputPath}.

exp1(end_of_trace = _Else, #state{output_path=OutputPath} = OuterS) ->
    (catch erlang:delete(hello_world)),
    PidStates = get(),
    {ok, FH} = file:open(OutputPath, [write, raw, binary, delayed_write]),
    io:format("\n\nWriting to ~s for ~w processes... ", [OutputPath, length(PidStates)]),
    [
        [begin
             Pid_str0 = lists:flatten(io_lib:format("~w", [Pid])),
             Size = length(Pid_str0),
             Pid_str = [$(, lists:sublist(Pid_str0, 2, Size-2), $)],
             Time_str = integer_to_list(Time),
             file:write(FH, [Pid_str, $;, intersperse($;, lists:reverse(Stack)), 32, Time_str, 10])
         end || {Stack, Time} <- Acc]
     || {Pid, #state{acc=Acc} = _S} <- PidStates],
    file:close(FH),
    io:format("finished\n"),
    OuterS;
exp1(T, #state{output_path=OutputPath} = S) ->
    trace_ts = element(1, T),
    Pid = element(2, T),
    PidState = case erlang:get(Pid) of
                   undefined ->
                       io:format("~p ", [Pid]),
                       #state{output_path=OutputPath};
                   SomeState ->
                       SomeState
               end,
    NewPidState = exp1_inner(T, PidState),
    erlang:put(Pid, NewPidState),
    S.

exp1_inner({trace_ts, _Pid, InOut, _MFA, _TS}, #state{last_ts=undefined} = S)
  when InOut == in; InOut == out ->
    exp1_hello_world(),
    %% in & out, without call context, don't help us
    S;
exp1_inner({trace_ts, _Pid, Return, _MFA, _TS}, #state{last_ts=undefined} = S)
  when Return == return_from; Return == return_to ->
    exp1_hello_world(),
    %% return_from and return_to, without call context, don't help us
    S;
exp1_inner({trace_ts, Pid, call, MFA, BIN, TS},
     #state{last_ts=LastTS, acc=Acc, count=Count} = S) ->
  try
    exp1_hello_world(),
    %% Calculate time elapsed, TS-LastTs.
    %% 0. If Acc is empty, then skip step #1.
    %% 1. Credit elapsed time to the stack on the top of Acc.
    %% 2. Push a 0 usec item with this stack onto Acc.
    Stak = lists:filter(fun(<<"unknown function">>) -> false;
                           (_)                      -> true
                        end, stak_binify(BIN)),
    Stack0 = stak_trim(Stak),
    MFA_bin = mfa_binify(MFA),
    Stack1 = [MFA_bin|lists:reverse(Stack0)],
    Acc2 = case Acc of
               [] ->
                   [{Stack1, 0}];
               [{LastStack, LastTime}|Tail] ->
                   USec = timer:now_diff(TS, LastTS),
%                   io:format("Stack1: ~p ~p\n", [Stack1, USec]),
                   [{Stack1, 0},
                    {LastStack, LastTime + USec}|Tail]
           end,
    %% TODO: more state tracking here.
    S#state{pid=Pid, last_ts=TS, count=Count+1, acc=Acc2}
  catch XX:YY ->
            io:format(user, "~p: ~p:~p @ ~p\n", [?LINE, XX, YY, erlang:get_stacktrace()]),
            S
  end;
exp1_inner({trace_ts, _Pid, return_to, MFA, TS}, #state{last_ts=LastTS, acc=Acc} = S) ->
  try
    %% Calculate time elapsed, TS-LastTs.
    %% 1. Credit elapsed time to the stack on the top of Acc.
    %% 2. Push a 0 usec item with the "best" stack onto Acc.
    %%    "best" = MFA exists in the middle of the stack onto Acc,
    %%    or else MFA exists at the top of a stack elsewhere in Acc.
    [{LastStack, LastTime}|Tail] = Acc,
    MFA_bin = mfa_binify(MFA),
    BestStack = lists:dropwhile(fun(SomeMFA) when SomeMFA /= MFA_bin -> true;
                                   (_)                               -> false
                                end, find_matching_stack(MFA_bin, Acc)),
    USec = timer:now_diff(TS, LastTS),
    Acc2 = [{BestStack, 0},
            {LastStack, LastTime + USec}|Tail],
%    io:format(user, "return-to: ~p\n", [lists:sublist(Acc2, 4)]),
    S#state{last_ts=TS, acc=Acc2}
  catch XX:YY ->
            io:format(user, "~p: ~p:~p @ ~p\n", [?LINE, XX, YY, erlang:get_stacktrace()]),
            S
  end;
    
exp1_inner({trace_ts, _Pid, gc_start, _Info, TS}, #state{last_ts=LastTS, acc=Acc} = S) ->
  try
    %% Push a 0 usec item onto Acc.
    [{LastStack, LastTime}|Tail] = Acc,
    NewStack = [<<"GARBAGE-COLLECTION">>|LastStack],
    USec = timer:now_diff(TS, LastTS),
    Acc2 = [{NewStack, 0},
            {LastStack, LastTime + USec}|Tail],
%    io:format(user, "GC 1: ~p\n", [lists:sublist(Acc2, 4)]),
    S#state{last_ts=TS, acc=Acc2}
  catch _XX:_YY ->
            %% io:format(user, "~p: ~p:~p @ ~p\n", [?LINE, _XX, _YY, erlang:get_stacktrace()]),
            S
  end;
exp1_inner({trace_ts, _Pid, gc_end, _Info, TS}, #state{last_ts=LastTS, acc=Acc} = S) ->
  try
    %% Push the GC time onto Acc, then push 0 usec item from last exec
    %% stack onto Acc.
    [{GCStack, GCTime},{LastExecStack,_}|Tail] = Acc,
    USec = timer:now_diff(TS, LastTS),
    Acc2 = [{LastExecStack, 0}, {GCStack, GCTime + USec}|Tail],
%    io:format(user, "GC 2: ~p\n", [lists:sublist(Acc2, 4)]),
    S#state{last_ts=TS, acc=Acc2}
  catch _XX:_YY ->
            %% io:format(user, "~p: ~p:~p @ ~p\n", [?LINE, _XX, _YY, erlang:get_stacktrace()]),
            S
  end;

exp1_inner({trace_ts, _Pid, out, MFA, TS}, #state{last_ts=LastTS, acc=Acc} = S) ->
  try
    %% Push a 0 usec item onto Acc.
    %% The MFA reported here probably doesn't appear in the stacktrace
    %% given to us by the last 'call', so add it here.
    [{LastStack, LastTime}|Tail] = Acc,
    MFA_bin = mfa_binify(MFA),
    NewStack = [<<"SLEEP">>,MFA_bin|LastStack],
    USec = timer:now_diff(TS, LastTS),
    Acc2 = [{NewStack, 0},
            {LastStack, LastTime + USec}|Tail],
    S#state{last_ts=TS, acc=Acc2}
  catch XX:YY ->
            io:format(user, "~p: ~p:~p @ ~p\n", [?LINE, XX, YY, erlang:get_stacktrace()]),
            S
  end;
exp1_inner({trace_ts, _Pid, in, MFA, TS}, #state{last_ts=LastTS, acc=Acc} = S) ->
  try
    %% Push the Sleep time onto Acc, then push 0 usec item from last
    %% exec stack onto Acc.
    %% The MFA reported here probably doesn't appear in the stacktrace
    %% given to us by the last 'call', so add it here.
    MFA_bin = mfa_binify(MFA),
    [{SleepStack, SleepTime},{LastExecStack,_}|Tail] = Acc,
    USec = timer:now_diff(TS, LastTS),
    Acc2 = [{[MFA_bin|LastExecStack], 0}, {SleepStack, SleepTime + USec}|Tail],
    S#state{last_ts=TS, acc=Acc2}
  catch XX:YY ->
            io:format(user, "~p: ~p:~p @ ~p\n", [?LINE, XX, YY, erlang:get_stacktrace()]),
            S
  end;

exp1_inner(end_of_trace = _Else, #state{pid=Pid, output_path=OutputPath, acc=Acc} = S) ->
    {ok, FH} = file:open(OutputPath, [write, raw, binary, delayed_write]),
    io:format("Writing to ~s ... ", [OutputPath]),
    [begin
         Pid_str = io_lib:format("~w", [Pid]),
         Time_str = integer_to_list(Time),
         file:write(FH, [Pid_str, $;, intersperse($;, lists:reverse(Stack)), 32, Time_str, 10])
     end || {Stack, Time} <- Acc],
    file:close(FH),
    io:format("finished\n"),
    S;
exp1_inner(_Else, S) ->
    io:format("?? ~P\n", [_Else, 10]),
    S.

exp1_hello_world() ->
    case erlang:get(hello_world) of
        undefined ->
            io:format("Hello, world, I'm ~p and I'm running....\n", [self()]),
            erlang:put(hello_world, true);
        _ ->
            ok
    end.

find_matching_stack(MFA_bin, [{H,_Time}|_] = Acc) ->
    case lists:member(MFA_bin, H) of
        true ->
            H;
        false ->
            find_matching_stack2(MFA_bin, Acc)
    end.

find_matching_stack2(MFA_bin, [{[MFA_bin|_StackTail]=Stack,_Time}|_]) ->
    Stack;
find_matching_stack2(MFA_bin, [_H|T]) ->
    find_matching_stack2(MFA_bin, T);
find_matching_stack2(_MFA_bin, []) ->
    [<<"FIND-MATCHING-FAILED">>].    

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_tracer(IntermediateFile) ->
    dbg:tracer(port, dbg:trace_port(file, IntermediateFile)).

trace_flags(not_running) ->
    [call, arity, return_to, timestamp];
trace_flags(normal) ->%%%%%%%%%%%%%%%%%%%%%%%% YEAH
    [call, arity, return_to, timestamp, running];
trace_flags(normal_with_children) ->
    [call, arity, return_to, timestamp, running, set_on_spawn];
trace_flags(like_fprof) -> % fprof does this as 'normal', will not work!
    [call, arity, return_to, timestamp, running, set_on_spawn, garbage_collection].

entry_to_iolist({M, F, A}) ->
    [atom_to_binary(M, utf8), <<":">>, atom_to_binary(F, utf8), <<"/">>, integer_to_list(A)];
entry_to_iolist(A) when is_atom(A) ->
    [atom_to_binary(A, utf8)].

intercalate(Sep, Xs) -> lists:concat(intersperse(Sep, Xs)).

intersperse(_, []) -> [];
intersperse(_, [X]) -> [X];
intersperse(Sep, [X | Xs]) -> [X, Sep | intersperse(Sep, Xs)].

stak_trim([<<"proc_lib:init_p_do_apply/3">>,<<"gen_fsm:decode_msg/9">>,<<"gen_fsm:handle_msg/7">>,<<"gen_fsm:loop/7">>|T]) ->
    stak_trim([<<"GEN-FSM">>|T]);
stak_trim([<<"GEN-FSM">>,<<"gen_fsm:decode_msg/9">>,<<"gen_fsm:handle_msg/7">>,<<"gen_fsm:loop/7">>|T]) ->
    stak_trim([<<"GEN-FSM">>|T]);
stak_trim(Else) ->
    Else.

stak_binify(Bin) when is_binary(Bin) ->
    [list_to_binary(X) || X <- stak(Bin)];
stak_binify(X) ->
    list_to_binary(io_lib:format("~w", [X])).

mfa_binify({M,F,A}) ->
    list_to_binary(io_lib:format("~w:~w/~w", [M, F, A]));
mfa_binify(X) ->
    list_to_binary(io_lib:format("~w", [X])).

%% Borrowed from redbug.erl

stak(Bin) ->
  lists:foldl(fun munge/2,[],string:tokens(binary_to_list(Bin),"\n")).

munge(I,Out) ->
  case I of %% lists:reverse(I) of
    "..."++_ -> ["truncated!!!"|Out];
    _ ->
      case string:str(I, "Return addr") of
        0 ->
          case string:str(I, "cp = ") of
            0 -> Out;
            _ -> [mfaf(I)|Out]
          end;
        _ ->
          case string:str(I, "erminate process normal") of
            0 -> [mfaf(I)|Out];
            _ -> Out
          end
      end
  end.

mfaf(I) ->
  [_, C|_] = string:tokens(I,"()+"),
  string:strip(C).
