const std = @import("std");

const core = @import("mist-core");
const ft = @import("mach-freetype");
const pack = @import("turbopack");

const Shape = core.Shape;
const math = core.math;

const Vec2 = @Vector(2, f64);

const Generator = @This();

pub const FontMetrics = struct {
    line_height: f64,
    ascender: f64,
    descender: f64,
    underline_y: f64,
    underline_thickness: f64,
};

pub const GlyphMetrics = core.GlyphMetrics;

pub const KerningPair = struct {
    codepoint_1: u21,
    codepoint_2: u21,
    x: f64,
    y: f64,
};

pub const GeneratedGlyph = core.GeneratedGlyph;

pub const GeneratedAtlasGlyph = struct {
    metrics: GlyphMetrics,
    codepoint: u21,
    /// This is the glyph's unscaled, unnormalized
    /// bounding box on the atlas, with padding included.
    tex_bounds: pack.Rect,
};

pub const GeneratedAtlas = struct {
    glyphs: []const GeneratedAtlasGlyph,
    kernings: []const KerningPair,
    /// In case of `msdf10` you should reinterpret this as a `Msdf10Pixel` slice,
    /// like with 10-bit ABGR GPU formats (assuming a little endian host).
    pixels: []const u8,

    pub fn deinit(self: GeneratedAtlas, allocator: std.mem.Allocator) void {
        allocator.free(self.glyphs);
        allocator.free(self.kernings);
        allocator.free(self.pixels);
    }
};

// The SDF generation types and pipeline live in the dependency-free
// `mist-core` module (see `core.zig`); they're re-exported here
// so the `mist` module's public API is unchanged.
pub const SdfType = core.SdfType;

pub const ColoringMethod = core.ColoringMethod;

pub const Winding = core.Winding;

pub const VarFontArgument = core.VarFontArgument;

pub const Options = core.Options;

pub const Msdf10Pixel = core.Msdf10Pixel;

const FreetypeContext = struct {
    allocator: std.mem.Allocator,
    scale: f64,
    shape: *Shape,
    pos: Vec2 = @splat(0.0),
    contour: ?*Shape.Contour = null,
};

library: ft.Library,
font_memory: []const u8,

/// `font_memory` is the raw font file data.
/// It should be valid and available during the entire Generator lifecycle,
/// as it's used to create new faces, since a shared one is not thread-safe.
pub fn create(font_memory: []const u8) !Generator {
    return .{
        .library = try .init(),
        .font_memory = font_memory,
    };
}

pub fn destroy(self: *Generator) void {
    self.library.deinit();
}

pub fn fontMetrics(self: *Generator) !FontMetrics {
    const face = try self.library.createFaceMemory(self.font_memory, 0);
    defer face.deinit();

    const scale = 1.0 / f64i(face.unitsPerEM());
    return .{
        .line_height = scale * f64i(face.height()),
        .ascender = scale * f64i(face.ascender()),
        .descender = scale * f64i(face.descender()),
        .underline_y = scale * f64i(face.underlinePosition()),
        .underline_thickness = scale * f64i(face.underlineThickness()),
    };
}

fn handleVarFont(
    self: *Generator,
    face: ft.Face,
    allocator: std.mem.Allocator,
    var_args: []const VarFontArgument,
    face_flags: ft.FaceFlags,
) !void {
    if (var_args.len == 0) return;

    if (face_flags.multiple_masters) {
        std.log.warn("Var font args supplied, but the face only has a single master", .{});
        return;
    }

    const vf = try face.createVarFontInfo();
    if (vf) |var_font| if (var_font.num_axis > 0) {
        var coords = try allocator.alloc(ft.c.FT_Fixed, var_font.num_axis);
        defer allocator.free(coords);
        try face.getVarDesignCoords(coords);
        for (var_args) |args|
            for (var_font.axis[0..var_font.num_axis], 0..) |axis, i|
                if (std.mem.eql(u8, std.mem.span(axis.name), args.name)) {
                    coords[i] = @trunc(std.math.maxInt(u16) * args.value);
                };
        try face.setVarDesignCoords(coords);
    };
    try self.library.destroyVarFontInfo(vf);
}

