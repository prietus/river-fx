// SPDX-FileCopyrightText: © 2026 Carlos Prieto Ortiz
// SPDX-License-Identifier: GPL-3.0-only

//! river-fx-v1 set_close_fade: the last content of a window that closed,
//! fading out where the window was. It belongs to no window: the Window is
//! destroyed as usual, the ghost takes its saved buffers and frees itself
//! when it is done.

const Ghost = @This();

const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");
const scenefx = @import("scenefx.zig");

const log = std.log.scoped(.wm);

const step_ms = 16;

tree: *wlr.SceneTree,
timer: *wl.EventSource,
opacity: f32,
duration_ms: u32,
elapsed_ms: u32 = 0,

/// Takes the children of `saved` (the saved buffers of a window), drawn at
/// (x, y) in the parent of `above`, right above it.
pub fn create(saved: *wlr.SceneTree, above: *wlr.SceneNode, x: c_int, y: c_int, opacity: f32, duration_ms: u32) void {
    const parent = above.parent orelse return;
    const ghost = util.gpa.create(Ghost) catch return;
    const tree = parent.createSceneTree() catch {
        util.gpa.destroy(ghost);
        return;
    };
    const timer = server.wl_server.getEventLoop().addTimer(*Ghost, handleTimer, ghost) catch {
        tree.node.destroy();
        util.gpa.destroy(ghost);
        return;
    };
    ghost.* = .{ .tree = tree, .timer = timer, .opacity = opacity, .duration_ms = duration_ms };

    tree.node.placeAbove(above);
    tree.node.setPosition(x, y);
    var it = saved.children.safeIterator(.forward);
    while (it.next()) |node| node.reparent(tree);
    tree.node.forEachBuffer(*Ghost, noInputIter, ghost);

    timer.timerUpdate(step_ms) catch ghost.destroy();
}

fn destroy(ghost: *Ghost) void {
    ghost.timer.remove();
    ghost.tree.node.destroy();
    util.gpa.destroy(ghost);
}

fn handleTimer(ghost: *Ghost) c_int {
    ghost.elapsed_ms += step_ms;
    if (ghost.elapsed_ms >= ghost.duration_ms) {
        ghost.destroy();
        return 0;
    }
    ghost.tree.node.forEachBuffer(*Ghost, fadeIter, ghost);
    ghost.timer.timerUpdate(step_ms) catch ghost.destroy();
    return 0;
}

fn fadeIter(buffer: *wlr.SceneBuffer, _: c_int, _: c_int, ghost: *Ghost) void {
    const t = @as(f32, @floatFromInt(ghost.elapsed_ms)) / @as(f32, @floatFromInt(ghost.duration_ms));
    scenefx.bufferSetOpacity(buffer, ghost.opacity * (1 - t) * (1 - t));
}

fn noInputIter(buffer: *wlr.SceneBuffer, _: c_int, _: c_int, _: *Ghost) void {
    buffer.point_accepts_input = noInput;
}

fn noInput(_: *wlr.SceneBuffer, _: *f64, _: *f64) callconv(.c) bool {
    return false;
}
