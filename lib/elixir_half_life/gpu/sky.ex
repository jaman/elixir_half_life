defmodule ElixirHalfLife.Gpu.Sky do
  @moduledoc """
  A level's sky box for `CauldronGPU.Environment`'s `sky_picture`: the six pictures
  `gfx/env/<name><suffix>` (`ElixirHalfLife.Pictures.get/1`), suffixes `ft`, `bk`, `lf`,
  `rt`, `up` and `dn` looking along map +x, -x, +y, -y, +z and -z, laid out as the
  software picture lays them (`Cauldron3D.Paint.Rgba`'s `{:skybox, ...}`). Each face the
  renderer takes is made texel by texel from the picture the software picture shows in
  that texel's direction.

      sky = ElixirHalfLife.Gpu.Sky.upload(target, "desert")
      %CauldronGPU.Environment{sky_picture: ElixirHalfLife.Gpu.Sky.picture(sky)}
  """

  alias Cauldron3D.Texture
  alias CauldronGPU.Texture, as: GpuTexture
  alias ElixirHalfLife.Pictures

  @type t :: %{name: String.t(), faces: %{atom() => CauldronGPU.Handle.t()} | nil}

  @suffixes [front: "ft", back: "bk", left: "lf", right: "rt", up: "up", down: "dn"]
  @faces [pos_x: :front, neg_x: :back, pos_y: :up, neg_y: :down, pos_z: :right, neg_z: :left]

  @doc "Sky `name` uploaded through `target`; its faces are `nil` when any picture is missing."
  @spec upload(CauldronGPU.Target.t(), String.t()) :: t()
  def upload(target, name) do
    pictures =
      for {face, suffix} <- @suffixes,
          picture = Pictures.get("gfx/env/#{name}#{suffix}"),
          into: %{},
          do: {face, picture}

    faces =
      if map_size(pictures) == 6,
        do:
          Map.new(@faces, fn {face, source} ->
            {face, face_texture(target, face, pictures, source)}
          end)

    %{name: name, faces: faces}
  end

  @doc "The environment's `sky_picture` for `sky`."
  @spec picture(t()) :: CauldronGPU.Environment.sky_picture()
  def picture(%{faces: nil}), do: nil
  def picture(%{faces: faces}), do: {:box, faces}

  @doc "Releases the sky's handles."
  @spec release(CauldronGPU.Target.t(), t()) :: :ok
  def release(_target, %{faces: nil}), do: :ok

  def release(target, %{faces: faces}),
    do: Enum.each(Map.values(faces), &CauldronGPU.Target.release(target, &1))

  defp face_texture(target, face, pictures, source) do
    %Texture{width: size} = Map.fetch!(pictures, source)

    pixels =
      for row <- 0..(size - 1), column <- 0..(size - 1), into: <<>> do
        sc = (column + 0.5) / size * 2 - 1
        tc = (row + 0.5) / size * 2 - 1
        texel(pictures, map_direction(renderer_direction(face, sc, tc)))
      end

    CauldronGPU.Target.texture(target, %GpuTexture{
      width: size,
      height: size,
      pixels: pixels,
      filter: :nearest,
      wrap: :clamp,
      mipmaps: false
    })
  end

  defp renderer_direction(:pos_x, sc, tc), do: {1.0, -tc, -sc}
  defp renderer_direction(:neg_x, sc, tc), do: {-1.0, -tc, sc}
  defp renderer_direction(:pos_y, sc, tc), do: {sc, 1.0, tc}
  defp renderer_direction(:neg_y, sc, tc), do: {sc, -1.0, -tc}
  defp renderer_direction(:pos_z, sc, tc), do: {sc, -tc, 1.0}
  defp renderer_direction(:neg_z, sc, tc), do: {-sc, -tc, -1.0}

  defp map_direction({x, y, z}), do: {x, -z, y}

  defp texel(pictures, direction) do
    {face, s, t} = box_face(direction)
    %Texture{width: w, height: h, pixels: pixels} = Map.fetch!(pictures, face)
    column = trunc((s + 1) / 2 * w) |> max(0) |> min(w - 1)
    row = trunc((t + 1) / 2 * h) |> max(0) |> min(h - 1)
    <<r, g, b, _a>> = binary_part(pixels, (row * w + column) * 4, 4)
    <<r, g, b, 255>>
  end

  defp box_face({dx, dy, dz}), do: box_face({dx, dy, dz}, {abs(dx), abs(dy), abs(dz)})

  defp box_face({dx, dy, dz}, {ax, ay, az}) when ax >= ay and ax >= az and dx > 0,
    do: {:front, -dy / ax, -dz / ax}

  defp box_face({_dx, dy, dz}, {ax, ay, az}) when ax >= ay and ax >= az,
    do: {:back, dy / ax, -dz / ax}

  defp box_face({dx, dy, dz}, {_ax, ay, az}) when ay >= az and dy > 0,
    do: {:left, dx / ay, -dz / ay}

  defp box_face({dx, _dy, dz}, {_ax, ay, az}) when ay >= az,
    do: {:right, -dx / ay, -dz / ay}

  defp box_face({dx, dy, dz}, {_ax, _ay, az}) when dz > 0,
    do: {:up, -dy / az, dx / az}

  defp box_face({dx, dy, _dz}, {_ax, _ay, az}),
    do: {:down, -dy / az, -dx / az}
end
