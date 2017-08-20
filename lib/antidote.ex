defmodule Antidote do
  @type escape :: :json | :unicode | :html | :javascript
  @type validate :: boolean
  @type maps :: :naive | :strict

  @type encode_opt :: {:escape, escape} | {:validate, validate} | {:maps, maps}

  @spec decode(String.t, Keyword.t) :: {:ok, term} | {:error, Antidote.ParseError.t}
  def decode(input, opts \\ []) do
    case Antidote.Parser.parse(input, format_decode_opts(opts)) do
      {:ok, result} -> {:ok, result, ""}
      {:ok, result, rest} -> {:ok, result, rest}
      {:continuation, cont, _pos} -> {:more, cont}
      {:error, error} -> {:error, error}
    end
  end

  @spec decode!(String.t, Keyword.t) :: term | no_return
  def decode!(input, opts \\ []) do
    case Antidote.Parser.parse(input, format_decode_opts(opts)) do
      {:ok, result} ->
        result
      {:ok, _result, rest} ->
        raise %Antidote.ParseError{extra: rest}
      {:error, error} ->
        raise error
      {:continuation, _cont, pos} ->
        raise %Antidote.ParseError{position: pos, data: :eof}
    end
  end

  @spec encode(term, [encode_opt]) :: {:ok, String.t} | {:error, Antidote.EncodeError.t}
  def encode(input, opts \\ []) do
    case Antidote.Encode.encode(input, format_encode_opts(opts)) do
      {:ok, result} -> {:ok, IO.iodata_to_binary(result)}
      {:error, error} -> {:error, error}
    end
  end

  @spec encode!(term, [encode_opt]) :: String.t | no_return
  def encode!(input, opts \\ []) do
    case Antidote.Encode.encode(input, format_encode_opts(opts)) do
      {:ok, result} -> IO.iodata_to_binary(result)
      {:error, error} -> raise error
    end
  end

  @spec encode_to_iodata(term, [encode_opt]) :: {:ok, iodata} | {:error, Antidote.EncodeError.t}
  def encode_to_iodata(input, opts \\ []) do
    Antidote.Encode.encode(input, format_encode_opts(opts))
  end

  @spec encode_to_iodata!(term, [encode_opt]) :: iodata | no_return
  def encode_to_iodata!(input, opts \\ []) do
    case Antidote.Encode.encode(input, format_encode_opts(opts)) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp format_encode_opts(opts) do
    Enum.into(opts, %{escape: :json, validate: true, maps: :naive})
  end

  defp format_decode_opts(opts) do
    Enum.into(opts, %{keys: :strings})
  end
end
