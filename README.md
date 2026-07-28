# Mist
A signed distance field generator with support for [Viktor Chlumský's MSDF technique](https://github.com/Chlumsky/msdfgen).

## Usage
A simple example can be found below, with a more in-depth one in `example/generate.zig`.

```zig
const Generator = @import("mist");
const font_data = @embedFile("OpenSans-Bold.ttf");

var gen: Generator = try .create(font_data);
defer gen.destroy();

var seed: u64 = undefined;
io.random(std.mem.asBytes(&seed));

const gen_opts: Generator.Options = .{
    .sdf_type = .mtsdf,
    .px_size = 64,
    .px_range = 8,
    .coloring_rng_seed = seed,
    .validate_shape = true,
    .normalize_shape = true,
    .orient_contours = true,
};

for ([_]u21{ 'A', 'B', 'C' }) |codepoint| {
    const data = try gen.generateSingle(allocator, codepoint, &gen_opts);
    defer data.deinit(allocator);
    
    var image: stbi.Image = try .createEmpty(
        data.glyph_data.width,
        data.glyph_data.height,
        gen_opts.sdf_type.numChannels(),
        .{},
    );
    defer image.deinit();
    @memcpy(image.data, data.pixels);

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{u}_sdf.png", .{codepoint});
    try image.writeToFile(path, .png);
}
```

## Note
The library exposes a similar set of functionality to Chlumský's work, but it's not intended to be its equivalent, some features will be implemented differently and some will be intentionally omitted. Issues and PRs can still compare to msdfgen, like if the library generates a less correct SDF than it, but direct ports, or the request for them will be closed.
