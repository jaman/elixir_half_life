defmodule ElixirHalfLife.Csqc.Sprites do
  @moduledoc """
  Sprites as FTE draws them for FreeHL: each frame a picture whose colours come from the
  sprite's palette by its format (`index_alpha`: each colour's alpha its index;
  `alpha_test`: colour 255 see-through and black; otherwise opaque), the colour then
  multiplied by its alpha, and cut away where its alpha is below 0.666.

  A frame's picture is named `<sprite>_<frame>.tga`, or `<sprite>_<frame>_<picture>.tga`
  for a picture of a group, and polygons may paint with those names.

  A sprite entity stands at its origin (a held one placed from the view) as a quad from
  the frame's left to right and down to up along two axes chosen by the sprite's kind:
  `:parallel` the view's right and up; `:parallel_upright` the view's right and the
  world's up; `:facing_upright` the world's up and the horizontal at right angles to the
  line from the view; `:oriented` the entity's own left and up; `:parallel_oriented` the
  view's right and up turned by the entity's roll. The axes are scaled by its scale, and
  its tint is its colour modulation (white when unset) and alpha.
  """

  alias Cauldron3D.Formats.Spr
  alias Cauldron3D.{Polygon, Texture, Vec}

  @doc "The picture named `name` when it names a sprite's frame, or `nil`."
  @spec picture(String.t()) :: Texture.t() | nil
  def picture(name) do
    case Regex.run(~r/^(.+\.spr)_(\d+)(?:_(\d+))?\.tga$/i, name) do
      [_, model, frame] ->
        frame_picture(model, String.to_integer(frame), nil)

      [_, model, frame, sub] ->
        frame_picture(model, String.to_integer(frame), String.to_integer(sub))

      nil ->
        nil
    end
  end

  @doc "The frames of `sprite` (from model `name`) as pictures, `{:single, picture}` or `{:group, [{picture, until}]}`."
  @spec frames(String.t(), Spr.t()) :: tuple()
  def frames(name, %Spr{} = sprite) do
    key = {__MODULE__, :frames, String.downcase(name)}

    case :persistent_term.get(key, nil) do
      nil ->
        frames =
          sprite.frames |> Tuple.to_list() |> Enum.map(&prepare(sprite, &1)) |> List.to_tuple()

        :persistent_term.put(key, frames)
        frames

      frames ->
        frames
    end
  end

  @doc """
  The sprite entity `thing` (a snapshot from `ElixirHalfLife.Csqc.Render`) as a
  polygon in `view`, drawn with its frame `thing.frame`, or frame 0 when the sprite has no
  such frame. `weapon` is the view's `{origin, {forward, left, up}}` for a held sprite.
  """
  @spec polygon(map(), String.t(), Spr.t(), Cauldron3D.View.t(), tuple()) :: Polygon.t()
  def polygon(thing, name, %Spr{} = sprite, view, weapon) do
    frames = frames(name, sprite)
    index = if thing.frame >= 0 and thing.frame < tuple_size(frames), do: thing.frame, else: 0
    %{texture: texture, origin: {ox, oy}} = choose(elem(frames, index), thing.frame_time)
    origin = sprite_origin(thing, weapon)
    {right, up} = axes(sprite.kind, thing, view, origin)
    scale = if thing.scale == 0, do: 1.0, else: thing.scale
    {right, up} = {Vec.scale(right, scale), Vec.scale(up, scale)}
    {left_x, right_x} = {-ox / 1, texture.width - ox / 1}
    {up_y, down_y} = {oy / 1, oy - texture.height / 1}
    at = fn x, y -> origin |> Vec.madd(up, y) |> Vec.madd(right, x) end
    tint = tint(thing)
    {w, h} = {texture.width / 1, texture.height / 1}

    %Polygon{
      points: [at.(left_x, down_y), at.(left_x, up_y), at.(right_x, up_y), at.(right_x, down_y)],
      uvs: [{0.0, h}, {0.0, 0.0}, {w, 0.0}, {w, h}],
      tints: [tint, tint, tint, tint],
      paint: {:texture, texture, nil},
      alpha_test: 0.666
    }
  end

  defp tint(%{colormod: nil, alpha: alpha}), do: {1.0, 1.0, 1.0, alpha}
  defp tint(%{colormod: {r, g, b}, alpha: alpha}), do: {r, g, b, alpha}

  defp sprite_origin(%{flags: flags, origin: {x, y, z}}, {origin, {forward, left, up}})
       when Bitwise.band(flags, 1) != 0,
       do: origin |> Vec.madd(forward, x) |> Vec.madd(left, y) |> Vec.madd(up, z)

  defp sprite_origin(%{origin: origin}, _weapon), do: origin

  defp axes(:oriented, %{axes: {_forward, left, up}}, _view, _origin), do: {left, up}

  defp axes(:facing_upright, _thing, view, {x, y, _z}) do
    {vx, vy, _} = view.origin
    {Vec.normalize({y - vy, -(x - vx), 0.0}), {0.0, 0.0, 1.0}}
  end

  defp axes(:parallel_upright, _thing, view, _origin), do: {view.right, {0.0, 0.0, 1.0}}

  defp axes(:parallel_oriented, %{axes: {forward, _left, up}}, view, _origin) do
    roll = roll(forward, up)
    cr = :math.cos(roll * :math.pi() / 180)
    sr = :math.sin(roll)

    {Vec.add(Vec.scale(view.right, cr), Vec.scale(view.up, sr)),
     Vec.add(Vec.scale(view.right, -sr), Vec.scale(view.up, cr))}
  end

  defp axes(_kind, _thing, view, _origin), do: {view.right, view.up}

  defp roll({fx, fy, _fz}, _up) when fx == 0 and fy == 0, do: 0.0

  defp roll({fx, fy, fz}, up) do
    yaw = :math.atan2(fy, fx)
    pitch = -:math.atan2(fz, :math.sqrt(fx * fx + fy * fy))
    {cp, sp, cy, sy} = {:math.cos(pitch), :math.sin(pitch), :math.cos(yaw), :math.sin(yaw)}
    roll = -:math.atan2(Vec.dot(up, {-sy, cy, 0.0}), Vec.dot(up, {sp * cy, sp * sy, cp}))
    degrees = roll * 180 / :math.pi()
    if degrees < 0, do: degrees + 360, else: degrees
  end

  defp choose({:single, picture}, _time), do: picture

  defp choose({:group, pictures}, time) do
    {_, full} = List.last(pictures)
    target = if full > 0, do: time - trunc(time / full) * full, else: 0.0

    {picture, _} =
      Enum.find(Enum.drop(pictures, -1), List.last(pictures), fn {_, until} -> until > target end)

    picture
  end

  defp frame_picture(model, frame, sub) do
    with data when is_binary(data) <- ElixirHalfLife.Assets.read(model),
         {:ok, sprite} <- Spr.parse(data),
         frames = frames(model, sprite),
         true <- frame < tuple_size(frames) do
      case {elem(frames, frame), sub} do
        {{:single, %{texture: texture}}, nil} ->
          texture

        {{:group, pictures}, sub} when is_integer(sub) and sub < length(pictures) ->
          pictures |> Enum.at(sub) |> elem(0) |> Map.fetch!(:texture)

        _ ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp prepare(sprite, {:single, picture}), do: {:single, prepared(sprite, picture)}

  defp prepare(sprite, {:group, pictures}),
    do:
      {:group, Enum.map(pictures, fn {picture, until} -> {prepared(sprite, picture), until} end)}

  defp prepared(sprite, %{texture: texture} = picture),
    do: %{picture | texture: rgba(sprite, texture)}

  defp rgba(%Spr{format: format}, %Texture{} = texture) do
    palette = texture.palette || :binary.copy(<<0>>, 768)

    colours =
      for index <- 0..255 do
        <<r, g, b>> = binary_part(palette, index * 3, 3)

        case format do
          :index_alpha -> premultiplied(r, g, b, index)
          :alpha_test when index == 255 -> <<0, 0, 0, 0>>
          _ -> <<r, g, b, 255>>
        end
      end
      |> List.to_tuple()

    pixels = for <<index <- texture.pixels>>, into: <<>>, do: elem(colours, index)
    Texture.rgba(texture.width, texture.height, pixels)
  end

  defp premultiplied(r, g, b, a), do: <<div(r * a, 255), div(g * a, 255), div(b * a, 255), a>>
end
