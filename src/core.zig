//! Dependency-free SDF generation core.
//! Has no dependencies, so it's usable on freestanding targets.

const std = @import("std");

pub const coloring = @import("coloring.zig");
pub const error_correction = @import("error_correction.zig");
pub const math = @import("math.zig");
pub const EdgeSegment = @import("EdgeSegment.zig");
pub const Scanline = @import("Scanline.zig");
pub const Shape = @import("Shape.zig");

const Bitmap = @import("bitmap.zig").Bitmap;
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

/// Font-agnostic glyph placement: the advance and bearings of the glyph the
/// shape was taken from, in em units, as reported by whatever produced the
/// outline. The result's pixel `width`/`height` are computed by `generateSingle`.
pub const GlyphPlacement = struct {
    advance: f64,
    bearing_x: f64,
    bearing_y: f64,
};

/// Font-agnostic outline ingestion: feed one glyph's contours through the
/// methods in outline order, starting with `moveTo`, then hand the shape to
/// `generateSingle`. Incoming coordinates are multiplied by `scale`, so raw
/// font units can be pushed directly with `scale` set to 1/units_per_em.
/// Zero-length lines/curves are dropped, matching what the freetype front end does.
pub const ShapeSink = struct {
    allocator: std.mem.Allocator,
    shape: *Shape,
    scale: f64,
    pos: Vec2 = @splat(0.0),
    contour: ?*Shape.Contour = null,

    fn scaled(p: Vec2, scale: f64) Vec2 {
        return p * @as(Vec2, @splat(scale));
    }

    pub fn moveTo(self: *ShapeSink, to: Vec2) !void {
        if (self.contour == null or self.contour.?.edges.items.len != 0) {
            self.contour = self.shape.contours.addOne(self.allocator) catch return error.OutOfMemory;
            self.contour.?.* = .{};
        }
        self.pos = scaled(to, self.scale);
    }

    pub fn lineTo(self: *ShapeSink, to: Vec2) !void {
        const endpoint = scaled(to, self.scale);
        if (!std.meta.eql(endpoint, self.pos)) {
            self.contour.?.edges.append(
                self.allocator,
                .create(self.pos, endpoint, null, null, .all),
            ) catch return error.OutOfMemory;
            self.pos = endpoint;
        }
    }

    pub fn quadTo(self: *ShapeSink, control: Vec2, to: Vec2) !void {
        const endpoint = scaled(to, self.scale);
        if (!std.meta.eql(endpoint, self.pos)) {
            self.contour.?.edges.append(self.allocator, .create(
                self.pos,
                scaled(control, self.scale),
                endpoint,
                null,
                .all,
            )) catch return error.OutOfMemory;
            self.pos = endpoint;
        }
    }

    pub fn cubicTo(self: *ShapeSink, control_1: Vec2, control_2: Vec2, to: Vec2) !void {
        const endpoint = scaled(to, self.scale);
        const c1 = scaled(control_1, self.scale);
        const c2 = scaled(control_2, self.scale);
        if (!std.meta.eql(endpoint, self.pos) or math.cross(c1 - endpoint, c2 - endpoint) != 0.0) {
            self.contour.?.edges.append(
                self.allocator,
                .create(self.pos, c1, c2, endpoint, .all),
            ) catch return error.OutOfMemory;
            self.pos = endpoint;
        }
    }

    /// Ends the current contour. Only observable right after a `moveTo`:
    /// the next `moveTo` then starts a fresh contour instead of reusing the
    /// still-empty one.
    pub fn close(self: *ShapeSink) void {
        self.contour = null;
    }
};

