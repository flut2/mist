const std = @import("std");

const EdgeSegment = @import("EdgeSegment.zig");
const math = @import("math.zig");
const Scanline = @import("Scanline.zig");

const Vec2 = @Vector(2, f64);

const deconverge_overshoot = 1.11111111111111111;
const corner_dot_epsilon = 0.000001;

const Shape = @This();

pub const Contour = struct {
    edges: std.ArrayList(EdgeSegment) = .empty,

    pub fn reverse(self: *Contour) void {
        std.mem.reverse(EdgeSegment, self.edges.items);
        for (self.edges.items) |*edge| edge.reverse();
    }
};

pub const Bounds = struct {
    left: f64,
    right: f64,
    bottom: f64,
    top: f64,

    pub const whole_frame: Bounds = .{
        .left = 0.0,
        .right = 1.0,
        .bottom = 0.0,
        .top = 1.0,
    };

    pub fn bound(self: *Bounds, x: f64, y: f64) void {
        self.left = @min(self.left, x);
        self.bottom = @min(self.bottom, y);
        self.right = @max(self.right, x);
        self.top = @max(self.top, y);
    }
};

contours: std.ArrayList(Contour) = .empty,

pub fn deinit(self: *Shape, allocator: std.mem.Allocator) void {
    for (self.contours.items) |*contour|
        contour.edges.deinit(allocator);
    self.contours.deinit(allocator);
}

pub fn validate(self: Shape) bool {
    for (self.contours.items) |contour| if (contour.edges.items.len > 0) {
        var corner = contour.edges.getLast().point(1);
        for (contour.edges.items) |edge| {
            const p0 = edge.point(0);
            if (!std.meta.eql(p0, corner)) return false;
            corner = edge.point(1);
        }
    };

    return true;
}

pub fn normalize(self: *Shape, allocator: std.mem.Allocator) !void {
    for (self.contours.items) |*contour| {
        if (contour.edges.items.len == 1) {
            const parts = contour.edges.items[0].splitInThirds();
            contour.edges.clearRetainingCapacity();
            try contour.edges.appendSlice(allocator, &parts);
        } else {
            var prev_edge = &contour.edges.items[contour.edges.items.len - 1];
            for (contour.edges.items) |*edge| {
                const prev_dir = math.normal(prev_edge.direction(1), true);
                const cur_dir = math.normal(edge.direction(0), true);
                if (math.dot(prev_dir, cur_dir) < corner_dot_epsilon - 1) {
                    const factor = deconverge_overshoot *
                        @sqrt(1 - (corner_dot_epsilon - 1) * (corner_dot_epsilon - 1)) / (corner_dot_epsilon - 1);
                    var axis = math.normal(cur_dir - prev_dir, true) * math.v2(factor);
                    if (convergentCurveOrdering(prev_edge, edge))
                        axis = -axis;

                    const ortho = math.ortho(axis);
                    prev_edge.deconverge(1, ortho);
                    edge.deconverge(0, -ortho);
                }

                prev_edge = edge;
            }
        }
    }
}

pub fn calcBounds(self: Shape) Bounds {
    var bounds: Bounds = .{
        .left = std.math.floatMax(f64),
        .bottom = std.math.floatMax(f64),
        .right = std.math.floatMin(f64),
        .top = std.math.floatMin(f64),
    };
    for (self.contours.items) |contour|
        for (contour.edges.items) |edge|
            edge.bound(&bounds);
    return bounds;
}

pub fn scanline(self: Shape, line: *Scanline, y: f64, allocator: std.mem.Allocator) !void {
    line.intersections.clearRetainingCapacity();
    defer line.preprocess();

    var x: [3]f64 = @splat(0.0);
    var dy: [3]i32 = @splat(0);
    for (self.contours.items) |contour| for (contour.edges.items) |edge| {
        const len = edge.scanlineIntersections(&x, &dy, y);
        for (0..len) |i| try line.intersections.append(allocator, .{ .x = x[i], .dir = dy[i] });
    };
}

pub fn orientContours(self: *Shape, allocator: std.mem.Allocator) !void {
    const Intersection = struct {
        x: f64,
        direction: i32,
        contour_index: i32,

        pub fn lessThan(_: void, a: @This(), b: @This()) bool {
            return a.x < b.x;
        }
    };

    const ratio = 0.5 * (@sqrt(5.0) - 1);
    var intersections: std.ArrayList(Intersection) = .empty;
    defer intersections.deinit(allocator);
    var orientations: std.ArrayList(i32) = .empty;
    defer orientations.deinit(allocator);
    const contours_len = self.contours.items.len;
    try orientations.ensureTotalCapacity(allocator, contours_len);
    try orientations.appendNTimes(allocator, 0, contours_len);
    for (0..contours_len) |i| {
        if (orientations.items[i] == 0 or self.contours.items[i].edges.items.len == 0) continue;
        const y0 = self.contours.items[i].edges.items[0].point(0)[1];
        var y1 = y0;
        for (self.contours.items[i].edges.items) |edge| y1 = edge.point(1)[1];
        for (self.contours.items[i].edges.items) |edge| y1 = edge.point(ratio)[1];
        const y = math.mix(y0, y1, ratio);
        var x: [3]f64 = @splat(0.0);
        var dy: [3]i32 = @splat(0);
        for (0..self.contours.items.len) |j|
            for (self.contours.items[j].edges.items) |edge|
                for (0..edge.scanlineIntersections(&x, &dy, y)) |k|
                    try intersections.append(allocator, .{ .x = x[k], .direction = dy[k], .contour_index = @intCast(j) });

        if (intersections.items.len == 0) continue;
        std.sort.pdq(Intersection, intersections.items, {}, Intersection.lessThan);
        for (1..intersections.items.len) |j| if (intersections.items[j].x == intersections.items[j - 1].x) {
            intersections.items[j].direction = 0;
            intersections.items[j - 1].direction = 0;
        };
        for (0..intersections.items.len) |j| if (intersections.items[j].direction != 0) {
            orientations.items[@intCast(intersections.items[j].contour_index)] +=
                2 * ((@as(i32, @intCast(j)) & 1) ^ @intFromBool(intersections.items[j].direction > 0)) - 1;
        };
        intersections.clearRetainingCapacity();
    }

    for (self.contours.items, orientations.items) |*contour, orientation|
        if (orientation < 0) contour.reverse();
}

