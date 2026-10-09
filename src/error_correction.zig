const std = @import("std");

const Bitmap = @import("bitmap.zig").Bitmap;
const EdgeSegment = @import("EdgeSegment.zig");
const f64i = @import("core.zig").f64i;
const findDistanceAt = @import("core.zig").findDistanceAt;
const math = @import("math.zig");
const median = math.median;
const Shape = @import("Shape.zig");

const Vec2 = @Vector(2, f64);

const ErrorCorrection = @This();

const f64_nan = std.math.nan(f64);

const artifact_t_epsilon = 0.01;
const protection_radius_tolerance = 1.001;

pub const Mode = enum { indiscriminate, edge_priority, edge_only };
pub const Options = struct {
    mode: Mode = .edge_priority,
    /// Will be forcefully turned off if the scanline pass is enabled.
    check_distance: bool = true,
    min_deviation_ratio: f64 = 10.0 / 9.0,
    min_improve_ratio: f64 = 10.0 / 9.0,
};

const StencilFlags = packed struct {
    err: bool = false,
    protected: bool = false,
};

const ClassifierFlags = packed struct {
    candidate: bool = false,
    artifact: bool = false,

    pub fn merge(self: ClassifierFlags, other: ClassifierFlags) ClassifierFlags {
        return @bitCast(@as(u2, @bitCast(self)) | @as(u2, @bitCast(other)));
    }
};

const ColorFlags = packed struct {
    red: bool = false,
    green: bool = false,
    blue: bool = false,
};

const DistanceEvaluation = struct {
    shape: *const Shape,
    sdf: *const Bitmap(f64),
    options: *const Options,
    tfm: Vec2,
    scale: f64,
    px_range: f64,
    x: u16,
    y: u16,
};

const Direction = enum {
    north,
    north_east,
    east,
    south_east,
    south,
    south_west,
    west,
    north_west,
};

pub fn correct(
    allocator: std.mem.Allocator,
    shape: *const Shape,
    options: *const Options,
    scale: f64,
    px_range: f64,
    tfm: Vec2,
    sdf: *Bitmap(f64),
    skip_distance: bool,
) !void {
    var stencil: Bitmap(StencilFlags) = try .create(.{}, allocator, sdf.w, sdf.h, sdf.channels);
    defer stencil.destroy(allocator);

    var mod_opts: Options = options.*;
    mod_opts.check_distance = mod_opts.check_distance and !skip_distance;

    switch (mod_opts.mode) {
        .edge_priority => {
            protectCorners(&stencil, shape, scale, tfm);
            protectEdges(&stencil, px_range / scale * protection_radius_tolerance, sdf);
        },
        .edge_only => {
            for (stencil.pixels) |*mask| mask.protected = true;
        },
        .indiscriminate => {},
    }

    findErrors(&stencil, shape, sdf, &mod_opts, tfm, scale, px_range);

    for (0..stencil.h) |y| for (0..stencil.w) |x| {
        const ux: u16 = @intCast(x);
        const uy: u16 = @intCast(y);
        if (stencil.at(true, ux, uy, 1)[0].err) {
            const rgb = sdf.at(true, ux, uy, 3)[0..3];
            @memset(rgb, median(rgb));
        }
    };
}

pub fn protectCorners(stencil: *Bitmap(StencilFlags), shape: *const Shape, scale: f64, tfm: Vec2) void {
    for (shape.contours.items) |contour| {
        if (contour.edges.items.len == 0) continue;

        var last_color = contour.edges.getLast().color;
        for (contour.edges.items) |edge| {
            const common_color = @backingInt(last_color) & @backingInt(edge.color);
            last_color = edge.color;
            if ((common_color & (common_color - 1)) == 0) continue;

            const base_point = (edge.point(0) + tfm) * math.v2(scale);
            const left: i32 = @trunc(base_point[0] - 0.5);
            const top: i32 = @trunc(base_point[1] - 0.5);
            const right = stencil.w - left - 1;
            const bottom = stencil.h - top - 1;

            if (left < stencil.w and bottom < stencil.h and right >= 0 and top >= 0) {
                if (left >= 0 and bottom >= 0)
                    stencil.at(true, @intCast(left), @intCast(bottom), 1)[0].protected = true;
                if (right < stencil.w and bottom >= 0)
                    stencil.at(true, @intCast(right), @intCast(bottom), 1)[0].protected = true;
                if (left >= 0 and top < stencil.h)
                    stencil.at(true, @intCast(left), @intCast(top), 1)[0].protected = true;
                if (right < stencil.w and top < stencil.h)
                    stencil.at(true, @intCast(right), @intCast(top), 1)[0].protected = true;
            }
        }
    }
}

