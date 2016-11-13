defmodule Mimic.Server do
  use GenServer
  @moduledoc false

  defmodule State do
    @moduledoc false
    defstruct verify_on_exit: MapSet.new(),
              mode: :private,
              global_pid: nil,
              stubs: %{},
              expectations: %{}
  end

  defmodule Expectation do
    @moduledoc false
    defstruct ~w(func)a
  end

  def allow(module, owner_pid, allowed_pid) do
    GenServer.call(__MODULE__, {:allow, module, owner_pid, allowed_pid})
  end

  def verify(pid) do
    GenServer.call(__MODULE__, {:verify, pid})
  end

  def verify_on_exit(pid) do
    GenServer.call(__MODULE__, {:verify_on_exit, pid})
  end

  def stub(module, fn_name, arity, func) do
    GenServer.call(__MODULE__, {:stub, module, fn_name, func, arity, self()})
  end

  def stub(module) do
    GenServer.call(__MODULE__, {:stub, module, self()})
  end

  def expect(module, fn_name, arity, func) do
    GenServer.call(__MODULE__, {:expect, module, fn_name, func, arity, self()})
  end

  def set_global_mode(owner_pid) do
    GenServer.call(__MODULE__, {:set_global_mode, owner_pid})
  end

  def set_private_mode do
    GenServer.call(__MODULE__, :set_private_mode)
  end

  def exit(pid) do
    GenServer.cast(__MODULE__, {:exit, pid})
  end

  def apply(module, fn_name, args) do
    arity = Enum.count(args)
    original_module = Mimic.Module.original(module)

    if :erlang.function_exported(original_module, fn_name, arity) do
      case allowed_pid(self(), module) do
        {:ok, owner_pid} ->
          do_apply(owner_pid, module, fn_name, arity, args)

        _ ->
          apply_original(module, fn_name, args)
      end
    else
      raise Mimic.Error, module: module, fn_name: fn_name, arity: arity
    end
  end

  defp do_apply(owner_pid, module, fn_name, arity, args) do
    case GenServer.call(__MODULE__, {:apply, owner_pid, module, fn_name, arity}, :infinity) do
      {:ok, func} ->
        Kernel.apply(func, args)

      :original ->
        apply_original(module, fn_name, args)

      :unexpected ->
        mfa = Exception.format_mfa(module, fn_name, args)

        raise Mimic.UnexpectedCallError, "Unexpected call to #{mfa} from #{inspect(self())}"
    end
  end

  defp apply_original(module, fn_name, args),
    do: Kernel.apply(Mimic.Module.original(module), fn_name, args)

  defp allowed_pid(pid, module) do
    case :ets.lookup(__MODULE__, :mode) do
      [{:mode, :private}] ->
        case :ets.lookup(__MODULE__, {pid, module}) do
          [] -> :none
          [{{^pid, ^module}}] -> {:ok, pid}
          [{{^pid, ^module}, owner_pid}] -> {:ok, owner_pid}
        end

      [{:mode, :global, global_pid}] ->
        case :ets.lookup(__MODULE__, {global_pid, module}) do
          [] -> :none
          [{owner_pid}] -> {:ok, owner_pid}
        end
    end
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init([]) do
    :ets.new(__MODULE__, [:named_table, :protected, :set])
    :ets.insert_new(__MODULE__, {:mode, :private})
    {:ok, %State{mode: :private}}
  end

  def handle_cast({:exit, pid}, state) do
    {:noreply, clear_data_from_pid(pid, state)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, clear_data_from_pid(pid, state)}
  end

  def handle_info(msg, state) do
    IO.puts("handle_info with #{inspect(msg)} not handled")
    {:noreply, state}
  end

  defp clear_data_from_pid(pid, state) do
    expectations = Map.delete(state.expectations, pid)
    stubs = Map.delete(state.stubs, pid)

    select = [{{{pid, :_}}, [], [true]}, {{{:_, :_}, pid}, [], [true]}]

    :ets.select_delete(__MODULE__, select)
    %{state | expectations: expectations, stubs: stubs}
  end

  defp find_stub(stubs, module, fn_name, arity, caller) do
    case get_in(stubs, [caller, {module, fn_name, arity}]) do
      func when is_function(func) -> {:ok, func}
      nil -> :unexpected
    end
  end

  def handle_call({:apply, owner_pid, module, fn_name, arity}, _from, state) do
    caller =
      if state.mode == :private do
        owner_pid
      else
        state.global_pid
      end

    case get_in(state.expectations, [Access.key(caller, %{}), {module, fn_name, arity}]) do
      [%Expectation{func: func} | tail] ->
        expectations = put_in(state.expectations, [caller, {module, fn_name, arity}], tail)
        {:reply, {:ok, func}, %{state | expectations: expectations}}

      _ ->
        case find_stub(state.stubs, module, fn_name, arity, caller) do
          :unexpected ->
            {:reply, :original, state}

          {:ok, func} ->
            {:reply, {:ok, func}, state}
        end
    end
  end

  def handle_call({:stub, module, fn_name, func, arity, owner}, _from, state) do
    if valid_mode?(state, owner) do
      monitor_if_not_verify_on_exit(owner, state.verify_on_exit)

      :ets.insert_new(__MODULE__, {{owner, module}})

      {:reply, :ok,
       %{
         state
         | stubs: put_in(state.stubs, [Access.key(owner, %{}), {module, fn_name, arity}], func)
       }}
    else
      {:reply, {:error, :not_global_owner}, state}
    end
  end

  def handle_call({:stub, module, owner}, _from, state) do
    if valid_mode?(state, owner) do
      monitor_if_not_verify_on_exit(owner, state.verify_on_exit)

      :ets.insert_new(__MODULE__, {{owner, module}})

      original_module = Mimic.Module.original(module)

      internal_functions = [__info__: 1, module_info: 0, module_info: 1]

      stubs =
        original_module.module_info[:exports]
        |> Enum.filter(&(&1 not in internal_functions))
        |> Enum.reduce(state.stubs, fn {fn_name, arity}, stubs ->
          func = stub_function(module, fn_name, arity)
          put_in(stubs, [Access.key(owner, %{}), {module, fn_name, arity}], func)
        end)

      {:reply, :ok, %{state | stubs: stubs}}
    else
      {:reply, {:error, :not_global_owner}, state}
    end
  end

  def handle_call({:expect, module, fn_name, func, arity, owner}, _from, state) do
    if valid_mode?(state, owner) do
      monitor_if_not_verify_on_exit(owner, state.verify_on_exit)

      :ets.insert_new(__MODULE__, {{owner, module}})

      expectation = %Expectation{func: func}

      expectations =
        update_in(
          state.expectations,
          [Access.key(owner, %{}), {module, fn_name, arity}],
          &((&1 || []) ++ [expectation])
        )

      {:reply, :ok, %{state | expectations: expectations}}
    else
      {:reply, {:error, :not_global_owner}, state}
    end
  end

  def handle_call({:set_global_mode, owner_pid}, _from, state) do
    :ets.insert(__MODULE__, {:mode, :global, owner_pid})
    {:reply, :ok, %{state | global_pid: owner_pid, mode: :global}}
  end

  def handle_call(:set_private_mode, _from, state) do
    :ets.insert(__MODULE__, {:mode, :private})
    {:reply, :ok, %{state | global_pid: nil, mode: :private}}
  end

  def handle_call({:allow, module, owner_pid, allowed_pid}, _from, state = %State{mode: :private}) do
    case :ets.lookup(__MODULE__, {owner_pid, module}) do
      [{{^owner_pid, ^module}}] ->
        :ets.insert(__MODULE__, {{allowed_pid, module}, owner_pid})

      [{{^owner_pid, ^module}, actual_owner_pid}] ->
        :ets.insert(__MODULE__, {{allowed_pid, module}, actual_owner_pid})
    end

    {:reply, :ok, state}
  end

  def handle_call(
        {:allow, _module, _owner_pid, _allowed_pid},
        _from,
        state = %State{mode: :global}
      ) do
    {:reply, {:error, :global_mode}, state}
  end

  def handle_call({:verify, pid}, _from, state) do
    expectations = state.expectations[pid] || %{}

    pending =
      for {{module, fn_name, arity}, mfa_expectations} <- expectations,
          _mfa_expectation <- mfa_expectations do
        {module, fn_name, arity}
      end

    {:reply, pending, state}
  end

  def handle_call({:verify_on_exit, pid}, _from, state) do
    {:reply, :ok, %{state | verify_on_exit: MapSet.put(state.verify_on_exit, pid)}}
  end

  defp valid_mode?(state, caller) do
    state.mode == :private or (state.mode == :global and state.global_pid == caller)
  end

  def monitor_if_not_verify_on_exit(pid, verify_on_exit) do
    unless MapSet.member?(verify_on_exit, pid) do
      Process.monitor(pid)
    end
  end

  defp stub_function(module, fn_name, arity) do
    args = 0..arity |> Enum.to_list() |> tl |> Enum.map(fn i -> Macro.var(:"arg_#{i}", nil) end)

    clause =
      quote do
        unquote_splicing(args) ->
          mfa = Exception.format_mfa(unquote(module), unquote(fn_name), unquote(args))

          raise Mimic.UnexpectedCallError,
                "Stub! Unexpected call to #{mfa} from #{inspect(self())}"
      end

    {fun, _} = Code.eval_quoted({:fn, [], clause})
    fun
  end
end