fn simplifyDegenerateCurve(ctrl: []Vec2, len: *u8) void {
    const eql = std.meta.eql;
    switch (len.*) {
        3 => if ((eql(ctrl[1], ctrl[0]) or eql(ctrl[1], ctrl[3])) and
            (eql(ctrl[2], ctrl[0]) or eql(ctrl[2], ctrl[3])))
        {
            ctrl[1] = ctrl[3];
            len.* = 1;
        },
        2 => if (eql(ctrl[1], ctrl[0]) or eql(ctrl[1], ctrl[2])) {
            ctrl[1] = ctrl[2];
            len.* = 1;
        },
        1 => {
            if (eql(ctrl[0], ctrl[1])) len.* = 0;
        },
        else => {},
    }
}

fn convergentCurveOrdering(a: *const EdgeSegment, b: *const EdgeSegment) bool {
    const eql = std.meta.eql;

    var a_pts: [4]Vec2 = undefined;
    var a_len: u8 = 0;
    switch (a.segment) {
        inline else => |pts| {
            // these exclude zero
            a_len = pts.len - 1;
            @memcpy(a_pts[0..pts.len], &pts);
        },
    }

    var b_pts: [4]Vec2 = undefined;
    var b_len: u8 = 0;
    switch (b.segment) {
        inline else => |pts| {
            b_len = pts.len - 1;
            @memcpy(b_pts[0..pts.len], &pts);
        },
    }

    if (!eql(a_pts[0], b_pts[0]))
        return false;

    simplifyDegenerateCurve(&a_pts, &a_len);
    simplifyDegenerateCurve(&b_pts, &b_len);

    var a1: Vec2 = a_pts[a_len - 1] - b_pts[0];
    var b1: Vec2 = b_pts[1] - b_pts[0];
    var a2: Vec2 = if (a_len >= 2) a_pts[a_len - 2] - a_pts[a_len - 1] - a1 else @splat(0.0);
    var b2: Vec2 = if (b_len >= 2) b_pts[2] - b_pts[1] - b1 else @splat(0.0);
    var a3: Vec2 = @splat(0.0);
    var b3: Vec2 = @splat(0.0);
    if (a_len >= 3) {
        a3 = a_pts[a_len - 3] - a_pts[a_len - 2] - (a_pts[a_len - 2] - a_pts[a_len - 1]) - a2;
        a2 *= math.v2(3.0);
    }

    if (b_len >= 3) {
        b3 = b_pts[3] - b_pts[2] - (b_pts[2] - b_pts[1]) - b2;
        b2 *= math.v2(3.0);
    }

    a1 *= math.v2(a_len);
    b1 *= math.v2(b_len);

    const a_filled = !eql(a1, @splat(0.0));
    const b_filled = !eql(b1, @splat(0.0));
    if (a_filled and b_filled) {
        const as = math.length(a1);
        const bs = math.length(b1);

        inline for (.{
            as * math.cross(a1, b2) + bs * math.cross(a2, b1),
            as * as * math.cross(a1, b3) + as * bs * math.cross(a2, b2) + bs * bs * math.cross(a3, b1),
            as * math.cross(a2, b3) + bs * math.cross(a3, b2),
            math.cross(a3, b3),
        }) |derivative| {
            if (derivative < 0.0) return true;
            if (derivative > 0.0) return false;
        }
    }

    var flip = false;
    if (a_filled) {
        std.mem.swap(Vec2, &a1, &b1);
        std.mem.swap(Vec2, &a2, &b2);
        std.mem.swap(Vec2, &a3, &b3);
        flip = true;
    }

    if (b_filled) {
        inline for (.{
            math.cross(a3, b1),
            math.cross(a2, b2),
            math.cross(a3, b2),
            math.cross(a2, b3),
            math.cross(a3, b3),
        }) |derivative| {
            if (derivative < 0.0) return !flip;
            if (derivative > 0.0) return flip;
        }
    }

    inline for (.{
        @sqrt(math.length(a2)) * math.cross(a2, b3) + @sqrt(math.length(b2)) * math.cross(a3, b2),
        math.cross(a3, b3),
    }) |derivative| {
        if (derivative < 0.0) return true;
        if (derivative > 0.0) return false;
    }

    return false;
}
