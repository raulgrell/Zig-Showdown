//! The software renderer is the reference backend
//! for rendering Zig SHOWDOWN.
//!
//! Most types are empty or NO-OPs, but documented on how they
//! are supposed to work and what their purpose is.

const std = @import("std");
const zwl = @import("zwl");
const painterz = @import("painterz");

const WindowPlatform = @import("root").WindowPlatform;

const Color = @import("../Color.zig");

const Self = @This();

const Resources = @import("../../Resources.zig");
const Renderer = @import("../../Renderer.zig");

fn toNativeColor(c: Color) zwl.Pixel {
    return zwl.Pixel{
        .r = c.r,
        .g = c.g,
        .b = c.b,
        .a = c.a,
    };
}

window: *WindowPlatform.Window,
pixbuf: ?zwl.PixelBuffer,

/// Initializes a new rendering backend instance for the given window.
pub fn init(allocator: *std.mem.Allocator, window: *WindowPlatform.Window) !Self {

    // this is required to kick-off ZWLs software rendering loop
    const pbuf = try window.mapPixels();
    try window.submitPixels(&[_]zwl.UpdateArea{
        zwl.UpdateArea{
            .x = 0,
            .y = 0,
            .w = pbuf.width,
            .h = pbuf.height,
        },
    });

    return Self{
        .window = window,
        .pixbuf = null,
    };
}

/// Destroys a previously created rendering instance.
pub fn deinit(self: *Self) void {}

/// Starts to render a new frame. This is meant as a notification
/// event to prepare a newly rendered frame.
/// Each call must be followed by draw calls and finally by a call to
/// `endFrame()`.
pub fn beginFrame(self: *Self) !void {
    std.debug.assert(self.pixbuf == null);
    self.pixbuf = try self.window.mapPixels();

    std.mem.set(u32, self.pixbuf.?.span(), 0xFFFF00FF);
}

/// Finishes the frame and pushes the resulting image to the screen.
pub fn endFrame(self: *Self) !void {
    std.debug.assert(self.pixbuf != null);
    try self.window.submitPixels(&[_]zwl.UpdateArea{
        zwl.UpdateArea{
            .x = 0,
            .y = 0,
            .w = self.pixbuf.?.width,
            .h = self.pixbuf.?.height,
        },
    });
    self.pixbuf = null;
}

fn getPixBuf(self: *Self, rt: Renderer.RenderTarget) zwl.PixelBuffer {
    return if (rt.backing_texture) |tex|
        zwl.PixelBuffer{
            .data = @ptrCast([*]u32, tex.pixels.ptr),
            .width = @intCast(u16, tex.width),
            .height = @intCast(u16, tex.height),
        }
    else
        self.pixbuf.?;
}

pub fn clear(self: *Self, rt: Renderer.RenderTarget, color: Color) void {
    std.debug.assert(self.pixbuf != null);
    const pixel_value = zwl.Pixel{
        .r = color.r,
        .g = color.g,
        .b = color.b,
        .a = color.a,
    };
    const pixbuf = self.getPixBuf(rt);

    std.mem.set(u32, pixbuf.span(), @bitCast(u32, pixel_value));
}

pub fn submitUiPass(self: *Self, render_target: Renderer.RenderTarget, pass: Renderer.UiPass) !void {
    const pixbuf = self.getPixBuf(render_target);

    for (pass.drawcalls.items) |dc| {
        switch (dc) {
            .rectangle => |rectangle| {
                @panic("TODO: not implemented yet!");
            },
            .line => |line| {
                const Context = struct {
                    target: zwl.PixelBuffer,
                    width: u8,
                };

                const Canvas = painterz.Canvas(Context, Color, struct {
                    fn setPixel(context: Context, sx: isize, sy: isize, col: Color) void {
                        const ncol = toNativeColor(col);
                        const limit = @as(isize, context.width) * @as(isize, context.width);

                        var ry: isize = -@as(isize, context.width);
                        while (ry <= @as(isize, context.width)) : (ry += 1) {
                            var rx: isize = -@as(isize, context.width);
                            while (rx <= @as(isize, context.width)) : (rx += 1) {
                                const x = sx + rx;
                                const y = sy + ry;

                                if (x < 0 or y < 0 or x >= context.target.width or y >= context.target.height)
                                    continue;
                                if (rx * rx + ry * ry > limit)
                                    continue;

                                context.target.setPixel(@intCast(u16, x), @intCast(u16, y), ncol);
                            }
                        }
                    }
                }.setPixel);

                var canvas = Canvas.init(Context{
                    .target = pixbuf,
                    .width = line.thickness,
                });

                canvas.drawLine(line.x0, line.y0, line.x1, line.y1, line.color);
            },
            .polygon => |polygon| {
                @panic("TODO: not implemented yet!");
            },
        }
    }
}

pub fn submitScenePass(self: *Self, render_target: Renderer.RenderTarget, pass: Renderer.ScenePass) !void {
    @panic("not implemented yet!");
}