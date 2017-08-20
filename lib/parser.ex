defmodule Antidote.ParseError do
  @type t :: %__MODULE__{position: integer, data: String.t | nil, token: String.t | nil}

  defexception [:position, :token, :data, :extra]

  def message(%{extra: extra}) when is_binary(extra) do
    "unexpected extra input after valid json: #{inspect extra}"
  end
  def message(%{position: position, token: token}) when is_binary(token) do
    "unexpected sequence at position #{position}: #{inspect token}"
  end
  def message(%{position: position, data: :eof}) do
    "unexpected end of input at position #{position}"
  end
  def message(%{position: position, data: data}) do
    byte = :binary.at(data, position)
    str = <<byte>>
    if String.printable?(str) do
      "unexpected byte at position #{position}: " <>
        "#{inspect byte, base: :hex} ('#{str}')"
    else
      "unexpected byte at position #{position}: " <>
        "#{inspect byte, base: :hex}"
    end
  end
end

defmodule Antidote.Parser do
  @moduledoc false

  alias Antidote.ParseError
  require Antidote.Codegen, as: Codegen

  # @compile :native

  # We use integers instead of atoms to take advantage of the jump table
  # optimization
  @terminate 0
  @array     1
  @key       2
  @object    3

  def parse(data, opts) when is_binary(data) do
    key_decode = key_decode_function(opts)
    case do_parse(data, key_decode) do
      {:continuation, cont} ->
        offset = byte_size(data)
        {:continuation, &parse_loop(&1, cont, offset), offset}
      other ->
        other
    end
  end

  def parse(data, opts) when is_list(data) do
    key_decode = key_decode_function(opts)
    parse_loop(data, &do_parse(&1, key_decode), 0)
  end

  defp parse_loop(data, cont, offset) do
    case iodata_part(data) do
      {data, rest} ->
        case cont.(data) do
          {:continuation, cont} ->
            parse_loop(rest, cont, offset + byte_size(data))
          {:error, %{position: position} = error} ->
            {:error, %{error | position: position + offset}}
          other ->
            other
        end
      :done ->
        {:continuation, &parse_loop(&1, cont, offset), offset}
    end
  end

  defp do_parse(data, key_decode) do
    value(data, data, 0, [@terminate], key_decode)
  catch
    {:position, position} when position === byte_size(data) ->
      {:error, %ParseError{position: position, data: :eof}}
    {:position, position} ->
      {:error, %ParseError{position: position, data: data}}
    {:token, token, position} ->
      {:error, %ParseError{token: token, position: position, data: data}}
  end

  defp iodata_part([head | tail]) when is_binary(head) do
    {head, tail}
  end
  defp iodata_part([list | tail]) when is_list(list) do
    case iodata_part(list) do
      {data, rest} ->
        {data, [rest | tail]}
      :done ->
        iodata_part(tail)
    end
  end
  defp iodata_part([int | tail]) when is_integer(int) do
    collect_integers(tail, [int])
  end
  defp iodata_part(binary) when is_binary(binary) do
    {binary, []}
  end
  defp iodata_part([]) do
    :done
  end

  defp collect_integers([int | rest], acc) when is_integer(int) do
    collect_integers(rest, [acc, int])
  end
  defp collect_integers(rest, acc) do
    {IO.iodata_to_binary(acc), rest}
  end

  defp key_decode_function(%{keys: :atoms}), do: &String.to_atom/1
  defp key_decode_function(%{keys: :atoms!}), do: &String.to_existing_atom/1
  defp key_decode_function(%{keys: :strings}), do: &(&1)
  defp key_decode_function(%{keys: fun}) when is_function(fun, 1), do: fun

  ranges = [{?0..?9, :skip}, {?-, :skip}, {?\", :skip}, {'\s\n\t\r', :value},
            {hd('{'), :object}, {hd('['), :array}, {hd(']'), :empty_array},
            {?n, :skip}, {?t, :skip}, {?f, :skip}]

  for {byte, action} <- Codegen.jump_table(ranges, :error), action != :skip do
    defp value(<<unquote(byte), rest::bits>>, original, skip, stack, key_decode) do
      unquote(action)(rest, original, skip + 1, stack, key_decode)
    end
  end
  for byte <- ?1..?9 do
    defp value(<<unquote(byte), rest::bits>>, original, skip, stack, key_decode) do
      number(rest, original, skip, stack, key_decode, 1)
    end
  end
  defp value(<<?-, rest::bits>>, original, skip, stack, key_decode) do
    number_minus(rest, original, skip, stack, key_decode)
  end
  defp value(<<?\", rest::bits>>, original, skip, stack, key_decode) do
    string(rest, original, skip + 1, stack, key_decode, 0)
  end
  defp value(<<?0, rest::bits>>, original, skip, stack, key_decode) do
    number_zero(rest, original, skip, stack, key_decode, 1)
  end
  defp value(<<"true", rest::bits>>, original, skip, stack, key_decode) do
    continue(rest, original, skip + 4, stack, key_decode, true)
  end
  defp value(<<"t", rest::bits>>, original, skip, stack, key_decode) do
    expect(rest, original, skip + 1, stack, key_decode, true, 'rue')
  end
  defp value(<<"false", rest::bits>>, original, skip, stack, key_decode) do
    continue(rest, original, skip + 5, stack, key_decode, false)
  end
  defp value(<<"f", rest::bits>>, original, skip, stack, key_decode) do
    expect(rest, original, skip + 1, stack, key_decode, false, 'alse')
  end
  defp value(<<"null", rest::bits>>, original, skip, stack, key_decode) do
    continue(rest, original, skip + 4, stack, key_decode, nil)
  end
  defp value(<<"n", rest::bits>>, original, skip, stack, key_decode) do
    expect(rest, original, skip + 1, stack, key_decode, nil, 'ull')
  end
  defp value(<<>>, _original, _skip, stack, key_decode) do
    continuation(&value(&1, &1, 0, stack, key_decode))
  end
  defp value(<<_rest::bits>>, original, skip, _stack, _key_decode) do
    error(original, skip)
  end

  defp expect(<<byte, rest::bits>>, original, skip, stack, key_decode, value, [byte | rest_expect]) do
    expect(rest, original, skip + 1, stack, key_decode, value, rest_expect)
  end
  defp expect(<<>>, _original, _skip, stack, key_decode, value, rest_expect) do
    continuation(&expect(&1, &1, 0, stack, key_decode, value, rest_expect))
  end
  defp expect(<<rest::bits>>, original, skip, stack, key_decode, value, rest_expect) do
    case rest_expect do
      [] -> continue(rest, original, skip, stack, key_decode, value)
      [_|_] -> error(original, skip)
    end
  end

  digits = '0123456789'

  defp number_minus(<<?0, rest::bits>>, original, skip, stack, key_decode) do
    number_zero(rest, original, skip, stack, key_decode, 2)
  end
  defp number_minus(<<byte, rest::bits>>, original, skip, stack, key_decode)
       when byte in '123456789' do
    number(rest, original, skip, stack, key_decode, 2)
  end
  defp number_minus(<<>>, _original, _skip, stack, key_decode) do
    continuation(&number_minus(&1, &1, 0, stack, key_decode))
  end
  defp number_minus(<<_rest::bits>>, original, skip, _stack, _key_decode) do
    error(original, skip + 1)
  end

  defp number(<<byte, rest::bits>>, original, skip, stack, key_decode, len)
       when byte in unquote(digits) do
    number(rest, original, skip, stack, key_decode, len + 1)
  end
  defp number(<<?., rest::bits>>, original, skip, stack, key_decode, len) do
    number_frac(rest, original, skip, stack, key_decode, len + 1)
  end
  defp number(<<e, rest::bits>>, original, skip, stack, key_decode, len) when e in 'eE' do
    prefix = binary_part(original, skip, len)
    number_exp_copy(rest, original, skip + len + 1, stack, key_decode, prefix)
  end
  # TODO: continuation?
  defp number(<<rest::bits>>, original, skip, stack, key_decode, len) do
    int = String.to_integer(binary_part(original, skip, len))
    continue(rest, original, skip + len, stack, key_decode, int)
  end

  defp number_frac(<<byte, rest::bits>>, original, skip, stack, key_decode, len)
       when byte in unquote(digits) do
    number_frac_cont(rest, original, skip, stack, key_decode, len + 1)
  end
  # TODO: continuation with len
  #defp number_frac(<<>>, original, skip, stack, key_decode, len) do
  #  continuation(&number_frac(&1, original, skip, stack, key_decode, len))
  #end
  defp number_frac(<<_rest::bits>>, original, skip, _stack, _key_decode, len) do
    error(original, skip + len)
  end

  defp number_frac_cont(<<byte, rest::bits>>, original, skip, stack, key_decode, len)
       when byte in unquote(digits) do
    number_frac_cont(rest, original, skip, stack, key_decode, len + 1)
  end
  defp number_frac_cont(<<e, rest::bits>>, original, skip, stack, key_decode, len)
       when e in 'eE' do
    number_exp(rest, original, skip, stack, key_decode, len + 1)
  end
  # TODO: continuation?
  defp number_frac_cont(<<rest::bits>>, original, skip, stack, key_decode, len) do
    token = binary_part(original, skip, len)
    float = try_parse_float(token, token, skip)
    continue(rest, original, skip + len, stack, key_decode, float)
  end

  defp number_exp(<<byte, rest::bits>>, original, skip, stack, key_decode, len)
       when byte in unquote(digits) do
    number_exp_cont(rest, original, skip, stack, key_decode, len + 1)
  end
  defp number_exp(<<byte, rest::bits>>, original, skip, stack, key_decode, len)
       when byte in '+-' do
    number_exp_sign(rest, original, skip, stack, key_decode, len + 1)
  end
  # TODO: continuation with len
  #defp number_exp(<<>>, original, skip, stack, key_decode, len) do
  #  continuation(&number_exp(&1, original, skip, stack, key_decode, len))
  #end
  defp number_exp(<<_rest::bits>>, original, skip, _stack, _key_decode, len) do
    error(original, skip + len)
  end

  defp number_exp_sign(<<byte, rest::bits>>, original, skip, stack, key_decode, len)
       when byte in unquote(digits) do
    number_exp_cont(rest, original, skip, stack, key_decode, len + 1)
  end
  # TODO: continuation with len
  #defp number_exp_sign(<<>>, original, skip, stack, key_decode, len) do
  #  continuation(&number_exp_sign(&1, original, skip, stack, key_decode, len))
  #end
  defp number_exp_sign(<<_rest::bits>>, original, skip, _stack, _key_decode, len) do
    error(original, skip + len)
  end

  defp number_exp_cont(<<byte, rest::bits>>, original, skip, stack, key_decode, len)
       when byte in unquote(digits) do
    number_exp_cont(rest, original, skip, stack, key_decode, len + 1)
  end
  # TODO: continuation?
  defp number_exp_cont(<<rest::bits>>, original, skip, stack, key_decode, len) do
    token = binary_part(original, skip, len)
    float = try_parse_float(token, token, skip)
    continue(rest, original, skip + len, stack, key_decode, float)
  end

  defp number_exp_copy(<<byte, rest::bits>>, original, skip, stack, key_decode, prefix)
       when byte in unquote(digits) do
    number_exp_cont(rest, original, skip, stack, key_decode, prefix, 1)
  end
  defp number_exp_copy(<<byte, rest::bits>>, original, skip, stack, key_decode, prefix)
       when byte in '+-' do
    number_exp_sign(rest, original, skip, stack, key_decode, prefix, 1)
  end
  defp number_exp_copy(<<>>, _original, _skip, stack, key_decode, prefix) do
    continuation(&number_exp_copy(&1, &1, 0, stack, key_decode, prefix))
  end
  defp number_exp_copy(<<_rest::bits>>, original, skip, _stack, _key_decode, _prefix) do
    error(original, skip)
  end

  defp number_exp_sign(<<byte, rest::bits>>, original, skip, stack, key_decode, prefix, len)
       when byte in unquote(digits) do
    number_exp_cont(rest, original, skip, stack, key_decode, prefix, len + 1)
  end
  # TODO: continuation with len
  defp number_exp_sign(<<_rest::bits>>, original, skip, _stack, _key_decode, _prefix, len) do
    error(original, skip + len)
  end

  defp number_exp_cont(<<byte, rest::bits>>, original, skip, stack, key_decode, prefix, len)
       when byte in unquote(digits) do
    number_exp_cont(rest, original, skip, stack, key_decode, prefix, len + 1)
  end
  # TODO: continuation?
  defp number_exp_cont(<<rest::bits>>, original, skip, stack, key_decode, prefix, len) do
    suffix = binary_part(original, skip, len)
    string = prefix <> ".0e" <> suffix
    prefix_size = byte_size(prefix)
    initial_skip = skip - prefix_size - 1
    final_skip = skip + len
    token = binary_part(original, initial_skip, prefix_size + len + 1)
    float = try_parse_float(string, token, initial_skip)
    continue(rest, original, final_skip, stack, key_decode, float)
  end

  defp number_zero(<<?., rest::bits>>, original, skip, stack, key_decode, len) do
    number_frac(rest, original, skip, stack, key_decode, len + 1)
  end
  defp number_zero(<<e, rest::bits>>, original, skip, stack, key_decode, len) when e in 'eE' do
    number_exp_copy(rest, original, skip + len + 1, stack, key_decode, "0")
  end
  # TODO: continuation?
  defp number_zero(<<rest::bits>>, original, skip, stack, key_decode, len) do
    continue(rest, original, skip + len, stack, key_decode, 0)
  end

  @compile {:inline, array: 5}

  defp array(rest, original, skip, stack, key_decode) do
    value(rest, original, skip, [@array, [] | stack], key_decode)
  end

  defp empty_array(<<rest::bits>>, original, skip, stack, key_decode) do
    case stack do
      [@array, [] | stack] ->
        continue(rest, original, skip, stack, key_decode, [])
      _ ->
        error(original, skip - 1)
    end
  end

  ranges = [{'\s\n\t\r', :array}, {hd(']'), :continue}, {?,, :value}]
  array_jt = Codegen.jump_table(ranges, :error)

  Enum.map(array_jt, fn
    {byte, :array} ->
      defp array(<<unquote(byte), rest::bits>>, original, skip, stack, key_decode, value) do
        array(rest, original, skip + 1, stack, key_decode, value)
      end
    {byte, :continue} ->
      defp array(<<unquote(byte), rest::bits>>, original, skip, stack, key_decode, value) do
        [acc | stack] = stack
        continue(rest, original, skip + 1, stack, key_decode, :lists.reverse(acc, [value]))
      end
    {byte, :value} ->
      defp array(<<unquote(byte), rest::bits>>, original, skip, stack, key_decode, value) do
        [acc | stack] = stack
        value(rest, original, skip + 1, [@array, [value | acc] | stack], key_decode)
      end
    {byte, :error} ->
      defp array(<<unquote(byte), _rest::bits>>, original, skip, _stack, _key_decode, _value) do
        error(original, skip)
      end
  end)
  defp array(<<>>, _original, _skip, stack, key_decode, value) do
    continuation(&array(&1, &1, 0, stack, key_decode, value))
  end
  defp array(<<_rest::bits>>, original, skip, _stack, _key_decode, _value) do
    # TODO: common error? What with the jump table?
    empty_error(original, skip)
  end

  @compile {:inline, object: 5}

  defp object(rest, original, skip, stack, key_decode) do
    key(rest, original, skip, [[] | stack], key_decode)
  end

  ranges = [{'\s\n\t\r', :object}, {hd('}'), :continue}, {?,, :key}]
  object_jt = Codegen.jump_table(ranges, :error)

  Enum.map(object_jt, fn
    {byte, :object} ->
      defp object(<<unquote(byte), rest::bits>>, original, skip, stack, key_decode, value) do
        object(rest, original, skip + 1, stack, key_decode, value)
      end
    {byte, :continue} ->
      defp object(<<unquote(byte), rest::bits>>, original, skip, stack, key_decode, value) do
        skip = skip + 1
        [key, acc | stack] = stack
        final = [{key_decode.(key), value} | acc]
        continue(rest, original, skip, stack, key_decode, :maps.from_list(final))
      end
    {byte, :key} ->
      defp object(<<unquote(byte), rest::bits>>, original, skip, stack, key_decode, value) do
        skip = skip + 1
        [key, acc | stack] = stack
        acc = [{key_decode.(key), value} | acc]
        key(rest, original, skip, [acc | stack], key_decode)
      end
    {byte, :error} ->
      defp object(<<unquote(byte), _rest::bits>>, original, skip, _stack, _key_decode, _value) do
        error(original, skip)
      end
  end)
  defp object(<<>>, _original, _skip, stack, key_decode, value) do
    continuation(&object(&1, &1, 0, stack, key_decode, value))
  end
  defp object(<<_rest::bits>>, original, skip, _stack, _key_decode, _value) do
    empty_error(original, skip)
  end

  ranges = [{'\s\n\t\r', :key}, {hd('}'), :continue}, {?\", :string}]
  key_jt = Codegen.jump_table(ranges, :error)

  Enum.map(key_jt, fn
    {byte, :key} ->
      defp key(<<unquote(byte), rest::bits>>, original, skip, stack, key_decode) do
        key(rest, original, skip + 1, stack, key_decode)
      end
    {byte, :continue} ->
      defp key(<<unquote(byte), rest::bits>>, original, skip, stack, key_decode) do
        case stack do
          [[] | stack] ->
            continue(rest, original, skip + 1, stack, key_decode, %{})
          _ ->
            error(original, skip)
        end
      end
    {byte, :string} ->
      defp key(<<unquote(byte), rest::bits>>, original, skip, stack, key_decode) do
        string(rest, original, skip + 1, [@key | stack], key_decode, 0)
      end
    {byte, :error} ->
      defp key(<<unquote(byte), _rest::bits>>, original, skip, _stack, _key_decode) do
        error(original, skip)
      end
  end)
  defp key(<<>>, _original, _skip, stack, key_decode) do
    continuation(&key(&1, &1, 0, stack, key_decode))
  end
  defp key(<<_rest::bits>>, original, skip, _stack, _key_decode) do
    empty_error(original, skip)
  end

  ranges = [{'\s\n\t\r', :key}, {?:, :value}]
  key_jt = Codegen.jump_table(ranges, :error)

  Enum.map(key_jt, fn
    {byte, :key} ->
      defp key(<<unquote(byte), rest::bits>>, original, skip, stack, key_decode, value) do
        key(rest, original, skip + 1, stack, key_decode, value)
      end
    {byte, :value} ->
      defp key(<<unquote(byte), rest::bits>>, original, skip, stack, key_decode, value) do
        value(rest, original, skip + 1, [@object, value | stack], key_decode)
      end
    {byte, :error} ->
      defp key(<<unquote(byte), _rest::bits>>, original, skip, _stack, _key_decode, _value) do
        error(original, skip)
      end
  end)
  defp key(<<>>, _original, _skip, stack, key_decode, value) do
    continuation(&key(&1, &1, 0, stack, key_decode, value))
  end
  defp key(<<_rest::bits>>, original, skip, _stack, _key_decode, _value) do
    empty_error(original, skip)
  end

  ranges = [{?\", :continue}, {?\\, :escape}, {0x00..0x1F, :error}]
  string_jt = Codegen.jump_table(ranges, :string, 128)

  Enum.map(string_jt, fn
    {byte, :continue} ->
      defp string(<<unquote(byte), rest::bits>>, original, skip, stack, key_decode, len) do
        string = binary_part(original, skip, len)
        continue(rest, original, skip + len + 1, stack, key_decode, string)
      end
    {byte, :escape} ->
      defp string(<<unquote(byte), rest::bits>>, original, skip, stack, key_decode, len) do
        part = binary_part(original, skip, len)
        escape(rest, original, skip + len, stack, key_decode, part)
      end
    {byte, :string} ->
      defp string(<<unquote(byte), rest::bits>>, original, skip, stack, key_decode, len) do
        string(rest, original, skip, stack, key_decode, len + 1)
      end
    {byte, :error} ->
      defp string(<<unquote(byte), _rest::bits>>, original, skip, _stack, _key_decode, len) do
        error(original, skip + len)
      end
  end)
  defp string(<<char::utf8, rest::bits>>, original, skip, stack, key_decode, len)
       when char <= 0x7FF do
    string(rest, original, skip, stack, key_decode, len + 2)
  end
  defp string(<<char::utf8, rest::bits>>, original, skip, stack, key_decode, len)
       when char <= 0xFFFF do
    string(rest, original, skip, stack, key_decode, len + 3)
  end
  defp string(<<_char::utf8, rest::bits>>, original, skip, stack, key_decode, len) do
    string(rest, original, skip, stack, key_decode, len + 4)
  end
  defp string(<<>>, original, skip, stack, key_decode, len) do
    part = binary_part(original, skip, len)
    continuation(&string(&1, &1, 0, stack, key_decode, part, 0))
  end
  defp string(<<0b110::3, _rest::bits>>, original, skip, stack, key_decode, len) do
    acc = binary_part(original, skip, len)
    left_bytes = byte_size(original) - skip
    left = binary_part(original, skip, left_bytes)
    expected = 2 - left_bytes
    continuation = &string(&1, &1, 0, stack, key_decode, acc)
    continuation(&expect_bytes(&1, expected, left, continuation))
  end
  defp string(<<0b1110::4, _rest::bits>>, original, skip, stack, key_decode, len) do
    acc = binary_part(original, skip, len)
    left_bytes = byte_size(original) - skip
    left = binary_part(original, skip, left_bytes)
    expected = 3 - left_bytes
    continuation = &string(&1, &1, 0, stack, key_decode, acc)
    continuation(&expect_bytes(&1, expected, left, continuation))
  end
  defp string(<<0b11110::5, _rest::bits>>, original, skip, stack, key_decode, len) do
    acc = binary_part(original, skip, len)
    left_bytes = byte_size(original) - skip
    left = binary_part(original, skip, left_bytes)
    expected = 4 - left_bytes
    continuation = &string(&1, &1, 0, stack, key_decode, acc)
    continuation(&expect_bytes(&1, expected, left, continuation))
  end
  defp string(<<_rest::bits>>, original, skip, _stack, _key_decode, len) do
    error(original, skip + len)
  end

  Enum.map(string_jt, fn
    {byte, :continue} ->
      defp string(<<unquote(byte), rest::bits>>, original, skip, stack, key_decode, acc, len) do
        last = binary_part(original, skip, len)
        string = IO.iodata_to_binary([acc | last])
        continue(rest, original, skip + len + 1, stack, key_decode, string)
      end
    {byte, :escape} ->
      defp string(<<unquote(byte), rest::bits>>, original, skip, stack, key_decode, acc, len) do
        part = binary_part(original, skip, len)
        escape(rest, original, skip + len, stack, key_decode, [acc | part])
      end
    {byte, :string} ->
      defp string(<<unquote(byte), rest::bits>>, original, skip, stack, key_decode, acc, len) do
        string(rest, original, skip, stack, key_decode, acc, len + 1)
      end
    {byte, :error} ->
      defp string(<<unquote(byte), _rest::bits>>, original, skip, _stack, _key_decode, _acc, _len) do
      error(original, skip)
    end
  end)
  defp string(<<char::utf8, rest::bits>>, original, skip, stack, key_decode, acc, len)
       when char <= 0x7FF do
    string(rest, original, skip, stack, key_decode, acc, len + 2)
  end
  defp string(<<char::utf8, rest::bits>>, original, skip, stack, key_decode, acc, len)
       when char <= 0xFFFF do
    string(rest, original, skip, stack, key_decode, acc, len + 3)
  end
  defp string(<<_char::utf8, rest::bits>>, original, skip, stack, key_decode, acc, len) do
    string(rest, original, skip, stack, key_decode, acc, len + 4)
  end
  defp string(<<>>, original, skip, stack, key_decode, acc, len) do
    acc = [acc | binary_part(original, skip, len)]
    continuation(&string(&1, &1, 0, stack, key_decode, acc, 0))
  end
  defp string(<<0b110::3, _rest::bits>>, original, skip, stack, key_decode, acc, len) do
    acc = [acc | binary_part(original, skip, len)]
    left_bytes = byte_size(original) - skip
    left = binary_part(original, skip, left_bytes)
    expected = 2 - left_bytes
    continuation = &string(&1, &1, 0, stack, key_decode, acc)
    continuation(&expect_bytes(&1, expected, left, continuation))
  end
  defp string(<<0b1110::4, _rest::bits>>, original, skip, stack, key_decode, acc, len) do
    acc = [acc | binary_part(original, skip, len)]
    left_bytes = byte_size(original) - skip
    left = binary_part(original, skip, left_bytes)
    expected = 3 - left_bytes
    continuation = &string(&1, &1, 0, stack, key_decode, acc)
    continuation(&expect_bytes(&1, expected, left, continuation))
  end
  defp string(<<0b11110::5, _rest::bits>>, original, skip, stack, key_decode, acc, len) do
    acc = [acc | binary_part(original, skip, len)]
    left_bytes = byte_size(original) - skip
    left = binary_part(original, skip, left_bytes)
    expected = 4 - left_bytes
    continuation = &string(&1, &1, 0, stack, key_decode, acc)
    continuation(&expect_bytes(&1, expected, left, continuation))
  end
  defp string(<<_rest::bits>>, original, skip, _stack, _key_decode, _acc, len) do
    empty_error(original, skip + len)
  end

  escapes = Enum.zip('btnfr"\\/', '\b\t\n\f\r"\\/')
  escape_jt = Codegen.jump_table([{?u, :escapeu} | escapes], :error)

  Enum.map(escape_jt, fn
    {byte, :escapeu} ->
      defp escape(<<unquote(byte), rest::bits>>, original, skip, stack, key_decode, acc) do
        escapeu(rest, original, skip, stack, key_decode, acc)
      end
    {byte, :error} ->
      defp escape(<<unquote(byte), _rest::bits>>, original, skip, _stack, _key_decode, _acc) do
        error(original, skip + 1)
      end
    {byte, escape} ->
      defp escape(<<unquote(byte), rest::bits>>, original, skip, stack, key_decode, acc) do
        string(rest, original, skip + 2, stack, key_decode, [acc, unquote(escape)], 0)
      end
  end)
  defp escape(<<>>, _original, _skip, stack, key_decode, acc) do
    continuation(&escape(&1, &1, 0, stack, key_decode, acc))
  end
  defp escape(<<_rest::bits>>, original, skip, _stack, _key_decode, _acc) do
    error(original, skip)
  end

  defp escapeu(<<int1::16, int2::16, rest::bits>>, original, skip, stack, key_decode, acc) do
    last = escapeu_last(int2, original, skip)
    Codegen.escapeu_first(int1, last, rest, original, skip, stack, key_decode, acc)
  end
  defp escapeu(<<_bad::binary-size(4), _rest::bits>>, original, skip, _stack, _key_decode, _acc) do
    error(original, skip)
  end
  defp escapeu(<<_rest::bits>>, original, skip, stack, key_decode, acc) do
    left_bytes = byte_size(original) - skip
    left = binary_part(original, skip, left_bytes)
    expected = 4 - left_bytes
    continuation = &escapeu(&1, &1, -6, stack, key_decode, acc)
    continuation(&expect_bytes(&1, expected, left, continuation))
  end

  defp escapeu_last(int, original, skip) do
    Codegen.escapeu_last(int, original, skip)
  end

  defp escape_surrogate(<<?\\, ?u, int1::16, int2::16, rest::bits>>,
                        original, skip, stack, key_decode, acc, hi) do
    last = escapeu_last(int2, original, skip + 6)
    Codegen.escapeu_surrogate(int1, last, rest, original, skip, stack, key_decode, acc, hi)
  end
  defp escape_surrogate(<<_bad::binary-size(6), _rest::bits>>,
                        original, skip, _stack, _key_decode, _acc, _hi) do
    error(original, skip + 6)
  end
  defp escape_surrogate(<<_rest::bits>>, original, skip, stack, key_decode, acc, hi) do
    left_bytes = byte_size(original) - skip
    left = binary_part(original, skip, left_bytes)
    expected = 6 - left_bytes
    continuation = &escape_surrogate(&1, &1, -6, stack, key_decode, acc, hi)
    continuation(&expect_bytes(&1, expected, left, continuation))
  end

  defp expect_bytes(input, expected, left, continuation) do
    case input do
      <<input::binary-size(expected), rest::bits>> ->
        # Don't call with all data to limit copying as much as possible
        input = left <> input
        {:continuation, continuation} = continuation.(input)
        continuation.(rest)
      _ ->
        expected = expected - byte_size(input)
        continuation(&expect_bytes(&1, expected, left <> input, continuation))
    end
  end

  defp try_parse_float(string, token, skip) do
    String.to_float(string)
  rescue
    ArgumentError ->
      token_error(token, skip)
  end

  defp error(<<_rest::bits>>, original, skip, _stack, _key_decode) do
    error(original, skip - 1)
  end

  defp empty_error(_original, skip) do
    throw {:position, skip}
  end

  @compile {:inline, error: 2, token_error: 2, token_error: 3, continuation: 1}
  defp error(_original, skip) do
    throw {:position, skip}
  end

  defp token_error(token, position) do
    throw {:token, token, position}
  end

  defp token_error(token, position, len) do
    token_error(binary_part(token, position, len), position)
  end

  defp continuation(fun) do
    {:continuation, fun}
  end

  @compile {:inline, continue: 6}
  defp continue(rest, original, skip, stack, key_decode, value) do
    case stack do
      [@terminate | stack] ->
        terminate(rest, original, skip, stack, key_decode, value)
      [@array | stack] ->
        array(rest, original, skip, stack, key_decode, value)
      [@key | stack] ->
        key(rest, original, skip, stack, key_decode, value)
      [@object | stack] ->
        object(rest, original, skip, stack, key_decode, value)
    end
  end

  defp terminate(<<byte, rest::bits>>, original, skip, stack, key_decode, value)
       when byte in '\s\n\r\t' do
    terminate(rest, original, skip + 1, stack, key_decode, value)
  end
  defp terminate(<<>>, _original, _skip, _stack, _key_decode, value) do
    {:ok, value}
  end
  defp terminate(<<_rest::bits>>, original, skip, _stack, _key_decode, value) do
    {:ok, value, binary_part(original, skip, byte_size(original) - skip)}
  end
end
