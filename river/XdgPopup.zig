// SPDX-FileCopyrightText: © 2023 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const XdgPopup = @This();

const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const scenefx = @import("scenefx.zig");
const server = &@import("main.zig").server;
const util = @import("util.zig");

const Output = @import("Output.zig");
const SceneNodeData = @import("SceneNodeData.zig");

const log = std.log.scoped(.xdg_popup);

wlr_popup: *wlr.XdgPopup,
tree: *wlr.SceneTree,
/// river-fx-v1 set_popup_blur
blur: ?*scenefx.SceneBlur = null,
blur_mask: ?*wlr.SceneBuffer = null,
capture_tree: ?*wlr.SceneTree = null,

destroy: wl.Listener(void) = .init(handleDestroy),
commit: wl.Listener(*wlr.Surface) = .init(handleCommit),
new_popup: wl.Listener(*wlr.XdgPopup) = .init(handleNewPopup),
reposition: wl.Listener(void) = .init(handleReposition),

// TODO check if popup is set_reactive and reposition on parent movement.
pub fn create(
    wlr_popup: *wlr.XdgPopup,
    parent: *wlr.SceneTree,
    capture_parent: ?*wlr.SceneTree,
) error{OutOfMemory}!void {
    const xdg_popup = try util.gpa.create(XdgPopup);
    errdefer util.gpa.destroy(xdg_popup);

    xdg_popup.* = .{
        .wlr_popup = wlr_popup,
        .tree = try parent.createSceneXdgSurface(wlr_popup.base),
    };
    if (capture_parent) |p| {
        xdg_popup.capture_tree = try p.createSceneXdgSurface(wlr_popup.base);
    }

    wlr_popup.events.destroy.add(&xdg_popup.destroy);
    wlr_popup.base.surface.events.commit.add(&xdg_popup.commit);
    wlr_popup.base.events.new_popup.add(&xdg_popup.new_popup);
    wlr_popup.events.reposition.add(&xdg_popup.reposition);
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const xdg_popup: *XdgPopup = @fieldParentPtr("destroy", listener);

    xdg_popup.destroy.link.remove();
    xdg_popup.commit.link.remove();
    xdg_popup.new_popup.link.remove();
    xdg_popup.reposition.link.remove();

    util.gpa.destroy(xdg_popup);
}

/// river-fx-v1 set_popup_blur: blur behind the geometry of the popup,
/// where the popup itself draws something.
fn applyBlur(xdg_popup: *XdgPopup) void {
    const base = xdg_popup.wlr_popup.base;
    const geometry = base.geometry;
    const wanted = server.fx.popup_blur > 0 and base.surface.mapped and
        geometry.width > 0 and geometry.height > 0;
    if (wanted and xdg_popup.blur == null) {
        const blur = scenefx.SceneBlur.create(xdg_popup.tree, geometry.width, geometry.height) catch return;
        blur.node.lowerToBottom();
        xdg_popup.blur = blur;
    }
    const blur = xdg_popup.blur orelse return;
    if (wanted) {
        var main: MainBuffer = .{ .surface = base.surface };
        xdg_popup.tree.node.forEachBuffer(*MainBuffer, mainBufferIter, &main);
        blur.node.setPosition(geometry.x, geometry.y);
        blur.setSize(geometry.width, geometry.height);
        blur.setCornerRadii(.all(server.fx.popup_corner_radius));
        blur.setStrength(server.fx.popup_blur);
        if (xdg_popup.blur_mask != main.buffer) {
            blur.setTransparencyMaskSource(main.buffer);
            xdg_popup.blur_mask = main.buffer;
        }
    }
    blur.node.setEnabled(wanted);
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

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const xdg_popup: *XdgPopup = @fieldParentPtr("commit", listener);

    xdg_popup.applyBlur();

    if (xdg_popup.wlr_popup.base.initial_commit) {
        handleReposition(&xdg_popup.reposition);
    }
}

fn handleNewPopup(listener: *wl.Listener(*wlr.XdgPopup), wlr_popup: *wlr.XdgPopup) void {
    const xdg_popup: *XdgPopup = @fieldParentPtr("new_popup", listener);

    XdgPopup.create(
        wlr_popup,
        xdg_popup.tree,
        xdg_popup.capture_tree,
    ) catch {
        wlr_popup.resource.postNoMemory();
        return;
    };
}

fn handleReposition(listener: *wl.Listener(void)) void {
    const xdg_popup: *XdgPopup = @fieldParentPtr("reposition", listener);
    const wlr_popup = xdg_popup.wlr_popup;

    var parent_lx: c_int = undefined;
    var parent_ly: c_int = undefined;
    _ = xdg_popup.tree.node.parent.?.node.coords(&parent_lx, &parent_ly);

    var anchor = wlr_popup.scheduled.rules.anchor_rect;
    anchor.x += parent_lx;
    anchor.y += parent_ly;
    const wlr_output = server.om.maxOverlapOutput(&anchor) orelse return;

    var constraint: wlr.Box = undefined;
    server.om.output_layout.getBox(wlr_output, &constraint);
    constraint.x -= parent_lx;
    constraint.y -= parent_ly;

    wlr_popup.scheduled.rules.unconstrainBox(&constraint, &wlr_popup.scheduled.geometry);
    _ = wlr_popup.base.scheduleConfigure();
}
