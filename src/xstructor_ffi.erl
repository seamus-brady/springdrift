-module(xstructor_ffi).
-include_lib("xmerl/include/xmerl.hrl").
-export([compile_schema/1, validate_xml/2, extract_elements/1,
         write_schema_file/2, suppress_xmerl_logging/0, restore_xmerl_logging/1]).

%% Write an XSD schema string to a file path. Creates parent dirs as needed.
%% Returns {ok, nil} | {error, Reason}.
write_schema_file(Path, Content) when is_binary(Path), is_binary(Content) ->
    PathStr = binary_to_list(Path),
    filelib:ensure_dir(PathStr),
    case file:write_file(PathStr, Content) of
        ok -> {ok, nil};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("write failed: ~p", [Reason]))}
    end.

%% Compile an XSD schema from a file path.
%% Returns {ok, SchemaState} | {error, Reason}.
compile_schema(FilePath) when is_binary(FilePath) ->
    try
        case xmerl_xsd:process_schema(binary_to_list(FilePath)) of
            {ok, State} -> {ok, State};
            {error, Reason} ->
                {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
        end
    catch
        _:Ex ->
            {error, iolist_to_binary(io_lib:format("~p", [Ex]))}
    end.

%% Validate an XML binary against a compiled schema state.
%% Returns {ok, XmlBinary} | {error, ReasonBinary}.
validate_xml(XmlBin, SchemaState) when is_binary(XmlBin) ->
    PrevLevel = suppress_xmerl_logging(),
    try
        {Doc, _Rest} = xmerl_scan:string(binary_to_list(XmlBin)),
        case xmerl_xsd:validate(Doc, SchemaState) of
            {ValidDoc, _} when is_record(ValidDoc, xmlElement) ->
                {ok, XmlBin};
            {error, Reason} ->
                {error, format_validation_error(Reason)}
        end
    catch
        _Class:Ex ->
            {error, iolist_to_binary(io_lib:format("XML parse/validation error: ~p", [Ex]))}
    after
        restore_xmerl_logging(PrevLevel)
    end.

format_validation_error(Reason) when is_list(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason]));
format_validation_error(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).

%% Extract flat key-value pairs from an XML binary string.
%% Returns a list of {PathBinary, ValueBinary} tuples.
%% Lists use parent.0, parent.1, etc. indexing.
extract_elements(XmlBin) when is_binary(XmlBin) ->
    PrevLevel = suppress_xmerl_logging(),
    try
        {Doc, _Rest} = xmerl_scan:string(binary_to_list(XmlBin)),
        Pairs = walk_element(Doc, <<>>),
        [{ensure_bin(K), ensure_bin(V)} || {K, V} <- Pairs]
    catch
        _:_ -> []
    after
        restore_xmerl_logging(PrevLevel)
    end.

%% Recursive walk of the xmerl element tree.
walk_element(El, Prefix) when is_record(El, xmlElement) ->
    Name = El#xmlElement.name,
    Content = El#xmlElement.content,
    NameBin = atom_to_binary(Name, utf8),
    Path = case Prefix of
        <<>> -> NameBin;
        _ -> <<Prefix/binary, ".", NameBin/binary>>
    end,
    %% Check if children are all text or contain sub-elements
    SubElements = [C || C <- Content, is_record(C, xmlElement)],
    case SubElements of
        [] ->
            %% Leaf node — extract text content
            Text = extract_text(Content),
            [{Path, Text}];
        _ ->
            %% Has child elements — check for repeated element names (lists)
            ChildNames = [C#xmlElement.name || C <- SubElements],
            Counts = count_names(ChildNames),
            walk_children(SubElements, Path, Counts, #{})
    end;
walk_element(_, _Prefix) ->
    [].

%% Walk child elements, tracking indices for repeated names.
walk_children([], _Prefix, _Counts, _Indices) ->
    [];
walk_children([Child | Rest], Prefix, Counts, Indices) ->
    ChildName = Child#xmlElement.name,
    Count = maps:get(ChildName, Counts, 1),
    case Count > 1 of
        true ->
            %% Repeated element — use index
            Idx = maps:get(ChildName, Indices, 0),
            ChildNameBin = atom_to_binary(ChildName, utf8),
            IdxBin = integer_to_binary(Idx),
            IndexedPath = <<Prefix/binary, ".", ChildNameBin/binary, ".", IdxBin/binary>>,
            %% Walk this child's sub-elements with the indexed path
            ChildContent = Child#xmlElement.content,
            ChildSubElements = [C || C <- ChildContent, is_record(C, xmlElement)],
            Pairs = case ChildSubElements of
                [] ->
                    Text = extract_text(ChildContent),
                    [{IndexedPath, Text}];
                _ ->
                    SubCounts = count_names([S#xmlElement.name || S <- ChildSubElements]),
                    walk_children(ChildSubElements, IndexedPath, SubCounts, #{})
            end,
            NewIndices = maps:put(ChildName, Idx + 1, Indices),
            Pairs ++ walk_children(Rest, Prefix, Counts, NewIndices);
        false ->
            %% Unique element — no index
            Pairs = walk_element(Child, Prefix),
            Pairs ++ walk_children(Rest, Prefix, Counts, Indices)
    end.

%% Extract text content from a list of xmerl content nodes.
extract_text(Content) ->
    Texts = [text_value(C) || C <- Content, is_record(C, xmlText)],
    iolist_to_binary(Texts).

text_value(T) when is_record(T, xmlText) ->
    V = T#xmlText.value,
    case is_list(V) of
        true -> unicode:characters_to_binary(V);
        false when is_binary(V) -> V;
        _ -> <<>>
    end;
text_value(_) ->
    <<>>.

%% Count occurrences of each name in a list.
count_names(Names) ->
    lists:foldl(fun(N, Acc) ->
        maps:put(N, maps:get(N, Acc, 0) + 1, Acc)
    end, #{}, Names).

ensure_bin(V) when is_binary(V) -> V;
ensure_bin(V) when is_list(V) -> unicode:characters_to_binary(V);
ensure_bin(V) -> iolist_to_binary(io_lib:format("~p", [V])).

%% Suppress xmerl's noisy error_logger output during tests.
%% Returns the previous log level so it can be restored.
suppress_xmerl_logging() ->
    #{level := PrevLevel} = logger:get_primary_config(),
    logger:set_primary_config(level, none),
    PrevLevel.

%% Restore the log level after suppression.
restore_xmerl_logging(PrevLevel) ->
    logger:set_primary_config(level, PrevLevel),
    nil.
