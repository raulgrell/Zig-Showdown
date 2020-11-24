//! This state provides a menu to join games.
//! Tasks:
//! - Allow the user to input a server IP
//! - Listen to UDP broadcasts and display a LAN game list
//! - optional: Load a list of games from a central "game list server"

const std = @import("std");
const Renderer = @import("../Renderer.zig");
const Resources = @import("../Resources.zig");
const Color = @import("../renderer/Color.zig");

const Self = @This();

resources: *Resources,
font_id: Resources.FontPool.ResourceName,

pub fn init(resources: *Resources) !Self {
    return Self{
        .resources = resources,
        .font_id = try resources.fonts.getName("/assets/font.tex"),
    };
}

pub fn render(self: *Self, renderer: *Renderer, render_target: Renderer.RenderTarget, total_time: f32, delta_time: f32) !void {
    var pass = renderer.createUiPass();
    defer pass.deinit();

    const font = try self.resources.fonts.get(self.font_id, Resources.usage.debug_draw);
    try pass.drawString(
        10,
        @intCast(isize, renderer.screenSize().height - font.glyph_size.height - 10),
        font,
        Color.fromRgb(1, 1, 1),
        "Join Game",
    );

    renderer.clear(render_target, Color.fromRgb(1, 0, 1));
    try renderer.submit(render_target, pass);
}
