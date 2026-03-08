-module(store_ffi).
-export([new_table/2, insert/3, lookup/2, lookup_bag/2,
         all_values/1, last_n/2, delete_table/1, table_size/1]).

%% Create a new ETS table. Type is one of: set, bag, ordered_set.
%% Returns the table reference (atom name).
new_table(Name, Type) when is_binary(Name) ->
    AtomName = binary_to_atom(Name, utf8),
    TypeAtom = case Type of
        <<"set">> -> set;
        <<"bag">> -> bag;
        <<"ordered_set">> -> ordered_set;
        _ -> set
    end,
    ets:new(AtomName, [TypeAtom, public, named_table, {read_concurrency, true}]),
    AtomName.

%% Insert a {Key, Value} tuple into an ETS table.
insert(Table, Key, Value) when is_atom(Table) ->
    ets:insert(Table, {Key, Value}),
    nil.

%% Lookup a single value by key in a set table.
%% Returns {ok, Value} or {error, nil}.
lookup(Table, Key) when is_atom(Table) ->
    case ets:lookup(Table, Key) of
        [{_, Value}] -> {ok, Value};
        _ -> {error, nil}
    end.

%% Lookup all values for a key in a bag table.
%% Returns a list of values.
lookup_bag(Table, Key) when is_atom(Table) ->
    [V || {_K, V} <- ets:lookup(Table, Key)].

%% Return all values from a table (ignoring keys).
all_values(Table) when is_atom(Table) ->
    [V || {_K, V} <- ets:tab2list(Table)].

%% Return the last N entries from an ordered_set table (by key order).
%% Keys are assumed to be sortable (e.g. timestamps or integers).
last_n(Table, N) when is_atom(Table), is_integer(N), N > 0 ->
    last_n_loop(Table, ets:last(Table), N, []);
last_n(_Table, _N) ->
    [].

last_n_loop(_Table, '$end_of_table', _N, Acc) ->
    Acc;
last_n_loop(_Table, _Key, 0, Acc) ->
    Acc;
last_n_loop(Table, Key, N, Acc) ->
    case ets:lookup(Table, Key) of
        [{_, Value}] ->
            last_n_loop(Table, ets:prev(Table, Key), N - 1, [Value | Acc]);
        _ ->
            last_n_loop(Table, ets:prev(Table, Key), N, Acc)
    end.

%% Delete an ETS table.
delete_table(Table) when is_atom(Table) ->
    catch ets:delete(Table),
    nil.

%% Return the number of entries in a table.
table_size(Table) when is_atom(Table) ->
    ets:info(Table, size).
