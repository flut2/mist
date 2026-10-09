const std = @import("std");

const EdgeSegment = @import("EdgeSegment.zig");
const f64i = @import("core.zig").f64i;
const math = @import("math.zig");
const Shape = @import("Shape.zig");

const Vec2 = @Vector(2, f64);

const max_distance_recolors = 32;
const edge_distance_precision = 32;

const edge_length_precision = 4;

const ColorSelection = packed struct(u3) {
    red_green: bool = false,
    red_blue: bool = false,
    green_blue: bool = false,

    pub const all: ColorSelection = .{
        .red_green = true,
        .red_blue = true,
        .green_blue = true,
    };

    pub fn set(self: *ColorSelection, color: EdgeColor) void {
        switch (color) {
            .red_green => self.red_green = true,
            .red_blue => self.red_blue = true,
            .green_blue => self.green_blue = true,
            else => {},
        }
    }
};

pub const EdgeColor = enum(u8) {
    none = 0,
    red = 1,
    green = 2,
    blue = 3,
    red_green = 4,
    red_blue = 5,
    green_blue = 6,
    all = 7,

    pub fn init(rng: *std.Random.DefaultPrng) EdgeColor {
        const two_ch: [3]EdgeColor = .{ .red_green, .red_blue, .green_blue };
        return two_ch[@intCast(rng.next() % two_ch.len)];
    }

    fn cmyWithExcls(excl_1: EdgeColor, excl_2: EdgeColor) EdgeColor {
        const T = EdgeColor;
        const cmy_tuple = .{ T.red_green, T.red_blue, T.green_blue };

        var validation: [2]bool = @splat(false);
        for (cmy_tuple) |c| {
            if (c == excl_1) validation[0] = true;
            if (c == excl_2) validation[1] = true;
        }
        if (!std.meta.eql(validation, @splat(true)))
            @compileError("You must provide CMY exclusion values");

        for (cmy_tuple) |c| if (c != excl_1 and c != excl_2)
            return c;
    }

    fn colorSwitchTargets(self: EdgeColor) [2]EdgeColor {
        return switch (self) {
            .red_green => .{ .green_blue, .red_blue },
            .red_blue => .{ .red_green, .green_blue },
            .green_blue => .{ .red_blue, .red_green },
            else => @compileError("Switching is only allowed on two-channel edge colors"),
        };
    }

    pub fn change(self: *EdgeColor, banned: EdgeColor) void {
        switch (self.*) {
            inline .red_green, .red_blue, .green_blue => |c| switch (banned) {
                inline .red_green, .red_blue, .green_blue => |bc| if (comptime c != bc) {
                    self.* = comptime cmyWithExcls(c, bc);
                    return;
                },
                else => unreachable,
            },
            else => unreachable,
        }
    }

    pub fn random(self: *EdgeColor, rng: *std.Random.DefaultPrng) void {
        switch (self.*) {
            inline .red_green, .red_blue, .green_blue => |c| {
                const switch_targets = comptime colorSwitchTargets(c);
                self.* = switch_targets[@intCast(rng.next() % switch_targets.len)];
            },
            else => unreachable,
        }
    }

    pub fn hasChannel(self: EdgeColor, target_ch: EdgeColor) bool {
        return switch (target_ch) {
            .red => self == .all or self == .red_green or self == .red_blue or self == .red,
            .green => self == .all or self == .red_green or self == .green_blue or self == .green,
            .blue => self == .all or self == .red_blue or self == .green_blue or self == .blue,
            else => @panic("This function requires a single channel target"),
        };
    }
};

fn isCorner(a: Vec2, b: Vec2, cross_threshold: f64) bool {
    return math.dot(a, b) <= 0 or @abs(math.cross(a, b)) > cross_threshold;
}

fn findCorners(allocator: std.mem.Allocator, contour: *const Shape.Contour, corners: *std.ArrayList(u32), cross_threshold: f64) !void {
    corners.clearRetainingCapacity();
    var prev_dir = math.normal(contour.edges.getLast().direction(1), true);
    for (contour.edges.items, 0..) |edge, i| {
        const edge_dir = math.normal(edge.direction(0), true);
        if (isCorner(prev_dir, edge_dir, cross_threshold))
            try corners.append(allocator, @intCast(i));

        prev_dir = math.normal(edge.direction(1), true);
    }
}

