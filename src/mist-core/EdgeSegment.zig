const std = @import("std");

const Bounds = @import("Shape.zig").Bounds;
const EdgeColor = @import("coloring.zig").EdgeColor;
const math = @import("math.zig");
const mix = math.mix;
const dot = math.dot;
const cross = math.cross;
const normal = math.normal;
const v2 = math.v2;

const Vec2 = @Vector(2, f64);
const EdgeSegment = @This();

const cubic_starts = 4;
const cubic_steps = 4;

pub const SignedDist = struct {
    distance: f64,
    dot: f64 = 0.0,

    pub const init: SignedDist = .{ .distance = std.math.floatMax(f64), .dot = 0.0 };

    pub fn lessThan(self: SignedDist, other: SignedDist) bool {
        const self_dist = @abs(self.distance);
        const other_dist = @abs(other.distance);
        if (self_dist > other_dist) return false;
        if (self_dist < other_dist) return true;
        return self.dot < other.dot;
    }
};

pub const PointPosition = enum {
    within_segment,
    outside_start,
    outside_end,

    pub fn fromNormalized(t: f64) PointPosition {
        if (t < 0.0) return .outside_start;
        if (t > 1.0) return .outside_end;
        return .within_segment;
    }
};

color: EdgeColor,
segment: union(enum) {
    linear: [2]Vec2,
    quadratic_bezier: [3]Vec2,
    cubic_bezier: [4]Vec2,
},

fn createLinear(p0: Vec2, p1: Vec2, color: EdgeColor) EdgeSegment {
    return .{ .color = color, .segment = .{ .linear = .{ p0, p1 } } };
}

fn createQuadratic(p0: Vec2, p1: Vec2, p2: Vec2, color: EdgeColor) EdgeSegment {
    return .{ .color = color, .segment = .{ .quadratic_bezier = .{ p0, p1, p2 } } };
}

fn createCubic(p0: Vec2, p1: Vec2, p2: Vec2, p3: Vec2, color: EdgeColor) EdgeSegment {
    return .{ .color = color, .segment = .{ .cubic_bezier = .{ p0, p1, p2, p3 } } };
}

pub fn create(p0: Vec2, p1: Vec2, maybe_p2: ?Vec2, maybe_p3: ?Vec2, color: EdgeColor) EdgeSegment {
    if (maybe_p3) |p3| {
        if (maybe_p2 == null)
            @panic("Invalid parameters, you need to specify `p2` if you specify `p3`.");

        const p2 = maybe_p2.?;
        var p12: Vec2 = p2 - p1;
        if (cross(p1 - p0, p12) == 0.0 and cross(p12, p3 - p2) == 0.0)
            return createLinear(p0, p3, color);

        p12 = p1 * v2(1.5) - p0 * v2(0.5);
        if (std.meta.eql(p12, p2 * v2(1.5) - p3 * v2(0.5)))
            return createQuadratic(p0, p12, p3, color);

        return createCubic(p0, p1, p2, p3, color);
    }

    if (maybe_p2) |p2| {
        if (cross(p1 - p0, p2 - p1) == 0.0)
            return createLinear(p0, p2, color);
        return createQuadratic(p0, p1, p2, color);
    }

    return createLinear(p0, p1, color);
}

pub fn point(self: EdgeSegment, param: f64) Vec2 {
    switch (self.segment) {
        .linear => |p| return mix(p[0], p[1], param),
        .quadratic_bezier => |p| return mix(
            mix(p[0], p[1], param),
            mix(p[1], p[2], param),
            param,
        ),
        .cubic_bezier => |p| {
            const p12 = mix(p[1], p[2], param);
            return mix(
                mix(mix(p[0], p[1], param), p12, param),
                mix(p12, mix(p[2], p[3], param), param),
                param,
            );
        },
    }
}

pub fn direction(self: EdgeSegment, comptime index: u1) Vec2 {
    switch (self.segment) {
        .linear => |p| return p[1] - p[0],
        .quadratic_bezier => |p| {
            const tangent = switch (index) {
                0 => p[1] - p[0],
                1 => p[2] - p[1],
            };
            if (std.meta.eql(tangent, @splat(0.0))) return p[2] - p[0];
            return tangent;
        },
        .cubic_bezier => |p| {
            const tangent = switch (index) {
                0 => p[1] - p[0],
                1 => p[3] - p[2],
            };
            if (std.meta.eql(tangent, @splat(0.0))) switch (index) {
                0 => return p[2] - p[0],
                1 => return p[3] - p[1],
            };
            return tangent;
        },
    }
}

