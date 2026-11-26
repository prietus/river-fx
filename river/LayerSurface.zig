// SPDX-FileCopyrightText: © 2025 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const LayerSurface = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const zwlr = @import("wayland").server.zwlr;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Ghost = @import("Ghost.zig");
const Output = @import("Output.zig");
const scenefx = @import("scenefx.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const SlotMap = @import("slotmap").SlotMap;
const XdgPopup = @import("XdgPopup.zig");

const log = std.log.scoped(.wm);

/// Only packed in order to make == work.
pub const Ref = packed struct {
    key: SlotMap(*LayerSurface).Key,

    pub fn get(ref: Ref) ?*LayerSurface {
        return server.layer_shell.surfaces.get(ref.key);
    }
};

ref: Ref,

wlr_layer_surface: *wlr.LayerSurfaceV1,
scene_layer_surface: *wlr.SceneLayerSurfaceV1,
popup_tree: *wlr.SceneTree,
configurable: bool = false,

/// river-fx-v1 set_layer_effects: created when a rule first asks for them.
blur: ?*scenefx.SceneBlur = null,
blur_mask: ?*wlr.SceneBuffer = null,
shadow: ?*scenefx.SceneShadow = null,
/// river-fx-v1 set_layer_fade: how far the surface has faded in (1: done).
fade: f32 = 1,
fade_applied: f32 = 1,
fade_elapsed_ms: u32 = 0,
fade_ms: u32 = 0,
fade_timer: ?*wl.EventSource = null,

destroy: wl.Listener(*wlr.LayerSurfaceV1) = wl.Listener(*wlr.LayerSurfaceV1).init(handleDestroy),
map: wl.Listener(void) = wl.Listener(void).init(handleMap),
unmap: wl.Listener(void) = wl.Listener(void).init(handleUnmap),
commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(handleCommit),
new_popup: wl.Listener(*wlr.XdgPopup) = wl.Listener(*wlr.XdgPopup).init(handleNewPopup),

pub fn create(wlr_layer_surface: *wlr.LayerSurfaceV1) error{OutOfMemory}!void {
    const layer_surface = try util.gpa.create(LayerSurface);
    errdefer util.gpa.destroy(layer_surface);

    const key = try server.layer_shell.surfaces.put(util.gpa, layer_surface);
    errdefer server.layer_shell.surfaces.remove(key);

    const layer_tree = server.scene.layerSurfaceTree(wlr_layer_surface.current.layer);

    layer_surface.* = .{
        .ref = .{ .key = key },
        .wlr_layer_surface = wlr_layer_surface,
        .scene_layer_surface = try layer_tree.createSceneLayerSurfaceV1(wlr_layer_surface),
        .popup_tree = try server.scene.layers.popups.createSceneTree(),
    };

    try SceneNodeData.attach(&layer_surface.scene_layer_surface.tree.node, .{ .layer_surface = layer_surface });
    try SceneNodeData.attach(&layer_surface.popup_tree.node, .{ .layer_surface = layer_surface });

    wlr_layer_surface.surface.data = &layer_surface.scene_layer_surface.tree.node;

    wlr_layer_surface.events.destroy.add(&layer_surface.destroy);
    wlr_layer_surface.surface.events.map.add(&layer_surface.map);
    wlr_layer_surface.surface.events.unmap.add(&layer_surface.unmap);
    wlr_layer_surface.surface.events.commit.add(&layer_surface.commit);
    wlr_layer_surface.events.new_popup.add(&layer_surface.new_popup);
}

/// river-fx-v1 set_layer_effects: give the surface the effects of the rule
/// for its namespace, or none.
pub fn applyEffects(layer_surface: *LayerSurface) void {
    const wlr_layer_surface = layer_surface.wlr_layer_surface;
    const tree = layer_surface.scene_layer_surface.tree;
    const rule = server.fx.layerRule(std.mem.span(wlr_layer_surface.namespace));
    const width = wlr_layer_surface.surface.current.width;
    const height = wlr_layer_surface.surface.current.height;
    const sized = width > 0 and height > 0;
    const corners: scenefx.CornerRadii = .all(if (rule) |r| r.corner_radius else 0);

    // The buffer of the surface itself (not of a subsurface): it is what
    // gets the rounded corners and what masks the blur.
    var main: MainBuffer = .{ .surface = wlr_layer_surface.surface };
    tree.node.forEachBuffer(*MainBuffer, mainBufferIter, &main);
    if (main.buffer) |buffer| scenefx.bufferSetCornerRadii(buffer, corners);

    var fade = layer_surface.fade;
    if (fade != layer_surface.fade_applied or fade < 1) {
        tree.node.forEachBuffer(*f32, opacityIter, &fade);
        layer_surface.fade_applied = fade;
    }

    const wants_blur = sized and rule != null and rule.?.blur > 0;
    if (wants_blur and layer_surface.blur == null) {
        if (scenefx.SceneBlur.create(tree, width, height)) |blur| {
            blur.node.lowerToBottom();
            layer_surface.blur = blur;
        } else |_| {
            log.err("out of memory", .{});
        }
    }
    if (layer_surface.blur) |blur| {
        if (wants_blur) {
            blur.setSize(width, height);
            blur.setCornerRadii(corners);
            blur.setStrength(rule.?.blur * fade);
            // With only the wallpaper behind it, the blurred copy of the
            // wallpaper that the output keeps will do.
            const state = &wlr_layer_surface.current;
            blur.setOnlyBlurBottomLayer(state.layer == .bottom or
                (state.layer == .top and state.exclusive_zone > 0));
            if (layer_surface.blur_mask != main.buffer) {
                blur.setTransparencyMaskSource(main.buffer);
                layer_surface.blur_mask = main.buffer;
            }
        }
        blur.node.setEnabled(wants_blur);
    }

    const wants_shadow = sized and rule != null and rule.?.shadow.color[3] > 0;
    if (wants_shadow and layer_surface.shadow == null) {
        if (scenefx.SceneShadow.create(tree, &rule.?.shadow.color)) |shadow| {
            layer_surface.shadow = shadow;
        } else |_| {
            log.err("out of memory", .{});
        }
    }
    if (layer_surface.shadow) |shadow| {
        if (wants_shadow) {
            const sh = &rule.?.shadow;
            const r: i32 = sh.radius;
            // Under the blur and the surface.
            shadow.node.lowerToBottom();
            shadow.node.setPosition(-r + sh.x, -r + sh.y);
            shadow.setSize(width + 2 * r, height + 2 * r);
            shadow.setCornerRadius(rule.?.corner_radius);
            shadow.setBlurSigma(@floatFromInt(r));
            shadow.setColor(&.{ sh.color[0] * fade, sh.color[1] * fade, sh.color[2] * fade, sh.color[3] * fade });
            shadow.setClippedRegion(.{
                .area = .{ .x = r - sh.x, .y = r - sh.y, .width = width, .height = height },
                .corners = corners,
            });
        }
        shadow.node.setEnabled(wants_shadow);
    }
}

fn opacityIter(buffer: *wlr.SceneBuffer, _: c_int, _: c_int, opacity: *f32) void {
    scenefx.bufferSetOpacity(buffer, opacity.*);
}

const fade_step_ms = 16;

/// river-fx-v1 set_layer_fade: the surface appeared, fade it in.
fn startFadeIn(layer_surface: *LayerSurface) void {
    const rule = server.fx.layerRule(std.mem.span(layer_surface.wlr_layer_surface.namespace)) orelse return;
    if (rule.fade_ms == 0) return;
    if (layer_surface.fade_timer == null) {
        layer_surface.fade_timer = server.wl_server.getEventLoop().addTimer(*LayerSurface, handleFadeTimer, layer_surface) catch return;
    }
    layer_surface.fade = 0;
    layer_surface.fade_elapsed_ms = 0;
    layer_surface.fade_ms = rule.fade_ms;
    layer_surface.fade_timer.?.timerUpdate(fade_step_ms) catch {
        layer_surface.fade = 1;
    };
}

fn handleFadeTimer(layer_surface: *LayerSurface) c_int {
    layer_surface.fade_elapsed_ms += fade_step_ms;
    if (layer_surface.fade_elapsed_ms >= layer_surface.fade_ms) {
        layer_surface.fade = 1;
    } else {
        const t = @as(f32, @floatFromInt(layer_surface.fade_elapsed_ms)) / @as(f32, @floatFromInt(layer_surface.fade_ms));
        // ease out
        layer_surface.fade = 1 - (1 - t) * (1 - t);
        layer_surface.fade_timer.?.timerUpdate(fade_step_ms) catch {
            layer_surface.fade = 1;
        };
    }
    if (layer_surface.wlr_layer_surface.surface.mapped) layer_surface.applyEffects();
    return 0;
}

/// river-fx-v1 set_layer_fade: the surface is going away, leave a copy of
/// what it shows fading out in its place.
fn startFadeOut(layer_surface: *LayerSurface) void {
    const rule = server.fx.layerRule(std.mem.span(layer_surface.wlr_layer_surface.namespace)) orelse return;
    if (rule.fade_ms == 0) return;
    const tree = layer_surface.scene_layer_surface.tree;
    const parent = tree.node.parent orelse return;
    const ghost = Ghost.create(parent, .{ .opacity = layer_surface.fade, .duration_ms = rule.fade_ms }) orelse return;
    ghost.tree.node.placeAbove(&tree.node);
    ghost.copyFrom(tree);
    ghost.start();
}

const MainBuffer = struct {
    surface: *wlr.Surface,
    buffer: ?*wlr.SceneBuffer = null,
};

fn mainBufferIter(buffer: *wlr.SceneBuffer, _: c_int, _: c_int, main: *MainBuffer) void {
    if (wlr.SceneSurface.tryFromBuffer(buffer)) |scene_surface| {
        if (scene_surface.surface == main.surface) main.buffer = buffer;
    }
}

pub fn destroyPopups(layer_surface: *LayerSurface) void {
    var it = layer_surface.wlr_layer_surface.popups.safeIterator(.forward);
    while (it.next()) |wlr_xdg_popup| wlr_xdg_popup.destroy();
}

fn handleDestroy(listener: *wl.Listener(*wlr.LayerSurfaceV1), _: *wlr.LayerSurfaceV1) void {
    const layer_surface: *LayerSurface = @fieldParentPtr("destroy", listener);

    log.debug("layer surface '{s}' destroyed", .{layer_surface.wlr_layer_surface.namespace});

    if (layer_surface.fade_timer) |timer| timer.remove();

    layer_surface.destroy.link.remove();
    layer_surface.map.link.remove();
    layer_surface.unmap.link.remove();
    layer_surface.commit.link.remove();
    layer_surface.new_popup.link.remove();

    layer_surface.destroyPopups();

    layer_surface.popup_tree.node.destroy();

    // The wlr_surface may outlive the wlr_layer_surface so we must clean up the user data.
    layer_surface.wlr_layer_surface.surface.data = null;

    server.layer_shell.surfaces.remove(layer_surface.ref.key);
    util.gpa.destroy(layer_surface);
}

fn handleMap(listener: *wl.Listener(void)) void {
    const layer_surface: *LayerSurface = @fieldParentPtr("map", listener);
    const wlr_layer_surface = layer_surface.wlr_layer_surface;

    log.debug("layer surface '{s}' mapped", .{wlr_layer_surface.namespace});

    layer_surface.startFadeIn();
    layer_surface.applyEffects();

    if (wlr_layer_surface.current.keyboard_interactive == .on_demand) {
        var it = server.input_manager.seats.iterator(.forward);
        while (it.next()) |seat| {
            if (seat.layer_shell.scheduled.focus != .exclusive) {
                seat.layer_shell.scheduled.focus = .{ .non_exclusive = layer_surface.ref };
            }
        }
    }

    // Beware: it is possible for arrange() to destroy this LayerSurface!
    const output: *Output = @ptrCast(@alignCast(layer_surface.wlr_layer_surface.output.?.data));
    output.layer_shell.arrange();
    server.layer_shell.checkExclusiveFocus();
    server.wm.dirtyWindowing();
}

fn handleUnmap(listener: *wl.Listener(void)) void {
    const layer_surface: *LayerSurface = @fieldParentPtr("unmap", listener);

    log.debug("layer surface '{s}' unmapped", .{layer_surface.wlr_layer_surface.namespace});
    layer_surface.configurable = false;
    layer_surface.startFadeOut();

    {
        var it = server.input_manager.seats.iterator(.forward);
        while (it.next()) |seat| {
            if (seat.focused == .layer_surface and seat.focused.layer_surface == layer_surface) {
                seat.focus(.none);
            }
            if (seat.layer_shell.scheduled.focus == .non_exclusive and
                seat.layer_shell.scheduled.focus.non_exclusive == layer_surface.ref)
            {
                seat.layer_shell.scheduled.focus = .none;
            }
        }
    }

    // Beware: it is possible for arrange() to destroy this LayerSurface!
    const output: *Output = @ptrCast(@alignCast(layer_surface.wlr_layer_surface.output.?.data));
    output.layer_shell.arrange();
    server.layer_shell.checkExclusiveFocus();
    server.wm.dirtyWindowing();
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const layer_surface: *LayerSurface = @fieldParentPtr("commit", listener);
    const wlr_layer_surface = layer_surface.wlr_layer_surface;

    assert(wlr_layer_surface.output != null);

    if (wlr_layer_surface.initial_commit) layer_surface.configurable = true;

    // river-fx-v1: its size may have changed.
    if (wlr_layer_surface.surface.mapped) layer_surface.applyEffects();
    // river-fx-v1: a new frame of the wallpaper.
    if (wlr_layer_surface.current.layer == .background) {
        const wallpaper_output: *Output = @ptrCast(@alignCast(wlr_layer_surface.output.?.data));
        wallpaper_output.markWallpaperBlurDirty();
    }

    // If the layer was changed, move the LayerSurface to the proper tree.
    if (wlr_layer_surface.current.committed.layer) {
        const tree = server.scene.layerSurfaceTree(wlr_layer_surface.current.layer);
        layer_surface.scene_layer_surface.tree.node.reparent(tree);
    }

    if (wlr_layer_surface.initial_commit or
        @as(u32, @bitCast(wlr_layer_surface.current.committed)) != 0)
    {
        // Beware: it is possible for arrange() to destroy this LayerSurface!
        const output: *Output = @ptrCast(@alignCast(layer_surface.wlr_layer_surface.output.?.data));
        output.layer_shell.arrange();
        server.layer_shell.checkExclusiveFocus();
        server.wm.dirtyWindowing();
    }
}

fn handleNewPopup(listener: *wl.Listener(*wlr.XdgPopup), wlr_xdg_popup: *wlr.XdgPopup) void {
    const layer_surface: *LayerSurface = @fieldParentPtr("new_popup", listener);

    XdgPopup.create(
        wlr_xdg_popup,
        layer_surface.popup_tree,
        null,
    ) catch {
        wlr_xdg_popup.resource.postNoMemory();
        return;
    };
}
