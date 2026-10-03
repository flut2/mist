const std = @import("std");

pub fn Bitmap(comptime T: type) type {
    return struct {
        w: u16,
        h: u16,
        channels: u8,
        pixels: []T,

        pub fn create(
            comptime default_value: T,
            allocator: std.mem.Allocator,
            w: u16,
            h: u16,
            channels: u8,
        ) !@This() {
            const pixels = try allocator.alloc(T, @as(usize, w) * @as(usize, h) * @as(usize, channels));
            @memset(pixels, default_value);

            return .{
                .w = w,
                .h = h,
                .channels = channels,
                .pixels = pixels,
            };
        }

        pub fn destroy(self: *const @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.pixels);
        }

        pub fn at(self: *const @This(), comptime inv_y: bool, x: u16, y: u16, len: u8) []T {
            const mod_y = if (inv_y) self.h - y - 1 else y;
            const idx = mod_y * self.w * self.channels + x * self.channels;
            return self.pixels[idx..][0..len];
        }
    };
}