pub fn perpDistConvert(
    self: *const EdgeSegment,
    dist: *SignedDist,
    origin: Vec2,
    point_pos: PointPosition,
) void {
    switch (point_pos) {
        .within_segment => return,
        inline else => |pos| {
            const idx = if (pos == .outside_start) 0 else 1;
            const dir = normal(self.direction(idx), true);
            const pq = origin - self.point(idx);
            const d = if (pos == .outside_start) -dot(pq, dir) else dot(pq, dir);
            if (d > 0) {
                const perp_dist = cross(pq, dir);
                if (@abs(perp_dist) <= @abs(dist.distance))
                    dist.* = .{ .distance = perp_dist };
            }
        },
    }
}

pub fn signedDistance(self: EdgeSegment, origin: Vec2) struct { SignedDist, PointPosition } {
    switch (self.segment) {
        .linear => |p| {
            const aq = origin - p[0];
            const ab = p[1] - p[0];
            const t = dot(aq, ab) / dot(ab, ab);
            const eq = p[@intFromBool(t > 0.5)] - origin;
            const point_pos: PointPosition = .fromNormalized(t);
            const endpoint_dist = math.length(eq);
            if (point_pos == .within_segment) {
                const ortho_dist = dot(-math.orthonormal(ab, true), aq);
                if (@abs(ortho_dist) < endpoint_dist)
                    return .{ .{ .distance = ortho_dist }, point_pos };
            }

            return .{
                .{
                    .distance = math.nonZeroSign(cross(aq, ab)) * endpoint_dist,
                    .dot = @abs(dot(normal(ab, true), normal(eq, true))),
                },
                point_pos,
            };
        },
        .quadratic_bezier => |p| {
            const qa = p[0] - origin;
            const qc = p[2] - origin;
            const ab = p[1] - p[0];
            const br = p[2] - p[1] - ab;
            const d0 = self.direction(0);
            const d1 = self.direction(1);

            var min_dist = math.nonZeroSign(cross(d0, qa)) * math.length(qa);
            var point_pos: PointPosition = .fromNormalized(-dot(qa, d0) / dot(d0, d0));

            var dist = math.length(qc);
            if (dist < @abs(min_dist)) {
                min_dist = math.nonZeroSign(cross(d1, qc)) * dist;
                point_pos = .fromNormalized(dot(origin - p[1], d1) / dot(d1, d1));
            }

            var buf: [3]f64 = undefined;
            for (math.solveEquation(&buf, &.{
                .a = dot(br, br),
                .b = 3.0 * dot(ab, br),
                .c = 2.0 * dot(ab, ab) + dot(qa, br),
                .d = dot(qa, ab),
            })) |root|
                if (root > 0.0 and root < 1.0) {
                    const qe = qa + ab * v2(root * 2.0) + br * v2(root * root);
                    dist = math.length(qe);
                    if (dist < @abs(min_dist)) {
                        min_dist = math.nonZeroSign(cross(ab + br * v2(root), qe)) * dist;
                        point_pos = .fromNormalized(root);
                    }
                };

            return .{
                .{
                    .distance = min_dist,
                    .dot = switch (point_pos) {
                        .within_segment => 0.0,
                        .outside_start => @abs(dot(
                            normal(d0, true),
                            normal(qa, true),
                        )),
                        .outside_end => @abs(dot(
                            normal(d1, true),
                            normal(qc, true),
                        )),
                    },
                },
                point_pos,
            };
        },
        .cubic_bezier => |p| {
            const qa = p[0] - origin;
            const qd = p[3] - origin;
            const ab = p[1] - p[0];
            const br = p[2] - p[1] - ab;
            const as = (p[3] - p[2]) - (p[2] - p[1]) - br;
            const d0 = self.direction(0);
            const d1 = self.direction(1);

            var min_dist = math.nonZeroSign(cross(d0, qa)) * math.length(qa);
            var point_pos: PointPosition = .fromNormalized(-dot(qa, d0) / dot(d0, d0));

            const qd_dist = math.length(qd);
            if (qd_dist < @abs(min_dist)) {
                min_dist = math.nonZeroSign(cross(d1, qd)) * qd_dist;
                point_pos = .fromNormalized(dot(d1 - qd, d1) / dot(d1, d1));
            }

            for (0..cubic_starts) |i| {
                const fi: f64 = @floatFromInt(i);
                var t = fi / cubic_starts;

                var qe = qa +
                    ab * v2(t * 3.0) +
                    br * v2(t * t * 3.0) +
                    as * v2(t * t * t);
                var cd1 = ab * v2(3.0) +
                    br * v2(t * 6.0) +
                    as * v2(t * t * 3.0);
                var cd2 = br * v2(6.0) +
                    as * v2(t * 6.0);

                var next_t = t - dot(qe, cd1) / (dot(cd1, cd1) + dot(qe, cd2));
                if (next_t > 0.0 and next_t < 1.0) {
                    for (0..cubic_steps) |_| {
                        t = next_t;

                        qe = qa +
                            ab * v2(t * 3.0) +
                            br * v2(t * t * 3.0) +
                            as * v2(t * t * t);
                        cd1 = ab * v2(3.0) +
                            br * v2(t * 6.0) +
                            as * v2(t * t * 3.0);
                        cd2 = br * v2(6.0) +
                            as * v2(t * 6.0);

                        next_t = t - dot(qe, cd1) / (dot(cd1, cd1) + dot(qe, cd2));
                        if (next_t <= 0.0 or next_t >= 1.0) break;
                    }

                    const qe_dist = math.length(qe);
                    if (qe_dist < @abs(min_dist)) {
                        min_dist = math.nonZeroSign(cross(cd1, qe)) * qe_dist;
                        point_pos = .fromNormalized(t);
                    }
                }
            }

            return .{
                .{
                    .distance = min_dist,
                    .dot = switch (point_pos) {
                        .within_segment => 0.0,
                        .outside_start => @abs(dot(
                            normal(d0, true),
                            normal(qa, true),
                        )),
                        .outside_end => @abs(dot(
                            normal(d1, true),
                            normal(qd, true),
                        )),
                    },
                },
                point_pos,
            };
        },
    }
}

