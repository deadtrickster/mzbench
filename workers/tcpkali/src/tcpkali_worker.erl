-module(tcpkali_worker).

-export([
    initial_state/0,
    metrics/0,
    statsd/2,
    start/3,
    start_cmd/3,
    json2cbor/3,
    json2cbor/4,
    encode/4,
    replace_expressions/2,
    replace_back/2,
    traffic_in_resolver/0,
    traffic_out_resolver/0,
    connections_in_resolver/0,
    connections_out_resolver/0,
    latency_mean_resolver/0,
    latency_min_resolver/0,
    latency_50_resolver/0,
    latency_95_resolver/0,
    latency_99_resolver/0,
    latency_max_resolver/0,
    latency_connect_mean_resolver/0,
    latency_connect_min_resolver/0,
    latency_connect_50_resolver/0,
    latency_connect_95_resolver/0,
    latency_connect_99_resolver/0,
    latency_connect_max_resolver/0,
    pkts_in_resolver/0,
    pkts_out_resolver/0
]).

-define(Timeout, 5000).
-define(StatsdPort, 8125).

-record(state, {
            executable :: string()
        }).

initial_state() ->
    {ok, WorkerDirs} = application:get_env(mzbench, workers_dirs),
    Masks = [filename:join([D, "*", "resources/tcpkali"]) || D <- WorkerDirs],
    #state{executable = case lists:append([mzb_file:wildcard(M) || M <- Masks])  of
                [] -> erlang:error("Can't find tcpkali binary");
                [Path|_] -> Path
            end}.