fn edgeBetweenTexels(a: *const [3]f64, b: *const [3]f64) ColorFlags {
    var mask: ColorFlags = .{};
    for (0..3) |channel| {
        const delta = a[channel] - b[channel];
        if (delta == 0.0)
            continue;

        const t = (a[channel] - 0.5) / delta;
        if (t < 0.0 or t > 1.0)
            continue;

        const c: [3]f64 = .{
            math.mix(a[0], b[0], t),
            math.mix(a[1], b[1], t),
            math.mix(a[2], b[2], t),
        };
        if (median(&c) == c[channel])
            switch (channel) {
                0 => mask.red = true,
                1 => mask.green = true,
                2 => mask.blue = true,
                else => unreachable,
            };
    }

    return mask;
}

fn protectExtremeChannels(stencil_point: *StencilFlags, msd: *const [3]f64, m: f64, mask: ColorFlags) void {
    if (mask.red and msd[0] != m or
        mask.green and msd[1] != m or
        mask.blue and msd[2] != m)
        stencil_point.protected = true;
}

fn protectEdges(stencil: *Bitmap(StencilFlags), radius: f64, sdf: *const Bitmap(f64)) void {
    for (0..sdf.h) |y| {
        const uy: u16 = @intCast(y);
        const left = sdf.at(true, 0, uy, 3)[0..3];
        const right = sdf.at(true, 1, uy, 3)[0..3];
        const median_left = median(left);
        const median_right = median(right);
        const mask = edgeBetweenTexels(left, right);
        if (@abs(median_left - 0.5) + @abs(median_right - 0.5) < radius)
            for (0..sdf.w - 1) |x| {
                const ux: u16 = @intCast(x);
                protectExtremeChannels(&stencil.at(true, ux, uy, 1)[0], left, median_left, mask);
                protectExtremeChannels(&stencil.at(true, ux + 1, uy, 1)[0], right, median_right, mask);
            };
    }

    for (0..sdf.h - 1) |y| {
        const uy: u16 = @intCast(y);
        const bottom = sdf.at(true, 0, uy, 3)[0..3];
        const top = sdf.at(true, 1, uy, 3)[0..3];
        const median_bottom = median(bottom);
        const median_top = median(top);
        const mask = edgeBetweenTexels(bottom, top);
        if (@abs(median_bottom - 0.5) + @abs(median_top - 0.5) < radius)
            for (0..sdf.w) |x| {
                const ux: u16 = @intCast(x);
                protectExtremeChannels(&stencil.at(true, ux, uy, 1)[0], bottom, median_bottom, mask);
                protectExtremeChannels(&stencil.at(true, ux, uy + 1, 1)[0], top, median_top, mask);
            };
    }

    const diag_radius = radius * @sqrt(2.0);
    for (0..sdf.h - 1) |y| {
        const uy: u16 = @intCast(y);
        const bottom_left = sdf.at(true, 0, uy, 3)[0..3];
        const bottom_right = sdf.at(true, 1, uy, 3)[0..3];
        const top_left = sdf.at(true, 0, uy + 1, 3)[0..3];
        const top_right = sdf.at(true, 1, uy + 1, 3)[0..3];
        const median_bottom_left = median(bottom_left);
        const median_bottom_right = median(bottom_right);
        const median_top_left = median(top_left);
        const median_top_right = median(top_right);
        const left_to_right_mask = edgeBetweenTexels(bottom_left, top_right);
        const left_to_right = @abs(median_bottom_left - 0.5) + @abs(median_top_right - 0.5) < diag_radius;
        const right_to_left_mask = edgeBetweenTexels(bottom_right, top_left);
        const right_to_left = @abs(median_bottom_right - 0.5) + @abs(median_top_left - 0.5) < diag_radius;

        if (left_to_right or right_to_left)
            for (0..sdf.w - 1) |x| {
                const ux: u16 = @intCast(x);

                if (left_to_right) {
                    protectExtremeChannels(&stencil.at(true, ux, uy, 1)[0], bottom_left, median_bottom_left, left_to_right_mask);
                    protectExtremeChannels(&stencil.at(true, ux + 1, uy + 1, 1)[0], top_right, median_top_right, left_to_right_mask);
                }

                if (right_to_left) {
                    protectExtremeChannels(&stencil.at(true, ux + 1, uy, 1)[0], bottom_right, median_bottom_right, right_to_left_mask);
                    protectExtremeChannels(&stencil.at(true, ux, uy + 1, 1)[0], top_left, median_top_left, right_to_left_mask);
                }
            };
    }
}

