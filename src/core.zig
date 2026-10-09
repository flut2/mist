//! Dependency-free SDF generation core.
//! Has no dependencies, so it's usable on freestanding targets.

const std = @import("std");

pub const coloring = @import("coloring.zig");
pub const error_correction = @import("error_correction.zig");
pub const math = @import("math.zig");
pub const EdgeSegment = @import("EdgeSegment.zig");
pub const Scanline = @import("Scanline.zig");
pub const Shape = @import("Shape.zig");

const EdgeColor = coloring.EdgeColor;

const Vec2 = @Vector(2, f64);

pub const GlyphMetrics = struct {
    advance: f64,
    bearing_x: f64,
    bearing_y: f64,
    width: u16,
    height: u16,
};

pub const GeneratedGlyph = struct {
    metrics: GlyphMetrics,
    pixels: []const u8,

    pub fn deinit(self: GeneratedGlyph, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

pub const SdfType = enum {
    sdf,
    psdf,
    msdf,
    mtsdf,
    /// Experimental: A packed BGR MSDF where each channel is 10-bit,
    /// with a 2-bit alpha channel that is ignored (set to u2 max).
    ///
    /// Can prove useful in place of MSDFs as native `R8G8B8_X` (and equivalent)
    /// format support is scarce. Additionally, 3-channel images are often padded
    /// to have an alignment of 4 bytes per pixel on a lot of hardware,
    /// which results in the final byte getting wasted on such formats.
    msdf10,

    pub fn numChannels(self: SdfType) u8 {
        return switch (self) {
            .sdf, .psdf => 1,
            .msdf, .msdf10 => 3,
            .mtsdf => 4,
        };
    }

    pub fn requiresColoring(self: SdfType) bool {
        return switch (self) {
            .msdf, .msdf10, .mtsdf => true,
            else => false,
        };
    }
};

pub const ColoringMethod = enum {
    simple,
    /// Only for use with ink trap fonts, as the coloring remains correct
    /// after removing the edges required for trapping ink.
    ink_trap,
    /// Performs the coloring based on edge distances.
    /// Somewhat slower than other methods, but it produces a better result most of the time.
    distance,

    pub fn execute(self: ColoringMethod, args: anytype) !void {
        try switch (self) {
            .simple => @call(.auto, coloring.colorSimple, args),
            .ink_trap => @call(.auto, coloring.colorInkTrap, args),
            .distance => @call(.auto, coloring.colorDistance, args),
        };
    }
};

pub const Winding = enum {
    /// Attempts to figure out winding on its own, by checking
    /// the polarity of an OOB point's distance.
    guess,
    positive,
    negative,
};

pub const VarFontArgument = struct {
    name: []const u8,
    value: f64,
};

pub const Options = struct {
    sdf_type: SdfType,
    px_size: u16,
    px_range: u16,
    /// Has no effect if `sdf_type.requiresColoring()` is false.
    coloring_rng_seed: u64 = 0,
    /// The method with which to perform the MSDF 3-coloring.
    /// While the implementations are based on msdfgen, they're (intentionally)
    /// not equivalent, but should resolve corners similarly well.
    ///
    /// Has no effect if `sdf_type.requiresColoring()` is false.
    coloring_method: ColoringMethod = .distance,
    /// The angle which is considered to be a corner, in radians.
    corner_angle_threshold: f64 = 3.0,
    winding: Winding = .guess,
    /// Validates that the given (or generated) shapes' contours form a
    /// closed loop, with each edge connecting to each other properly.
    validate_shape: bool = false,
    normalize_shape: bool = false,
    orient_contours: bool = false,
    /// Requires `orient_contours` to be disabled.
    scanline_fill_rule: ?Scanline.FillRule = null,
    /// Only MSDFs (both their normal and their 10-bit versions) and MTSDFs can be error corrected.
    error_correction_opts: ?error_correction.Options = null,
    /// The list of arguments to use if the given font has multiple masters.
    /// Only used by font front ends (e.g. the freetype-based `mist` module).
    var_font_args: []const VarFontArgument = &.{},
    /// Whether to use async tasks over concurrent ones during atlas generation.
    /// Currently has no effect outside of atlas generation.
    disable_concurrency: bool = false,
};

pub const Msdf10Pixel = packed struct(u32) {
    r: u10 = 0,
    g: u10 = 0,
    b: u10 = 0,
    a: u2 = std.math.maxInt(u2),
};

fn pxRangeNorm(dist: f64, px_range: f64) f64 {
    return (dist + px_range / 2.0) / px_range;
}

pub fn findDistanceAt(
    comptime sdf_type: SdfType,
    shape: Shape,
    p: Vec2,
    px_range: f64,
) switch (sdf_type) {
    .sdf, .psdf => f64,
    inline .msdf, .msdf10, .mtsdf => |ty| [ty.numChannels()]f64,
} {
    const PsdfData = struct {
        dist: EdgeSegment.SignedDist = .init,
        edge: ?*const EdgeSegment = null,
        point_pos: EdgeSegment.PointPosition = .within_segment,
    };

    var true_ch: EdgeSegment.SignedDist = .init;
    var perp_ch: [if (sdf_type == .psdf) 1 else 3]PsdfData = @splat(.{});
    for (shape.contours.items) |contour| for (contour.edges.items) |*edge| {
        const dist, const point_pos = edge.signedDistance(p);

        switch (sdf_type) {
            .sdf, .mtsdf => {
                if (dist.lessThan(true_ch))
                    true_ch = dist;
            },
            .psdf => {
                if (dist.lessThan(perp_ch[0].dist)) perp_ch[0] = .{
                    .dist = dist,
                    .edge = edge,
                    .point_pos = point_pos,
                };
            },
            else => {},
        }

        if (sdf_type != .sdf and sdf_type != .psdf)
            for ([_]struct { channel: EdgeColor, target: *PsdfData }{
                .{ .channel = .red, .target = &perp_ch[0] },
                .{ .channel = .green, .target = &perp_ch[1] },
                .{ .channel = .blue, .target = &perp_ch[2] },
            }) |params|
                if (edge.color.hasChannel(params.channel) and dist.lessThan(params.target.dist)) {
                    params.target.* = .{
                        .dist = dist,
                        .edge = edge,
                        .point_pos = point_pos,
                    };
                };
    };

    if (sdf_type != .sdf) for (&perp_ch) |*psdf| {
        if (psdf.edge) |edge|
            edge.perpDistConvert(&psdf.dist, p, psdf.point_pos);
    };

    return switch (sdf_type) {
        .sdf => pxRangeNorm(true_ch.distance, px_range),
        .psdf => pxRangeNorm(perp_ch[0].dist.distance, px_range),
        .msdf, .msdf10 => .{
            pxRangeNorm(perp_ch[0].dist.distance, px_range),
            pxRangeNorm(perp_ch[1].dist.distance, px_range),
            pxRangeNorm(perp_ch[2].dist.distance, px_range),
        },
        .mtsdf => .{
            pxRangeNorm(perp_ch[0].dist.distance, px_range),
            pxRangeNorm(perp_ch[1].dist.distance, px_range),
            pxRangeNorm(perp_ch[2].dist.distance, px_range),
            pxRangeNorm(true_ch.distance, px_range),
        },
    };
}

pub fn f64i(int: anytype) f64 {
    return @floatFromInt(int);
}