pub fn scanlineIntersections(self: EdgeSegment, x: *[3]f64, dy: *[3]i32, y: f64) u32 {
    switch (self.segment) {
        .linear => |p| {
            if (y >= p[0][1] and y < p[1][1] or y >= p[1][1] and y < p[0][1]) {
                const param = (y - p[0][1]) / (p[1][1] - p[0][1]);
                x[0] = mix(p[0][0], p[1][0], param);
                dy[0] = std.math.sign(p[1][1] - p[0][1]);
                return 1;
            }
            return 0;
        },
        .quadratic_bezier => |p| {
            var total: u32 = 0;
            var next_dy: i32 = math.boolSign(y > p[0][1]);
            x[total] = p[0][0];
            if (p[0][1] == y) {
                if (p[0][1] < p[1][1] or p[0][1] == p[1][1] and p[0][1] < p[2][1]) {
                    dy[total] = 1;
                    total += 1;
                } else next_dy = 1;
            }

            const ab = p[1] - p[0];
            const br = p[2] - p[1] - ab;

            var buf: [2]f64 = undefined;
            const roots = math.solveEquation(&buf, &.{
                .a = br[1],
                .b = 2 * ab[1],
                .c = p[0][1] - y,
            });
            std.sort.pdq(f64, roots, {}, struct {
                pub fn lessThan(_: void, a: f64, b: f64) bool {
                    return a > b;
                }
            }.lessThan);

            for (roots) |root|
                if (total < 2 and root >= 0 and root <= 1) {
                    x[total] = p[0][0] + 2 * root * ab[0] + root * root * br[0];
                    if (@as(f64, @floatFromInt(next_dy)) * (ab[1] + root * br[1]) >= 0) {
                        dy[total] = next_dy;
                        total += 1;
                        next_dy = -next_dy;
                    }
                };

            if (p[2][1] == y) {
                if (next_dy > 0 and total > 0) {
                    total -= 1;
                    next_dy = -1;
                }
                if ((p[2][1] < p[1][1] or p[2][1] == p[1][1] and p[2][1] < p[0][1]) and total < 2) {
                    x[total] = p[2][0];
                    if (next_dy < 0) {
                        dy[total] = -1;
                        total += 1;
                        next_dy = 1;
                    }
                }
            }

            if (next_dy != math.boolSign(y >= p[2][1])) {
                if (total > 0)
                    total -= 1
                else {
                    if (@abs(p[2][1] - y) < @abs(p[0][1] - y)) x[total] = p[2][0];
                    dy[total] = next_dy;
                    total += 1;
                }
            }

            return total;
        },
        .cubic_bezier => |p| {
            var total: u32 = 0;
            var next_dy: i32 = math.boolSign(y > p[0][1]);
            x[total] = p[0][0];
            if (p[0][1] == y) {
                if (p[0][1] < p[1][1] or (p[0][1] == p[1][1] and (p[0][1] < p[2][1] or (p[0][1] == p[2][1] and p[0][1] < p[3][1])))) {
                    dy[total] = 1;
                    total += 1;
                } else next_dy = 1;
            }

            const ab = p[1] - p[0];
            const br = p[2] - p[1] - ab;
            const as = (p[3] - p[2]) - (p[2] - p[1]) - br;

            var buf: [3]f64 = undefined;
            const roots = math.solveEquation(&buf, &.{
                .a = as[1],
                .b = 3 * br[1],
                .c = 3 * ab[1],
                .d = p[0][1] - y,
            });
            std.sort.pdq(f64, roots, {}, struct {
                pub fn lessThan(_: void, a: f64, b: f64) bool {
                    return a > b;
                }
            }.lessThan);

            for (roots) |root|
                if (total < 3 and root >= 0 and root <= 1) {
                    x[total] = p[0][0] +
                        3 * root * ab[0] +
                        3 * root * root * br[0] +
                        root * root * root * as[0];
                    if (@as(f64, @floatFromInt(next_dy)) * (ab[1] + 2 * root * br[1] + root * root * as[1]) >= 0) {
                        dy[total] = next_dy;
                        total += 1;
                        next_dy = -next_dy;
                    }
                };

            if (p[3][1] == y) {
                if (next_dy > 0 and total > 0) {
                    total -= 1;
                    next_dy = -1;
                }

                if ((p[3][1] < p[2][1] or (p[3][1] == p[2][1] and (p[3][1] < p[1][1] or (p[3][1] == p[1][1] and p[3][1] < p[0][1])))) and total < 3) {
                    x[total] = p[3][0];
                    if (next_dy < 0) {
                        dy[total] = -1;
                        total += 1;
                        next_dy = 1;
                    }
                }
            }

            if (next_dy != math.boolSign(y >= p[3][1])) {
                if (total > 0)
                    total -= 1
                else {
                    if (@abs(p[3][1] - y) < @abs(p[0][1] - y)) x[total] = p[3][0];
                    dy[total] = next_dy;
                    total += 1;
                }
            }

            return total;
        },
    }
}

