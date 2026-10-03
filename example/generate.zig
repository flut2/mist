const std = @import("std");

const Generator = @import("mist");
const stbi = @import("stbi");

fn printableAscii() []const u21 {
    var ret: []const u21 = &.{};
    for (32..127) |i| ret = ret ++ [_]u21{i};
    return ret;
}

pub fn main(init: std.process.Init) !void {
    const clock_res = try std.Io.Clock.resolution(.real, init.io);
    if (clock_res.nanoseconds == 0)
        return std.Io.Clock.ResolutionError.ClockUnavailable;

    stbi.init(init.gpa, init.io);
    defer stbi.deinit();

    var file = try std.Io.Dir.cwd().openFile(init.io, "assets/DMSerifDisplay-Regular.ttf", .{});
    defer file.close(init.io);

    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(init.io, &read_buf);

    const font_memory = try reader.interface.allocRemaining(init.gpa, .unlimited);
    defer init.gpa.free(font_memory);

    var gen: Generator = try .create(font_memory);
    defer gen.destroy();

    const metrics = try gen.fontMetrics();
    std.log.info(
        \\Font Metrics:
        \\Ascender: {d:.2}
        \\Descender: {d:.2}
        \\Underline Y: {d:.2}
        \\Underline Thickness: {d:.2}
        \\Line Height: {d:.2}
    , .{
        metrics.ascender,
        metrics.descender,
        metrics.underline_y,
        metrics.underline_thickness,
        metrics.line_height,
    });

    const sdf_type: Generator.SdfType = .mtsdf;

    var seed: u64 = undefined;
    if (sdf_type.requiresColoring())
        init.io.random(std.mem.asBytes(&seed));

    const opts: Generator.Options = .{
        .sdf_type = sdf_type,
        .px_size = 64,
        .px_range = 8,
        .coloring_rng_seed = seed,
        .validate_shape = true,
        .normalize_shape = true,
        .orient_contours = true,
    };

    for ([_]u21{ 'A', 'B', 'C' }) |codepoint| {
        const time: std.Io.Timestamp = .now(init.io, .real);
        const glyph = try gen.generateSingle(init.gpa, codepoint, &opts);
        defer glyph.deinit(init.gpa);

        const glyph_ns = time.durationTo(.now(init.io, .real)).nanoseconds;
        std.log.info("SDF for codepoint `{u}` generated in {}us ({}ms)", .{
            codepoint,
            @divFloor(glyph_ns, std.time.ns_per_us),
            @divFloor(glyph_ns, std.time.ns_per_ms),
        });

        var image: stbi.Image = try .createEmpty(
            glyph.metrics.width,
            glyph.metrics.height,
            opts.sdf_type.numChannels(),
            .{},
        );
        defer image.deinit();
        @memcpy(image.data, glyph.pixels);

        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&path_buf, "{u}_sdf.png", .{codepoint}, 0);
        try image.writeToFile(path, .png);
    }

    const atlas_w = 512;
    const atlas_h = 512;
    const time: std.Io.Timestamp = .now(init.io, .real);
    const atlas = try gen.generateAtlas(
        init.gpa,
        init.io,
        comptime printableAscii(),
        atlas_w,
        atlas_h,
        2,
        true,
        &opts,
    );
    defer atlas.deinit(init.gpa);

    const atlas_ns = time.durationTo(.now(init.io, .real)).nanoseconds;
    std.log.info("SDFs for atlas ({} glyphs) generated in {}us ({}ms)", .{
        atlas.glyphs.len,
        @divFloor(atlas_ns, std.time.ns_per_us),
        @divFloor(atlas_ns, std.time.ns_per_ms),
    });

    var image: stbi.Image = try .createEmpty(
        atlas_w,
        atlas_h,
        opts.sdf_type.numChannels(),
        .{},
    );
    defer image.deinit();
    @memcpy(image.data, atlas.pixels);

    try image.writeToFile("atlas_sdf.png", .png);
}
