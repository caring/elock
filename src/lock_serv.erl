-module (lock_serv).

-behaviour (gen_server).

-export([start_link/0, terminate/2, handle_info/2, code_change/3]).
-export([lock/1, lock/2, unlock/1, unlock_all/0, get_locker_id/0, stats/0]).
-export([init/1, handle_call/3, handle_cast/2]).

-include ("lock_stats.hrl").

-record(lock_state, {
    % Currently held locks (key -> locker_id)
    locks=dict:new(),
    % Current clients waiting for lock (key -> queue<pid>)
    waiters=dict:new(),
    % Current locks held by clients (locker_id -> list<key)
    clients=dict:new(),
    % locker_id -> pid mappings
    lockers=dict:new(),
    % pid -> locker_id -> locker_id
    lockers_rev=dict:new(),
    % Simple locker id allocation
    next_locker_id=1,
    % pid -> monitor ref
    mon_refs=dict:new()
    }).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

terminate(shutdown, State) ->
    {ok, State}.

handle_info({'EXIT', Pid, Reason}, State) ->
    error_logger:info_msg("Got an exit from ~p: ~p~n", [Pid, Reason]),
    {noreply, State};
handle_info({'DOWN', _Ref, process, Pid, _Why}, State) ->
    % Release all this guy's locks and locker info
    {noreply, unregister(Pid, unlock_all(Pid, State))}.

code_change(_OldVsn, State, _Extra) ->
    error_logger:info_msg("Code's changing.  Hope that's OK~n", []),
    {ok, State}.

get_locker_id() ->
    gen_server:call(?MODULE, get_locker_id).

stats() ->
    gen_server:call(?MODULE, stats).

lock(Key) ->
    gen_server:call(?MODULE, {lock, Key}).

