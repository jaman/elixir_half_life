defmodule ElixirHalfLife.Csqc.Particles.Script do
  @moduledoc """
  Particle effect descriptions read from FTE's particle configs (`r_part name { ... }`
  blocks) into effect types.

      types = ElixirHalfLife.Csqc.Particles.Script.parse(text, "fx_impact", %{})

  An effect type is a map keyed by `{config, name}`. A block named `+name` adds to the
  effect `name`: when `name` is already read it becomes `+0name`, `+1name` and so on, each
  run after the one before (`:assoc`). `assoc`, `emit`, `cliptype` and model `trail=`
  name effects in the same config. Fields not read keep FTE's defaults; after reading,
  `alpha`'s fade is `-alphadelta / die * alpha` unless `alphadelta` (or a third `alpha`
  value) was given, a `scalefactor` above 1 multiplies `scale` and `scalerand`, and a
  beam with no `beamtexstep` has a texture step of 1/128.
  """

  @pi :math.pi()

  @blend_modes %{
    "adda" => {:adda, 0},
    "add" => {:adda, 0},
    "addc" => {:addc, 0},
    "subtract" => {:subtract, 0},
    "invmoda" => {:invmoda, 0},
    "invmod" => {:invmoda, 0},
    "invmodc" => {:invmodc, 0},
    "blendcolour" => {:blendcolour, 0},
    "blendcolor" => {:blendcolour, 0},
    "blendalpha" => {:blend, 0},
    "premul_subtract" => {:invmodc, 1},
    "premul_add" => {:premul, 2},
    "premul_blend" => {:premul, 1},
    "rtsmoke" => {:rtsmoke, 1}
  }

  @spawn_modes %{
    "circle" => :circle,
    "ball" => :ball,
    "spiral" => :spiral,
    "tracer" => :tracer,
    "telebox" => :telebox,
    "lavasplash" => :lavasplash,
    "uniformcircle" => :unicircle,
    "syncfield" => :field,
    "distball" => :distball
  }

  @particle_types %{
    "beam" => :beam,
    "vbeam" => :beam,
    "spark" => :spark,
    "linespark" => :spark,
    "sparkfan" => :sparkfan,
    "trianglefan" => :sparkfan,
    "texturedspark" => :texturedspark,
    "decal" => :cdecal,
    "cdecal" => :cdecal,
    "udecal" => :udecal
  }

  @doc "The effect types of config `config` in `text`, added to `types`."
  @spec parse(String.t(), String.t(), map()) :: map()
  def parse(text, config, types) do
    text
    |> String.split(["\r\n", "\n"])
    |> Enum.map(&strip_comment/1)
    |> blocks([])
    |> Enum.reduce(types, fn {name, lines}, acc -> add(acc, config, name, lines) end)
  end

  @doc "A type with FTE's defaults, named `name` in config `config`."
  @spec default(String.t(), String.t()) :: map()
  def default(config, name) do
    %{
      config: config,
      name: name,
      loaded: false,
      texname: "",
      s1: 0.0,
      t1: 0.0,
      s2: 1.0,
      t2: 1.0,
      randsmax: 1,
      texsstride: 0.0,
      rotationstartmin: -@pi,
      rotationstartrand: @pi - -@pi,
      rotationmin: 0.0,
      rotationrand: 0.0,
      scale: 0.0,
      scalerand: 0.0,
      scalefactor: 0.0,
      invscalefactor: 1.0,
      scaledelta: 0.0,
      stretch: 0.05,
      minstretch: 0.0,
      count: 0.0,
      countrand: 0.0,
      countextra: 0.0,
      countspacing: 0.0,
      alpha: 1.0,
      alpharand: 0.0,
      alphachange: 1.0,
      die: 0.0,
      randdie: 0.0,
      velbias: {0.0, 0.0, 0.0},
      velwrand: {0.0, 0.0, 0.0},
      veladd: 0.0,
      randomveladd: 0.0,
      orgadd: 0.0,
      randomorgadd: 0.0,
      orgbias: {0.0, 0.0, 0.0},
      orgwrand: {0.0, 0.0, 0.0},
      friction: {0.0, 0.0, 0.0},
      gravity: 0.0,
      flurry: 0.0,
      assoc: nil,
      models: [],
      rgb: {0.0, 0.0, 0.0},
      rgbchange: {0.0, 0.0, 0.0},
      rgbchangetime: 0.0,
      rgbrand: {0.0, 0.0, 0.0},
      rgbrandsync: {0.0, 0.0, 0.0},
      blendmode: :blend,
      premul: 0,
      spawnmode: :box,
      spawnparam1: 0.0,
      spawnparam2: 0.0,
      type: :normal,
      spawntime: 0.0,
      spawnchance: 1.0,
      cliptype: nil,
      clipcount: 1.0,
      clipbounce: 0.8,
      emit: nil,
      emittime: 0.0,
      emitrand: 0.0,
      emitstart: 0.0,
      areaspread: 0.0,
      areaspreadvert: 0.0,
      spawnvel: 0.0,
      spawnvelvert: 0.0,
      rampmode: :none,
      ramp: [],
      dl_radius: {0.0, 0.0},
      dl_decay: {0.0, 0.0, 0.0, 0.0},
      dl_rgb: {1.0, 1.0, 1.0},
      dl_time: 0.0,
      flags: MapSet.new()
    }
  end

  defp strip_comment(line) do
    case :binary.match(line, "//") do
      {at, _} -> binary_part(line, 0, at)
      :nomatch -> line
    end
  end

  defp blocks([], acc), do: Enum.reverse(acc)

  defp blocks([line | rest], acc) do
    case tokens(line) do
      ["r_part", name | _] ->
        {lines, rest} = block(rest)
        blocks(rest, [{name, lines} | acc])

      _ ->
        blocks(rest, acc)
    end
  end

  defp block(lines) do
    lines = Enum.drop_while(lines, &(String.trim(&1) == ""))

    case lines do
      [first | rest] ->
        if String.starts_with?(String.trim(first), "{"),
          do: body(rest, []),
          else: {[], lines}

      [] ->
        {[], []}
    end
  end

  defp body([], acc), do: {Enum.reverse(acc), []}

  defp body([line | rest], acc) do
    trimmed = String.trim(line)

    cond do
      String.starts_with?(trimmed, "}") -> {Enum.reverse(acc), rest}
      trimmed == "" -> body(rest, acc)
      true -> body(rest, [tokens(trimmed) | acc])
    end
  end

  @doc "A line's words, a quoted run being one word without its quotes."
  @spec tokens(String.t()) :: [String.t()]
  def tokens(line) do
    ~r/"([^"]*)"|(\S+)/
    |> Regex.scan(line)
    |> Enum.map(fn
      [_, quoted] -> quoted
      [_, "", word] -> word
    end)
  end

  defp add(types, config, "+" <> base, lines) do
    case Map.get(types, {config, base}) do
      %{loaded: true} ->
        {types, previous} = last_in_chain(types, {config, base})
        name = free_plus_name(types, config, base, 0)
        types = Map.update!(types, previous, &%{&1 | assoc: {config, name}})
        store(types, config, name, lines)

      _ ->
        store(types, config, base, lines)
    end
  end

  defp add(types, config, name, lines), do: store(types, config, name, lines)

  defp last_in_chain(types, key) do
    case Map.get(types, key) do
      %{assoc: {_, "+" <> _} = next} -> last_in_chain(types, next)
      _ -> {types, key}
    end
  end

  defp free_plus_name(types, config, base, i) do
    name = "+#{i}#{base}"

    if Map.has_key?(types, {config, name}),
      do: free_plus_name(types, config, base, i + 1),
      else: name
  end

  defp store(types, config, name, lines) do
    start = default(config, name)

    {ptype, marks} =
      Enum.reduce(lines, {start, MapSet.new()}, fn words, {acc, marks} ->
        field(words, acc, marks, config)
      end)

    Map.put(types, {config, name}, finish(ptype, marks))
  end

  defp finish(ptype, marks) do
    ptype = settle_type(ptype, marks)
    ptype = %{ptype | alphachange: settled_alphachange(ptype, marks), loaded: true}
    ptype = %{ptype | flags: motion_flags(ptype)}
    ptype = fold_scalefactor(ptype)
    ptype = %{ptype | invscalefactor: 1 - ptype.scalefactor}
    ptype = if ptype.clipcount < 1, do: %{ptype | clipcount: 1.0}, else: ptype
    ptype = settle_light_time(ptype)

    ptype =
      if ptype.rampmode != :none and ptype.ramp == [], do: %{ptype | rampmode: :none}, else: ptype

    if ptype.type == :beam and not MapSet.member?(marks, :beamlen),
      do: %{ptype | rotationstartmin: 1 / 128},
      else: ptype
  end

  defp settled_alphachange(ptype, marks) do
    cond do
      MapSet.member?(marks, :alphadelta) -> ptype.alphachange
      ptype.die == 0 -> 0.0
      true -> -ptype.alphachange / ptype.die * ptype.alpha
    end
  end

  defp fold_scalefactor(%{scalefactor: factor} = ptype) when factor > 1 do
    %{
      ptype
      | scale: ptype.scale * factor,
        scalerand: ptype.scalerand * factor,
        scalefactor: 1.0
    }
  end

  defp fold_scalefactor(ptype), do: ptype

  defp settle_light_time(%{dl_decay: {_, _, _, decay}, dl_time: time} = ptype)
       when decay != 0 and time == 0,
       do: %{ptype | dl_time: elem(ptype.dl_radius, 0) / decay}

  defp settle_light_time(ptype), do: ptype

  defp settle_type(ptype, marks) do
    cond do
      MapSet.member?(marks, :type) ->
        ptype

      ptype.type == :normal and ptype.texname == "" and ptype.scale != 0 ->
        %{ptype | type: :sparkfan}

      ptype.type == :normal and ptype.texname == "" ->
        %{ptype | type: :spark}

      true ->
        ptype
    end
  end

  defp motion_flags(ptype) do
    moves? =
      ptype.gravity != 0 or ptype.veladd != 0 or ptype.spawnvel != 0 or ptype.spawnvelvert != 0 or
        nonzero?(ptype.velwrand) or nonzero?(ptype.velbias) or ptype.flurry != 0

    spreads? = nonzero?(ptype.velbias) or nonzero?(ptype.velwrand) or nonzero?(ptype.orgwrand)
    rubs? = nonzero?(ptype.friction)

    ptype.flags
    |> put_flag(:velocity, moves?)
    |> put_flag(:worldspacerand, spreads?)
    |> put_flag(:friction, rubs?)
  end

  defp nonzero?({a, b, c}), do: a != 0 or b != 0 or c != 0

  defp put_flag(flags, flag, true), do: MapSet.put(flags, flag)
  defp put_flag(flags, _flag, false), do: flags

  defp num(nil), do: 0.0

  defp num(text) do
    case Float.parse(text) do
      {value, _} -> value
      :error -> 0.0
    end
  end

  defp int(text), do: trunc(num(text))

  defp arg(words, i), do: Enum.at(words, i)
  defp has?(words, count), do: length(words) > count

  defp field(["texture", value | _], p, m, _c), do: {%{p | texname: value}, m}
  defp field(["linear_texture", value | _], p, m, _c), do: {%{p | texname: value}, m}
  defp field(["nearest_texture", value | _], p, m, _c), do: {%{p | texname: value}, m}
  defp field(["nearesttexture", value | _], p, m, _c), do: {%{p | texname: value}, m}

  defp field(["tcoords" | _] = w, p, m, _c) do
    tscale = num(arg(w, 5))
    tscale = if tscale <= 0, do: 1.0, else: tscale
    randsmax = int(arg(w, 6))
    stride = if has?(w, 7), do: num(arg(w, 7)), else: 1 / tscale
    randsmax = if randsmax < 1 or stride == 0, do: 1, else: randsmax

    {%{
       p
       | s1: num(arg(w, 1)) / tscale,
         t1: num(arg(w, 2)) / tscale,
         s2: num(arg(w, 3)) / tscale,
         t2: num(arg(w, 4)) / tscale,
         randsmax: randsmax,
         texsstride: stride
     }, m}
  end

  defp field(["atlas" | _] = w, p, m, _c) do
    dims = max(trunc(num(arg(w, 1))), 1)
    i = int(arg(w, 2))
    last = int(arg(w, 3))
    last = min(last, div(last, dims) * dims + dims - 1) |> max(i)

    {%{
       p
       | s1: 1 / dims * rem(i, dims),
         s2: 1 / dims * (1 + rem(i, dims)),
         t1: 1 / dims * div(i, dims),
         t2: 1 / dims * (1 + div(i, dims)),
         randsmax: last - i + 1,
         texsstride: 1 / dims
     }, m}
  end

  defp field(["rotation" | _] = w, p, m, _c) do
    start = num(arg(w, 1)) * @pi / 180
    speed = num(arg(w, 3)) * @pi / 180

    {%{
       p
       | rotationstartmin: start,
         rotationstartrand: if(has?(w, 2), do: num(arg(w, 2)) * @pi / 180 - start, else: 0.0),
         rotationmin: speed,
         rotationrand: if(has?(w, 4), do: num(arg(w, 4)) * @pi / 180 - speed, else: 0.0)
     }, m}
  end

  defp field(["rotationstart" | _] = w, p, m, _c) do
    start = num(arg(w, 1)) * @pi / 180

    {%{
       p
       | rotationstartmin: start,
         rotationstartrand: if(has?(w, 2), do: num(arg(w, 2)) * @pi / 180 - start, else: 0.0)
     }, m}
  end

  defp field(["rotationspeed" | _] = w, p, m, _c) do
    speed = num(arg(w, 1)) * @pi / 180

    {%{
       p
       | rotationmin: speed,
         rotationrand: if(has?(w, 2), do: num(arg(w, 2)) * @pi / 180 - speed, else: 0.0)
     }, m}
  end

  defp field(["beamtexstep", value | _], p, m, _c),
    do: {%{p | rotationstartmin: 1 / num(value), rotationstartrand: 0.0}, MapSet.put(m, :beamlen)}

  defp field(["beamtexspeed", value | _], p, m, _c), do: {%{p | rotationmin: num(value)}, m}

  defp field(["scale" | _] = w, p, m, _c) do
    scale = num(arg(w, 1))

    {%{
       p
       | scale: scale,
         scalerand: if(has?(w, 2), do: num(arg(w, 2)) - scale, else: p.scalerand)
     }, m}
  end

  defp field(["scalerand", value | _], p, m, _c), do: {%{p | scalerand: num(value)}, m}
  defp field(["scalefactor", value | _], p, m, _c), do: {%{p | scalefactor: num(value)}, m}
  defp field(["scaledelta", value | _], p, m, _c), do: {%{p | scaledelta: num(value)}, m}

  defp field(["stretchfactor" | _] = w, p, m, _c),
    do:
      {%{p | stretch: num(arg(w, 1)), minstretch: if(has?(w, 2), do: num(arg(w, 2)), else: 0.0)},
       m}

  defp field(["step" | _] = w, p, m, _c) do
    value = num(arg(w, 1))

    {%{
       p
       | countspacing: value,
         count: 1 / value,
         countrand: if(has?(w, 2), do: 1 / num(arg(w, 2)), else: p.countrand),
         countextra: if(has?(w, 3), do: num(arg(w, 3)), else: p.countextra)
     }, m}
  end

  defp field(["count" | _] = w, p, m, _c) do
    {%{
       p
       | countspacing: 0.0,
         count: num(arg(w, 1)),
         countrand: if(has?(w, 2), do: num(arg(w, 2)), else: p.countrand),
         countextra: if(has?(w, 3), do: num(arg(w, 3)), else: p.countextra)
     }, m}
  end

  defp field(["alpha" | _] = w, p, m, _c) do
    alpha = num(arg(w, 1))
    p = %{p | alpha: alpha}
    p = if has?(w, 2), do: %{p | alpharand: num(arg(w, 2)) - alpha}, else: p

    if has?(w, 3),
      do: {%{p | alphachange: num(arg(w, 3))}, MapSet.put(m, :alphadelta)},
      else: {p, m}
  end

  defp field(["alpharand", value | _], p, m, _c), do: {%{p | alpharand: num(value)}, m}
  defp field(["alphachange", value | _], p, m, _c), do: {%{p | alphachange: num(value)}, m}

  defp field(["alphadelta", value | _], p, m, _c),
    do: {%{p | alphachange: num(value)}, MapSet.put(m, :alphadelta)}

  defp field(["die" | _] = w, p, m, _c) do
    die = num(arg(w, 1))

    if has?(w, 2) do
      {low, high} = Enum.min_max([die, num(arg(w, 2))])
      {%{p | die: high, randdie: high - low}, m}
    else
      {%{p | die: die}, m}
    end
  end

  defp field(["diesubrand", value | _], p, m, _c), do: {%{p | randdie: num(value)}, m}

  defp field(["randomvel" | _] = w, p, m, _c) do
    spread = num(arg(w, 1))
    {bx, by, _} = {0.0, 0.0, 0.0}

    {wz, bz} =
      cond do
        has?(w, 3) ->
          low = num(arg(w, 2))
          range = (num(arg(w, 3)) - low) / 2
          {range, low + range}

        has?(w, 2) ->
          {num(arg(w, 2)), 0.0}

        true ->
          {spread, 0.0}
      end

    {%{p | velbias: {bx, by, bz}, velwrand: {spread, spread, wz}}, m}
  end

  defp field(["veladd" | _] = w, p, m, _c) do
    value = num(arg(w, 1))
    {%{p | veladd: value, randomveladd: if(has?(w, 2), do: num(arg(w, 2)) - value, else: 0.0)}, m}
  end

  defp field(["orgadd" | _] = w, p, m, _c) do
    value = num(arg(w, 1))
    {%{p | orgadd: value, randomorgadd: if(has?(w, 2), do: num(arg(w, 2)) - value, else: 0.0)}, m}
  end

  defp field(["orgbias" | _] = w, p, m, _c), do: {%{p | orgbias: vec3(w)}, m}
  defp field(["velbias" | _] = w, p, m, _c), do: {%{p | velbias: vec3(w)}, m}
  defp field(["orgwrand" | _] = w, p, m, _c), do: {%{p | orgwrand: vec3(w)}, m}
  defp field(["velwrand" | _] = w, p, m, _c), do: {%{p | velwrand: vec3(w)}, m}

  defp field(["friction" | _] = w, p, m, _c) do
    f = num(arg(w, 1))

    friction =
      cond do
        has?(w, 3) -> {f, num(arg(w, 2)), num(arg(w, 3))}
        has?(w, 2) -> {f, f, num(arg(w, 2))}
        true -> {f, f, f}
      end

    {%{p | friction: friction}, m}
  end

  defp field(["gravity", value | _], p, m, _c), do: {%{p | gravity: num(value)}, m}
  defp field(["flurry", value | _], p, m, _c), do: {%{p | flurry: num(value)}, m}
  defp field(["assoc", value | _], p, m, c), do: {%{p | assoc: key(c, value)}, m}
  defp field(["model" | _] = w, p, m, c), do: {%{p | models: p.models ++ [model(w, c)]}, m}

  defp field(["red", value | _], p, m, _c),
    do: {%{p | rgb: put_elem(p.rgb, 0, num(value) / 255)}, m}

  defp field(["green", value | _], p, m, _c),
    do: {%{p | rgb: put_elem(p.rgb, 1, num(value) / 255)}, m}

  defp field(["blue", value | _], p, m, _c),
    do: {%{p | rgb: put_elem(p.rgb, 2, num(value) / 255)}, m}

  defp field(["rgb" | _] = w, p, m, _c), do: {%{p | rgb: colour(w, 255)}, m}
  defp field(["rgbf" | _] = w, p, m, _c), do: {%{p | rgb: colour(w, 1)}, m}

  defp field(["rgbdelta" | _] = w, p, m, _c), do: {delta(p, colour(w, 255)), m}
  defp field(["rgbdeltaf" | _] = w, p, m, _c), do: {delta(p, colour(w, 1)), m}

  defp field(["reddelta", v | _], p, m, _c),
    do: {delta(p, put_elem(p.rgbchange, 0, num(v) / 255)), m}

  defp field(["greendelta", v | _], p, m, _c),
    do: {delta(p, put_elem(p.rgbchange, 1, num(v) / 255)), m}

  defp field(["bluedelta", v | _], p, m, _c),
    do: {delta(p, put_elem(p.rgbchange, 2, num(v) / 255)), m}

  defp field(["rgbdeltatime", v | _], p, m, _c), do: {%{p | rgbchangetime: num(v)}, m}

  defp field(["rgbrand" | _] = w, p, m, _c), do: {%{p | rgbrand: colour(w, 255)}, m}
  defp field(["rgbrandf" | _] = w, p, m, _c), do: {%{p | rgbrand: colour(w, 1)}, m}

  defp field(["redrand", v | _], p, m, _c),
    do: {%{p | rgbrand: put_elem(p.rgbrand, 0, num(v) / 255)}, m}

  defp field(["greenrand", v | _], p, m, _c),
    do: {%{p | rgbrand: put_elem(p.rgbrand, 1, num(v) / 255)}, m}

  defp field(["bluerand", v | _], p, m, _c),
    do: {%{p | rgbrand: put_elem(p.rgbrand, 2, num(v) / 255)}, m}

  defp field(["rgbrandsync" | _] = w, p, m, _c), do: {%{p | rgbrandsync: colour(w, 1)}, m}

  defp field(["blend", value | _], p, m, _c) do
    {mode, premul} = Map.get(@blend_modes, value, {:blend, 0})
    {%{p | blendmode: mode, premul: premul}, m}
  end

  defp field(["spawnmode", value | rest], p, m, _c) do
    mode = Map.get(@spawn_modes, value, :box)
    p = %{p | spawnmode: mode}
    p = if mode == :field, do: %{p | spawnparam1: 16.0, spawnparam2: 0.0}, else: p
    {spawn_params(p, rest), m}
  end

  defp field(["type", value | _], p, m, _c) do
    type = Map.get(@particle_types, value, :normal)
    {%{p | type: type}, MapSet.put(m, :type)}
  end

  defp field(["spawntime", v | _], p, m, _c), do: {%{p | spawntime: num(v)}, m}
  defp field(["spawnchance", v | _], p, m, _c), do: {%{p | spawnchance: num(v)}, m}
  defp field(["cliptype", v | _], p, m, c), do: {%{p | cliptype: key(c, v)}, m}
  defp field(["clipcount", v | _], p, m, _c), do: {%{p | clipcount: num(v)}, m}

  defp field(["clipbounce", v | _], p, m, c) do
    bounce = num(v)
    self = if bounce < 0 and p.cliptype == nil, do: {c, p.name}, else: p.cliptype
    {%{p | clipbounce: bounce, cliptype: self}, m}
  end

  defp field(["bounce", v | _], p, m, c),
    do: {%{p | cliptype: {c, p.name}, clipbounce: num(v)}, m}

  defp field(["emit", v | _], p, m, c), do: {%{p | emit: key(c, v)}, m}
  defp field(["emitinterval", v | _], p, m, _c), do: {%{p | emittime: num(v)}, m}
  defp field(["emitintervalrand", v | _], p, m, _c), do: {%{p | emitrand: num(v)}, m}
  defp field(["emitstart", v | _], p, m, _c), do: {%{p | emitstart: num(v)}, m}

  defp field(["spawnorg" | _] = w, p, m, _c) do
    value = num(arg(w, 1))
    {%{p | areaspread: value, areaspreadvert: if(has?(w, 2), do: num(arg(w, 2)), else: value)}, m}
  end

  defp field(["spawnvel" | _] = w, p, m, _c) do
    value = num(arg(w, 1))
    {%{p | spawnvel: value, spawnvelvert: if(has?(w, 2), do: num(arg(w, 2)), else: value)}, m}
  end

  defp field(["areaspread", v | _], p, m, _c), do: {%{p | areaspread: num(v)}, m}
  defp field(["areaspreadvert", v | _], p, m, _c), do: {%{p | areaspreadvert: num(v)}, m}
  defp field(["offsetspread", v | _], p, m, _c), do: {%{p | spawnvel: num(v)}, m}
  defp field(["offsetspreadvert", v | _], p, m, _c), do: {%{p | spawnvelvert: num(v)}, m}
  defp field(["up", v | _], p, m, _c), do: {%{p | orgbias: put_elem(p.orgbias, 2, num(v))}, m}

  defp field(["rampmode", value | _], p, m, _c) do
    mode =
      case value do
        "none" -> :none
        v when v in ["nearest", "absolute"] -> :nearest
        "lerp" -> :lerp
        _ -> :delta
      end

    {%{p | rampmode: mode}, m}
  end

  defp field(["ramp" | _] = w, p, m, _c) do
    red = num(arg(w, 1)) / 255

    entry =
      cond do
        has?(w, 4) ->
          %{
            rgb: {red, num(arg(w, 2)) / 255, num(arg(w, 3)) / 255},
            alpha: num(arg(w, 4)),
            scale: if(has?(w, 5), do: num(arg(w, 5)), else: p.scaledelta)
          }

        has?(w, 3) ->
          %{
            rgb: {red, num(arg(w, 2)) / 255, num(arg(w, 3)) / 255},
            alpha: p.alpha,
            scale: p.scaledelta
          }

        true ->
          %{rgb: {red, red, red}, alpha: p.alpha, scale: p.scaledelta}
      end

    {%{p | ramp: p.ramp ++ [entry]}, m}
  end

  defp field(["perframe" | _], p, m, _c),
    do: {%{p | flags: MapSet.put(p.flags, :invframetime)}, m}

  defp field(["averageout" | _], p, m, _c),
    do: {%{p | flags: MapSet.put(p.flags, :averagetrail)}, m}

  defp field(["nostate" | _], p, m, _c), do: {%{p | flags: MapSet.put(p.flags, :nostate)}, m}

  defp field(["nospreadfirst" | _], p, m, _c),
    do: {%{p | flags: MapSet.put(p.flags, :nospreadfirst)}, m}

  defp field(["nospreadlast" | _], p, m, _c),
    do: {%{p | flags: MapSet.put(p.flags, :nospreadlast)}, m}

  defp field(["lightradius" | _] = w, p, m, _c) do
    low = num(arg(w, 1))
    high = if has?(w, 2), do: num(arg(w, 2)), else: low
    {%{p | dl_radius: {low, high - low}}, m}
  end

  defp field(["lightradiusfade", v | _], p, m, _c),
    do: {%{p | dl_decay: put_elem(p.dl_decay, 3, num(v))}, m}

  defp field(["lightrgb" | _] = w, p, m, _c), do: {%{p | dl_rgb: vec3(w)}, m}

  defp field(["lightrgbfade" | _] = w, p, m, _c) do
    {r, g, b} = vec3(w)
    {%{p | dl_decay: {r, g, b, elem(p.dl_decay, 3)}}, m}
  end

  defp field(["lighttime", v | _], p, m, _c), do: {%{p | dl_time: num(v)}, m}
  defp field(_words, p, m, _c), do: {p, m}

  defp delta(p, change) do
    p = %{p | rgbchange: change}
    if p.rgbchangetime == 0, do: %{p | rgbchangetime: p.die}, else: p
  end

  defp vec3(w), do: {num(arg(w, 1)), num(arg(w, 2)), num(arg(w, 3))}

  defp colour(w, divisor) do
    first = num(arg(w, 1)) / divisor

    if has?(w, 3),
      do: {first, num(arg(w, 2)) / divisor, num(arg(w, 3)) / divisor},
      else: {first, first, first}
  end

  defp spawn_params(p, [one, two | _]), do: %{p | spawnparam1: num(one), spawnparam2: num(two)}
  defp spawn_params(p, [one]), do: %{p | spawnparam1: num(one)}
  defp spawn_params(p, []), do: p

  defp key(config, value) do
    case String.split(value, ".", parts: 2) do
      [other, name] -> {other, name}
      [name] -> {config, name}
    end
  end

  defp model([_, name | rest], config) do
    start = %{
      name: name,
      framestart: 0.0,
      framecount: 1.0,
      framerate: 10.0,
      alpha: 1.0,
      skin: 0,
      trail: nil,
      flags: MapSet.new([:noshadow]),
      scalemin: 1.0,
      scalemax: 1.0,
      rgb: {1.0, 1.0, 1.0}
    }

    if Enum.any?(rest, &String.contains?(&1, "=")) or Enum.any?(rest, &named_flag?/1),
      do: Enum.reduce(rest, start, &model_arg(&1, &2, config)),
      else: positional_model(start, rest, config)
  end

  defp named_flag?(word),
    do:
      String.downcase(word) in ["additive", "transparent", "fullbright", "shadow", "noshadow"] or
        String.starts_with?(String.downcase(word), "orient")

  defp positional_model(start, rest, config) do
    [a, b, c, d, e] = Enum.take(rest ++ List.duplicate(nil, 5), 5)

    %{
      start
      | framestart: num(a),
        framecount: num(b),
        framerate: num(c),
        alpha: num(d),
        trail: if(e && e != "", do: key(config, e))
    }
  end

  defp model_arg(word, mod, config) do
    case String.split(word, "=", parts: 2) do
      [k, v] -> model_value(String.downcase(k), v, mod, config)
      [flag] -> model_flag(String.downcase(flag), mod)
    end
  end

  defp model_value("frame", v, mod, _c), do: %{mod | framestart: num(v), framecount: 1.0}
  defp model_value("framestart", v, mod, _c), do: %{mod | framestart: num(v)}

  defp model_value(k, v, mod, _c) when k in ["framecount", "frameend", "frames"],
    do: %{mod | framecount: num(v)}

  defp model_value("framerate", v, mod, _c), do: %{mod | framerate: num(v)}
  defp model_value("skin", v, mod, _c), do: %{mod | skin: int(v)}
  defp model_value("alpha", v, mod, _c), do: %{mod | alpha: num(v)}
  defp model_value("scalemin", v, mod, _c), do: %{mod | scalemin: num(v)}
  defp model_value("scalemax", v, mod, _c), do: %{mod | scalemax: num(v)}
  defp model_value("r", v, mod, _c), do: %{mod | rgb: put_elem(mod.rgb, 0, num(v))}
  defp model_value("g", v, mod, _c), do: %{mod | rgb: put_elem(mod.rgb, 1, num(v))}
  defp model_value("b", v, mod, _c), do: %{mod | rgb: put_elem(mod.rgb, 2, num(v))}
  defp model_value("trail", v, mod, c), do: %{mod | trail: key(c, v)}
  defp model_value(_k, _v, mod, _c), do: mod

  defp model_flag("additive" <> _, mod), do: %{mod | flags: MapSet.put(mod.flags, :additive)}

  defp model_flag("transparent" <> _, mod),
    do: %{mod | flags: MapSet.put(mod.flags, :translucent)}

  defp model_flag("fullbright" <> _, mod), do: %{mod | flags: MapSet.put(mod.flags, :fullbright)}
  defp model_flag("orient" <> _, mod), do: %{mod | flags: MapSet.put(mod.flags, :orient)}
  defp model_flag("noshadow" <> _, mod), do: %{mod | flags: MapSet.put(mod.flags, :noshadow)}
  defp model_flag("shadow" <> _, mod), do: %{mod | flags: MapSet.delete(mod.flags, :noshadow)}
  defp model_flag(_word, mod), do: mod
end
