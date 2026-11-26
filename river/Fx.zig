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
const scenefx = @import("scenefx.zig");

const log = std.log.scoped(.wm);

global: *wl.Global,

/// set_popup_blur
popup_blur: f32 = 0,
popup_corner_radius: u16 = 0,

/// set_layer_effects: what the wm asked for, by namespace.
layer_rules: [max_layer_rules]LayerRule = undefined,
layer_rules_len: usize = 0,

const max_layer_rules = 32;

pub const LayerRule = struct {
    namespace_buf: [64]u8,
    namespace_len: usize,
    corner_radius: u16 = 0,
    blur: f32 = 0,
    shadow: Window.Shadow = .{},
    /// set_layer_fade
    fade_ms: u32 = 0,

    fn empty(rule: *const LayerRule) bool {
        return rule.corner_radius == 0 and rule.blur == 0 and rule.shadow.color[3] == 0 and rule.fade_ms == 0;
    }

    pub fn namespace(rule: *const LayerRule) []const u8 {
        return rule.namespace_buf[0..rule.namespace_len];
    }
};

pub fn layerRule(fx: *const Fx, namespace: []const u8) ?*const LayerRule {
    for (fx.layer_rules[0..fx.layer_rules_len]) |*rule| {
        if (std.mem.eql(u8, rule.namespace(), namespace)) return rule;
    }
    return null;
}

/// Replace the rule of a namespace, except for what `keep` says to take
/// from the one it already has.
fn setLayerRule(fx: *Fx, wanted: LayerRule, keep: enum { fade, effects }) void {
    var new = wanted;
    if (fx.layerRule(wanted.namespace())) |old| switch (keep) {
        .fade => new.fade_ms = old.fade_ms,
        .effects => {
            new = old.*;
            new.fade_ms = wanted.fade_ms;
        },
    };
    const empty = new.empty();
    for (fx.layer_rules[0..fx.layer_rules_len], 0..) |*rule, i| {
        if (!std.mem.eql(u8, rule.namespace(), new.namespace())) continue;
        if (empty) {
            fx.layer_rules[i] = fx.layer_rules[fx.layer_rules_len - 1];
            fx.layer_rules_len -= 1;
        } else {
            rule.* = new;
        }
        return;
    }
    if (empty) return;
    if (fx.layer_rules_len == max_layer_rules) {
        log.err("too many layer effects, ignoring those of '{s}'", .{new.namespace()});
        return;
    }
    fx.layer_rules[fx.layer_rules_len] = new;
    fx.layer_rules_len += 1;
}

fn applyLayerRules() void {
    {
        var it = server.om.outputs.iterator(.forward);
        while (it.next()) |output| output.syncWallpaperBlur();
    }
    var it = server.layer_shell.surfaces.iterator();
    while (it.next()) |layer_surface| layer_surface.applyEffects();
}

/// Whether some layer surface may want the shared blur of the wallpaper.
pub fn wallpaperBlurWanted(fx: *const Fx) bool {
    for (fx.layer_rules[0..fx.layer_rules_len]) |*rule| {
        if (rule.blur > 0) return true;
    }
    return false;
}

fn setBlurData(data: scenefx.BlurData) void {
    scenefx.sceneSetBlurData(server.scene.wlr_scene, data);
    var it = server.om.outputs.iterator(.forward);
    while (it.next()) |output| output.markWallpaperBlurDirty();
}

pub fn init(fx: *Fx) !void {
    fx.* = .{
        .global = try wl.Global.create(server.wl_server, river.FxV1, 5, *Fx, fx, bind),
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
    object.setHandler(?*anyopaque, handleRequest, handleDestroy, null);
}

fn handleDestroy(_: *river.FxV1, _: ?*anyopaque) void {
    // The wm is gone (or restarting): layer surfaces go back to plain.
    server.fx.layer_rules_len = 0;
    server.fx.popup_blur = 0;
    applyLayerRules();
    setBlurData(scenefx.BlurData.default());
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
        .set_layer_effects => |args| {
            const namespace = std.mem.span(args.namespace);
            var rule: LayerRule = .{
                .namespace_buf = undefined,
                .namespace_len = @min(namespace.len, 64),
                .corner_radius = @intCast(@min(args.corner_radius, 1024)),
                .blur = @floatCast(@as(f64, @floatFromInt(args.blur)) / math.maxInt(u32)),
                .shadow = .{
                    .radius = @intCast(@min(args.shadow_radius, 1024)),
                    .x = math.clamp(args.shadow_x, -1024, 1024),
                    .y = math.clamp(args.shadow_y, -1024, 1024),
                    .color = undefined,
                },
            };
            @memcpy(rule.namespace_buf[0..rule.namespace_len], namespace[0..rule.namespace_len]);
            inline for (.{ args.r, args.g, args.b, args.a }, 0..) |component, i| {
                rule.shadow.color[i] = @floatCast(@as(f64, @floatFromInt(component)) / math.maxInt(u32));
            }
            server.fx.setLayerRule(rule, .fade);
            applyLayerRules();
        },
        .set_layer_fade => |args| {
            const namespace = std.mem.span(args.namespace);
            var rule: LayerRule = .{
                .namespace_buf = undefined,
                .namespace_len = @min(namespace.len, 64),
                .fade_ms = @min(args.duration, 5000),
            };
            @memcpy(rule.namespace_buf[0..rule.namespace_len], namespace[0..rule.namespace_len]);
            server.fx.setLayerRule(rule, .effects);
        },
        .set_popup_blur => |args| {
            server.fx.popup_blur = @floatCast(@as(f64, @floatFromInt(args.strength)) / math.maxInt(u32));
            server.fx.popup_corner_radius = @intCast(@min(args.corner_radius, 1024));
        },
        .set_dim => |args| {
            if (!server.wm.ensureRendering()) return;
            const window = windowFrom(args.window) orelse return;
            window.rendering_requested.dim =
                @floatCast(@as(f64, @floatFromInt(args.strength)) / math.maxInt(u32));
        },
        .set_close_scale => |args| {
            if (!server.wm.ensureRendering()) return;
            const window = windowFrom(args.window) orelse return;
            window.close_scale = @floatCast(@as(f64, @floatFromInt(args.scale)) / math.maxInt(u32));
        },
        .set_resize_fade => |args| {
            if (!server.wm.ensureRendering()) return;
            const window = windowFrom(args.window) orelse return;
            window.resize_fade_ms = @min(args.duration, 2000);
        },
        .set_blur_parameters => |args| {
            setBlurData(.{
                .num_passes = @intCast(math.clamp(args.passes, 1, 10)),
                .radius = @floatFromInt(math.clamp(args.radius, 1, 20)),
                .noise = @floatCast(math.clamp(args.noise.toDouble(), 0, 1)),
                .brightness = @floatCast(math.clamp(args.brightness.toDouble(), 0, 2)),
                .contrast = @floatCast(math.clamp(args.contrast.toDouble(), 0, 2)),
                .saturation = @floatCast(math.clamp(args.saturation.toDouble(), 0, 2)),
            });
        },
        .set_corner_radius => |args| {
            if (!server.wm.ensureRendering()) return;
            const window = windowFrom(args.window) orelse return;
            window.rendering_requested.corner_radius = @intCast(@min(args.radius, math.maxInt(u16)));
        },
    }
}