fn interpolatedMedianBilinear(a: *const [3]f64, l: *const [3]f64, q: *const [3]f64, t: f64) f64 {
    return median(&.{
        t * (t * q[0] + l[0]) + a[0],
        t * (t * q[1] + l[1]) + a[1],
        t * (t * q[2] + l[2]) + a[2],
    });
}

fn rangeTest(span: f64, protected: bool, at: f64, bt: f64, xt: f64, am: f64, bm: f64, xm: f64) ClassifierFlags {
    if (!(am > 0.5 and bm > 0.5 and xm <= 0.5 or
        am < 0.5 and bm < 0.5 and xm >= 0.5 or
        !protected and median(&.{ am, bm, xm }) != xm))
        return .{};

    const ax_span = (xt - at) * span;
    const bx_span = (bt - xt) * span;
    return .{
        .candidate = true,
        .artifact = !(xm >= am - ax_span and
            xm <= am + ax_span and
            xm >= bm - bx_span and
            xm <= bm + bx_span),
    };
}

fn evaluateArtifact(
    dist_eval: *const DistanceEvaluation,
    dir: Direction,
    flags: ClassifierFlags,
    t: f64,
) bool {
    if (flags.artifact) return true;
    if (!dist_eval.options.check_distance or !flags.candidate) return false;

    const t_vec: Vec2 = switch (dir) {
        .north => .{ 0, -t },
        .north_east => .{ t, -t },
        .east => .{ t, 0 },
        .south_east => .{ t, t },
        .south => .{ 0, t },
        .south_west => .{ -t, t },
        .west => .{ -t, 0 },
        .north_west => .{ -t, -t },
    };
    const sdf_coord: Vec2 = .{ f64i(dist_eval.x) + 0.5, f64i(dist_eval.y) + 0.5 };
    const tx = sdf_coord - math.v2(0.5) + t_vec;
    const lr = tx[0] - @floor(tx[0]);
    const bt = tx[1] - @floor(tx[1]);
    const left = @min(@as(u16, @trunc(tx[0])), dist_eval.sdf.w - 1);
    const bottom = @min(@as(u16, @trunc(tx[1])), dist_eval.sdf.w - 1);
    const right = @min(left + 1, dist_eval.sdf.h - 1);
    const top = @min(bottom + 1, dist_eval.sdf.h - 1);
    const lb_px = dist_eval.sdf.at(true, left, bottom, 3);
    const rb_px = dist_eval.sdf.at(true, right, bottom, 3);
    const lt_px = dist_eval.sdf.at(true, left, top, 3);
    const lr_px = dist_eval.sdf.at(true, left, right, 3);
    var old_sdf: [3]f64 = undefined;
    for (&old_sdf, 0..) |*c, i|
        c.* = math.mix(
            math.mix(lb_px[i], rb_px[i], lr),
            math.mix(lt_px[i], lr_px[i], lr),
            bt,
        );

    const wt = (1 - @abs(t_vec[0])) * (1 - @abs(t_vec[1]));
    const sdf_px = dist_eval.sdf.at(true, dist_eval.x, dist_eval.y, 3)[0..3];
    const m = median(sdf_px);
    const new_sdf: [3]f64 = .{
        old_sdf[0] + wt * (m - sdf_px[0]),
        old_sdf[1] + wt * (m - sdf_px[1]),
        old_sdf[2] + wt * (m - sdf_px[2]),
    };
    const om = median(&old_sdf);
    const nm = median(&new_sdf);
    const scale_vec = math.v2(dist_eval.scale);
    const dist = findDistanceAt(
        .psdf,
        dist_eval.shape.*,
        sdf_coord / scale_vec - dist_eval.tfm + t_vec / scale_vec,
        dist_eval.px_range,
    );
    return dist_eval.options.min_improve_ratio * @abs(nm - dist) < @abs(om - dist);
}