pub fn bound(self: EdgeSegment, bounds: *Bounds) void {
    switch (self.segment) {
        .linear => |p| {
            bounds.bound(p[0][0], p[0][1]);
            bounds.bound(p[1][0], p[1][1]);
        },
        .quadratic_bezier => |p| {
            bounds.bound(p[0][0], p[0][1]);
            bounds.bound(p[2][0], p[2][1]);

            const bot = (p[1] - p[0]) - (p[2] - p[1]);
            inline for (0..2) |i| if (bot[i] != 0.0) {
                const t = (p[1][i] - p[0][i]) / bot[i];
                if (t > 0 and t < 1) {
                    const t_pt = self.point(t);
                    bounds.bound(t_pt[0], t_pt[1]);
                }
            };
        },
        .cubic_bezier => |p| {
            bounds.bound(p[0][0], p[0][1]);
            bounds.bound(p[3][0], p[3][1]);

            const a0 = p[1] - p[0];
            const a1 = (p[2] - p[1] - a0) * v2(2.0);
            const a2 = p[3] - p[2] * v2(3.0) + p[1] * v2(3.0) - p[0];

            var buf: [2]f64 = undefined;
            inline for (0..2) |i| for (math.solveEquation(&buf, &.{
                .a = a2[i],
                .b = a1[i],
                .c = a0[i],
            })) |root| if (root > 0 and root < 1) {
                const root_pt = self.point(root);
                bounds.bound(root_pt[0], root_pt[1]);
            };
        },
    }
}

