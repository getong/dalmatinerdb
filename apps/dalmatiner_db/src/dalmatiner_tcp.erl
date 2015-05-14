-module(dalmatiner_tcp).

-behaviour(ranch_protocol).

-include_lib("dproto/include/dproto.hrl").
-include_lib("mmath/include/mmath.hrl").

-export([start_link/4]).
-export([init/4]).

-record(state,
        {cbin,
         nodes,
         n = 1 :: pos_integer(),
         w = 1 :: pos_integer(),
         fast_loop_count :: pos_integer(),
         wait = 5000 :: pos_integer()
        }).

-record(sstate,
        {last = undefined :: non_neg_integer() | undefined,
         max_diff = 1 :: pos_integer(),
         wait = 5000 :: pos_integer(),
         dict :: bkt_dict:bkt_dict()}).


-type state() :: #state{}.

-type stream_state() :: #sstate{}.

start_link(Ref, Socket, Transport, Opts) ->
    Pid = spawn_link(?MODULE, init, [Ref, Socket, Transport, Opts]),
    {ok, Pid}.

init(Ref, Socket, Transport, _Opts = []) ->
    {ok, FLC} = application:get_env(dalmatiner_db, fast_loop_count),
    {ok, Wait} = application:get_env(dalmatiner_db, loop_wait),
    {ok, N} = application:get_env(dalmatiner_db, n),
    {ok, W} = application:get_env(dalmatiner_db, w),
    State = #state{n=N, w=W, fast_loop_count=FLC, wait=Wait},
    ok = Transport:setopts(Socket, [{packet, 4}]),
    ok = ranch:accept_ack(Ref),
    loop(Socket, Transport, State, 0).

-spec loop(port(), term(), state(), non_neg_integer()) -> ok.

