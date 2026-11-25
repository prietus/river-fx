// SPDX-FileCopyrightText: © 2026 Carlos Prieto Ortiz
// SPDX-License-Identifier: GPL-3.0-only

//! river-fx-v1: effects the window manager may ask for on windows.

const Fx = @This();

const std = @import("std");
const math = std.math;
const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;

const server = &@import("main.zig").server;

const Window = @import("Window.zig");

const log = std.log.scoped(.wm);

global: *wl.Global,

pub fn init(fx: *Fx) !void {
    fx.* = .{
        .global = try wl.Global.create(server.wl_server, river.FxV1, 2, *Fx, fx, bind),
    };
}

pub fn deinit(fx: *Fx) void {
    fx.global.destroy();
}

fn bind(client: *wl.Client, _: *Fx, version: u32, id: u32) void {
    const object = river.FxV1.create(client, version, id) catch {
        client.postNoMemory();
        log.err("out of memory", .{});
        return;
    };
    object.setHandler(?*anyopaque, handleRequest, null, null);
}

/// The window behind a river_window_v1 object, unless it is inert (closed).
fn windowFrom(window_v1: *river.WindowV1) ?*Window {
    const data = window_v1.getUserData() orelse return null;
    return @ptrCast(@alignCast(data));
}

fn handleRequest(
    object: *river.FxV1,
    request: river.FxV1.Request,
    _: ?*anyopaque,
) void {
    switch (request) {
        .destroy => object.destroy(),
        .set_opacity => |args| {
            if (!server.wm.ensureRendering()) return;
            const window = windowFrom(args.window) orelse return;
            // f32 cannot represent all u32 values exactly: divide as f64 first.
            window.rendering_requested.opacity =
                @floatCast(@as(f64, @floatFromInt(args.opacity)) / math.maxInt(u32));
        },
        .set_blur => |args| {
            if (!server.wm.ensureRendering()) return;
            const window = windowFrom(args.window) orelse return;
            window.rendering_requested.blur =
                @floatCast(@as(f64, @floatFromInt(args.strength)) / math.maxInt(u32));
        },
        .set_shadow => |args| {
            if (!server.wm.ensureRendering()) return;
            const window = windowFrom(args.window) orelse return;
            var color: [4]f32 = undefined;
            inline for (.{ args.r, args.g, args.b, args.a }, 0..) |component, i| {
                color[i] = @floatCast(@as(f64, @floatFromInt(component)) / math.maxInt(u32));
            }
            window.rendering_requested.shadow = .{
                .radius = @intCast(@min(args.radius, 1024)),
                .x = math.clamp(args.x, -1024, 1024),
                .y = math.clamp(args.y, -1024, 1024),
                .color = color,
            };
        },
        .set_close_fade => |args| {
            if (!server.wm.ensureRendering()) return;
            const window = windowFrom(args.window) orelse return;
            // Not in rendering_requested: that is reset when the window
            // closes, which is when this is needed.
            window.close_fade_ms = @min(args.duration, 5000);
        },
        .set_corner_radius => |args| {
            if (!server.wm.ensureRendering()) return;
            const window = windowFrom(args.window) orelse return;
            window.rendering_requested.corner_radius = @intCast(@min(args.radius, math.maxInt(u16)));
        },
    }
}