pub fn reverse(self: *EdgeSegment) void {
    switch (self.segment) {
        .linear => |*p| std.mem.swap(Vec2, &p[0], &p[1]),
        .quadratic_bezier => |*p| std.mem.swap(Vec2, &p[0], &p[2]),
        .cubic_bezier => |*p| {
            std.mem.swap(Vec2, &p[0], &p[3]);
            std.mem.swap(Vec2, &p[1], &p[2]);
        },
    }
}

pub fn splitInThirds(self: EdgeSegment) [3]EdgeSegment {
    return switch (self.segment) {
        .linear => |p| .{
            createLinear(p[0], self.point(1.0 / 3.0), self.color),
            createLinear(self.point(1.0 / 3.0), self.point(2.0 / 3.0), self.color),
            createLinear(self.point(2.0 / 3.0), p[1], self.color),
        },
        .quadratic_bezier => |p| .{
            createQuadratic(p[0], mix(p[0], p[1], 1.0 / 3.0), self.point(1.0 / 3.0), self.color),
            createQuadratic(
                self.point(1.0 / 3.0),
                mix(
                    mix(p[0], p[1], 5.0 / 9.0),
                    mix(p[1], p[2], 4.0 / 9.0),
                    0.5,
                ),
                self.point(2.0 / 3.0),
                self.color,
            ),
            createQuadratic(self.point(2.0 / 3.0), mix(p[1], p[2], 2.0 / 3.0), p[2], self.color),
        },
        .cubic_bezier => |p| .{
            createCubic(
                p[0],
                if (std.meta.eql(p[0], p[1])) p[0] else mix(p[0], p[1], 1.0 / 3.0),
                mix(
                    mix(p[0], p[1], 1.0 / 3.0),
                    mix(p[1], p[2], 1.0 / 3.0),
                    1.0 / 3.0,
                ),
                self.point(1.0 / 3.0),
                self.color,
            ),
            createCubic(
                self.point(1.0 / 3.0),
                mix(
                    mix(
                        mix(p[0], p[1], 1.0 / 3.0),
                        mix(p[1], p[2], 1.0 / 3.0),
                        1.0 / 3.0,
                    ),
                    mix(
                        mix(p[1], p[2], 1.0 / 3.0),
                        mix(p[2], p[3], 1.0 / 3.0),
                        1.0 / 3.0,
                    ),
                    2.0 / 3.0,
                ),
                mix(
                    mix(
                        mix(p[0], p[1], 2.0 / 3.0),
                        mix(p[1], p[2], 2.0 / 3.0),
                        2.0 / 3.0,
                    ),
                    mix(
                        mix(p[1], p[2], 2.0 / 3.0),
                        mix(p[2], p[3], 2.0 / 3.0),
                        2.0 / 3.0,
                    ),
                    1.0 / 3.0,
                ),
                self.point(2.0 / 3.0),
                self.color,
            ),
            createCubic(
                self.point(2.0 / 3.0),
                mix(
                    mix(p[1], p[2], 2.0 / 3.0),
                    mix(p[2], p[3], 2.0 / 3.0),
                    2.0 / 3.0,
                ),
                if (std.meta.eql(p[2], p[3])) p[3] else mix(p[2], p[3], 2.0 / 3.0),
                p[3],
                self.color,
            ),
        },
    };
}

pub fn convertToCubic(self: *EdgeSegment) void {
    if (self.segment != .quadratic_bezier) @panic("This function is only supported on quadratic beziers");
    const p = self.segment.quadratic_bezier;
    self.* = createCubic(
        p[0],
        mix(p[0], p[1], 2.0 / 3.0),
        mix(p[1], p[2], 1.0 / 3.0),
        p[2],
        self.color,
    );
}

pub fn deconverge(self: *EdgeSegment, param: u32, vector: Vec2) void {
    switch (self.segment) {
        .linear => @panic("Deconverging an edge is only supported on quadratic and cubic beziers"),
        .cubic_bezier => {},
        .quadratic_bezier => self.convertToCubic(),
    }

    const p = self.segment.cubic_bezier;
    switch (param) {
        0 => self.segment.cubic_bezier[1] = p[1] + v2(math.length(p[1] - p[0])) * vector,
        1 => self.segment.cubic_bezier[2] = p[2] + v2(math.length(p[2] - p[3])) * vector,
        else => @panic("Unsupported operation"),
    }
}
