defmodule ElixirHalfLife.Gpu.Looks do
  @moduledoc """
  Materials for the software picture's ways of laying a picture down, its colours times
  `colour` (linear, `ElixirHalfLife.Gpu.Light.linear/1`), unlit unless lit by a lightmap
  or the instance's `shading`:

    * `:none` — opaque, cut away where the picture's alpha is below `:cutoff`
    * `:alpha` — laid over by the picture's alpha times `alpha`
    * `:add` — the colour times `alpha` and the picture's alpha added (`alpha_mode: :add`)
    * `:premultiplied` — a picture whose colours are already multiplied by its alpha,
      uploaded divided by it (`ElixirHalfLife.Gpu.Pictures`), laid over by `alpha` times
      its alpha: its colours times `alpha` added, what is behind kept at one minus that
    * `:multiply` — what is behind multiplied by the colour as far as `alpha` goes
      (`alpha_mode: :multiply`)

  Options: `:cutoff` (default 0.0), `:double_sided` (default false), `:lightmap` and
  `:lightmap_styles` (lit by the lightmap), `:shaded` (default false, lit by its
  instance's `shading`), `:scroll` (`uv_scroll`, default `{0.0, 0.0}`) and `:uv_from`
  (default `:mesh`).

      ElixirHalfLife.Gpu.Looks.material(picture, {1.0, 1.0, 1.0}, 0.5, :alpha)
  """

  alias CauldronGPU.{Handle, Material}

  @type blend :: :none | :alpha | :add | :premultiplied | :multiply

  @modes %{none: :opaque, alpha: :blend, add: :add, premultiplied: :blend, multiply: :multiply}

  @doc "The material laying `picture` down by `blend`."
  @spec material(Handle.t() | nil, {number(), number(), number()}, number(), blend(), keyword()) ::
          Material.t()
  def material(picture, {r, g, b}, alpha, blend, opts \\ []) do
    lightmap = Keyword.get(opts, :lightmap)

    %Material{
      base_texture: picture,
      base_color: {r, g, b, if(blend == :none, do: 1.0, else: alpha)},
      alpha_mode: Map.fetch!(@modes, blend),
      alpha_cutoff: Keyword.get(opts, :cutoff, 0.0),
      double_sided: Keyword.get(opts, :double_sided, false),
      unlit: lightmap == nil and not Keyword.get(opts, :shaded, false),
      lightmap: lightmap,
      lightmap_styles: Keyword.get(opts, :lightmap_styles, 1),
      lightmap_scale: 1.0,
      uv_scroll: Keyword.get(opts, :scroll, {0.0, 0.0}),
      uv_from: Keyword.get(opts, :uv_from, :mesh),
      roughness: 1.0,
      metallic: 0.0
    }
  end
end
