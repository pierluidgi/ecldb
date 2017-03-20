%%
%% Hash ring module
%%


-module(ecldb_ring).

-include("../include/ecldb.hrl").

-export([
    new/0,
    ring_size/1,
    add_domain/2,   %% Add domain to ring
    add_domain/3,
    del_domain/2,   %% Del domain from ring
    del_domain/3,
    list_domains/1,
    list_nodes/1,

    route/3,
    r/2, r/3
  ]).

-compile({no_auto_import, [size/1]}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Bisect exports {{{
%-export([new/2, new/3, insert/3, bulk_insert/2, append/3, find/2, foldl/3]).
%-export([next/2, next_nth/3, first/1, last/1, delete/2, compact/1, cas/4, update/4]).
%-export([serialize/1, deserialize/1, from_orddict/2, to_orddict/1, find_many/2]).
%-export([merge/2, intersection/1, intersection/2]).
%-export([expected_size/2, expected_size_mb/2, num_keys/1, size/1]).
%% }}}
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

new() -> new(32,32).
  
ring_size(Ring) -> size(Ring).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% ADD & DEL {{{
%% add N domains to ring, return count domains in ring
add_domain(DomainKey, Ring) ->
  add_domain(DomainKey, Ring, 16).

add_domain(DomainKey, Ring, N) when N > 0 ->
  Key = ecldb_misc:md5_hex(ecldb_misc:random_bin(16)),
  NewRing = insert(Ring, Key, DomainKey),
  add_domain(DomainKey, NewRing, N-1);
add_domain(DomainKey, Ring, _N) -> 
  DomainsCount = proplists:get_value(DomainKey, list_domains(Ring), 0),  
  {ok, Ring, DomainsCount}.


% Del N damains from ring, return count domains in ring
del_domain(DomainKey, Ring) -> 
  del_domain(DomainKey, Ring, 1).

del_domain(DomainKey, Ring, Num) -> 
  KFun = fun (K, V, Acc) when V == DomainKey -> [K|Acc]; (_, _, Acc) -> Acc end,
  Keys = ecldb_misc:shuffle_list(foldl(Ring, KFun, [])),
  DFun = fun
    (Fu, [K|RestK], R,  N) when N > 0 -> Fu(Fu, RestK, delete(R, K), N - 1);
    (_F, _,         R, _N) -> R
  end,
  NewRing = DFun(DFun, Keys, Ring, Num),
  DomainsCount = proplists:get_value(DomainKey, list_domains(NewRing), 0),
  {ok, NewRing, DomainsCount}.
%% }}}
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%%
list_domains(Ring) ->
  F =
    fun(_Key, Value, Acc) ->
      Counter = proplists:get_value(Value, Acc, 0),
      lists:keystore(Value, 1, Acc, {Value, Counter+1})
    end,
  foldl(Ring, F, []).


%%
list_nodes(Ring) ->
  List = list_domains(Ring),
  F = fun
    ({{ok, #{node := Node}}, Len}, Acc) ->
        Counter = proplists:get_value(Node, Acc, 0),
        lists:keystore(Node, 1, Acc, {Node, Counter + Len});
    (_, Acc) -> Acc
  end,
  lists:foldl(F, [], List).


r(A, B) -> {A, B}.
r(A, B, C) -> {A, B, C}.



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% ROUTING {{{
%% Route thru the rings
%% 1. use dynamic compiling beam with name same as claster name
%% 2. In dynamic compiling module:
%-define(MODE, proxy).
%route(KeyHash) -> ecldb_ring:route(?MODULE, KeyHash).
%mode()         -> ?MODE.
%first()        -> ring1.
%second()       -> ring2.
%domains()      -> domains.
%% 
-define(ZERO_HASH, <<0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0>>).

% Module = ClusterName
route(Module, norma, KeyHash) -> 
  case get_domain(Module, first, KeyHash) of
    {ok, Domain} -> {norma, Domain};
    Else         -> Else
  end;
route(Module, Mode,  KeyHash) -> 
  case [get_domain(Module, Ring, KeyHash) || Ring <- [first, second]] of
    [{ok,V1}, {ok,V2}] when V1 == V2 -> {norma, V1};
    [{ok,V1}, {ok,V2}]               -> {Mode, V1, V2};
    Else                             -> ?e(cluster_rings_error, ?p(Else))
  end.

%
get_domain(Module, Ring, KeyHash) ->
  case get_value_from_ring(Module, Ring, KeyHash) of
    {ok, ValueKey} ->
      case Module:domains() of
        #{ValueKey := Domain} -> {ok, Domain};
        error   -> ?e(domain_not_found)
      end;
    Else -> Else
  end.

%
get_value_from_ring(Module, Ring, KeyHash) ->
  case next(Module:Ring(), KeyHash) of
    {_Next, V} -> {ok, V};
    not_found  -> %% TODO optimize this
      case next(Module:Ring(), ?ZERO_HASH) of
        {_Next, V} -> {ok, V};
        not_found  -> ?e(domain_not_found)
      end
  end.
%% }}}
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%








%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Bisect {{{
%% @doc: Space-efficient dictionary implemented using a binary
%%
%% This module implements a space-efficient dictionary with no
%% overhead per entry. Read and write access is O(log n).
%%
%% Keys and values are fixed size binaries stored ordered in a larger
%% binary which acts as a sparse array. All operations are implemented
%% using a binary search.
%%
%% As large binaries can be shared among processes, there can be
%% multiple concurrent readers of an instance of this structure.
%%
%% serialize/1 and deserialize/1
%-module(ecl_bisect).
%-author('Knut Nesheim <knutin@gmail.com>').
%-compile({no_auto_import, [size/1]}).

%%
%% TYPES
%%

-type key_size()   :: pos_integer().
-type value_size() :: pos_integer().
-type block_size() :: pos_integer().

-type key()        :: binary().
-type value()      :: binary().

-type index()      :: pos_integer().

-record(bindict, {
          key_size   :: key_size(),
          value_size :: value_size(),
          block_size :: block_size(),
          b          :: binary()
}).
-type bindict() :: #bindict{}.


%%
%% API
%%

-spec new(key_size(), value_size()) -> bindict().
%% @doc: Returns a new empty dictionary where where the keys and
%% values will always be of the given size.
new(KeySize, ValueSize) when is_integer(KeySize)
                             andalso is_integer(ValueSize) ->
    new(KeySize, ValueSize, <<>>).

-spec new(key_size(), value_size(), binary()) -> bindict().
%% @doc: Returns a new dictionary with the given data
new(KeySize, ValueSize, Data) when is_integer(KeySize)
                                   andalso is_integer(ValueSize)
                                   andalso is_binary(Data) ->
    #bindict{key_size = KeySize,
             value_size = ValueSize,
             block_size = KeySize + ValueSize,
             b = Data}.


-spec insert(bindict(), key(), value()) -> bindict().
%% @doc: Inserts the key and value into the dictionary. If the size of
%% key and value is wrong, throws badarg. If the key is already in the
%% array, the value is updated.
insert(B, K, V) when byte_size(K) =/= B#bindict.key_size orelse
                     byte_size(V) =/= B#bindict.value_size ->
    erlang:error(badarg);

insert(#bindict{b = <<>>} = B, K, V) ->
    B#bindict{b = <<K/binary, V/binary>>};

insert(B, K, V) ->
    Index = index(B, K),
    LeftOffset = Index * B#bindict.block_size,
    RightOffset = byte_size(B#bindict.b) - LeftOffset,

    KeySize = B#bindict.key_size,
    ValueSize = B#bindict.value_size,

    case B#bindict.b of
        <<Left:LeftOffset/binary, K:KeySize/binary, _:ValueSize/binary, Right/binary>> ->
            B#bindict{b = iolist_to_binary([Left, K, V, Right])};

        <<Left:LeftOffset/binary, Right:RightOffset/binary>> ->
            B#bindict{b = iolist_to_binary([Left, K, V, Right])}
    end.



%% @doc: Update the value stored under the key by calling F on the old
%% value to get a new value. If the key is not present, initial will
%% be stored as the first value. Same as dict:update/4. Note: find and
%% insert requires two binary searches in the binary, while update
%% only needs one. It's as close to in-place update we can get in pure
%% Erlang.
update(B, K, Initial, F) when byte_size(K) =/= B#bindict.key_size orelse
                              byte_size(Initial) =/= B#bindict.value_size orelse
                              not is_function(F) ->
    erlang:error(badarg);

update(B, K, Initial, F) ->
    Index = index(B, K),
    LeftOffset = Index * B#bindict.block_size,
    RightOffset = byte_size(B#bindict.b) - LeftOffset,

    KeySize = B#bindict.key_size,
    ValueSize = B#bindict.value_size,

    case B#bindict.b of
        <<Left:LeftOffset/binary, K:KeySize/binary, OldV:ValueSize/binary, Right/binary>> ->
            case F(OldV) of
                OldV ->
                    B;
                NewV ->
                    byte_size(NewV) =:= ValueSize orelse erlang:error(badarg),
                    B#bindict{b = iolist_to_binary([Left, K, NewV, Right])}
            end;

        <<Left:LeftOffset/binary, Right:RightOffset/binary>> ->
            B#bindict{b = iolist_to_binary([Left, K, Initial, Right])}
    end.

-spec append(bindict(), key(), value()) -> bindict().
%% @doc: Append a key and value. This is only useful if the key is known
%% to be larger than any other key. Otherwise it will corrupt the bindict.
append(B, K, V) when byte_size(K) =/= B#bindict.key_size orelse
                     byte_size(V) =/= B#bindict.value_size ->
    erlang:error(badarg);

append(B, K, V) ->
    case last(B) of
        {KLast, _} when K =< KLast ->
          erlang:error(badarg);
        _ ->
          Bin = B#bindict.b,
          B#bindict{b = <<Bin/binary, K/binary, V/binary>>}
    end.

-spec cas(bindict(), key(), value() | 'not_found', value()) -> bindict().
%% @doc: Check-and-set operation. If 'not_found' is specified as the
%% old value, the key should not exist in the array. Provided for use
%% by bisect_server.
cas(B, K, OldV, V) ->
    case find(B, K) of
        OldV ->
            insert(B, K, V);
        _OtherV ->
            error(badarg)
    end.


-spec find(bindict(), key()) -> value() | not_found.
%% @doc: Returns the value associated with the key or 'not_found' if
%% there is no such key.
find(B, K) ->
    case at(B, index(B, K)) of
        {K, Value}   -> Value;
        {_OtherK, _} -> not_found;
        not_found    -> not_found
    end.

-spec find_many(bindict(), [key()]) -> [value() | not_found].
find_many(B, Keys) ->
    lists:map(fun (K) -> find(B, K) end, Keys).

-spec delete(bindict(), key()) -> bindict().
delete(B, K) ->
    LeftOffset = index2offset(B, index(B, K)),
    KeySize = B#bindict.key_size,
    ValueSize = B#bindict.value_size,

    case B#bindict.b of
        <<Left:LeftOffset/binary, K:KeySize/binary, _:ValueSize/binary, Right/binary>> ->
            B#bindict{b = <<Left/binary, Right/binary>>};
        _ ->
            erlang:error(badarg)
    end.

-spec next(bindict(), key()) -> {key(), value()} | not_found.
%% @doc: Returns the next larger key and value associated with it or
%% 'not_found' if no larger key exists.
next(B, K) ->
  next_nth(B, K, 1).

%% @doc: Returns the nth next larger key and value associated with it
%% or 'not_found' if it does not exist.
-spec next_nth(bindict(), key(), non_neg_integer()) -> value() | not_found.
next_nth(B, K, Steps) ->
    at(B, index(B, inc(K)) + Steps - 1).



-spec first(bindict()) -> {key(), value()} | not_found.
%% @doc: Returns the first key-value pair or 'not_found' if the dict is empty
first(B) ->
    at(B, 0).

-spec last(bindict()) -> {key(), value()} | not_found.
%% @doc: Returns the last key-value pair or 'not_found' if the dict is empty
last(B) ->
    at(B, num_keys(B) - 1).

-spec foldl(bindict(), fun(), any()) -> any().
foldl(B, F, Acc) ->
    case first(B) of
        {Key, Value} ->
            do_foldl(B, F, Key, F(Key, Value, Acc));
        not_found ->
            Acc
    end.

do_foldl(B, F, PrevKey, Acc) ->
    case next(B, PrevKey) of
        {Key, Value} ->
            do_foldl(B, F, Key, F(Key, Value, Acc));
        not_found ->
            Acc
    end.

%% @doc: Compacts the internal binary used for storage, by creating a
%% new copy where all the data is aligned in memory. Writes will cause
%% fragmentation.
compact(B) ->
    B#bindict{b = binary:copy(B#bindict.b)}.

%% @doc: Returns how many bytes would be used by the structure if it
%% was storing NumKeys.
expected_size(B, NumKeys) ->
    B#bindict.block_size * NumKeys.

expected_size_mb(B, NumKeys) ->
    expected_size(B, NumKeys) / 1024 / 1024.

-spec num_keys(bindict()) -> integer().
%% @doc: Returns the number of keys in the dictionary
num_keys(B) ->
    byte_size(B#bindict.b) div B#bindict.block_size.

size(#bindict{b = B}) ->
    erlang:byte_size(B).


-spec serialize(bindict()) -> binary().
%% @doc: Returns a binary representation of the dictionary which can
%% be deserialized later to recreate the same structure.
serialize(#bindict{} = B) ->
    term_to_binary(B).

-spec deserialize(binary()) -> bindict().
deserialize(Bin) ->
    case binary_to_term(Bin) of
        #bindict{} = B ->
            B;
        _ ->
            erlang:error(badarg)
    end.

%% @doc: Insert a batch of key-value pairs into the dictionary. A new
%% binary is only created once, making it much cheaper than individual
%% calls to insert/2. The input list must be sorted.
bulk_insert(#bindict{} = B, Orddict) ->
    L = do_bulk_insert(B, B#bindict.b, [], Orddict),
    B#bindict{b = iolist_to_binary(lists:reverse(L))}.

do_bulk_insert(_B, Bin, Acc, []) ->
    [Bin | Acc];
do_bulk_insert(B, Bin, Acc, [{Key, Value} | Rest]) ->
    {Left, Right} = split_at(Bin, B#bindict.key_size, B#bindict.value_size, Key, 0),
    do_bulk_insert(B, Right, [Value, Key, Left | Acc], Rest).

split_at(Bin, KeySize, ValueSize, Key, I) ->
    LeftOffset = I * (KeySize + ValueSize),
    case Bin of
        Bin when byte_size(Bin) < LeftOffset ->
            {Bin, <<>>};

        <<Left:LeftOffset/binary,
          Key:KeySize/binary, _:ValueSize/binary,
          Right/binary>> ->
            {Left, Right};

        <<Left:LeftOffset/binary,
          OtherKey:KeySize/binary, Value:ValueSize/binary,
          Right/binary>> when OtherKey > Key ->
            NewRight = <<OtherKey/binary, Value/binary, Right/binary>>,
            {Left, NewRight};
        _ ->
            split_at(Bin, KeySize, ValueSize, Key, I+1)
    end.

merge(Small, Big) ->
    Small#bindict.block_size =:= Big#bindict.block_size
        orelse erlang:error(badarg),

    L = do_merge(Small#bindict.b, Big#bindict.b, [],
                 Big#bindict.key_size, Big#bindict.value_size),
    Big#bindict{b = iolist_to_binary(L)}.

do_merge(Small, Big, Acc, KeySize, ValueSize) ->
    case Small of
        <<Key:KeySize/binary, Value:ValueSize/binary, RestSmall/binary>> ->
            {LeftBig, RightBig} = split_at(Big, KeySize, ValueSize, Key, 0),
            do_merge(RestSmall, RightBig, [Value, Key, LeftBig | Acc],
                     KeySize, ValueSize);
        <<>> ->
            lists:reverse([Big | Acc])
    end.

%% @doc: Intersect two or more bindicts by key. The resulting bindict
%% contains keys found in all input bindicts.
intersection(Bs) when length(Bs) >= 2 ->
    intersection(Bs, svs);
intersection(_TooFewSets) ->
    erlang:error(badarg).

%% @doc: SvS set intersection algorithm, as described in
%% http://www.cs.toronto.edu/~tl/papers/fiats.pdf
intersection(Bs, svs) ->
    [CandidateSet | Sets] = lists:sort(fun (A, B) -> size(A) =< size(B) end, Bs),
    from_orddict(new(CandidateSet#bindict.key_size,
                     CandidateSet#bindict.value_size),
                 do_svs(Sets, CandidateSet)).


do_svs([], Candidates) ->
    Candidates;
do_svs([Set | Sets], #bindict{} = Candidates) ->
    %% Optimization: we let the candidate set remain a bindict for the
    %% first iteration to avoid creating a large orddict just to throw
    %% most of it away. For the remainding sets, we keep the candidate
    %% set as a list
    {_, NewCandidatesList} =
        foldl(Candidates,
              fun (K, V, {L, Acc}) ->
                      Size = byte_size(Set#bindict.b) div Set#bindict.block_size,
                      Rank = index(Set, L, Size, K),
                      %% TODO: Skip candidates until OtherK?
                      case at(Set, Rank) of
                          {K, _}       -> {Rank, [{K, V} | Acc]};
                          {_OtherK, _} -> {Rank, Acc};
                          not_found    -> {Rank, Acc}
                      end
              end, {0, []}),
    do_svs(Sets, lists:reverse(NewCandidatesList));


do_svs([Set | Sets], Candidates) when is_list(Candidates) ->
    {_, NewCandidates} =
        lists:foldl(fun ({K, V}, {L, Acc}) ->
                            Size = byte_size(Set#bindict.b) div Set#bindict.block_size,
                            Rank = index(Set, L, Size, K),
                            case at(Set, Rank) of
                                {K, _}       -> {Rank, [{K, V} | Acc]};
                                {_OtherK, _} -> {Rank, Acc};
                                not_found    -> {Rank, Acc}
                            end
                    end, {0, []}, Candidates),
    do_svs(Sets, lists:reverse(NewCandidates)).

at(B, I) ->
    Offset = index2offset(B, I),
    KeySize = B#bindict.key_size,
    ValueSize = B#bindict.value_size,
    case B#bindict.b of
        <<_:Offset/binary, Key:KeySize/binary, Value:ValueSize/binary, _/binary>> ->
            {Key, Value};
        _ ->
            not_found
    end.


%% @doc: Populates the dictionary with data from the orddict, taking
%% advantage of the fact that it is already ordered. The given bindict
%% must be empty, but contain size parameters.
from_orddict(#bindict{b = <<>>} = B, Orddict) ->
    KeySize = B#bindict.key_size,
    ValueSize = B#bindict.value_size,
    L = orddict:fold(fun (K, V, Acc)
                           when byte_size(K) =:= B#bindict.key_size andalso
                                byte_size(V) =:= B#bindict.value_size ->
                             [<<K:KeySize/binary, V:ValueSize/binary>> | Acc];
                         (_, _, _) ->
                             erlang:error(badarg)
                     end, [], Orddict),
    B#bindict{b = iolist_to_binary(lists:reverse(L))}.

to_orddict(#bindict{} = B) ->
    lists:reverse(
      foldl(B, fun (Key, Value, Acc) ->
                       [{Key, Value} | Acc]
               end, [])).


%%
%% INTERNAL HELPERS
%%

index2offset(_, 0) -> 0;
index2offset(B, I) -> I * B#bindict.block_size.

%% @doc: Uses binary search to find the index of the given key. If the
%% key does not exist, the index where it should be inserted is
%% returned.
-spec index(bindict(), key()) -> index().
index(<<>>, _) ->
    0;
index(B, K) ->
    N = byte_size(B#bindict.b) div B#bindict.block_size,
    index(B, 0, N, K).

index(_B, Low, High, _K) when High =:= Low ->
    Low;

index(_B, Low, High, _K) when High < Low ->
    -1;

index(B, Low, High, K) ->
    Mid = (Low + High) div 2,
    MidOffset = index2offset(B, Mid),

    KeySize = B#bindict.key_size,
    case byte_size(B#bindict.b) > MidOffset of
        true ->
            <<_:MidOffset/binary, MidKey:KeySize/binary, _/binary>> = B#bindict.b,

            if
                MidKey > K ->
                    index(B, Low, Mid, K);
                MidKey < K ->
                    index(B, Mid + 1, High, K);
                MidKey =:= K ->
                    Mid
            end;
        false ->
            Mid
    end.

inc(B) ->
    IncInt = binary:decode_unsigned(B) + 1,
    SizeBits = erlang:size(B) * 8,
    <<IncInt:SizeBits>>.
%% }}}
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