/// The result is under the caller's ownership (call `deinit()` or deallocate fields manually)
pub fn generateSingle(
    self: *Generator,
    allocator: std.mem.Allocator,
    codepoint: u21,
    opts: *const Options,
) !GeneratedGlyph {
    const face = try self.library.createFaceMemory(self.font_memory, 0);
    defer face.deinit();

    try self.handleVarFont(face, allocator, opts.var_font_args, face.faceFlags());

    const scale = 1.0 / f64i(face.unitsPerEM());
    const glyph_index = face.getCharIndex(codepoint) orelse return error.InvalidCodepoint;
    try face.loadGlyph(glyph_index, .{ .no_scale = true, .no_bitmap = true });

    var shape: Shape = .{};
    defer shape.deinit(allocator);

    var context: FreetypeContext = .{
        .allocator = allocator,
        .scale = scale,
        .shape = &shape,
    };

    const outline = face.glyph().outline().?;
    try ft.intToError(ft.c.FT_Outline_Decompose(
        outline.handle,
        &.{
            .move_to = ftMoveTo,
            .line_to = ftLineTo,
            .conic_to = ftConicTo,
            .cubic_to = ftCubicTo,
            .shift = 0,
            .delta = 0,
        },
        &context,
    ));

    const metrics = face.glyph().metrics();
    return core.generateSingle(
        allocator,
        &shape,
        .{
            .advance = scale * f64i(face.glyph().advance().x),
            .bearing_x = scale * f64i(metrics.horiBearingX),
            .bearing_y = scale * f64i(metrics.horiBearingY),
        },
        opts,
    );
}