/// Renders a shape (in em units) into an SDF pixel buffer.
///
/// `shape` is mutated in place: empty contours are dropped, and depending on
/// `opts` the contours may get reoriented or normalized. An empty shape
/// produces a zero-size glyph. The placement's advance/bearings flow through
/// to the result's metrics; `width`/`height` are computed from the shape.
///
/// The result is under the caller's ownership (call `deinit()` or deallocate fields manually)
pub fn generateSingle(
    allocator: std.mem.Allocator,
    shape: *Shape,
    placement: GlyphPlacement,
    opts: *const Options,
) !GeneratedGlyph {
    if (shape.contours.items.len > 0) {
        var contour_it = std.mem.reverseIterator(shape.contours.items);
        var i: isize = @intCast(shape.contours.items.len - 1);
        while (contour_it.next()) |contour| : (i -= 1)
            if (contour.edges.items.len == 0) {
                _ = shape.contours.swapRemove(@intCast(i));
            };
    }

    if (shape.contours.items.len == 0)
        return .{
            .metrics = .{
                .advance = placement.advance,
                .bearing_x = placement.bearing_x,
                .bearing_y = placement.bearing_y,
                .width = 0,
                .height = 0,
            },
            .pixels = &.{},
        };

    if (opts.validate_shape and !shape.validate()) return error.InvalidShape;
    if (opts.orient_contours) try shape.orientContours(allocator);
    if (opts.normalize_shape) try shape.normalize(allocator);

    const px_size = f64i(opts.px_size);
    const px_range = f64i(opts.px_range) / px_size;

    var bounds = shape.calcBounds();
    if (bounds.left >= bounds.right or bounds.bottom >= bounds.top)
        bounds = .whole_frame;

    const bound_w = bounds.right - bounds.left;
    const bound_h = bounds.top - bounds.bottom;
    const w: u16 = @trunc((bound_w + px_range) * px_size);
    const h: u16 = @trunc((bound_h + px_range) * px_size);

    if (opts.winding == .negative or
        opts.winding == .guess and findDistanceAt(
            .sdf,
            shape.*,
            .{
                bounds.left - px_range - bound_w - 1.0,
                bounds.bottom - px_range - bound_h - 1.0,
            },
            px_range,
        ) > 0) for (shape.contours.items) |*contour| contour.reverse();

    return .{
        .metrics = .{
            .advance = placement.advance,
            .bearing_x = placement.bearing_x,
            .bearing_y = placement.bearing_y,
            .width = w,
            .height = h,
        },
        .pixels = try getSdfPixels(
            allocator,
            opts,
            w,
            h,
            shape,
            .{
                bounds.left - px_range / 2.0,
                bounds.bottom - px_range / 2.0,
            },
        ),
    };
}

fn getSdfPixels(
    allocator: std.mem.Allocator,
    opts: *const Options,
    w: u16,
    h: u16,
    shape: *Shape,
    tfm: Vec2,
) ![]const u8 {
    const px_size = f64i(opts.px_size);
    const px_range = f64i(opts.px_range) / px_size;

    const channels = opts.sdf_type.numChannels();
    var dist_bmp: Bitmap(f64) = try .create(0.0, allocator, w, h, channels);
    defer dist_bmp.destroy(allocator);

    switch (opts.sdf_type) {
        inline else => |ty| {
            if (ty.requiresColoring())
                try opts.coloring_method.execute(.{ allocator, opts.coloring_rng_seed, shape, opts.corner_angle_threshold });
            generate(ty, &dist_bmp, w, h, px_size, shape.*, px_range, tfm);
        },
    }

    if (!opts.orient_contours)
        if (opts.scanline_fill_rule) |fill_rule|
            switch (opts.sdf_type) {
                .sdf, .psdf => try sdfSignCorrection(
                    allocator,
                    &dist_bmp,
                    w,
                    h,
                    px_size,
                    shape.*,
                    tfm,
                    fill_rule,
                ),
                inline .msdf, .msdf10, .mtsdf => |ty| try msdfSignCorrection(
                    ty,
                    allocator,
                    &dist_bmp,
                    w,
                    h,
                    px_size,
                    shape.*,
                    tfm,
                    fill_rule,
                ),
            };

    if (opts.sdf_type == .msdf or
        opts.sdf_type == .mtsdf or
        opts.sdf_type == .msdf10)
        if (opts.error_correction_opts) |*ec_opts|
            try error_correction.correct(
                allocator,
                shape,
                ec_opts,
                px_size,
                px_range,
                tfm,
                &dist_bmp,
                opts.scanline_fill_rule != null,
            );

    const mod_channels = if (opts.sdf_type == .msdf10)
        4
    else
        channels;
    const pixels = try allocator.alloc(u8, @as(usize, w) * @as(usize, h) * @as(usize, mod_channels));

    for (0..h) |y| for (0..w) |x| {
        const idx = y * w * mod_channels + x * mod_channels;
        const ux: u16 = @intCast(x);
        const uy: u16 = @intCast(y);
        const dists = dist_bmp.at(false, ux, uy, channels);

        if (opts.sdf_type == .msdf10) {
            @memcpy(pixels[idx..][0..mod_channels], &std.mem.toBytes(Msdf10Pixel{
                .r = @trunc(std.math.maxInt(u10) * std.math.clamp(dists[0], 0.0, 1.0)),
                .g = @trunc(std.math.maxInt(u10) * std.math.clamp(dists[1], 0.0, 1.0)),
                .b = @trunc(std.math.maxInt(u10) * std.math.clamp(dists[2], 0.0, 1.0)),
                .a = std.math.maxInt(u2),
            }));
        } else for (0..channels) |i|
            pixels[idx + i] = @trunc(std.math.maxInt(u8) * std.math.clamp(dists[i], 0.0, 1.0));
    };
    return pixels;
}

