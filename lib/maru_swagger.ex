defmodule MaruSwagger do
  use Maru.Middleware
  alias Maru.Router.Endpoint

  def init(opts) do
    module_func = fn ->
      case Maru.Config.servers do
        [{module, _} | _] -> module
        _                 -> raise "missing module for maru swagger"
      end
    end

    path    = opts |> Keyword.fetch!(:at) |> Maru.Router.Path.split
    module  = opts |> Keyword.get_lazy(:for, module_func)

    prefix_func = fn ->
      if Code.ensure_loaded?(Phoenix) do
        phoenix_module = Module.concat(Mix.Phoenix.base(), "Router")
        phoenix_module.__routes__ |> Enum.filter(fn r ->
          match?(%{kind: :forward, plug: ^module}, r)
        end)
        |> case do
          [%{path: p}] -> p |> String.split("/", trim: true)
          _            -> []
        end
      else [] end
    end
    version = opts |> Keyword.get(:version, nil)
    pretty  = opts |> Keyword.get(:pretty, false)
    prefix  = opts |> Keyword.get_lazy(:prefix, prefix_func)
    {path, module, version, pretty, prefix}
  end

  def call(%Plug.Conn{path_info: path_info}=conn, {path, module, version, pretty, prefix}) do
    case Maru.Router.Path.lstrip(path_info, path) do
      {:ok, []} ->
        resp =
          generate(module, version, prefix)
          |> Poison.encode!(pretty: pretty)
        conn
        |> Plug.Conn.put_resp_header("access-control-allow-origin", "*")
        |> Plug.Conn.send_resp(200, resp)
        |> Plug.Conn.halt
      _ -> conn
    end
  end

  def generate(module, version, prefix) do
    module
    |> Maru.Builder.Routers.generate
    |> Dict.fetch!(version)
    |> Enum.sort(&(&1.path > &2.path))
    |> Enum.map(&extract_endpoint(&1, prefix))
    |> to_swagger(module, version)
  end

  defp extract_endpoint(ep, prefix) do
    params = ep |> extract_params
    method =
      case ep.method do
        {:_, [], nil} -> "MATCH"
        m             -> m
      end
    %{desc: ep.desc, method: method, path: prefix ++ ep.path, params: params, version: ep.version}
  end

  defp extract_params(%Endpoint{method: {:_, [], nil}}=ep) do
    %{ep | method: "MATCH"} |> extract_params
  end

  defp extract_params(%Endpoint{method: "GET"}), do: []
  defp extract_params(%Endpoint{method: "GET", path: path, param_context: params_list}) do
    for param <- params_list do
      %{ name:        param.attr_name,
         description: param.desc || "",
         required:    param.required,
         type:        decode_parser(param.parser),
         in:          param.attr_name in path && "path" || "query",
      }
    end
  end

  defp extract_params(%Endpoint{param_context: []}), do: []
  defp extract_params(%Endpoint{path: path, param_context: params_list}) do
    {file_list, param_list} =
      Enum.split_while(
        params_list,
        fn(param) ->
          decode_parser(param.parser) == "file"
        end
      )

    p = for param <- param_list do
      {param.attr_name, %{type: decode_parser(param.parser)}}
    end |> Enum.into(%{})

    f = for param <- file_list do
      %{ name:        param.attr_name,
         in:          "formData",
         description: "file",
         required:    true,
         type:        "file"
       }
    end

    %{ name: "body",
       in: "body",
       description: "desc",
       required: false,
     }
    |> fn r ->
      if p == %{} do
        r
      else
        r
        |> put_in([:schema], %{})
        |> put_in([:schema, :properties], p)
      end
    end.()
    |> fn r ->
      if f == [] do [r] else f end
    end.()
    |> fn r ->
      if Enum.any? path, &is_atom/1 do
        r ++ path |> Enum.filter(&is_atom/1) |> Enum.map(&(%{name: &1, in: "path", required: true, type: "string"}))
      else r end
    end.()
  end


  defp decode_parser(parser) do
    parser |> to_string |> String.split(".") |> List.last |> String.downcase
  end


  defp to_swagger(list, module, version) do
    paths = list |> List.foldr(%{}, fn (%{desc: desc, method: method, path: url_list, params: params}, result) ->
      url = join_path(url_list)
      if Map.has_key? result, url do
        result
      else
        result |> put_in([url], %{})
      end
      |> put_in([url, String.downcase(method)], %{
        description: desc || "",
        parameters: params,
        responses: %{
          "200" => %{description: "ok"}
        }
      })
    end)

    "Elixir." <> m = module |> to_string
    %{ swagger: "2.0",
       info: %{
         version: version,
         title: "Swagger API for #{m}",
       },
       paths: paths
     }
  end

  defp join_path(path) do
    [ "/" | for i <- path do
      cond do
        is_atom(i) -> "{#{i}}"
        is_binary(i) -> i
        true -> raise "unknow path type"
      end
    end ] |> Path.join
  end
end
