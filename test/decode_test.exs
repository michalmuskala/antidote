defmodule Jason.DecodeTest do
  use ExUnit.Case, async: true

  alias Jason.DecodeError

  test "numbers" do
    assert_fail_with "-", "unexpected end of input at position 1"
    assert_fail_with "--1", "unexpected byte at position 1: 0x2D ('-')"
    assert_fail_with "01", "unexpected byte at position 1: 0x31 ('1')"
    assert_fail_with ".1", "unexpected byte at position 0: 0x2E ('.')"
    assert_fail_with "1.", "unexpected end of input at position 2"
    assert_fail_with "1e", "unexpected end of input at position 2"
    assert_fail_with "1.0e+", "unexpected end of input at position 5"
    assert_fail_with "1e999", "unexpected sequence at position 0: \"1e999\""

    assert parse!("0") == 0
    assert parse!("1") == 1
    assert parse!("-0") == 0
    assert parse!("-1") == -1
    assert parse!("0.1") == 0.1
    assert parse!("-0.1") == -0.1
    assert parse!("0e0") == 0
    assert parse!("0E0") == 0
    assert parse!("1e0") == 1
    assert parse!("1E0") == 1
    assert parse!("1.0e0") == 1.0
    assert parse!("1e+0") == 1
    assert parse!("1.0e+0") == 1.0
    assert parse!("0.1e1") == 0.1e1
    assert parse!("0.1e-1") == 0.1e-1
    assert parse!("99.99e99") == 99.99e99
    assert parse!("-99.99e-99") == -99.99e-99
    assert parse!("123456789.123456789e123") == 123456789.123456789e123
  end
  test "strings" do
    assert_fail_with ~s("), "unexpected end of input at position 1"
    assert_fail_with ~s("\\"), "unexpected end of input at position 3"
    assert_fail_with ~s("\\k"), "unexpected byte at position 2: 0x6B ('k')"
    assert_fail_with <<?\", 128, ?\">>, "unexpected byte at position 1: 0x80"
    assert_fail_with ~s("\\u2603\\"), "unexpected end of input at position 9"
    assert_fail_with ~s("Here's a snowman for you: ☃. Good day!), "unexpected end of input at position 41"
    assert_fail_with ~s("𝄞), "unexpected end of input at position 5"
    assert_fail_with ~s(\u001F), "unexpected byte at position 0: 0x1F"
    assert_fail_with ~s("\\ud8aa\\udcxx"), "unexpected sequence at position 7: \"\\\\udcxx\""
    assert_fail_with ~s("\\ud8aa\\uda00"), "unexpected sequence at position 1: \"\\\\ud8aa\\\\uda00\""
    assert_fail_with ~s("\\uxxxx"), "unexpected sequence at position 1: \"\\\\uxxxx\""

    assert parse!(~s("\\"\\\\\\/\\b\\f\\n\\r\\t")) == ~s("\\/\b\f\n\r\t)
    assert parse!(~s("\\u2603")) == "☃"
    assert parse!(~s("\\u2028\\u2029")) == "\u2028\u2029"
    assert parse!(~s("\\uD834\\uDD1E")) == "𝄞"
    assert parse!(~s("\\uD834\\uDD1E")) == "𝄞"
    assert parse!(~s("\\uD799\\uD799")) == "힙힙"
    assert parse!(~s("✔︎")) == "✔︎"
  end

  test "objects" do
    assert_fail_with "{", "unexpected end of input at position 1"
    assert_fail_with "{,", "unexpected byte at position 1: 0x2C (',')"
    assert_fail_with ~s({"foo"}), "unexpected byte at position 6: 0x7D ('}')"
    assert_fail_with ~s({"foo": "bar",}), "unexpected byte at position 14: 0x7D ('}')"

    assert parse!("{}") == %{}
    assert parse!(~s({"foo": "bar"})) == %{"foo" => "bar"}
    assert parse!(~s({"foo"  : "bar"})) == %{"foo" => "bar"}

    expected = %{"foo" => "bar", "baz" => "quux"}
    assert parse!(~s({"foo": "bar", "baz": "quux"})) == expected

    expected = %{"foo" => %{"bar" => "baz"}}
    assert parse!(~s({"foo": {"bar": "baz"}})) == expected
  end

  test "objects with atom keys" do
    assert parse!("{}", keys: :atoms) == %{}
    assert parse!("{}", keys: :atoms!) == %{}
    assert parse!(~s({"foo": "bar"}), keys: :atoms) == %{foo: "bar"}
    assert parse!(~s({"foo": "bar"}), keys: :atoms!) == %{foo: "bar"}

    key = Integer.to_string(System.unique_integer)
    assert_raise ArgumentError, fn ->
      parse!(~s({"#{key}": "value"}), keys: :atoms!)
    end
    key = String.to_atom(key)
    assert parse!(~s({"#{key}": "value"}), keys: :atoms) == %{key => "value"}
  end

  test "copying strings on decode" do
    assert parse!("{}", strings: :copy) == %{}
    as = String.duplicate("a", 101)
    bs = String.duplicate("b", 102)

    # Copy decode, copies the key
    assert [{key, value}] = Map.to_list(parse!(~s({"#{as}": "#{bs}"}), strings: :copy))
    assert key == as
    assert value == bs
    assert :binary.referenced_byte_size(key) == byte_size(as)
    assert :binary.referenced_byte_size(value) == byte_size(bs)

    # Regular decode references the original string
    assert [{key, value}] = Map.to_list(parse!(~s({"#{as}": "#{bs}"})))
    assert key == as
    assert value == bs
    assert :binary.referenced_byte_size(key) > byte_size(as) + byte_size(bs)
    assert :binary.referenced_byte_size(value) > byte_size(bs) + byte_size(bs)
  end

  test "custom object key mapping function" do
    assert parse!("{}", keys: &String.downcase/1) == %{}
    assert parse!(~s({"FOO": "bar"}), keys: &String.downcase/1) == %{"foo" => "bar"}
  end

  test "parsing floats to decimals" do
    assert parse!("0.1", floats: :decimals) == Decimal.new("0.1")
    assert parse!("-0.1", floats: :decimals) == Decimal.new("-0.1")
    assert parse!("1.0e0", floats: :decimals) == Decimal.new("1.0e0")
    assert parse!("1.0e+0", floats: :decimals) == Decimal.new("1.0e+0")
    assert parse!("0.1e1", floats: :decimals) == Decimal.new("0.1e1")
    assert parse!("0.1e-1", floats: :decimals) == Decimal.new("0.1e-1")

    assert parse!("123456789.123456789e123", floats: :decimals) ==
             Decimal.new("123456789.123456789e123")
  end

  test "arrays" do
    assert_fail_with "[", "unexpected end of input at position 1"
    assert_fail_with "[,", "unexpected byte at position 1: 0x2C (',')"
    assert_fail_with "[1,]", "unexpected byte at position 3: 0x5D (']')"

    assert parse!("[]") == []
    assert parse!("[1, 2, 3]") == [1, 2, 3]
    assert parse!(~s(["foo", "bar", "baz"])) == ["foo", "bar", "baz"]
    assert parse!(~s([{"foo": "bar"}])) == [%{"foo" => "bar"}]
  end

  test "whitespace" do
    assert_fail_with "", "unexpected end of input at position 0"
    assert_fail_with "    ", "unexpected end of input at position 4"

    assert parse!("  [  ]  ") == []
    assert parse!("  {  }  ") == %{}

    assert parse!("  [  1  ,  2  ,  3  ]  ") == [1, 2, 3]

    expected = %{"foo" => "bar", "baz" => "quux"}
    assert parse!(~s(  {  "foo"  :  "bar"  ,  "baz"  :  "quux"  }  )) == expected
  end

  test "iodata" do
    body = String.split(~s([1,2,3,4]), "")
    expected = [1, 2, 3, 4]
    assert parse!(body) == expected
  end

  defp parse!(json, opts \\ []) do
    Jason.decode!(json, opts)
  end

  defp assert_fail_with(string, error) do
    assert_raise DecodeError, error, fn ->
      parse!(string)
    end
  end
end
