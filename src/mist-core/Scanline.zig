const std = @import("std");

const math = @import("math.zig");

const Scanline = @This();

pub const Intersection = struct {
    x: f64,
    dir: i32,

    pub fn lessThan(_: void, a: Intersection, b: Intersection) bool {
        return a.x < b.x;
    }
};

pub const FillRule = enum {
    non_zero,
    odd,
    positive,
    negative,
};

intersections: std.ArrayList(Intersection) = .empty,
last_index: u32 = 0,

pub fn interpretFillRule(intersections: i32, fill_rule: FillRule) bool {
    return switch (fill_rule) {
        .non_zero => intersections != 0,
        .odd => @mod(intersections, 2) == 1,
        .positive => intersections > 0,
        .negative => intersections < 0,
    };
}

pub fn overlap(a: Scanline, b: Scanline, x_from: f64, x_to: f64, fill_rule: FillRule) f64 {
    var total: f64 = 0.0;
    var a_inside = false;
    var b_inside = false;
    var ai: usize = 0;
    var bi: usize = 0;
    var ax = if (a.intersections.items.len != 0) a.intersections.items[ai].x else x_to;
    var bx = if (b.intersections.items.len != 0) b.intersections.items[bi].x else x_to;
    while (ax < x_from or bx < x_from) {
        const x_next = @min(ax, bx);
        if (ax == x_next and ai < a.intersections.items.len) {
            a_inside = interpretFillRule(a.intersections.items[ai].dir, fill_rule);
            ai += 1;
            ax = if (ai < a.intersections.items.len) a.intersections.items[ai].x else x_to;
        }
        if (bx == x_next and bi < b.intersections.items.len) {
            b_inside = interpretFillRule(b.intersections.items[bi].dir, fill_rule);
            bi += 1;
            bx = if (bi < b.intersections.items.len) b.intersections.items[bi].x else x_to;
        }
    }
    var x = x_from;
    while (ax < x_to or bx < x_to) {
        const x_next = @min(ax, bx);
        if (a_inside == b_inside) total += x_next - x;
        if (ax == x_next and ai < a.intersections.items.len) {
            a_inside = interpretFillRule(a.intersections.items[ai].dir, fill_rule);
            ai += 1;
            ax = if (ai < a.intersections.items.len) a.intersections.items[ai].x else x_to;
        }
        if (bx == x_next and bi < b.intersections.items.len) {
            b_inside = interpretFillRule(b.intersections.items[bi].dir, fill_rule);
            bi += 1;
            bx = if (bi < b.intersections.items.len) b.intersections.items[bi].x else x_to;
        }
        x = x_next;
    }
    if (a_inside == b_inside) total += x_to - x;
    return total;
}

pub fn countIntersections(self: *Scanline, x: f64) i32 {
    const index = self.moveTo(x) orelse return 0;
    return @intCast(index + 1);
}

pub fn sumIntersections(self: *Scanline, x: f64) i32 {
    const index = self.moveTo(x);
    if (index) |i| return self.intersections.items[i].dir;
    return 0;
}

pub fn filled(self: *Scanline, x: f64, fill_rule: FillRule) bool {
    return interpretFillRule(self.sumIntersections(x), fill_rule);
}

pub fn preprocess(self: *Scanline) void {
    self.last_index = 0;
    if (self.intersections.items.len == 0) return;
    std.sort.pdq(Intersection, self.intersections.items, {}, Intersection.lessThan);
    var total_direction: i32 = 0;
    for (self.intersections.items) |*intersection| {
        total_direction += intersection.dir;
        intersection.dir = total_direction;
    }
}

pub fn moveTo(self: *Scanline, x: f64) ?u32 {
    if (self.intersections.items.len == 0) return null;

    var index = self.last_index;
    if (x < self.intersections.items[index].x) {
        if (index == 0) {
            self.last_index = 0;
            return null;
        }
        index -= 1;

        while (x < self.intersections.items[index].x) {
            if (index == 0) {
                self.last_index = 0;
                return null;
            }
            index -= 1;
        }
    } else while (index < self.intersections.items.len - 1 and x >= self.intersections.items[index + 1].x)
        index += 1;

    self.last_index = index;
    return index;
}