fn hasLinearArtifact(
    dist_eval: *const DistanceEvaluation,
    dir: Direction,
    span: f64,
    protected: bool,
    am: f64,
    a: *const [3]f64,
    b: *const [3]f64,
) bool {
    const bm = median(b);
    if (@abs(am - 0.5) < @abs(bm - 0.5)) return false;
    for (0..3) |idx| {
        const next_idx = (idx + 1) % 3;
        const da = a[next_idx] - a[idx];
        const db = b[next_idx] - b[idx];
        const delta = da - db;
        if (delta == 0) continue;
        const t = da / (da - db);
        if (t > artifact_t_epsilon and t < 1 - artifact_t_epsilon) {
            const xm = math.median(&.{
                math.mix(a[0], b[0], t),
                math.mix(a[1], b[1], t),
                math.mix(a[2], b[2], t),
            });

            if (evaluateArtifact(
                dist_eval,
                dir,
                rangeTest(span, protected, 0, 1, t, am, bm, xm),
                t,
            )) return true;
        }
    }
    return false;
}

fn hasDiagonalArtifact(
    dist_eval: *const DistanceEvaluation,
    dir: Direction,
    span: f64,
    protected: bool,
    am: f64,
    a: *const [3]f64,
    b: *const [3]f64,
    c: *const [3]f64,
    d: *const [3]f64,
) bool {
    const dm = median(d);
    if (@abs(am - 0.5) < @abs(dm - 0.5)) return false;

    const abc: [3]f64 = .{
        a[0] - b[0] - c[0],
        a[1] - b[1] - c[1],
        a[2] - b[2] - c[2],
    };
    const q: [3]f64 = .{
        d[0] + abc[0],
        d[1] + abc[1],
        d[2] + abc[2],
    };
    const l: [3]f64 = .{
        -a[0] - abc[0],
        -a[1] - abc[1],
        -a[2] - abc[2],
    };
    const t_ex: [3]f64 = .{
        -0.5 * l[0] / q[0],
        -0.5 * l[1] / q[1],
        -0.5 * l[2] / q[2],
    };

    for (0..3) |idx| {
        const next_idx = (idx + 1) % 3;
        const d_a = a[next_idx] - a[idx];
        const d_bc = b[next_idx] - b[idx] + (c[next_idx] - c[idx]);
        const d_d = d[next_idx] - d[idx];
        const t_ex_0 = t_ex[idx];
        const t_ex_1 = t_ex[next_idx];

        var buf: [2]f64 = undefined;
        for (math.solveEquation(&buf, &.{
            .a = d_d - d_bc + d_a,
            .b = d_bc - d_a - d_a,
            .c = d_a,
        })) |root|
            if (root > artifact_t_epsilon and root < 1 - artifact_t_epsilon) {
                const xm = interpolatedMedianBilinear(a, &l, &q, root);
                var flags = rangeTest(span, protected, 0, 1, root, am, dm, xm);
                var t_end: [2]f64 = undefined;
                var em: [2]f64 = undefined;

                if (t_ex_0 > 0 and t_ex_0 < 1) {
                    t_end = .{ 0, 1 };
                    em = .{ am, dm };
                    t_end[@intFromBool(t_ex_0 > root)] = t_ex_0;
                    em[@intFromBool(t_ex_0 > root)] = interpolatedMedianBilinear(a, &l, &q, t_ex_0);
                    flags = flags.merge(rangeTest(span, protected, t_end[0], t_end[1], root, em[0], em[1], xm));
                }

                if (t_ex_1 > 0 and t_ex_1 < 1) {
                    t_end = .{ 0, 1 };
                    em = .{ am, dm };
                    t_end[@intFromBool(t_ex_1 > root)] = t_ex_1;
                    em[@intFromBool(t_ex_1 > root)] = interpolatedMedianBilinear(a, &l, &q, t_ex_1);
                    flags = flags.merge(rangeTest(span, protected, t_end[0], t_end[1], root, em[0], em[1], xm));
                }

                if (evaluateArtifact(dist_eval, dir, flags, root))
                    return true;
            };
    }

    return false;
}