fn sdfSignCorrection(
    allocator: std.mem.Allocator,
    out_pixels: *Bitmap(f64),
    w: u16,
    h: u16,
    scale: f64,
    shape: Shape,
    tfm: Vec2,
    fill_rule: Scanline.FillRule,
) !void {
    var scanline: Scanline = .{};
    defer scanline.intersections.deinit(allocator);
    for (0..h) |y| {
        try shape.scanline(&scanline, (f64i(y) + 0.5) / scale + tfm[1], allocator);
        for (0..w) |x| {
            const dists = out_pixels.at(true, @intCast(x), @intCast(y), 1);
            if ((dists[0] > 0.5) != scanline.filled((f64i(x) + 0.5) / scale + tfm[0], fill_rule))
                dists[0] = 1.0 - dists[0];
        }
    }
}

fn msdfSignCorrection(
    comptime sdf_type: SdfType,
    allocator: std.mem.Allocator,
    out_pixels: *Bitmap(f64),
    w: u16,
    h: u16,
    scale: f64,
    shape: Shape,
    tfm: Vec2,
    fill_rule: Scanline.FillRule,
) !void {
    if (sdf_type != .msdf and
        sdf_type != .mtsdf and
        sdf_type != .msdf10)
        @compileError("Invalid SDF type. Use `sdfSignCorrection()` instead.");

    var scanline: Scanline = .{};
    defer scanline.intersections.deinit(allocator);

    const match_map = try allocator.alloc(i32, w * h);
    defer allocator.free(match_map);
    @memset(match_map, 0);

    var ambiguous = false;
    var match_idx: usize = 0;
    for (0..h) |y| {
        try shape.scanline(&scanline, (f64i(y) + 0.5) / scale + tfm[1], allocator);
        for (0..w) |x| {
            const filled = scanline.filled((f64i(x) + 0.5) / scale + tfm[0], fill_rule);
            const px = out_pixels.at(true, @intCast(x), @intCast(y), comptime sdf_type.numChannels());
            const msdf_dist = math.median(px[0..3]);

            if (msdf_dist == 0.5) {
                ambiguous = true;
            } else if ((msdf_dist > 0.5) != filled) {
                for (px[0..3]) |*ch| ch.* = 1.0 - ch.*;
                match_map[match_idx] = -1;
            } else match_map[match_idx] = 1;

            if (sdf_type == .mtsdf and (px[3] > 0.5) != filled)
                px[3] = 1.0 - px[3];
            match_idx += 1;
        }
    }

    if (!ambiguous) return;

    match_idx = 0;
    for (0..h) |y| for (0..w) |x| {
        if (match_map[match_idx] != 0) {
            var neighbor_match: i32 = 0;
            if (x > 0) neighbor_match += match_map[match_idx - 1];
            if (x < w - 1) neighbor_match += match_map[match_idx + 1];
            if (y > 0) neighbor_match += match_map[match_idx - w];
            if (y < h - 1) neighbor_match += match_map[match_idx + w];
            if (neighbor_match < 0) {
                const px = out_pixels.at(true, @intCast(x), @intCast(y), comptime sdf_type.numChannels());
                for (px[0..3]) |*ch| ch.* = 1.0 - ch.*;
            }
        }
        match_idx += 1;
    };
}

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

fn generate(
    comptime sdf_type: SdfType,
    out_pixels: *Bitmap(f64),
    w: u16,
    h: u16,
    scale: f64,
    shape: Shape,
    px_range: f64,
    tfm: Vec2,
) void {
    for (0..h) |y| for (0..w) |x| {
        const channels = comptime sdf_type.numChannels();
        @memcpy(
            @as(*[channels]f64, @ptrCast(out_pixels.at(true, @intCast(x), @intCast(y), channels))),
            @as(*const [channels]f64, &findDistanceAt(
                sdf_type,
                shape,
                Vec2{
                    (f64i(x) + 0.5),
                    (f64i(y) + 0.5),
                } / math.v2(scale) + tfm,
                px_range,
            )),
        );
    };
}

pub fn f64i(int: anytype) f64 {
    return @floatFromInt(int);
}
