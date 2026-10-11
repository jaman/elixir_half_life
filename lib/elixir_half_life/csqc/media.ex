defmodule ElixirHalfLife.Csqc.Media do
  @moduledoc """
  FTE's video builtins for the client and menu programs (`PF_cs_media_*`): `gecko_create`
  (487), `gecko_destroy` (488), `gecko_navigate` (489), `gecko_keyevent` (490),
  `gecko_mousemove` (491), `gecko_resize` (492), `gecko_get_texture_extent` (493),
  `gecko_getproperty`, and `cin_open`, `cin_close`, `cin_setstate`, `cin_getstate` and
  `cin_restart` by name.

  `gecko_create(name, uri)` (`uri` defaulting to `http:`) makes a 2D shader `name`
  showing the video at `uri`, kept in the host's `ext.media_shaders`; this port has no
  video decoder, so no video starts and it returns 0, as FTE does when no decoder takes
  the video. With no video behind a shader, navigating, mouse moves and resizes do
  nothing, a key event returns 0, the texture extent is `{0, 0, 0}`, a property is null
  and the state is 0 (invalid, not playing). Destroying removes the shader.
  """

  alias QuakeServer.Args

  @doc "The builtins this module runs."
  @spec builtins() :: [integer() | String.t()]
  def builtins,
    do: [
      487,
      488,
      489,
      490,
      491,
      492,
      493,
      "gecko_getproperty",
      "cin_open",
      "cin_close",
      "cin_setstate",
      "cin_getstate",
      "cin_restart"
    ]

  @doc "Run video builtin `builtin`, one of `builtins/0`."
  @spec call(map(), integer() | String.t(), non_neg_integer()) :: map()
  def call(s, create, argc) when create in [487, "cin_open"] do
    name = Args.str(s, 0)
    uri = Args.str(s, 1, argc, "http:")

    %{s | ext: Map.update(s.ext, :media_shaders, %{name => uri}, &Map.put(&1, name, uri))}
    |> Args.return(0.0)
  end

  def call(s, destroy, _argc) when destroy in [488, "cin_close"] do
    name = Args.str(s, 0)
    %{s | ext: Map.update(s.ext, :media_shaders, %{}, &Map.delete(&1, name))}
  end

  def call(s, 490, _argc), do: Args.return(s, 0.0)
  def call(s, 493, _argc), do: Args.return(s, {0.0, 0.0, 0.0})
  def call(s, "gecko_getproperty", _argc), do: Args.return(s, 0)
  def call(s, "cin_getstate", _argc), do: Args.return(s, 0.0)
  def call(s, _ignored, _argc), do: s
end
