defmodule ElixirHalfLife.Csqc.Described do
  @moduledoc """
  The scene the client program draws, described for a graphics card in place of being
  drawn (`ElixirHalfLife.Csqc.Render.scene/1` with the host's `ext.gpu` set): each
  `renderscene` adds a description to the host's `ext.described` and leaves the view's
  box on the screen see-through (`ElixirHalfLife.Csqc.Screen.clear/2`), so the 2D drawn
  after it lies over the card's picture.

  A description is a map:

    * `:map`, `:sky` — the level's map name and its sky's name
    * `:camera` — `%{origin:, forward:, right:, up:, fov: {x, y}, near:}`, map units and
      degrees, as the software picture's view
    * `:rect`, `:screen` — the view's box `{x, y, w, h}` and the screen's size, in pixels
    * `:world?` — whether the world is drawn
    * `:styles` — the light styles 0 to 63 as `{value, {r, g, b}}`
      (`ElixirHalfLife.Csqc.Lighting.styles/1`)
    * `:brushes` — brush entities, `ElixirHalfLife.Csqc.Render.brush_model/3`'s maps
      each with a `:key`, its `:light` given as `:fixed` (the `{r, g, b}` level every
      face is lit at, or `nil` when lit by its lightmaps) and
      `:scroll` (how many of its own texels a second its textures move along `s`, for a
      glow modulation green of 0.5, or `nil`)
    * `:studios` — studio models: `%{key:, name:, bodies:, skin:, origin:, axes:,
      scale:, bones:, shading:, colour:, alpha:, blend:, depth:}`, `bones` each bone's
      3×4 transform in the model's own space, `colour` its colour modulation, and
      `shading` its light as `{ambient, directional, direction}`: a corner facing along
      normal `n` is lit `ambient + directional * (n · direction)`, the software picture's
      half-Lambert light `ambient + diffuse * (n · direction / 2 + 1 / 2)` times 0.75
      (each channel's hold at 1.5 and steps left out), `direction` in map axes; `chrome`
      its chrome-textured meshes as the software picture draws them, world-space
      `Cauldron3D.Polygon`s; `shell` the shell it is drawn as instead
      (`ElixirHalfLife.Csqc.Render.shell/2`: `%{texture:, colour:, bulge:, scroll:,
      cull_back?:}`) or `nil`
    * `:polygons` — sprites, particles, marks and the program's polygons, world-space
      `Cauldron3D.Polygon`s in the order they are drawn, each with its `depth`
    * `:lights` — the dynamic lights as the software picture lights the world with them,
      `%{origin:, radius:, colour:}` with `fov:` and `axes:` for a spot
  """

  alias Cauldron3D.Formats.Studio
  alias ElixirHalfLife.Csqc.{Lighting, Render, Screen}
  alias QuakeServer.Models

  @doc "The host with gathered scene `gathered` (`ElixirHalfLife.Csqc.Render.gather/1`) described and its box cleared."
  @spec put(map(), map()) :: map()
  def put(s, gathered) do
    description = describe(s, gathered)

    %{s | ext: Map.update(s.ext, :described, [description], &(&1 ++ [description]))}
    |> Screen.clear(gathered.rect)
  end

  @doc "The description of gathered scene `gathered`."
  @spec describe(map(), map()) :: map()
  def describe(s, %{view: view} = gathered) do
    %{
      map: s.map,
      sky: Map.get(s.ext, :sky, "desert"),
      camera: %{
        origin: view.origin,
        forward: view.forward,
        right: view.right,
        up: view.up,
        fov: gathered.fov,
        near: view.near
      },
      rect: gathered.rect,
      screen: Screen.size(s),
      world?: gathered.world?,
      styles: for(style <- 0..63, do: Map.fetch!(gathered.styles, style)),
      brushes: brushes(s, gathered),
      studios: studios(s, gathered),
      polygons: polygons(s, gathered),
      lights: gathered.lights
    }
  end

  defp brushes(s, gathered) do
    gathered.brushes
    |> keyed()
    |> Enum.map(fn {key, thing} ->
      %{light: light} = brush = Render.brush_model(s, thing, gathered.world_light)

      brush
      |> Map.drop([:light])
      |> Map.merge(%{key: key, fixed: fixed(light), scroll: scroll(thing)})
    end)
  end

  defp fixed(%{fixed: sample, store: store, shade: shade}),
    do: shade.(store.({sample, sample, sample}))

  defp fixed(_light), do: nil

  defp scroll(%{glowmod: {_red, 0.5, blue}}), do: blue * 1024 * -0.01
  defp scroll(_thing), do: nil

  defp studios(s, gathered) do
    for {key, thing} <- keyed(gathered.others),
        %{kind: :studio, data: %Studio{} = studio, name: name} <- [Models.get(s, thing.model)] do
      {origin, axes} = Render.placement(thing)

      %{
        key: key,
        name: name,
        bodies: bodies(studio, thing.geomsets),
        skin: thing.skin,
        origin: origin,
        axes: axes,
        scale: thing.scale,
        bones: studio |> Render.studio_bones(thing) |> Tuple.to_list(),
        shading: shading(s, thing, gathered),
        shell: shell(s, thing),
        chrome: chrome(s, studio, thing, gathered),
        colour: thing.colormod || {1.0, 1.0, 1.0},
        alpha: thing.alpha,
        blend: Render.blend(thing),
        depth: Render.depth(thing)
      }
    end
  end

  defp polygons(s, gathered) do
    sprites = Render.sprite_polygons(s, gathered.others, gathered.view, gathered.weapon)

    gathered.polygons
    |> Enum.map(fn {sort, polygon} -> {{sort, 0}, polygon} end)
    |> Kernel.++(sprites)
    |> Render.order()
  end

  defp keyed(things) do
    {keyed, _seen} =
      Enum.map_reduce(things, %{}, fn thing, seen ->
        base = {thing.entity, thing.model}
        nth = Map.get(seen, base, 0)
        {{{thing.entity, thing.model, nth}, thing}, Map.put(seen, base, nth + 1)}
      end)

    keyed
  end

  defp bodies(studio, geomsets) do
    studio.body_parts
    |> Enum.with_index()
    |> Map.new(fn {part, index} -> {index, body(part, Map.get(geomsets, index, 0))} end)
  end

  defp body(%{models: models}, value) when value >= 1,
    do: rem(trunc(value) - 1, max(length(models), 1))

  defp body(_part, _value), do: 0

  defp chrome(s, studio, thing, gathered) do
    flags = Tuple.to_list(studio.texture_flags)

    if Enum.any?(flags, &chrome?/1) do
      Render.studio_polygons(
        s,
        %{studio | textures: chrome_textures(studio.textures, flags)},
        thing,
        gathered.view,
        gathered.styles
      )
    else
      []
    end
  end

  defp chrome_textures(textures, flags) do
    textures
    |> Tuple.to_list()
    |> Enum.zip(flags)
    |> Enum.map(fn {texture, flags} -> if chrome?(flags), do: texture end)
    |> List.to_tuple()
  end

  defp chrome?(flags), do: Bitwise.band(flags, 0x02) != 0

  defp shell(s, thing) do
    case Render.shell(s, thing) do
      nil -> nil
      shell -> Map.take(shell, [:texture, :colour, :bulge, :scroll, :cull_back?])
    end
  end

  defp shading(s, thing, gathered) do
    %{ambient: {ar, ag, ab}, diffuse: {dr, dg, db}, direction: direction} =
      Lighting.model(s, thing, gathered.styles, gathered.view.origin)

    {{0.75 * (ar + dr / 2), 0.75 * (ag + dg / 2), 0.75 * (ab + db / 2)},
     {0.375 * dr, 0.375 * dg, 0.375 * db}, direction}
  end
end
