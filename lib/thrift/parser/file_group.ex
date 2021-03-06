defmodule Thrift.Parser.FileGroup do
  @moduledoc false

  alias Thrift.Parser

  alias Thrift.Parser.{
    FileGroup,
    Resolver
  }

  alias Thrift.AST.{
    Constant,
    Exception,
    Field,
    Schema,
    Service,
    Struct,
    TEnum,
    TypeRef,
    Union,
    ValueRef
  }

  @type t :: %FileGroup{
          initial_file: Path.t(),
          schemas: %{Path.t() => %Schema{}},
          namespaces: %{atom => String.t() | nil},
          opts: Parser.opts()
        }

  @enforce_keys [:initial_file, :opts]
  defstruct initial_file: nil,
            schemas: %{},
            resolutions: %{},
            immutable_resolutions: %{},
            namespaces: %{},
            opts: Keyword.new()

  @spec new(Path.t(), Parser.opts()) :: t
  def new(initial_file, opts \\ []) do
    %FileGroup{initial_file: initial_file, opts: opts}
  end

  @spec add(FileGroup.t(), Path.t(), Schema.t()) :: {FileGroup.t(), [Parser.error()]}
  def add(group, path, schema) do
    name = Path.basename(path, ".thrift")
    new_schemas = Map.put(group.schemas, name, schema)
    resolutions = Resolver.add(group.resolutions, name, schema)

    group = %{
      group
      | schemas: new_schemas,
        immutable_resolutions: resolutions,
        resolutions: resolutions
    }

    add_includes(group, path, schema)
  end

  @spec add_includes(FileGroup.t(), Path.t(), Schema.t()) :: {FileGroup.t(), [Parser.error()]}
  defp add_includes(%FileGroup{} = group, path, %Schema{} = schema) do
    # Search for included files in the current directory (relative to the
    # parsed file) as well as any additionally configured include paths.
    include_paths = [Path.dirname(path) | Keyword.get(group.opts, :include_paths, [])]

    Enum.reduce(schema.includes, {group, []}, fn include, {group, errors} ->
      included_path = find_include(include.path, include_paths)

      case Parser.parse_file(included_path) do
        {:ok, schema} ->
          add(group, included_path, schema)

        {:error, error} ->
          {group, [error | errors]}
      end
    end)
  end

  # Attempt to locate `path` in one of `dirs`, returning the path of the
  # first match on success or the original `path` if not match is found.
  defp find_include(path, dirs) do
    dirs
    |> Enum.map(&Path.join(&1, path))
    |> Enum.find(path, &File.exists?/1)
  end

  @spec set_current_module(t, atom) :: t
  def set_current_module(file_group, module) do
    # since in a file, we can refer to things defined in that file in a non-qualified
    # way, we add unqualified names to the resolutions map.

    current_module = Atom.to_string(module)

    resolutions =
      file_group.immutable_resolutions
      |> Enum.flat_map(fn {name, v} = original_mapping ->
        case String.split(Atom.to_string(name), ".") do
          [^current_module, enum_name, value_name] ->
            [{:"#{enum_name}.#{value_name}", v}, original_mapping]

          [^current_module, rest] ->
            [{:"#{rest}", v}, original_mapping]

          _ ->
            [original_mapping]
        end
      end)
      |> Map.new()

    namespaces = build_namespaces(file_group.schemas, file_group.opts[:namespace])

    %FileGroup{file_group | resolutions: resolutions, namespaces: namespaces}
  end

  @spec resolve(t, any) :: any
  for type <- Thrift.primitive_names() do
    def resolve(_, unquote(type)), do: unquote(type)
  end

  def resolve(%FileGroup{} = group, %Field{type: type} = field) do
    %Field{field | type: resolve(group, type)}
  end

  def resolve(%FileGroup{resolutions: resolutions} = group, %TypeRef{referenced_type: type_name}) do
    resolve(group, resolutions[type_name])
  end

  def resolve(%FileGroup{resolutions: resolutions} = group, %ValueRef{
        referenced_value: value_name
      }) do
    resolve(group, resolutions[value_name])
  end

  def resolve(%FileGroup{resolutions: resolutions} = group, path)
      when is_atom(path) and not is_nil(path) do
    # this can resolve local mappings like :Weather or
    # remote mappings like :"common.Weather"
    resolve(group, resolutions[path])
  end

  def resolve(%FileGroup{} = group, {:list, elem_type}) do
    {:list, resolve(group, elem_type)}
  end

  def resolve(%FileGroup{} = group, {:set, elem_type}) do
    {:set, resolve(group, elem_type)}
  end

  def resolve(%FileGroup{} = group, {:map, {key_type, val_type}}) do
    {:map, {resolve(group, key_type), resolve(group, val_type)}}
  end

  def resolve(_, other) do
    other
  end

  @spec dest_module(t, any) :: atom
  def dest_module(file_group, %Struct{name: name}) do
    dest_module(file_group, name)
  end

  def dest_module(file_group, %Union{name: name}) do
    dest_module(file_group, name)
  end

  def dest_module(file_group, %Exception{name: name}) do
    dest_module(file_group, name)
  end

  def dest_module(file_group, %TEnum{name: name}) do
    dest_module(file_group, name)
  end

  def dest_module(file_group, %Service{name: name}) do
    dest_module(file_group, name)
  end

  def dest_module(file_group, Constant) do
    # Default to naming the constants module after the namespaced, camelized
    # basename of its file. For foo.thrift, this would be `foo.Foo`.
    base = Path.basename(file_group.initial_file, ".thrift")
    default = base <> "." <> Macro.camelize(base)

    # However, if we're already going to generate an equivalent module name
    # (ignoring case), use that instead to avoid generating two modules with
    # the same spellings but different cases.
    schema = file_group.schemas[base]

    symbols =
      [
        Enum.map(schema.enums, fn {_, s} -> s.name end),
        Enum.map(schema.exceptions, fn {_, s} -> s.name end),
        Enum.map(schema.structs, fn {_, s} -> s.name end),
        Enum.map(schema.services, fn {_, s} -> s.name end),
        Enum.map(schema.unions, fn {_, s} -> s.name end)
      ]
      |> List.flatten()
      |> Enum.map(&Atom.to_string/1)

    target = String.downcase(default)
    name = Enum.find(symbols, default, fn s -> String.downcase(s) == target end)

    dest_module(file_group, String.to_atom(name))
  end

  def dest_module(file_group, name) do
    name_parts =
      name
      |> Atom.to_string()
      |> String.split(".", parts: 2)

    module_name =
      name_parts
      |> Enum.at(0)
      |> String.to_atom()

    struct_name =
      name_parts
      |> Enum.at(1)
      |> initialcase()

    case file_group.namespaces[module_name] do
      nil ->
        Module.concat([struct_name])

      namespace ->
        namespace_parts =
          namespace
          |> String.split(".")
          |> Enum.map(&Macro.camelize/1)

        Module.concat(namespace_parts ++ [struct_name])
    end
  end

  # Capitalize just the initial character of a string, leaving the rest of the
  # string's characters intact.
  @spec initialcase(String.t()) :: String.t()
  defp initialcase(string) when is_binary(string) do
    {first, rest} = String.next_grapheme(string)
    String.upcase(first) <> rest
  end

  # check if the given model is defined in the root file of the file group
  #   this should eventually be replaced if we find a way to only parse files
  #   once
  @spec own_constant?(t, Constant.t()) :: boolean
  def own_constant?(%FileGroup{} = file_group, %Constant{} = constant) do
    basename = Path.basename(file_group.initial_file, ".thrift")
    schema = file_group.schemas[basename]
    Enum.member?(Map.keys(schema.constants), constant.name)
  end

  defp build_namespaces(schemas, default_namespace) do
    Map.new(schemas, fn
      {module_name, %Schema{namespaces: %{:elixir => namespace}}} ->
        {String.to_atom(module_name), namespace.value}

      {module_name, _} ->
        {String.to_atom(module_name), default_namespace}
    end)
  end
end
