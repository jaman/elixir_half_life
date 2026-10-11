defmodule ElixirHalfLife.FontFile.CffStandard do
  @moduledoc """
  The Compact Font Format's Standard Encoding: the standard string (SID) each character
  code 0 to 255 names, 0 for a code it leaves unnamed.

      ElixirHalfLife.FontFile.CffStandard.encoding_sid(?A)
  """

  @high %{
    161 => 96,
    162 => 97,
    163 => 98,
    164 => 99,
    165 => 100,
    166 => 101,
    167 => 102,
    168 => 103,
    169 => 104,
    170 => 105,
    171 => 106,
    172 => 107,
    173 => 108,
    174 => 109,
    175 => 110,
    177 => 111,
    178 => 112,
    179 => 113,
    180 => 114,
    182 => 115,
    183 => 116,
    184 => 117,
    185 => 118,
    186 => 119,
    187 => 120,
    188 => 121,
    189 => 122,
    191 => 123,
    193 => 124,
    194 => 125,
    195 => 126,
    196 => 127,
    197 => 128,
    198 => 129,
    199 => 130,
    200 => 131,
    202 => 132,
    203 => 133,
    205 => 134,
    206 => 135,
    207 => 136,
    208 => 137,
    225 => 138,
    227 => 139,
    232 => 140,
    233 => 141,
    234 => 142,
    235 => 143,
    241 => 144,
    245 => 145,
    248 => 146,
    249 => 147,
    250 => 148,
    251 => 149
  }

  @doc "The standard string that character code `code` names in the Standard Encoding."
  @spec encoding_sid(integer()) :: non_neg_integer()
  def encoding_sid(code) when code >= 32 and code <= 126, do: code - 31
  def encoding_sid(code), do: Map.get(@high, code, 0)
end
