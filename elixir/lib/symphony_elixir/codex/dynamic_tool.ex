defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.AzureDevOps.Client, as: AzureDevOpsClient
  alias SymphonyElixir.{Config, Linear.Client}

  @azure_devops_request_tool "azure_devops_request"
  @azure_devops_request_description """
  Execute a raw Azure DevOps REST request against Symphony's configured Azure Boards / Azure Repos endpoint.
  """
  @azure_devops_request_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "enum" => ["GET", "POST", "PUT", "PATCH", "DELETE"],
        "description" => "HTTP method for the Azure DevOps REST request."
      },
      "path" => %{
        "type" => "string",
        "description" => "Relative path starting with `/`, or an absolute URL on the configured Azure DevOps endpoint."
      },
      "query" => %{
        "type" => ["object", "null"],
        "description" => "Optional query params object. `api-version` defaults from Symphony unless provided explicitly.",
        "additionalProperties" => true
      },
      "body" => %{
        "type" => ["object", "array", "string", "number", "boolean", "null"],
        "description" => "Optional JSON body payload for the request."
      }
    }
  }
  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @azure_devops_methods %{
    "GET" => :get,
    "POST" => :post,
    "PUT" => :put,
    "PATCH" => :patch,
    "DELETE" => :delete
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @azure_devops_request_tool ->
        execute_azure_devops_request(arguments, opts)

      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    case Config.tracker_kind() do
      "azure_devops" -> [azure_devops_request_tool_spec()]
      _other -> [linear_graphql_tool_spec()]
    end
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      response_payload(graphql_success?(response), response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_azure_devops_request(arguments, opts) do
    azure_devops_client =
      Keyword.get(opts, :azure_devops_client, &AzureDevOpsClient.raw_request/3)

    with {:ok, method, path, request_opts} <- normalize_azure_devops_request_arguments(arguments),
         {:ok, response} <- azure_devops_client.(method, path, request_opts) do
      response_payload(true, response)
    else
      {:error, reason} ->
        failure_response(azure_devops_tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_azure_devops_request_arguments(arguments) when is_map(arguments) do
    with {:ok, method} <- normalize_azure_devops_method(arguments),
         {:ok, path} <- normalize_azure_devops_path(arguments),
         {:ok, query} <- normalize_azure_devops_query(arguments),
         {:ok, body} <- normalize_azure_devops_body(arguments) do
      request_opts =
        %{}
        |> maybe_put_request_opt(:query, query)
        |> maybe_put_request_opt(:body, body)

      {:ok, method, path, request_opts}
    end
  end

  defp normalize_azure_devops_request_arguments(_arguments),
    do: {:error, :invalid_azure_devops_request_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp response_payload(success, response) do
    %{
      "success" => success,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(response)
        }
      ]
    }
  end

  defp maybe_put_request_opt(request_opts, _key, nil), do: request_opts
  defp maybe_put_request_opt(request_opts, key, value), do: Map.put(request_opts, key, value)

  defp graphql_success?(response) do
    case response do
      %{"errors" => errors} when is_list(errors) and errors != [] -> false
      %{errors: errors} when is_list(errors) and errors != [] -> false
      _ -> true
    end
  end

  defp linear_graphql_tool_spec do
    %{
      "name" => @linear_graphql_tool,
      "description" => @linear_graphql_description,
      "inputSchema" => @linear_graphql_input_schema
    }
  end

  defp azure_devops_request_tool_spec do
    %{
      "name" => @azure_devops_request_tool,
      "description" => @azure_devops_request_description,
      "inputSchema" => @azure_devops_request_input_schema
    }
  end

  defp failure_response(payload) do
    %{
      "success" => false,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(payload)
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:invalid_azure_devops_request_arguments) do
    %{
      "error" => %{
        "message" => "`azure_devops_request` expects an object with `method`, `path`, and optional `query` / `body`."
      }
    }
  end

  defp tool_error_payload(:missing_azure_devops_request_method) do
    %{
      "error" => %{
        "message" => "`azure_devops_request` requires a non-empty `method` string."
      }
    }
  end

  defp tool_error_payload(:invalid_azure_devops_request_method) do
    %{
      "error" => %{
        "message" => "`azure_devops_request.method` must be one of GET, POST, PUT, PATCH, DELETE."
      }
    }
  end

  defp tool_error_payload(:missing_azure_devops_request_path) do
    %{
      "error" => %{
        "message" => "`azure_devops_request` requires a non-empty `path` string."
      }
    }
  end

  defp tool_error_payload(:invalid_azure_devops_request_path) do
    %{
      "error" => %{
        "message" => "`azure_devops_request.path` must be a relative path starting with `/` or an absolute URL on the configured Azure DevOps endpoint, without query string or fragment."
      }
    }
  end

  defp tool_error_payload(:invalid_azure_devops_request_query) do
    %{
      "error" => %{
        "message" => "`azure_devops_request.query` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:invalid_azure_devops_request_body) do
    %{
      "error" => %{
        "message" => "`azure_devops_request.body` must be valid JSON when provided."
      }
    }
  end

  defp tool_error_payload(:missing_azure_devops_endpoint) do
    %{
      "error" => %{
        "message" => "Symphony is missing the Azure DevOps endpoint. Set `tracker.endpoint` in `WORKFLOW.md`."
      }
    }
  end

  defp tool_error_payload({:azure_devops_request_cross_host, configured_endpoint, request_path}) do
    %{
      "error" => %{
        "message" => "`azure_devops_request.path` must stay on the configured Azure DevOps endpoint.",
        "configuredEndpoint" => configured_endpoint,
        "requestPath" => request_path
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(:missing_azure_devops_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Azure DevOps auth. Set `tracker.api_key` in `WORKFLOW.md` or export `AZURE_DEVOPS_TOKEN`."
      }
    }
  end

  defp tool_error_payload({:azure_devops_api_status, status}) do
    %{
      "error" => %{
        "message" => "Azure DevOps request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:azure_devops_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Azure DevOps request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end

  defp azure_devops_tool_error_payload(:missing_azure_devops_request_method),
    do: tool_error_payload(:missing_azure_devops_request_method)

  defp azure_devops_tool_error_payload(:invalid_azure_devops_request_method),
    do: tool_error_payload(:invalid_azure_devops_request_method)

  defp azure_devops_tool_error_payload(:missing_azure_devops_request_path),
    do: tool_error_payload(:missing_azure_devops_request_path)

  defp azure_devops_tool_error_payload(:invalid_azure_devops_request_path),
    do: tool_error_payload(:invalid_azure_devops_request_path)

  defp azure_devops_tool_error_payload(:invalid_azure_devops_request_query),
    do: tool_error_payload(:invalid_azure_devops_request_query)

  defp azure_devops_tool_error_payload(:invalid_azure_devops_request_body),
    do: tool_error_payload(:invalid_azure_devops_request_body)

  defp azure_devops_tool_error_payload(:invalid_azure_devops_request_arguments),
    do: tool_error_payload(:invalid_azure_devops_request_arguments)

  defp azure_devops_tool_error_payload(:missing_azure_devops_endpoint),
    do: tool_error_payload(:missing_azure_devops_endpoint)

  defp azure_devops_tool_error_payload(:missing_azure_devops_api_token),
    do: tool_error_payload(:missing_azure_devops_api_token)

  defp azure_devops_tool_error_payload({:azure_devops_request_cross_host, configured_endpoint, request_path}),
    do: tool_error_payload({:azure_devops_request_cross_host, configured_endpoint, request_path})

  defp azure_devops_tool_error_payload({:azure_devops_api_status, status}),
    do: tool_error_payload({:azure_devops_api_status, status})

  defp azure_devops_tool_error_payload({:azure_devops_api_request, reason}),
    do: tool_error_payload({:azure_devops_api_request, reason})

  defp azure_devops_tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Azure DevOps tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp normalize_azure_devops_method(arguments) do
    arguments
    |> Map.get("method", Map.get(arguments, :method))
    |> normalize_azure_devops_method_value()
  end

  defp normalize_azure_devops_path(arguments) do
    case Map.get(arguments, "path") || Map.get(arguments, :path) do
      path when is_binary(path) ->
        do_normalize_azure_devops_path(String.trim(path))

      _ ->
        {:error, :missing_azure_devops_request_path}
    end
  end

  defp do_normalize_azure_devops_path(""), do: {:error, :missing_azure_devops_request_path}

  defp do_normalize_azure_devops_path(path) do
    with {:ok, endpoint_uri, configured_endpoint} <- configured_azure_devops_endpoint_uri() do
      parsed_path = URI.parse(path)

      cond do
        parsed_path.query not in [nil, ""] or parsed_path.fragment not in [nil, ""] ->
          {:error, :invalid_azure_devops_request_path}

        absolute_azure_devops_path?(path, parsed_path) ->
          normalize_absolute_azure_devops_path(parsed_path, configured_endpoint, endpoint_uri)

        String.starts_with?(path, "/") ->
          {:ok, path}

        true ->
          {:error, :invalid_azure_devops_request_path}
      end
    end
  end

  defp normalize_azure_devops_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      nil -> {:ok, nil}
      query when is_map(query) -> normalize_json_object(query, :invalid_azure_devops_request_query)
      _ -> {:error, :invalid_azure_devops_request_query}
    end
  end

  defp normalize_azure_devops_body(arguments) do
    case Map.get(arguments, "body") || Map.get(arguments, :body) do
      nil -> {:ok, nil}
      body -> normalize_json_value(body, :invalid_azure_devops_request_body)
    end
  end

  defp configured_azure_devops_endpoint_uri do
    case Config.azure_devops_endpoint() do
      endpoint when is_binary(endpoint) ->
        normalized_endpoint = String.trim(endpoint)

        case URI.parse(normalized_endpoint) do
          %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
            {:ok, uri, normalized_endpoint}

          _ ->
            {:error, :missing_azure_devops_endpoint}
        end

      _ ->
        {:error, :missing_azure_devops_endpoint}
    end
  end

  defp absolute_azure_devops_path?(path, %URI{scheme: scheme, host: host}) do
    is_binary(scheme) or is_binary(host) or String.starts_with?(path, "//")
  end

  defp normalize_absolute_azure_devops_path(parsed_path, configured_endpoint, endpoint_uri) do
    with :ok <- ensure_same_azure_devops_origin(parsed_path, configured_endpoint, endpoint_uri),
         :ok <- ensure_absolute_path_on_endpoint(parsed_path, configured_endpoint, endpoint_uri) do
      parsed_path
      |> Map.get(:path, "/")
      |> String.replace_prefix(endpoint_path_prefix(endpoint_uri), "")
      |> normalize_stripped_azure_devops_path()
    end
  end

  defp normalize_azure_devops_method_value(method) when is_binary(method) do
    method
    |> String.trim()
    |> String.upcase()
    |> case do
      "" ->
        {:error, :missing_azure_devops_request_method}

      normalized_method ->
        case Map.fetch(@azure_devops_methods, normalized_method) do
          {:ok, atom_method} -> {:ok, atom_method}
          :error -> {:error, :invalid_azure_devops_request_method}
        end
    end
  end

  defp normalize_azure_devops_method_value(_method), do: {:error, :missing_azure_devops_request_method}

  defp ensure_same_azure_devops_origin(parsed_path, configured_endpoint, endpoint_uri) do
    if same_endpoint_origin?(parsed_path, endpoint_uri) do
      :ok
    else
      {:error, {:azure_devops_request_cross_host, configured_endpoint, URI.to_string(parsed_path)}}
    end
  end

  defp ensure_absolute_path_on_endpoint(parsed_path, configured_endpoint, endpoint_uri) do
    absolute_path = parsed_path.path || "/"

    if String.starts_with?(absolute_path, endpoint_path_prefix(endpoint_uri)) do
      :ok
    else
      {:error, {:azure_devops_request_cross_host, configured_endpoint, URI.to_string(parsed_path)}}
    end
  end

  defp normalize_stripped_azure_devops_path(""), do: {:ok, "/"}
  defp normalize_stripped_azure_devops_path("/" <> _rest = stripped_path), do: {:ok, stripped_path}
  defp normalize_stripped_azure_devops_path(_stripped_path), do: {:error, :invalid_azure_devops_request_path}

  defp same_endpoint_origin?(request_uri, endpoint_uri) do
    normalized_port = fn uri ->
      uri.port ||
        case uri.scheme do
          "https" -> 443
          "http" -> 80
          _ -> nil
        end
    end

    request_uri.scheme == endpoint_uri.scheme and
      request_uri.host == endpoint_uri.host and
      normalized_port.(request_uri) == normalized_port.(endpoint_uri)
  end

  defp endpoint_path_prefix(%URI{path: nil}), do: ""

  defp endpoint_path_prefix(%URI{path: path}) do
    path
    |> String.trim()
    |> String.trim_trailing("/")
  end

  defp normalize_json_object(value, error_reason) when is_map(value) and not is_struct(value) do
    value
    |> Enum.reduce_while({:ok, %{}}, fn {key, nested_value}, {:ok, acc} ->
      with {:ok, normalized_key} <- normalize_json_key(key, error_reason),
           {:ok, normalized_value} <- normalize_json_value(nested_value, error_reason) do
        {:cont, {:ok, Map.put(acc, normalized_key, normalized_value)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_json_object(_value, error_reason), do: {:error, error_reason}

  defp normalize_json_value(value, _error_reason)
       when is_binary(value) or is_boolean(value) or is_number(value) or is_nil(value) do
    {:ok, value}
  end

  defp normalize_json_value(value, error_reason) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn nested_value, {:ok, acc} ->
      case normalize_json_value(nested_value, error_reason) do
        {:ok, normalized_value} -> {:cont, {:ok, [normalized_value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized_values} -> {:ok, Enum.reverse(normalized_values)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_json_value(value, error_reason) when is_struct(value), do: {:error, error_reason}

  defp normalize_json_value(value, error_reason) when is_map(value) do
    normalize_json_object(value, error_reason)
  end

  defp normalize_json_value(_value, error_reason), do: {:error, error_reason}

  defp normalize_json_key(key, _error_reason) when is_binary(key), do: {:ok, key}
  defp normalize_json_key(key, _error_reason) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_json_key(key, _error_reason) when is_integer(key), do: {:ok, Integer.to_string(key)}
  defp normalize_json_key(_key, error_reason), do: {:error, error_reason}
end