loop(Socket, Transport, State = #state{fast_loop_count = FL}, 0) ->
    {ok, CBin} = riak_core_ring_manager:get_chash_bin(),
    Nodes = chash:nodes(chashbin:to_chash(CBin)),
    Nodes1 = [{I, riak_core_apl:get_apl(I, State#state.n, metric)}
              || {I, _} <- Nodes],
    loop(Socket, Transport, State#state{nodes = Nodes1, cbin=CBin}, FL);

loop(Socket, Transport, State, Loop) ->
    case Transport:recv(Socket, 0, State#state.wait) of
        {ok, Data} ->
            case dproto_tcp:decode(Data) of
                buckets ->
                    {ok, Bs} = metric:list(),
                    Transport:send(Socket, dproto_tcp:encode_metrics(Bs)),
                    loop(Socket, Transport, State, Loop - 1);
                {list, Bucket} ->
                    {ok, Ms} = metric:list(Bucket),
                    Transport:send(Socket, dproto_tcp:encode_metrics(Ms)),
                    loop(Socket, Transport, State, Loop - 1);
                {get, B, M, T, C} ->
                    do_send(Socket, Transport, B, M, T, C),
                    loop(Socket, Transport, State, Loop - 1);
                {stream, Bucket, Delay} ->
                    lager:info("[tcp] Entering stream mode for bucket '~s' "
                               "and a max delay of: ~p", [Bucket, Delay]),
                    ok = Transport:setopts(Socket, [{packet, 0}]),
                    stream_loop(Socket, Transport,
                                #sstate{max_diff = Delay,
                                        dict = bkt_dict:new(Bucket,
                                                            State#state.n,
                                                            State#state.w)},
                                {incomplete, <<>>})
            end;
        {error, timeout} ->
            loop(Socket, Transport, State, Loop - 1);
        {error, closed} ->
            ok;
        E ->
            lager:error("[tcp:loop] Error: ~p~n", [E]),
            ok = Transport:close(Socket)
    end.
do_send(Socket, Transport, B, M, T, C) ->
    PPF = metric:ppf(B),
    [{T0, C0} | Splits] = mstore:make_splits(T, C, PPF),
    {ok, Resolution, Points} = metric:get(B, M, PPF, T0, C0),
    Transport:send(Socket, <<Resolution:64/integer, Points/binary>>),
    send_parts(Socket, Transport, PPF, B, M, Splits).

send_parts(_Socket, _Transport, _PPF, _B, _M, []) ->
    ok;

send_parts(Socket, Transport, PPF, B, M, [{T, C} | Splits]) ->
    {ok, _Resolution, Points} = metric:get(B, M, PPF, T, C),
    Transport:send(Socket, <<Points/binary>>),
    send_parts(Socket, Transport, PPF, B, M, Splits).

-spec stream_loop(port(), term(), stream_state(),
                  {dproto_tcp:stream_message(), binary()}) ->
                         ok.
stream_loop(Socket, Transport,
            State = #sstate{dict = Dict},
            {flush, Rest}) ->
    Dict1 = flush(Dict),
    stream_loop(Socket, Transport, State#sstate{dict = Dict1},
                dproto_tcp:decode_stream(Rest));

stream_loop(Socket, Transport,
            State = #sstate{dict = Dict, last = undefined},
            {{stream, Metric, Time, Points}, Rest}) ->
    Dict1 = bkt_dict:add(Metric, Time, Points, Dict),
    stream_loop(Socket, Transport, State#sstate{dict = Dict1, last = Time},
                dproto_tcp:decode_stream(Rest));

stream_loop(Socket, Transport,
            State = #sstate{last = _L, max_diff = _Max, dict = Dict},
            {{stream, Metric, Time, Points}, Rest})
  when Time - _L > _Max ->
    Dict1 = flush(Dict),
    Dict2 = bkt_dict:add(Metric, Time, Points, Dict1),
    stream_loop(Socket, Transport, State#sstate{dict = Dict2, last = undefined},
                dproto_tcp:decode_stream(Rest));

stream_loop(Socket, Transport, State = #sstate{dict = Dict},
            {{stream, Metric, Time, Points}, Acc}) ->
    Dict1 = bkt_dict:add(Metric, Time, Points, Dict),
    stream_loop(Socket, Transport, State#sstate{dict = Dict1},
                dproto_tcp:decode_stream(Acc));

stream_loop(Socket, Transport, State = #sstate{dict = Dict},
            {{batch, Time}, Acc}) ->
    %% When entering batch mode we make sure to drain the dict first and
    %% set last as undefined since we'll flush at the end too.
    %% TODO: figure out if this flushing makes sense or if we can make it
    %% conditional
    Dict1 = flush(Dict),
    batch_loop(Socket, Transport, State#sstate{dict = Dict1, last = undefined},
               Time, dproto_tcp:decode_batch(Acc));

stream_loop(Socket, Transport, State = #sstate{max_diff = D},
            {incomplete, Acc}) ->
    case Transport:recv(Socket, 0, min(D * 1000, 5000)) of
        {ok, Data} ->
            Acc1 = <<Acc/binary, Data/binary>>,
            stream_loop(Socket, Transport, State,
                        dproto_tcp:decode_stream(Acc1));
        {error, timeout} ->
            stream_loop(Socket, Transport, State, {incomplete, Acc});
        {error,closed} ->
            bkt_dict:flush(State#sstate.dict),
            ok;
        E ->
            lager:error("[tcp:stream] Error: ~p~n", [E]),
            bkt_dict:flush(State#sstate.dict),
            ok = Transport:close(Socket)
    end.


-spec batch_loop(port(), term(), stream_state(), non_neg_integer(),
                 {dproto_tcp:batch_message(), binary()}) ->
                        ok.

batch_loop(Socket, Transport, State = #sstate{dict = Dict}, _Time,
           {batch_end, Acc}) ->
    Dict1 = flush(Dict),
    stream_loop(Socket, Transport, State#sstate{dict = Dict1},
               dproto_tcp:decode_stream(Acc));

batch_loop(Socket, Transport, State  = #sstate{dict = Dict}, Time,
           {{batch, Metric, Point}, Acc}) ->
    Dict1 = bkt_dict:add(Metric, Time, Point, Dict),
    batch_loop(Socket, Transport, State#sstate{dict = Dict1}, Time,
               dproto_tcp:decode_batch(Acc));


batch_loop(Socket, Transport, State, Time, {incomplete, Acc}) ->
    case Transport:recv(Socket, 0, 1000) of
        {ok, Data} ->
            Acc1 = <<Acc/binary, Data/binary>>,
            batch_loop(Socket, Transport, State, Time,
                        dproto_tcp:decode_batch(Acc1));
        {error, timeout} ->
            batch_loop(Socket, Transport, State, Time, {incomplete, Acc});
        {error,closed} ->
            bkt_dict:flush(State#sstate.dict),
            ok;
        E ->
            lager:error("[tcp:stream] Error: ~p~n", [E]),
            bkt_dict:flush(State#sstate.dict),
            ok = Transport:close(Socket)
    end.

flush(Dict) ->
    Dict1 = bkt_dict:flush(Dict),
    drain(),
    Dict1.

drain() ->
    receive
        _ ->
            drain()
    after
        0 ->
            ok
    end.