lock(Key, WaitMillis) ->
    % Don't wait longer than erlang allows me to.
    Wait = lists:min([WaitMillis, 16#ffffffff]),
    case gen_server:call(?MODULE, {lock, Key, Wait}) of
        ok -> ok;
        delayed ->
            receive
                {acquiring, Key, From} ->
                    From ! {ack, self()},
                    receive {acquired, Key} -> ok end
                after Wait -> locked
            end
    end.

unlock(Key) ->
    gen_server:call(?MODULE, {unlock, Key}).

unlock_all() ->
    gen_server:cast(?MODULE, {unlock_all, self()}).

init(_Args) ->
    {ok, #lock_state{}}.

handle_call({lock, Key}, From, Locks) ->
    {Response, Locks2} = lock(Key, From, Locks),
    {reply, Response, Locks2};
handle_call({lock, Key, Wait}, From, Locks) ->
    {Response, Locks2} = lock(Key, Wait, From, Locks),
    {reply, Response, Locks2};
handle_call({unlock, Key}, From, Locks) ->
    {Response, Locks2} = unlock(Key, From, Locks),
    {reply, Response, Locks2};
handle_call(get_locker_id, From, Locks) ->
    {ok, Response, Locks2} = allocate_or_find_locker_id(From, Locks),
    {reply, Response, Locks2};
handle_call(stats, From, Locks) ->
    {ok, Response} = stats(From, Locks),
    {reply, Response, Locks}.

handle_cast(reset, _Locks) ->
    error_logger:info_msg("Someone casted a reset", []),
   {noreply, #lock_state{}};
handle_cast({unlock_all, Pid}, Locks) ->
   error_logger:info_msg("Unlocking all owned by ~p", [Pid]),
  {noreply, unlock_all(Pid, Locks)}.
  

% Actual lock handling

lock(Key, {From, Something}, LocksIn) ->
    {ok, Id, Locks} = allocate_or_find_locker_id({From, Something}, LocksIn),
    case dict:find(Key, Locks#lock_state.locks) of
        {ok, Id} -> {ok, Locks};
        {ok, _SomeoneElse} -> {locked, Locks};
        error -> {ok, unconditional_lock(Key, From, Locks)}
    end.

lock(Key, Wait, {From, Something}, Locks) ->
    case lock(Key, {From, Something}, Locks) of
        {ok, Rv} -> {ok, Rv};
        _ -> {delayed, enqueue_waiter(Key, Wait, From, Locks)}
    end.

unlock(Key, {From, Something}, LocksIn) ->
    {ok, Id, Locks} = allocate_or_find_locker_id({From, Something}, LocksIn),
    case dict:find(Key, Locks#lock_state.locks) of
        {ok, Id} -> {ok, hand_over_lock(Key, Id, Locks)};
        {ok, _Someone} -> {not_yours, Locks};
        _ -> {not_locked, Locks}
    end.

unlock_all(Pid, LocksIn) ->
    {ok, Id, Locks} = allocate_or_find_locker_id({Pid, unknown}, LocksIn),
    lists:foldl(fun(K, L) -> hand_over_lock(K, Id, L) end,
        Locks, get_client_list(Id, Locks#lock_state.clients)).

ensure_monitoring(Pid, Locks) ->
    R = Locks#lock_state.mon_refs,
    case dict:find(Pid, R) of
        {ok, _ref} -> R;
        error -> dict:store(Pid, erlang:monitor(process, Pid), R)
    end.

allocate_or_find_locker_id({From, _Something}, Locks) ->
    case dict:find(From, Locks#lock_state.lockers_rev) of
        {ok, Id} ->
            {ok, Id, Locks};
        _ ->
            Cid = Locks#lock_state.next_locker_id,
            Sid = io_lib:format("~p", [Cid]),
            {ok, Sid,
                Locks#lock_state{
                    next_locker_id=Cid + 1,
                    lockers=dict:store(Sid, From, Locks#lock_state.lockers),
                    lockers_rev=dict:store(From, Sid, Locks#lock_state.lockers_rev),
                    mon_refs=ensure_monitoring(From, Locks)
                }}
    end.

unregister(Pid, State) ->
    {ok, Id} = dict:find(Pid, State#lock_state.lockers_rev),
    State#lock_state{
        lockers=dict:erase(Id, State#lock_state.lockers),
        lockers_rev=dict:erase(Pid, State#lock_state.lockers_rev),
        mon_refs=dict:erase(Pid, State#lock_state.mon_refs)}.

stats({_From, _Something}, Locks) ->
    Rv = #stats{
        clients=dict:size(Locks#lock_state.lockers),
        locks=dict:size(Locks#lock_state.locks),
        monitoring=dict:size(Locks#lock_state.mon_refs)
    },
    % Assertion: size(lockers) == size(lockers_rev)
    Csize = Rv#stats.clients,
    Csize = dict:size(Locks#lock_state.lockers_rev),
    {ok, Rv}.

% Private support stuff

get_client_list(From, D) ->
    case dict:find(From, D) of
        {ok, V} -> V;
        error -> []
    end.

add_client(Key, From, D) ->
    dict:store(From, get_client_list(From, D) ++ [Key], D).

remove_client(Key, From, D) ->
    case get_client_list(From, D) of
        [Key] -> dict:erase(From, D);
        L -> dict:store(From, lists:delete(Key, L), D)
    end.

% Reserve the lock
unconditional_lock(Key, From, LocksIn) ->
    {ok, Id, Locks} = allocate_or_find_locker_id({From, none}, LocksIn),
    Locks#lock_state{
        locks=dict:store(Key, Id, Locks#lock_state.locks),
        clients=add_client(Key, Id, Locks#lock_state.clients),
        mon_refs=ensure_monitoring(From, Locks)}.

% return the specified lock.  If someone else wants it, give it up
hand_over_lock(Key, From, Locks) ->
    case dict:find(Key, Locks#lock_state.waiters) of
        {ok, Q} ->
            try_waiter(Key, From, Q, Locks);
        error ->
            Locks#lock_state{
                locks=dict:erase(Key, Locks#lock_state.locks),
                clients=remove_client(Key, From, Locks#lock_state.clients)}
    end.

try_waiter(Key, From, Q, Locks) ->
    case queue:is_empty(Q) of
    true ->
        Locks#lock_state{
            locks=dict:erase(Key, Locks#lock_state.locks),
            clients=remove_client(Key, From, Locks#lock_state.clients)};
    _ ->
        {{value, Waiter}, Q2} = queue:out(Q),
        Waiter ! {acquiring, Key, self()},
        receive
            {ack, Waiter} ->
                Waiter ! {acquired, Key},
                unconditional_lock(Key, Waiter,
                    Locks#lock_state{
                        waiters=dict:store(Key, Q2, Locks#lock_state.waiters)})
            after 25 ->
                try_waiter(Key, From, Q2, Locks)
        end
    end.

% I may want to have this thing magically time out after a while.
enqueue_waiter(Key, _Wait, From, Locks) ->
    Q = case dict:find(Key, Locks#lock_state.waiters) of
        {ok, Queue} -> Queue;
        error -> queue:new()
    end,
    Locks#lock_state{waiters=dict:store(
        Key, queue:in(From, Q), Locks#lock_state.waiters)}.