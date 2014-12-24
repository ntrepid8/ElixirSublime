defmodule SublimeCompletion do
  use Application

  ## Application Callbacks

  def start(_type, _args) do
    import Supervisor.Spec

    children = [
      supervisor(Task.Supervisor, [[name: SublimeCompletion.TaskSupervisor]]),
      worker(Task, [SublimeCompletion, :connect, [System.get_env("ELIXIR_SUBLIME_PORT") |> String.to_integer]])
    ]

    opts = [strategy: :one_for_one, name: KVServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  ## Internal

  def connect(port) do
    case :gen_tcp.connect('127.0.0.1', port, [:binary, packet: :line, active: false]) do
      {:ok, socket} -> loop(socket)
      {:error, _reason} -> :init.stop
    end
  end

  defp loop(socket) do
    socket
      |> read_line()
      |> write_line(socket)

    loop(socket)
  end

  defp read_line(socket) do
    {:ok, data} = :gen_tcp.recv(socket, 0)
    case data |> String.strip |> String.split(" ", parts: 2) do
      ["COMPLETE", expr] ->
        expr 
          |> normalize_expr
          |> expand
          |> Poison.encode_to_iodata!
      ["PATH", path] ->
        path 
          |> Code.append_path
        nil
      _ ->
        nil
    end
  end

  defp write_line(nil, _socket), do: :ok
  defp write_line(line, socket) do
    :gen_tcp.send(socket, [line, '\n'])
  end

  defp normalize_expr(expr) do
    if String.contains?(expr, ".") do
      expr = expr |> String.split(".") |> Enum.slice(0..-2) |> Enum.join(".")
      expr = "#{expr}."
    end

    cond do
      Regex.match?(~r/^[a-z]/, expr) -> "Kernel."
      Regex.match?(~r/^[A-Z]/, expr) -> "Elixir.#{expr}"
      true -> expr
    end
  end

  defp make_variants(args) do
    make_variants(args, [[]])
  end
  defp make_variants([], variants), do: variants
  defp make_variants([{:optional, arg}|args], [h|t]) do
    make_variants([{:required, arg}|args], [h,h|t])
  end
  defp make_variants([{:required, arg}|args], [h|t]) do
    make_variants(args, [[arg|h]|t])
  end

  defp make_completions("Elixir." <> name), do: make_completions(name)
  defp make_completions(name) do
    [%{type: :module, name: name, content: "#{name}."}]
  end
  defp make_completions(module_docs, function, arity) do
    args = 
      if module_docs == nil do
        case arity do
          0 -> []
          n -> 1..n |> Enum.map(fn _ -> {:required, :_} end)
        end
      else
        case List.keyfind(module_docs, {function, arity}, 0) do
          {{^function, ^arity}, _, _, args, _} ->
            Enum.map args, fn 
              {:\\, _, [{arg, _, _}|_]} -> {:optional, arg}
              {arg, _, _} -> {:required, arg} 
            end
          _ ->
            []
        end
      end

    args 
      |> make_variants
      |> Enum.map(fn args ->
        content =
          case args do
            [] -> 
              function
            args -> 
              placeholder_args = args 
                |> Enum.reverse
                |> Enum.with_index 
                |> Enum.map(fn {arg, i} -> "${#{i + 1}:#{arg}}" end)
                |> Enum.join(", ")
              "#{function}(#{placeholder_args})"
          end
        %{type: :function, name: function, arity: length(args), content: content}
      end)
      |> Enum.reverse
  end

  defp expand(expr) do
    case expr |> String.to_char_list |> Enum.reverse |> IEx.Autocomplete.expand do
      {:yes, '.', []} ->
        make_completions(expr)
      {:yes, hint, []} when length(hint) > 0 ->
        expand("#{expr}#{hint}")
      {:yes, [], entries} when length(entries) > 0 ->
        module_docs = expr 
          |> String.slice(0..-2) 
          |> String.to_atom 
          |> Code.get_docs(:docs)
        entries 
          |> Enum.map(&to_string/1)
          |> Enum.map(&String.split(&1, "/"))
          |> Enum.flat_map fn
            [module] ->
              make_completions(module)
            [function, arity] -> 
              function = String.to_atom(function)
              arity = String.to_integer(arity)
              make_completions(module_docs, function, arity)
            _ ->
              []
          end
      {:no, [], []} -> 
        []
    end
  end
end