metrics() ->
    [
        {group, "Tcpkali (aggregated)", [
            {graph, #{title => "Traffic bitrate",
                      units => "bits/sec",
                      metrics => [
                                  {"tcpkali.traffic.bitrate.in", derived, #{resolver => traffic_in_resolver}},
                                  {"tcpkali.traffic.bitrate.out", derived, #{resolver => traffic_out_resolver}}
                                  ]}},
            {graph, #{title => "Connections total",
                      units => "N",
                      metrics => [
                                  {"tcpkali.connections.total.in", derived, #{resolver => connections_in_resolver}},
                                  {"tcpkali.connections.total.out", derived, #{resolver => connections_out_resolver}}
                                  ]}},
            {graph, #{title => "Latency",
                      units => "ms",
                      metrics => [
                                  {"tcpkali.latency.message.mean", derived, #{resolver => latency_mean_resolver}},
                                  {"tcpkali.latency.message.min", derived, #{resolver => latency_min_resolver}},
                                  {"tcpkali.latency.message.50", derived, #{resolver => latency_50_resolver}},
                                  {"tcpkali.latency.message.95", derived, #{resolver => latency_95_resolver}},
                                  {"tcpkali.latency.message.99", derived, #{resolver => latency_99_resolver}},
                                  {"tcpkali.latency.message.max", derived, #{resolver => latency_max_resolver}}
                                 ]}},
            {graph, #{title => "Latency connect",
                      units => "ms",
                      metrics => [
                                  {"tcpkali.latency.connect.mean", derived, #{resolver => latency_connect_mean_resolver}},
                                  {"tcpkali.latency.connect.min", derived, #{resolver => latency_connect_min_resolver}},
                                  {"tcpkali.latency.connect.50", derived, #{resolver => latency_connect_50_resolver}},
                                  {"tcpkali.latency.connect.95", derived, #{resolver => latency_connect_95_resolver}},
                                  {"tcpkali.latency.connect.99", derived, #{resolver => latency_connect_99_resolver}},
                                  {"tcpkali.latency.connect.max", derived, #{resolver => latency_connect_max_resolver}}
                                 ]}},
            {graph, #{title => "Packet rate",
                      units => "packets/s",
                      metrics => [
                                  {"tcpkali.pkts.in", derived, #{resolver => pkts_in_resolver}},
                                  {"tcpkali.pkts.out", derived, #{resolver => pkts_out_resolver}}
                                 ]}}
        ]}
    ].

traffic_in_resolver() -> aggregate_sum("tcpkali.traffic.bitrate.in").
traffic_out_resolver() -> aggregate_sum("tcpkali.traffic.bitrate.out").
connections_in_resolver() -> aggregate_sum("tcpkali.connections.total.in").
connections_out_resolver() -> aggregate_sum("tcpkali.connections.total.out").
latency_mean_resolver() -> aggregate_mean("tcpkali.latency.message.mean", "tcpkali.traffic.msgs.rcvd.").
latency_min_resolver() -> aggregate_min("tcpkali.latency.message.min").
latency_50_resolver() -> aggregate_percentile("tcpkali.latency.message.50", 50).
latency_95_resolver() -> aggregate_percentile("tcpkali.latency.message.95", 95).
latency_99_resolver() -> aggregate_percentile("tcpkali.latency.message.99", 99).
latency_max_resolver() -> aggregate_max("tcpkali.latency.message.max").
latency_connect_mean_resolver() -> aggregate_mean("tcpkali.latency.connect.mean", "tcpkali.connections.opened.").
latency_connect_min_resolver() -> aggregate_min("tcpkali.latency.connect.min").
latency_connect_50_resolver() -> aggregate_percentile("tcpkali.latency.connect.50", 50).
latency_connect_95_resolver() -> aggregate_percentile("tcpkali.latency.connect.95", 95).
latency_connect_99_resolver() -> aggregate_percentile("tcpkali.latency.connect.99", 99).
latency_connect_max_resolver() -> aggregate_max("tcpkali.latency.connect.max").

% Temporarily use average while working on better solution for merging
aggregate_percentile("tcpkali.latency.message." ++ _ = Metric, _Percentile) ->
    aggregate_mean(Metric, "tcpkali.traffic.msgs.rcvd.");
aggregate_percentile("tcpkali.latency.connect." ++ _ = Metric, _Percentile) ->
    aggregate_mean(Metric, "tcpkali.connections.opened.").

pkts_in_resolver() ->
    lists:sum([V || {_, V} <- mzb_metrics:get_by_wildcard("systemload.netrx.pkts.*.*")]).

pkts_out_resolver() ->
    lists:sum([V || {_, V} <- mzb_metrics:get_by_wildcard("systemload.nettx.pkts.*.*")]).

aggregate_mean(Name, WeightMetric) ->
    {Time, Messages} = metric_fold(
        fun (Val, Pool, Worker, {TotalTime, TotalMsgs}) ->
            MessagesIn = get_metric("~s~b.~b", [WeightMetric, Pool, Worker], 0),
            {TotalTime + Val*MessagesIn, TotalMsgs + MessagesIn}
        end, {0, 0}, Name),
    case Messages of
        0 -> 0;
        _ -> Time / Messages
    end.

aggregate_min(Name) ->
    metric_fold(fun (Val, _, _, Acc) -> min(Acc, Val) end, undefined, Name).

aggregate_max(Name) ->
    metric_fold(fun (Val, _, _, Acc) -> max(Acc, Val) end, 0, Name).

aggregate_sum(Name) ->
    metric_fold(fun (Val, _, _, Acc) -> Acc + Val end, 0, Name).

metric_fold(Fun, InitialAcc, Name) ->
    case get_metric("tcpkali.pools_num", undefined) of
        undefined -> erlang:error(undefined_number_of_pools);
        Pools ->
            lists:foldl(
                fun (P, Acc1) ->
                    Workers = get_metric("tcpkali.workers_num.pool~b", [P], 0),
                    lists:foldl(
                        fun (W, Acc2) ->
                            case get_metric("~s.~b.~b", [Name, P, W], undefined) of
                                undefined -> Acc2;
                                Val -> Fun(Val, P, W, Acc2)
                            end
                        end, Acc1, lists:seq(1, Workers))
                end, InitialAcc, lists:seq(1, Pools))
    end.

get_metric(Format, Args, Default) ->
    get_metric(lists:flatten(io_lib:format(Format, Args)), Default).

get_metric(Name, Default) ->
    try mzb_metrics:get_value(Name) of
        Val -> Val
    catch
        error:{badarg, _, _} -> Default
    end.

metric_by_name("tcpkali.latency.connect." ++ _ = Name) ->
    {group, "Tcpkali", [{graph, #{title => "Latency connect", units => "ms", metrics => [{Name, gauge}]}}]};
metric_by_name("tcpkali.latency.message." ++ _ = Name) ->
    {group, "Tcpkali", [{graph, #{title => "Latency", units => "ms", metrics => [{Name, gauge}]}}]};
metric_by_name("tcpkali.traffic.bitrate.in." ++ _ = Name) ->
    {group, "Tcpkali", [{graph, #{title => "Traffic bitrate", units => "bits/s", metrics => [{Name, gauge}]}}]};
metric_by_name("tcpkali.traffic.bitrate.out." ++ _ = Name) ->
    {group, "Tcpkali", [{graph, #{title => "Traffic bitrate", units => "bits/s", metrics => [{Name, gauge}]}}]};
metric_by_name("tcpkali.traffic.bitrate." ++ _) ->
    undefined;
metric_by_name("tcpkali.connections.total." ++ _ = Name) ->
    {group, "Tcpkali", [{graph, #{title => "Connections total", units => "N", metrics => [{Name, gauge}]}}]};
metric_by_name("tcpkali.connections.opened." ++ _ = Name) ->
    {group, "Tcpkali", [{graph, #{title => "Connections opened", units => "N", metrics => [{Name, counter}]}}]};
metric_by_name("tcpkali.connections.opened" = Name) ->
    {group, "Tcpkali (aggregated)", [{graph, #{title => "Connections opened", units => "N", metrics => [{Name, counter}]}}]};
metric_by_name("tcpkali.traffic.msgs.rcvd." ++ _ = Name) ->
    {group, "Tcpkali", [{graph, #{title => "Messages", units => "N", metrics => [{Name, counter}]}}]};
metric_by_name("tcpkali.traffic.msgs.sent." ++ _ = Name) ->
    {group, "Tcpkali", [{graph, #{title => "Messages", units => "N", metrics => [{Name, counter}]}}]};
metric_by_name("tcpkali.traffic.msgs." ++ _ = Name) ->
    {group, "Tcpkali (aggregated)", [{graph, #{title => "Messages", units => "N", metrics => [{Name, counter}]}}]};
metric_by_name("tcpkali.traffic.data.writes" ++ _) ->
    undefined;
metric_by_name("tcpkali.traffic.data.reads" ++ _) ->
    undefined;
metric_by_name("tcpkali.traffic.data.sent." ++ _ = Name) ->
    {group, "Tcpkali", [{graph, #{title => "Traffic data", units => "bytes/s", metrics => [{Name, counter}]}}]};
metric_by_name("tcpkali.traffic.data.rcvd." ++ _ = Name) ->
    {group, "Tcpkali", [{graph, #{title => "Traffic data", units => "bytes/s", metrics => [{Name, counter}]}}]};
metric_by_name("tcpkali.traffic.data.sent" = Name) ->
    {group, "Tcpkali (aggregated)", [{graph, #{title => "Traffic data", units => "bytes/s", metrics => [{Name, counter}]}}]};
metric_by_name("tcpkali.traffic.data.rcvd" = Name) ->
    {group, "Tcpkali (aggregated)", [{graph, #{title => "Traffic data", units => "bytes/s", metrics => [{Name, counter}]}}]};
metric_by_name("tcpkali.pools_num" = Name) ->
    {group, "Tcpkali", [{graph, #{title => "Pools num", units => "N", metrics => [{Name, gauge, #{visibility => false}}]}}]};
metric_by_name("tcpkali.workers_num." ++ _ = Name) ->
    {group, "Tcpkali", [{graph, #{title => "Workers num", units => "N", metrics => [{Name, gauge, #{visibility => false}}]}}]};
metric_by_name(_) -> undefined.

start(#state{executable = Exec} = State, Meta, Options) ->
    Command = Exec ++ lists:foldl(fun({raw, Raw}, A) -> A ++ " " ++ Raw;
                        ({url, Url}, A) -> A ++ " \"" ++ Url ++ "\"";
                        ({Opt, Val}, A) ->
                            L = string:join(string:tokens(atom_to_list(Opt), "_"), "-"),
                            Val2 = prepare_val(Val),
                            case length(L) of
                                1 -> A ++ " -" ++ L ++ Val2;
                                _ -> A ++ " --" ++ L ++ " " ++ Val2 end end,
                            "", Options),
    ID = report_worker_nums(Meta),
    case run(Command, ID) of
        0 -> ok;
        ExitCode -> erlang:error({tcpkali_error, ExitCode})
    end,
    {nil, State}.

start_cmd(#state{executable = Exec} = State, Meta, "tcpkali " ++ Options) ->
    Command = Exec ++ " " ++ Options,
    ID = report_worker_nums(Meta),
    case run(Command, ID) of
        0 -> ok;
        ExitCode -> erlang:error({tcpkali_error, ExitCode})
    end,
    {nil, State}.

report_worker_nums(Meta) ->
    WorkerID = proplists:get_value(worker_id, Meta),
    PoolID = proplists:get_value(pool_id, Meta),
    PoolNum = proplists:get_value(pools_num, Meta),
    WorkersNum = proplists:get_value(pool_size, Meta),
    notify(lists:flatten(io_lib:format("tcpkali.workers_num.pool~b", [PoolID])), gauge, WorkersNum),
    notify("tcpkali.pools_num", gauge, PoolNum),
    lists:flatten(io_lib:format("~b.~b", [PoolID, WorkerID])).

generate_filler(N, Id) ->
    Prefix = "\\{" ++ erlang:integer_to_list(Id),
    Postfix = "}",
    NumToGenerate = N - length(Prefix) - length(Postfix),
    case NumToGenerate  >= 0 of
        true -> Prefix ++ [$\s || _  <- lists:seq(1, NumToGenerate)] ++ Postfix;
        false -> erlang:error({expression_too_small})
    end.

replace_expressions(Str) ->
    % Hack: {message.marker} will be replaced with 30 bytes long marker inside tcpkali
    % which will make cbor broken because "{message.marker}" itself has different length
    % so we replace it with "{message.marker             }" which has the same meaning
    % but it will not change the length after replacement is done
    Str2 = re:replace(Str, "\\\\{message.marker}", "\\\\{message.marker             }",[{return,list},global]),
    replace_expressions(Str2, []).

replace_expressions(Str, Acc) ->
    RE = "(?<PREFIX>^.*)(?<EXPR>\\\\{.*?})\\((?<NUM>[0-9]+)\\)(?<ENDING>.*$)",
    case re:run(Str, RE, [{capture, [<<"PREFIX">>,<<"EXPR">>, <<"NUM">>, <<"ENDING">>], list}]) of
        {match, [Prefix, Expr, NumStr, Ending]} ->
            Num = erlang:list_to_integer(NumStr),
            LastId =
                case Acc of
                    [] -> 0;
                    [{N, _}|_] -> N
                end,
            Replacement = generate_filler(Num, LastId + 1),
            replace_expressions(Prefix ++ Replacement ++ Ending, [{LastId + 1, Expr}|Acc]);
        nomatch ->
            {Str, Acc}
    end.

replace_back(Str, []) -> Str;
replace_back(Str, [{Id, Expr} | Tail]) ->
    RE = lists:flatten(io_lib:format("\\\\{~b\\s*}", [Id])),
    Expr2 = re:replace(Expr, "\\\\", "\\\\\\\\",[{return,list}, global]),
    Res = re:replace(Str, RE, Expr2, [{return,list}]),
    replace_back(Res, Tail).

json2cbor(State, _Meta, Str) ->
    json2cbor(State, _Meta, Str, string).

json2cbor(State, _Meta, Str, Type) ->
    Str2 = re:replace(Str, "\\\\", "\\\\\\\\",[{return,list}, global]),

    {Str3, Expressions} = replace_expressions(Str2),

    JSON = jiffy:decode(Str3, [return_maps]),
    CBORBin = erlang:iolist_to_binary(cbor:encode(JSON)),
    CBOR = replace_back(CBORBin, Expressions),
    Formatted =
        case Type of
            binary -> iolist_to_binary(CBOR);
            string -> lists:flatten([format_byte(X) || <<X:8>> <= iolist_to_binary(CBOR)])
        end,
    {Formatted, State}.

format_byte(B) ->
    case lists:member(B, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789()[]{} .,;-+=\\/") of
        true -> B;
        false -> io_lib:format("\\x~2.16.0B",[B])
    end.

encode(State, Meta, "cbor", Str) ->
    json2cbor(State, Meta, Str);
encode(State, _Meta, _, Str) ->
    Str2 = re:replace(Str, "(?<EXPR>\\\\{.*?})(?<NUM>\\([0-9]+\\))", "\\1", [{return,list},global]),
    {Str2, State}.

prepare_val(Val) when is_float(Val) ->   float_to_list(Val);
prepare_val(Val) when is_integer(Val) -> integer_to_list(Val);
prepare_val(Val) when is_list(Val) ->
    case length(string:tokens(Val, " ")) of
        0 -> Val;
        _ -> "'" ++ re:replace(Val, "'", "'\"'\"'",[{return,list}, global]) ++ "'"
    end.

run(Command, WorkerID) ->
    StatsdPort = spawn_statsd(WorkerID),
    CommandToExec = set_default_percentiles(set_statsd_port(Command, StatsdPort)),
    lager:info("Executing ~p...", [CommandToExec]),
    {ok, Pid, _OsPid} = exec:run(CommandToExec, [monitor, stdout, stderr]),
    get_data(Pid).

set_statsd_port(Command, Port) ->
    case is_arg_set(Command, "--statsd-port") of
        false -> Command ++ lists:flatten(io_lib:format(" --statsd-port ~b", [Port]));
        true -> Command
    end.

set_default_percentiles(Command) ->
    case is_arg_set(Command, "--latency-percentiles") of
        false -> Command ++ " --latency-percentiles 50,95,99";
        true -> Command
    end.

is_arg_set(Command, Arg) ->
    case re:run(Command, " " ++ Arg ++ " ") of
        {match, _} -> true;
        nomatch -> false
    end.

get_data(Pid) ->
    receive
        {Stream, _Pid, Bytes} when (Stream == stdout) or (Stream == stderr) ->
            lager:info("Output: ~s", [Bytes]),
            get_data(Pid);
        {'DOWN', _ , _, _, {exit_status, Code}} -> Code;
        {'DOWN', _ , _, _, normal} -> 0
    end.

spawn_statsd(WorkerID) ->
    erlang:spawn(?MODULE, statsd, [self(), WorkerID]),
    receive
        {started, Port} -> Port
    after
        5000 -> erlang:error(statsd_start_timed_out)
    end.

statsd(Parent, WorkerID) ->
    {ok, ListenSocket} = gen_udp:open(0, [binary, {active, false}]),
    {ok, Port} = inet:port(ListenSocket),
    Parent ! {started, Port},
    accept(ListenSocket, WorkerID).

parse(<<>>, _) -> ok;
parse(Bin, WId) ->
    lists:map(fun (B) -> report(B, WId) end, binary:split(Bin, <<"\n">>, [global])).

report(<<>>, _) -> ok;
report(Bin, WorkerID) ->
    case binary:split(Bin, [<<"|">>, <<":">>], [global]) of
        [Metric, Value, Type|_] ->
            MetricStr = binary_to_list(Metric),
            {TypeAtom, ValueInt} =
                case Type of
                    <<"c">> -> {counter, parse_int(Value)};
                    <<"g">> -> {gauge, parse_int(Value)};
                    _ -> lager:info("Unknown type ~p", [Type]), gauge
                end,

            case TypeAtom of
                gauge ->
                    notify(MetricStr ++ "." ++ WorkerID, TypeAtom, ValueInt);
                counter ->
                    notify(MetricStr ++ "." ++ WorkerID, TypeAtom, ValueInt),
                    notify(MetricStr, TypeAtom, ValueInt)
            end;
        _ -> lager:info("Unknown format: ~s", [Bin])
    end.

notify(Metric, Type, Value) ->
    case metric_by_name(Metric) of
        undefined -> ignore;
        MetricSpec ->
            case erlang:get({metric_cache, MetricSpec}) of
                declared -> ok;
                undefined ->
                    mzb_metrics:declare_metrics([MetricSpec]),
                    erlang:put({metric_cache, MetricSpec}, declared)
            end,
            mzb_metrics:notify({Metric, Type}, Value)
    end.

parse_int(Bin) ->
    try erlang:binary_to_integer(Bin) of
        V -> V
    catch
        _:_ ->
            erlang:round(erlang:binary_to_float(Bin))
    end.

accept(Socket, WId) ->
    inet:setopts(Socket, [{active, once}]),
    receive
        {udp, Socket, _Host, _Port, Binary} ->
            parse(Binary, WId),
            accept(Socket, WId)
    end.
