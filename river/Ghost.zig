// SPDX-FileCopyrightText: © 2026 Carlos Prieto Ortiz
// SPDX-License-Identifier: GPL-3.0-only

//! Content that is no longer anybody's, fading out where it was: the last
//! frame of a window or a layer surface that went away (set_close_fade,
//! set_layer_fade), or the previous one of a window that changed size
//! (set_resize_fade). A ghost owns a scene tree of plain buffers and frees
//! itself when it is done.

const Ghost = @This();

const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");
const scenefx = @import("scenefx.zig");

const log = std.log.scoped(.wm);

const step_ms = 16;
const max_items = 16;

pub const Options = struct {
    /// What the buffers start at.
    opacity: f32 = 1,
    duration_ms: u32,
    /// Size at the end, as a fraction: the buffers shrink towards the
    /// centre of (width, height).
    scale: f32 = 1,
    width: c_int = 0,
    height: c_int = 0,
};

const Item = struct {
    buffer: *wlr.SceneBuffer,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
};

tree: *wlr.SceneTree,
timer: *wl.EventSource,
options: Options,
elapsed_ms: u32 = 0,
items: [max_items]Item = undefined,
items_len: usize = 0,
/// Set to null when the ghost is gone, if somebody keeps a pointer to it.
owner: ?*?*Ghost = null,

/// An empty ghost: fill its tree with buffers (moveFrom, copyFrom) and
/// start() it.
pub fn create(parent: *wlr.SceneTree, options: Options) ?*Ghost {
    const ghost = util.gpa.create(Ghost) catch return null;
    const tree = parent.createSceneTree() catch {
        util.gpa.destroy(ghost);
        return null;
    };
    const timer = server.wl_server.getEventLoop().addTimer(*Ghost, handleTimer, ghost) catch {
        tree.node.destroy();
        util.gpa.destroy(ghost);
        return null;
    };
    ghost.* = .{ .tree = tree, .timer = timer, .options = options };
    return ghost;
}

/// Take the children of a tree of saved buffers.
pub fn moveFrom(ghost: *Ghost, saved: *wlr.SceneTree) void {
    var it = saved.children.safeIterator(.forward);
    while (it.next()) |node| node.reparent(ghost.tree);
}

/// Copy what a tree shows, or showed before it was disabled (a surface
/// that was just unmapped is). The copies are placed as if the ghost's tree were at the same place as the
/// parent of `source`.
pub fn copyFrom(ghost: *Ghost, source: *wlr.SceneTree) void {
    ghost.copyTree(source, source.node.x, source.node.y);
}

fn copyTree(ghost: *Ghost, tree: *wlr.SceneTree, x: c_int, y: c_int) void {
    var it = tree.children.iterator(.forward);
    while (it.next()) |node| {
        // Not skipping disabled nodes: wlroots disables the tree of a
        // surface when it is unmapped, and that is when this is called.
        // What is really gone has no buffer any more.
        if (@intFromEnum(node.type) == @intFromEnum(wlr.SceneNode.Type.tree)) {
            ghost.copyTree(wlr.SceneTree.fromNode(node), x + node.x, y + node.y);
        } else if (@intFromEnum(node.type) == @intFromEnum(wlr.SceneNode.Type.buffer)) {
            const buffer = wlr.SceneBuffer.fromNode(node);
            const wlr_buffer = buffer.buffer orelse continue;
            const copy = ghost.tree.createSceneBuffer(wlr_buffer) catch continue;
            copy.node.setPosition(x + node.x, y + node.y);
            copy.setDestSize(buffer.dst_width, buffer.dst_height);
            copy.setSourceBox(&buffer.src_box);
            copy.setTransform(buffer.transform);
        }
    }
}

pub fn start(ghost: *Ghost) void {
    var it = ghost.tree.children.iterator(.forward);
    while (it.next()) |node| {
        if (@intFromEnum(node.type) != @intFromEnum(wlr.SceneNode.Type.buffer)) continue;
        const buffer = wlr.SceneBuffer.fromNode(node);
        buffer.point_accepts_input = noInput;
        scenefx.bufferSetOpacity(buffer, ghost.options.opacity);
        if (ghost.items_len < max_items and buffer.dst_width > 0 and buffer.dst_height > 0) {
            ghost.items[ghost.items_len] = .{
                .buffer = buffer,
                .x = node.x,
                .y = node.y,
                .width = buffer.dst_width,
                .height = buffer.dst_height,
            };
            ghost.items_len += 1;
        }
    }
    ghost.timer.timerUpdate(step_ms) catch ghost.destroy();
}

pub fn destroy(ghost: *Ghost) void {
    if (ghost.owner) |owner| owner.* = null;
    ghost.timer.remove();
    ghost.tree.node.destroy();
    util.gpa.destroy(ghost);
}

fn handleTimer(ghost: *Ghost) c_int {
    ghost.elapsed_ms += step_ms;
    if (ghost.elapsed_ms >= ghost.options.duration_ms) {
        ghost.destroy();
        return 0;
    }
    const t = @as(f32, @floatFromInt(ghost.elapsed_ms)) / @as(f32, @floatFromInt(ghost.options.duration_ms));
    const left = (1 - t) * (1 - t);
    const opacity = ghost.options.opacity * left;
    {
        var it = ghost.tree.children.iterator(.forward);
        while (it.next()) |node| {
            if (@intFromEnum(node.type) != @intFromEnum(wlr.SceneNode.Type.buffer)) continue;
            scenefx.bufferSetOpacity(wlr.SceneBuffer.fromNode(node), opacity);
        }
    }
    if (ghost.options.scale < 1) {
        const s = ghost.options.scale + (1 - ghost.options.scale) * left;
        const cx = @as(f32, @floatFromInt(ghost.options.width)) / 2;
        const cy = @as(f32, @floatFromInt(ghost.options.height)) / 2;
        for (ghost.items[0..ghost.items_len]) |*item| {
            item.buffer.node.setPosition(
                @intFromFloat(cx + (@as(f32, @floatFromInt(item.x)) - cx) * s),
                @intFromFloat(cy + (@as(f32, @floatFromInt(item.y)) - cy) * s),
            );
            item.buffer.setDestSize(
                @max(1, @as(c_int, @intFromFloat(@as(f32, @floatFromInt(item.width)) * s))),
                @max(1, @as(c_int, @intFromFloat(@as(f32, @floatFromInt(item.height)) * s))),
            );
        }
    }
    ghost.timer.timerUpdate(step_ms) catch ghost.destroy();
    return 0;
}

fn noInput(_: *wlr.SceneBuffer, _: *f64, _: *f64) callconv(.c) bool {
    return false;
}