fn findErrors(
    stencil: *Bitmap(StencilFlags),
    shape: *const Shape,
    sdf: *const Bitmap(f64),
    options: *const Options,
    tfm: Vec2,
    scale: f64,
    px_range: f64,
) void {
    const span = px_range / scale * options.min_deviation_ratio;
    const diag_span = span * @sqrt(2.0);

    var dist_eval: DistanceEvaluation = .{
        .shape = shape,
        .sdf = sdf,
        .options = options,
        .tfm = tfm,
        .scale = scale,
        .px_range = px_range,
        .x = std.math.maxInt(u16),
        .y = std.math.maxInt(u16),
    };

    for (0..stencil.h) |y| for (0..stencil.w) |x| {
        const ux: u16 = @intCast(x);
        const uy: u16 = @intCast(y);

        dist_eval.x = ux;
        dist_eval.y = uy;

        const current = sdf.at(true, ux, uy, 3)[0..3];
        const median_current = median(current);
        var current_stencil = &stencil.at(true, ux, uy, 1)[0];
        const is_protected = current_stencil.protected;

        if (ux > 0) {
            const left = sdf.at(true, ux - 1, uy, 3)[0..3];
            if (hasLinearArtifact(
                &dist_eval,
                .west,
                span,
                is_protected,
                median_current,
                current,
                left,
            )) {
                current_stencil.err = true;
                continue;
            }

            if (uy > 0) {
                const top = sdf.at(true, ux, uy - 1, 3)[0..3];
                const top_left = sdf.at(true, ux - 1, uy - 1, 3)[0..3];
                if (hasDiagonalArtifact(
                    &dist_eval,
                    .north_west,
                    diag_span,
                    is_protected,
                    median_current,
                    current,
                    left,
                    top,
                    top_left,
                )) {
                    current_stencil.err = true;
                    continue;
                }
            }

            if (uy < sdf.h - 1) {
                const bottom = sdf.at(true, ux, uy + 1, 3)[0..3];
                const bottom_left = sdf.at(true, ux - 1, uy + 1, 3)[0..3];
                if (hasDiagonalArtifact(
                    &dist_eval,
                    .south_west,
                    diag_span,
                    is_protected,
                    median_current,
                    current,
                    left,
                    bottom,
                    bottom_left,
                )) {
                    current_stencil.err = true;
                    continue;
                }
            }
        }

        if (uy > 0) {
            const top = sdf.at(true, ux, uy - 1, 3)[0..3];
            if (hasLinearArtifact(
                &dist_eval,
                .north,
                span,
                is_protected,
                median_current,
                current,
                top,
            )) {
                current_stencil.err = true;
                continue;
            }
        }

        if (ux < sdf.w - 1) {
            const right = sdf.at(true, ux + 1, uy, 3)[0..3];
            if (hasLinearArtifact(
                &dist_eval,
                .east,
                span,
                is_protected,
                median_current,
                current,
                right,
            )) {
                current_stencil.err = true;
                continue;
            }

            if (uy > 0) {
                const top = sdf.at(true, ux, uy - 1, 3)[0..3];
                const top_right = sdf.at(true, ux + 1, uy - 1, 3)[0..3];
                if (hasDiagonalArtifact(
                    &dist_eval,
                    .north_east,
                    diag_span,
                    is_protected,
                    median_current,
                    current,
                    right,
                    top,
                    top_right,
                )) {
                    current_stencil.err = true;
                    continue;
                }
            }

            if (uy < sdf.h - 1) {
                const bottom = sdf.at(true, ux, uy + 1, 3)[0..3];
                const bottom_right = sdf.at(true, ux + 1, uy + 1, 3)[0..3];
                if (hasDiagonalArtifact(
                    &dist_eval,
                    .south_east,
                    diag_span,
                    is_protected,
                    median_current,
                    current,
                    right,
                    bottom,
                    bottom_right,
                )) {
                    current_stencil.err = true;
                    continue;
                }
            }
        }

        if (uy < sdf.h - 1) {
            const bottom = sdf.at(true, ux, uy + 1, 3)[0..3];
            if (hasLinearArtifact(
                &dist_eval,
                .south,
                span,
                is_protected,
                median_current,
                current,
                bottom,
            )) {
                current_stencil.err = true;
                continue;
            }
        }
    };
}