fn symmetricalTrichotomy(pos: usize, n: usize) i32 {
    const ip: i32 = @intCast(pos);
    const in: i32 = @intCast(n);
    return @divFloor(3 * ip + 1, in) - 1;
}

fn estimateEdgeLength(edge: *const EdgeSegment) f64 {
    var len: f64 = 0;
    var previous = edge.point(0);
    for (1..edge_length_precision) |i| {
        const current = edge.point(f64i(i) / @as(comptime_float, edge_length_precision));
        len += math.length(current - previous);
        previous = current;
    }
    return len;
}

pub fn colorSimple(
    allocator: std.mem.Allocator,
    rng_seed: u64,
    shape: *Shape,
    angle_threshold: f64,
) !void {
    const cross_threshold = @sin(angle_threshold);
    var rng: std.Random.DefaultPrng = .init(rng_seed);
    var color: EdgeColor = .init(&rng);

    var corners: std.ArrayList(u32) = .empty;
    defer corners.deinit(allocator);

    for (shape.contours.items) |*contour| {
        if (contour.edges.items.len == 0)
            continue;

        try findCorners(allocator, contour, &corners, cross_threshold);

        const corners_len = corners.items.len;
        switch (corners_len) {
            0 => {
                color.random(&rng);
                for (contour.edges.items) |*edge| edge.color = color;
            },
            1 => {
                const colors: [3]EdgeColor = .{ .init(&rng), .all, .init(&rng) };
                const corner = corners.items[0];
                const corner_idx = 3 * corner;
                const edges_len = contour.edges.items.len;
                if (edges_len >= 3) {
                    for (contour.edges.items, 0..) |*edge, i|
                        edge.color = colors[@intCast(1 + symmetricalTrichotomy(i, edges_len))];
                } else if (edges_len >= 1) {
                    var parts: [7]EdgeSegment = @splat(.{ .color = .none, .segment = undefined });

                    @memcpy(parts[corner_idx..][0..3], &contour.edges.items[0].splitInThirds());
                    if (edges_len >= 2) {
                        @memcpy(parts[3 - corner_idx ..][0..3], &contour.edges.items[1].splitInThirds());
                        for (0..6) |i| parts[i].color = colors[i / 2];
                    } else for (0..3) |i| parts[i].color = colors[i];

                    contour.edges.clearRetainingCapacity();
                    var i: usize = 0;
                    while (parts[i].color != .none) : (i += 1)
                        try contour.edges.append(allocator, parts[i]);
                }
            },
            else => {
                const start = corners.items[0];
                const edges_len = contour.edges.items.len;

                color.random(&rng);
                const initial_color = color;

                var spline: u32 = 0;
                for (0..edges_len) |i| {
                    const idx = (start + i) % edges_len;
                    if (spline + 1 < corners_len and corners.items[spline + 1] == idx) {
                        spline += 1;
                        if (spline == corners_len - 1)
                            color.change(initial_color)
                        else
                            color.random(&rng);
                    }
                    contour.edges.items[idx].color = color;
                }
            },
        }
    }
}