/// The result is under the caller's ownership (call `deinit()` or deallocate fields manually)
pub fn generateAtlas(
    self: *Generator,
    allocator: std.mem.Allocator,
    io: std.Io,
    codepoints: []const u21,
    atlas_w: u16,
    atlas_h: u16,
    glyph_padding: u8,
    use_kerning: bool,
    opts: *const Options,
) !GeneratedAtlas {
    const glyphs = try allocator.alloc(GeneratedAtlasGlyph, codepoints.len);
    errdefer allocator.free(glyphs);

    var kernings: std.ArrayList(KerningPair) = .empty;
    errdefer kernings.deinit(allocator);
    kerning: {
        if (!use_kerning)
            break :kerning;

        const face = try self.library.createFaceMemory(self.font_memory, 0);
        defer face.deinit();

        if (!face.faceFlags().kerning) {
            std.log.warn(
                \\Kerning requested, but none were found in the font file.
                \\Note: FreeType doesn't have full support for GPOS kerning, you might want to populate the kern table off of the GPOS one with a font editor if you were expecting kerning to be present.
            , .{});
            break :kerning;
        }

        const scale = 1.0 / f64i(face.unitsPerEM());
        for (codepoints) |codepoint_a| for (codepoints) |codepoint_b| {
            const idx_a = face.getCharIndex(codepoint_a) orelse return error.InvalidCodepoint;
            const idx_b = face.getCharIndex(codepoint_b) orelse return error.InvalidCodepoint;
            if (idx_a != idx_b) {
                const kern = try face.getKerning(idx_a, idx_b, .unscaled);
                if (kern.x != 0 or kern.y != 0)
                    try kernings.append(allocator, .{
                        .codepoint_1 = codepoint_a,
                        .codepoint_2 = codepoint_b,
                        .x = scale * f64i(kern.x),
                        .y = scale * f64i(kern.y),
                    });
            }
        };
    }

    const id_rects = try allocator.alloc(pack.IdRect, codepoints.len);
    defer allocator.free(id_rects);

    const rect_pixels = try allocator.alloc([]const u8, codepoints.len);
    defer {
        for (rect_pixels) |px| allocator.free(px);
        allocator.free(rect_pixels);
    }
    @memset(rect_pixels, &.{});

    var process_group: std.Io.Group = .init;
    for (
        codepoints,
        glyphs,
        id_rects,
        rect_pixels,
        0..,
    ) |codepoint, *glyph, *id_rect, *rect_px, i| {
        id_rect.id = @intCast(i);
        const args = .{
            self,
            allocator,
            opts,
            codepoint,
            glyph,
            id_rect,
            rect_px,
            glyph_padding,
        };

        if (opts.disable_concurrency)
            process_group.async(io, processAtlasCodepoint, args)
        else
            try process_group.concurrent(io, processAtlasCodepoint, args);
    }
    try process_group.await(io);

    var pack_ctx: pack.Context = try .create(allocator, atlas_w, atlas_h, .{});
    defer pack_ctx.deinit();
    try pack.pack(
        pack.IdRect,
        &pack_ctx,
        id_rects,
        .{ .sortLessThanFn = struct {
            fn lessThan(_: void, a: pack.IdRect, b: pack.IdRect) bool {
                return @max(a.rect.w, a.rect.h) > @max(b.rect.w, b.rect.h);
            }
        }.lessThan },
    );

    const mod_channels = if (opts.sdf_type == .msdf10)
        4
    else
        opts.sdf_type.numChannels();
    const pixels = try allocator.alloc(u8, @as(usize, atlas_w) * @as(usize, atlas_h) * @as(usize, mod_channels));
    errdefer allocator.free(pixels);
    @memset(pixels, 0);

    for (id_rects) |id_rect| {
        const index: usize = @intCast(id_rect.id);
        const rect = id_rect.rect;
        glyphs[index].tex_bounds = rect;
        if (rect.w <= 0 or rect.h <= 0)
            continue;

        const glyph_w: usize = @intCast(rect.w - glyph_padding * 2);
        const glyph_h: usize = @intCast(rect.h - glyph_padding * 2);
        const cur_atlas_x: usize = @intCast(rect.x + glyph_padding);
        const cur_atlas_y: usize = @intCast(rect.y + glyph_padding);

        for (0..glyph_h) |j| {
            const atlas_idx = ((cur_atlas_y + j) * atlas_w + cur_atlas_x) * mod_channels;
            const src_idx = (j * glyph_w) * mod_channels;
            @memcpy(
                pixels[atlas_idx .. atlas_idx + glyph_w * mod_channels],
                rect_pixels[index][src_idx .. src_idx + glyph_w * mod_channels],
            );
        }
    }

    return .{
        .glyphs = glyphs,
        .pixels = pixels,
        .kernings = if (use_kerning and kernings.items.len > 0)
            try kernings.toOwnedSlice(allocator)
        else
            &.{},
    };
}

fn processAtlasCodepoint(
    self: *Generator,
    allocator: std.mem.Allocator,
    opts: *const Options,
    codepoint: u21,
    glyph: *GeneratedAtlasGlyph,
    id_rect: *pack.IdRect,
    rect_px: *[]const u8,
    padding: u8,
) std.Io.Cancelable!void {
    self.processAtlasCodepointInner(
        allocator,
        opts,
        glyph,
        id_rect,
        rect_px,
        padding,
        codepoint,
    ) catch {
        if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
        return std.Io.Cancelable.Canceled;
    };
}

