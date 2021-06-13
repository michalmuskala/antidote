defmodule Jason do
  @moduledoc """
  A blazing fast JSON parser and generator in pure Elixir.
  """

  alias Jason.{Encode, Decoder, DecodeError, EncodeError, Formatter}

  @typedoc "A plain JSON string."
  @type str :: String.t()
  @typedoc "A plain JSON object where keys can only be strings."
  @type object :: %{optional(str) => value}
  @typedoc "A plain JSON array with JSON element values."
  @type array :: [value]
  @typedoc "A plain JSON value. Meaningful for specs where it's certain that nothing else is contained."
  @type value :: nil | str | number | boolean | array | object

  @typedoc "Encoder setting for string escapes."
  @type enc_escape :: :json | :unicode_safe | :html_safe | :javascript_safe
  @typedoc "Encoder setting for maps."
  @type enc_maps :: :naive | :strict
  @typedoc "Available encoder options."
  @type encode_opt ::
          {:escape, enc_escape} | {:maps, enc_maps} | {:pretty, boolean | Formatter.opts()}

  @typedoc "The type of the value returned by the custom decoder function."
  @type dec_map_key :: term
  @typedoc "Decoder setting for map keys."
  @type dec_keys :: :atoms | :atoms! | :strings | :copy | (key :: str -> dec_map_key)
  @typedoc "Decoder setting for strings."
  @type dec_strings :: :reference | :copy
  @typedoc "Available decoder options."
  @type decode_opt :: {:keys, dec_keys} | {:strings, dec_strings}

  @typedoc "A decoded JSON value where map keys can have any type."
  @type decoded :: value | [decoded] | %{optional(dec_map_key) => decoded}
  @typedoc """
  The types that can be encoded. In general it will be a JSON `t:value` but
  it can be any `term` that has the `c:Jason.Encoder` protocol implemented.
  """
  @type encodable :: value | term

  @doc """
  Parses a JSON value from `input` iodata.

  ## Options

    * `:keys` - controls how keys in objects are decoded. Possible values are:

      * `:strings` (default) - decodes keys as binary strings,
      * `:atoms` - keys are converted to atoms using `String.to_atom/1`,
      * `:atoms!` - keys are converted to atoms using `String.to_existing_atom/1`,
      * `fn s -> s end` - additionally a custom decoder function accepting a string and returning a key
        is accepted.

    * `:strings` - controls how strings (including keys) are decoded. Possible values are:

      * `:reference` (default) - when possible tries to create a sub-binary into the original
      * `:copy` - always copies the strings. This option is especially useful when parts of the
        decoded data will be stored for a long time (in ets or some process) to avoid keeping
        the reference to the original data.

  ## Decoding keys to atoms

  The `:atoms` option uses the `String.to_atom/1` call that can create atoms at runtime.
  Since the atoms are not garbage collected, this can pose a DoS attack vector when used
  on user-controlled data.

  ## Examples

      iex> Jason.decode("{}")
      {:ok, %{}}

      iex> Jason.decode("invalid")
      {:error, %Jason.DecodeError{data: "invalid", position: 0, token: nil}}
  """
  @spec decode(iodata, [decode_opt]) :: {:ok, decoded} | {:error, DecodeError.t()}
  def decode(input, opts \\ []) do
    input = IO.iodata_to_binary(input)
    Decoder.parse(input, format_decode_opts(opts))
  end

  @doc """
  Parses a JSON value from `input` iodata.

  Similar to `decode/2` except it will unwrap the error tuple and raise
  in case of errors.

  ## Examples

      iex> Jason.decode!("{}")
      %{}

      iex> Jason.decode!("invalid")
      ** (Jason.DecodeError) unexpected byte at position 0: 0x69 ('i')

  """
  @spec decode!(iodata, [decode_opt]) :: decoded | no_return
  def decode!(input, opts \\ []) do
    case decode(input, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Generates JSON corresponding to `input`.

  The generation is controlled by the `Jason.Encoder` protocol,
  please refer to the module to read more on how to define the protocol
  for custom data types.

  ## Options

    * `:escape` - controls how strings are encoded. Possible values are:

      * `:json` (default) - the regular JSON escaping as defined by RFC 7159.
      * `:javascript_safe` - additionally escapes the LINE SEPARATOR (U+2028)
        and PARAGRAPH SEPARATOR (U+2029) characters to make the produced JSON
        valid JavaScript.
      * `:html_safe` - similar to `:javascript_safe`, but also escapes the `/`
        character to prevent XSS.
      * `:unicode_safe` - escapes all non-ascii characters.

    * `:maps` - controls how maps are encoded. Possible values are:

      * `:strict` - checks the encoded map for duplicate keys and raises
        if they appear. For example `%{:foo => 1, "foo" => 2}` would be
        rejected, since both keys would be encoded to the string `"foo"`.
      * `:naive` (default) - does not perform the check.

    * `:pretty` - controls pretty printing of the output. Possible values are:

      * `true` to pretty print with default configuration
      * a keyword of options as specified by `Jason.Formatter.pretty_print/2`.

  ## Examples

      iex> Jason.encode(%{a: 1})
      {:ok, ~S|{"a":1}|}

      iex> Jason.encode("\\xFF")
      {:error, %Jason.EncodeError{message: "invalid byte 0xFF in <<255>>"}}

  """
  @spec encode(encodable, [encode_opt]) ::
          {:ok, str} | {:error, EncodeError.t() | Exception.t()}
  def encode(input, opts \\ []) do
    case do_encode(input, format_encode_opts(opts)) do
      {:ok, result} -> {:ok, IO.iodata_to_binary(result)}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Generates JSON corresponding to `input`.

  Similar to `encode/1` except it will unwrap the error tuple and raise
  in case of errors.

  ## Examples

      iex> Jason.encode!(%{a: 1})
      ~S|{"a":1}|

      iex> Jason.encode!("\\xFF")
      ** (Jason.EncodeError) invalid byte 0xFF in <<255>>

  """
  @spec encode!(encodable, [encode_opt]) :: str | no_return
  def encode!(input, opts \\ []) do
    case do_encode(input, format_encode_opts(opts)) do
      {:ok, result} -> IO.iodata_to_binary(result)
      {:error, error} -> raise error
    end
  end

  @doc """
  Generates JSON corresponding to `input` and returns iodata.

  This function should be preferred to `encode/2`, if the generated
  JSON will be handed over to one of the IO functions or sent
  over the socket. The Erlang runtime is able to leverage vectorised
  writes and avoid allocating a continuous buffer for the whole
  resulting string, lowering memory use and increasing performance.

  ## Examples

      iex> {:ok, iodata} = Jason.encode_to_iodata(%{a: 1})
      iex> IO.iodata_to_binary(iodata)
      ~S|{"a":1}|

      iex> Jason.encode_to_iodata("\\xFF")
      {:error, %Jason.EncodeError{message: "invalid byte 0xFF in <<255>>"}}

  """
  @spec encode_to_iodata(encodable, [encode_opt]) ::
          {:ok, iodata} | {:error, EncodeError.t() | Exception.t()}
  def encode_to_iodata(input, opts \\ []) do
    do_encode(input, format_encode_opts(opts))
  end

  @doc """
  Generates JSON corresponding to `input` and returns iodata.

  Similar to `encode_to_iodata/1` except it will unwrap the error tuple
  and raise in case of errors.

  ## Examples

      iex> iodata = Jason.encode_to_iodata!(%{a: 1})
      iex> IO.iodata_to_binary(iodata)
      ~S|{"a":1}|

      iex> Jason.encode_to_iodata!("\\xFF")
      ** (Jason.EncodeError) invalid byte 0xFF in <<255>>

  """
  @spec encode_to_iodata!(encodable, [encode_opt]) :: iodata | no_return
  def encode_to_iodata!(input, opts \\ []) do
    case do_encode(input, format_encode_opts(opts)) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp do_encode(input, %{pretty: true} = opts) do
    case Encode.encode(input, opts) do
      {:ok, encoded} -> {:ok, Formatter.pretty_print_to_iodata(encoded)}
      other -> other
    end
  end

  defp do_encode(input, %{pretty: pretty} = opts) when pretty !== false do
    case Encode.encode(input, opts) do
      {:ok, encoded} -> {:ok, Formatter.pretty_print_to_iodata(encoded, pretty)}
      other -> other
    end
  end

  defp do_encode(input, opts) do
    Encode.encode(input, opts)
  end

  @spec format_encode_opts([encode_opt]) :: %{atom => any}
  defp format_encode_opts(opts) do
    Enum.into(opts, %{escape: :json, maps: :naive})
  end

  @spec format_decode_opts([encode_opt]) :: %{atom => any}
  defp format_decode_opts(opts) do
    Enum.into(opts, %{keys: :strings, strings: :reference})
  end
end