pub fn colorInkTrap(
    allocator: std.mem.Allocator,
    rng_seed: u64,
    shape: *Shape,
    angle_threshold: f64,
) !void {
    const cross_threshold = @sin(angle_threshold);
    var rng: std.Random.DefaultPrng = .init(rng_seed);
    var color: EdgeColor = .init(&rng);

    var corners: std.ArrayList(struct {
        idx: u32,
        est_prev_edge_len: f64,
        minor: bool = false,
        color: EdgeColor = .none,
    }) = .empty;
    defer corners.deinit(allocator);

    for (shape.contours.items) |*contour| {
        if (contour.edges.items.len == 0) continue;

        var spline_length: f64 = 0.0;

        corners.clearRetainingCapacity();
        var prev_dir = math.normal(contour.edges.getLast().direction(1), true);
        for (contour.edges.items, 0..) |edge, i| {
            const edge_dir = math.normal(edge.direction(0), true);
            if (isCorner(prev_dir, edge_dir, cross_threshold)) {
                try corners.append(allocator, .{
                    .idx = @intCast(i),
                    .est_prev_edge_len = spline_length,
                });
                spline_length = 0;
            }

            spline_length += estimateEdgeLength(&edge);
            prev_dir = math.normal(edge.direction(1), true);
        }

        const corners_len = corners.items.len;
        switch (corners_len) {
            0 => {
                color.random(&rng);
                for (contour.edges.items) |*edge| edge.color = color;
            },
            1 => {
                const colors: [3]EdgeColor = .{ .init(&rng), .all, .init(&rng) };
                const corner = corners.items[0].idx;
                const corner_idx = 3 * corner;
                const edges_len = contour.edges.items.len;
                if (edges_len >= 3) {
                    for (contour.edges.items, 0..) |*edge, i|
                        edge.color = colors[@intCast(1 + symmetricalTrichotomy(i, edges_len))];
                } else if (edges_len >= 1) {
                    var parts: [7]EdgeSegment = @splat(.{ .color = .none, .segment = undefined });

                    @memcpy(parts[corner_idx..][0..3], &contour.edges.items[0].splitInThirds());
                    if (edges_len >= 2) {
                        @memcpy(parts[3 - corner_idx ..][0..3], &contour.edges.items[1].splitInThirds());
                        for (0..6) |i| parts[i].color = colors[i / 2];
                    } else for (0..3) |i| parts[i].color = colors[i];

                    contour.edges.clearRetainingCapacity();
                    var i: usize = 0;
                    while (parts[i].color != .none) : (i += 1)
                        try contour.edges.append(allocator, parts[i]);
                }
            },
            else => {
                var significant_corners = corners_len;
                if (corners_len > 3) {
                    corners.items[0].est_prev_edge_len += spline_length;
                    for (0..corners_len) |i| {
                        const current = corners.items[i].est_prev_edge_len;
                        const next = corners.items[(i + 1) % corners_len].est_prev_edge_len;
                        if (current > next and
                            next < corners.items[(i + 2) % corners_len].est_prev_edge_len)
                        {
                            corners.items[i].minor = true;
                            significant_corners -= 1;
                        }
                    }
                }

                var initial_color: EdgeColor = .none;
                for (0..corners_len) |i|
                    if (!corners.items[i].minor) {
                        significant_corners -= 1;
                        if (significant_corners == 0 or initial_color == .none)
                            color.random(&rng)
                        else
                            color.change(initial_color);
                        corners.items[i].color = color;
                        if (initial_color == .none)
                            initial_color = color;
                    };

                for (0..corners_len) |i| {
                    if (!corners.items[i].minor) {
                        color = corners.items[i].color;
                        continue;
                    }

                    color.change(corners.items[(i + 1) % corners_len].color);
                    corners.items[i].color = color;
                }

                const start = corners.items[0].idx;
                const edges_len = contour.edges.items.len;

                color = corners.items[0].color;

                var spline: u32 = 0;
                for (0..edges_len) |i| {
                    const idx = (start + i) % edges_len;
                    if (spline + 1 < corners_len and corners.items[spline + 1].idx == idx) {
                        spline += 1;
                        color = corners.items[spline].color;
                    }
                    contour.edges.items[idx].color = color;
                }
            },
        }
    }
}