fn processAtlasCodepointInner(
    self: *Generator,
    allocator: std.mem.Allocator,
    opts: *const Options,
    glyph: *GeneratedAtlasGlyph,
    id_rect: *pack.IdRect,
    rect_px: *[]const u8,
    padding: u8,
    codepoint: u21,
) !void {
    const single_glyph = try self.generateSingle(allocator, codepoint, opts);
    const glyph_w = single_glyph.metrics.width;
    const glyph_h = single_glyph.metrics.height;
    if (glyph_w == 0 or glyph_h == 0) {
        glyph.* = .{
            .metrics = .{
                .advance = single_glyph.metrics.advance,
                .bearing_x = single_glyph.metrics.bearing_x,
                .bearing_y = single_glyph.metrics.bearing_y,
                .width = 0.0,
                .height = 0.0,
            },
            .codepoint = codepoint,
            .tex_bounds = .{ .w = 0, .h = 0 },
        };
        id_rect.rect = .{ .w = 0, .h = 0 };
        return;
    }

    rect_px.* = single_glyph.pixels;
    id_rect.rect = .{
        .w = glyph_w + padding * 2,
        .h = glyph_h + padding * 2,
    };
    glyph.* = .{
        .metrics = .{
            .advance = single_glyph.metrics.advance,
            .bearing_x = single_glyph.metrics.bearing_x,
            .bearing_y = single_glyph.metrics.bearing_y,
            .width = @intCast(id_rect.rect.w),
            .height = @intCast(id_rect.rect.h),
        },
        .codepoint = codepoint,
        .tex_bounds = .{
            .x = std.math.minInt(i32),
            .y = std.math.minInt(i32),
            .w = std.math.minInt(i32),
            .h = std.math.minInt(i32),
        },
    };
}

pub const findDistanceAt = core.findDistanceAt;

fn scaledFtVec(vec: [*c]const ft.Vector, scale: f64) Vec2 {
    return .{
        f64i(vec.*.x) * scale,
        f64i(vec.*.y) * scale,
    };
}

fn ftMoveTo(to: [*c]const ft.Vector, ud: ?*anyopaque) callconv(.c) i32 {
    var context: *FreetypeContext = @ptrCast(@alignCast(ud));
    if (context.contour == null or context.contour.?.edges.items.len != 0) {
        context.contour = context.shape.contours.addOne(context.allocator) catch return ft.c.FT_Err_Out_Of_Memory;
        context.contour.?.* = .{};
    }
    context.pos = scaledFtVec(to, context.scale);
    return 0;
}

fn ftLineTo(to: [*c]const ft.Vector, ud: ?*anyopaque) callconv(.c) i32 {
    var context: *FreetypeContext = @ptrCast(@alignCast(ud));
    const endpoint: Vec2 = scaledFtVec(to, context.scale);
    if (!std.meta.eql(endpoint, context.pos)) {
        context.contour.?.edges.append(
            context.allocator,
            .create(context.pos, endpoint, null, null, .all),
        ) catch return ft.c.FT_Err_Out_Of_Memory;
        context.pos = endpoint;
    }
    return 0;
}

fn ftConicTo(control: [*c]const ft.Vector, to: [*c]const ft.Vector, ud: ?*anyopaque) callconv(.c) i32 {
    var context: *FreetypeContext = @ptrCast(@alignCast(ud));
    const endpoint: Vec2 = scaledFtVec(to, context.scale);
    if (!std.meta.eql(endpoint, context.pos)) {
        context.contour.?.edges.append(context.allocator, .create(
            context.pos,
            scaledFtVec(control, context.scale),
            endpoint,
            null,
            .all,
        )) catch return ft.c.FT_Err_Out_Of_Memory;
        context.pos = endpoint;
    }
    return 0;
}

fn ftCubicTo(
    control_1: [*c]const ft.Vector,
    control_2: [*c]const ft.Vector,
    to: [*c]const ft.Vector,
    ud: ?*anyopaque,
) callconv(.c) i32 {
    var context: *FreetypeContext = @ptrCast(@alignCast(ud));
    const endpoint: Vec2 = scaledFtVec(to, context.scale);
    const scaled_c1: Vec2 = scaledFtVec(control_1, context.scale);
    const scaled_c2: Vec2 = scaledFtVec(control_2, context.scale);
    if (!std.meta.eql(endpoint, context.pos) or math.cross(scaled_c1 - endpoint, scaled_c2 - endpoint) != 0.0) {
        context.contour.?.edges.append(
            context.allocator,
            .create(context.pos, scaled_c1, scaled_c2, endpoint, .all),
        ) catch return ft.c.FT_Err_Out_Of_Memory;
        context.pos = endpoint;
    }
    return 0;
}

pub const f64i = core.f64i;