fn splineToSplineDistance(
    edge_segments: []const *EdgeSegment,
    a_from: u32,
    a_to: u32,
    b_from: u32,
    b_to: u32,
) f64 {
    var min_dist = std.math.floatMax(f64);
    for (a_from..a_to) |a_idx| for (b_from..b_to) |b_idx| {
        const a = edge_segments[a_idx];
        const b = edge_segments[b_idx];

        const eql = std.meta.eql;
        if (eql(a.point(0), b.point(0)) or
            eql(a.point(0), b.point(1)) or
            eql(a.point(1), b.point(0)) or
            eql(a.point(1), b.point(1)))
            return 0.0;

        min_dist = @min(min_dist, math.length(b.point(0) - a.point(0)));
        for (0..edge_distance_precision) |i| {
            const t = f64i(i) / @as(comptime_float, edge_distance_precision);
            const ab_dist, _ = a.signedDistance(b.point(t));
            const ba_dist, _ = b.signedDistance(a.point(t));
            min_dist = @min(min_dist, @abs(ab_dist.distance));
            min_dist = @min(min_dist, @abs(ba_dist.distance));
        }
    };

    return min_dist;
}

fn colorGraph(colors: []EdgeColor, edge_matrix: []const []const bool, rng: *std.Random.DefaultPrng) void {
    for (colors, 0..) |*color, i| {
        var banned_colors: ColorSelection = .{};

        for (0..i) |j| if (edge_matrix[i][j])
            banned_colors.set(colors[j]);

        switch (banned_colors) {
            .{} => {
                const rem_colors: [3]EdgeColor = .{ .red_green, .red_blue, .green_blue };
                color.* = rem_colors[@intCast(rng.next() % rem_colors.len)];
            },
            .{ .red_green = true } => {
                const rem_colors: [2]EdgeColor = .{ .red_blue, .green_blue };
                color.* = rem_colors[@intCast(rng.next() % rem_colors.len)];
            },
            .{ .red_blue = true } => {
                const rem_colors: [2]EdgeColor = .{ .red_green, .green_blue };
                color.* = rem_colors[@intCast(rng.next() % rem_colors.len)];
            },
            .{ .green_blue = true } => {
                const rem_colors: [2]EdgeColor = .{ .red_green, .red_blue };
                color.* = rem_colors[@intCast(rng.next() % rem_colors.len)];
            },
            .{ .red_green = true, .red_blue = true } => color.* = .green_blue,
            .{ .red_green = true, .green_blue = true } => color.* = .red_blue,
            .{ .red_blue = true, .green_blue = true } => color.* = .red_green,
            .all => color.* = .red_green,
        }
    }
}

fn vertexPossibleColors(colors: []EdgeColor, edge_vec: []const bool) ?EdgeColor {
    var banned_colors: ColorSelection = .{};
    for (colors, edge_vec) |color, edge|
        if (edge) banned_colors.set(color);

    return switch (banned_colors) {
        .{} => .red_green,
        .{ .red_green = true } => .red_blue,
        .{ .red_blue = true } => .green_blue,
        .{ .green_blue = true } => .red_green,
        .{ .red_green = true, .red_blue = true } => .green_blue,
        .{ .red_green = true, .green_blue = true } => .red_blue,
        .{ .red_blue = true, .green_blue = true } => .red_green,
        .all => null,
    };
}

fn uncolorSameNeighbors(
    allocator: std.mem.Allocator,
    uncolored: *std.Deque(u32),
    colors: []EdgeColor,
    edge_matrix: []const []const bool,
    idx: usize,
) !void {
    const size = colors.len;
    for (idx + 1..size) |i|
        if (edge_matrix[idx][i] and colors[i] == colors[idx]) {
            colors[i] = .none;
            try uncolored.pushFront(allocator, @intCast(i));
        };

    for (0..idx) |i|
        if (edge_matrix[idx][i] and colors[i] == colors[idx]) {
            colors[i] = .none;
            try uncolored.pushFront(allocator, @intCast(i));
        };
}

fn addEdge(allocator: std.mem.Allocator, front_buf: []EdgeColor, back_buf: []EdgeColor, edge_matrix: [][]bool, a: usize, b: usize) !bool {
    edge_matrix[a][b] = true;
    edge_matrix[b][a] = true;

    if (front_buf[a] != front_buf[b])
        return true;

    if (vertexPossibleColors(front_buf, edge_matrix[b])) |color| {
        front_buf[b] = color;
        return true;
    }

    @memcpy(back_buf, front_buf);

    back_buf[b] = switch (back_buf[a]) {
        .red_green => .red_blue,
        .red_blue => .green_blue,
        .green_blue => .red_green,
        else => unreachable,
    };

    var uncolored: std.Deque(u32) = .empty;
    defer uncolored.deinit(allocator);

    try uncolorSameNeighbors(allocator, &uncolored, back_buf, edge_matrix, b);

    var step: u16 = 0;
    while (step < max_distance_recolors) {
        const i = uncolored.popFront() orelse break;
        if (vertexPossibleColors(back_buf, edge_matrix[i])) |color| {
            back_buf[i] = color;
            continue;
        }

        step += 1;
        back_buf[i] = switch (step % 3) {
            0 => .red_green,
            1 => .red_blue,
            2 => .green_blue,
            else => unreachable,
        };

        while (edge_matrix[i][a] and
            back_buf[i] == back_buf[a]) : (step += 1)
            back_buf[i] = switch (step % 3) {
                0 => .red_green,
                1 => .red_blue,
                2 => .green_blue,
                else => unreachable,
            };

        try uncolorSameNeighbors(allocator, &uncolored, back_buf, edge_matrix, i);
    }

    if (uncolored.len > 0) {
        edge_matrix[a][b] = false;
        edge_matrix[b][a] = false;
        return false;
    }

    @memcpy(front_buf, back_buf);
    return true;
}

pub fn colorDistance(
    allocator: std.mem.Allocator,
    rng_seed: u64,
    shape: *Shape,
    angle_threshold: f64,
) !void {
    const cross_threshold = @sin(angle_threshold);
    var rng: std.Random.DefaultPrng = .init(rng_seed);

    var edge_segments: std.ArrayList(*EdgeSegment) = .empty;
    defer edge_segments.deinit(allocator);

    var spline_starts: std.ArrayList(u32) = .empty;
    defer spline_starts.deinit(allocator);

    var corners: std.ArrayList(u32) = .empty;
    defer corners.deinit(allocator);

    for (shape.contours.items) |*contour| {
        if (contour.edges.items.len == 0)
            continue;

        try findCorners(allocator, contour, &corners, cross_threshold);
        try spline_starts.append(allocator, @intCast(edge_segments.items.len));

        const corners_len = corners.items.len;
        switch (corners_len) {
            0 => {
                for (contour.edges.items) |*edge|
                    try edge_segments.append(allocator, edge);
            },
            1 => {
                const corner = corners.items[0];
                const edges_len = contour.edges.items.len;
                if (edges_len >= 3) {
                    for (0..edges_len) |i| {
                        if (i == edges_len / 2)
                            try spline_starts.append(allocator, @intCast(edge_segments.items.len));

                        const edge = &contour.edges.items[(corner + i) % edges_len];
                        if (symmetricalTrichotomy(i, edges_len) != 0)
                            try edge_segments.append(allocator, edge)
                        else
                            edge.color = .all;
                    }
                } else if (edges_len >= 1) {
                    var parts: [7]EdgeSegment = @splat(.{ .color = .none, .segment = undefined });
                    var append: [7]bool = @splat(false);

                    const corner_idx = 3 * corner;
                    @memcpy(parts[corner_idx..][0..3], &contour.edges.items[0].splitInThirds());
                    if (edges_len >= 2) {
                        @memcpy(parts[3 - corner_idx ..][0..3], &contour.edges.items[1].splitInThirds());
                        append[0] = true;
                        append[1] = true;
                        parts[2].color = .all;
                        parts[3].color = .all;
                        try spline_starts.append(allocator, @intCast(edge_segments.items.len + 2));
                        append[4] = true;
                        append[5] = true;
                    } else {
                        append[0] = true;
                        parts[1].color = .all;
                        try spline_starts.append(allocator, @intCast(edge_segments.items.len + 1));
                        append[2] = true;
                    }

                    contour.edges.clearRetainingCapacity();
                    var i: usize = 0;
                    while (parts[i].color != .none) : (i += 1) {
                        try contour.edges.append(allocator, parts[i]);
                        if (append[i])
                            try edge_segments.append(allocator, &contour.edges.items[contour.edges.items.len - 1]);
                    }
                }
            },
            else => {
                const start = corners.items[0];
                const edges_len = contour.edges.items.len;

                var spline: u32 = 0;
                for (0..edges_len) |i| {
                    const idx = (start + i) % edges_len;
                    if (spline + 1 < corners_len and corners.items[spline + 1] == idx) {
                        try spline_starts.append(allocator, @intCast(edge_segments.items.len));
                        spline += 1;
                    }
                    try edge_segments.append(allocator, &contour.edges.items[idx]);
                }
            },
        }
    }
    try spline_starts.append(allocator, @intCast(edge_segments.items.len));

    const spline_count = spline_starts.items.len - 1;
    if (spline_count == 0) return;

    const distance_matrix = try allocator.alloc(f64, spline_count * spline_count);
    defer allocator.free(distance_matrix);
    @memset(distance_matrix, 0.0);

    for (0..spline_count) |i| {
        distance_matrix[i * spline_count + i] = -1.0;
        for (i + 1..spline_count) |j| {
            const dist = splineToSplineDistance(
                edge_segments.items,
                spline_starts.items[i],
                spline_starts.items[i + 1],
                spline_starts.items[j],
                spline_starts.items[j + 1],
            );
            distance_matrix[i * spline_count + j] = dist;
            distance_matrix[j * spline_count + i] = dist;
        }
    }

    const graph_edge_distances = try allocator.alloc(u32, spline_count * (spline_count - 1) / 2);
    defer allocator.free(graph_edge_distances);
    @memset(graph_edge_distances, 0);

    var graph_idx: usize = 0;
    for (0..spline_count) |i| for (i + 1..spline_count) |j| {
        graph_edge_distances[graph_idx] = @intCast(i * spline_count + j);
        graph_idx += 1;
    };

    const SortCtx = struct {
        distance_matrix: []const f64,

        pub fn lessThan(self: @This(), a: u32, b: u32) bool {
            return self.distance_matrix[a] < self.distance_matrix[b];
        }
    };
    std.sort.pdq(
        u32,
        graph_edge_distances[0..graph_idx],
        SortCtx{ .distance_matrix = distance_matrix },
        SortCtx.lessThan,
    );

    const edge_matrix_buf = try allocator.alloc(bool, spline_count * spline_count);
    defer allocator.free(edge_matrix_buf);
    @memset(edge_matrix_buf, false);

    const edge_matrix = try allocator.alloc([]bool, spline_count);
    defer allocator.free(edge_matrix);
    for (edge_matrix, 0..) |*vec, i|
        vec.* = edge_matrix_buf[i * spline_count ..][0..spline_count];

    var next_edge: usize = 0;
    while (next_edge < graph_idx) : (next_edge += 1) {
        const dist_idx = graph_edge_distances[next_edge];
        if (distance_matrix[dist_idx] != 0.0) break;

        const row = dist_idx / spline_count;
        const col = dist_idx % spline_count;
        edge_matrix[row][col] = true;
        edge_matrix[col][row] = true;
    }

    const colors = try allocator.alloc(EdgeColor, spline_count * 2);
    defer allocator.free(colors);
    @memset(colors, .none);

    const front_buf = colors[0..spline_count];
    const back_buf = colors[spline_count..][0..spline_count];

    colorGraph(front_buf, edge_matrix, &rng);
    while (next_edge < graph_idx) : (next_edge += 1) {
        const dist_idx = graph_edge_distances[next_edge];
        const row = dist_idx / spline_count;
        const col = dist_idx % spline_count;
        _ = try addEdge(
            allocator,
            front_buf,
            back_buf,
            edge_matrix,
            row,
            col,
        );
    }

    var spline: usize = 0;
    for (spline_starts.items[0]..edge_segments.items.len) |i| {
        if (spline_starts.items[spline + 1] == i)
            spline += 1;

        const new_color = front_buf[spline];
        if (new_color != .none) edge_segments.items[i].color = new_color;
    }
}
