// SPDX-FileCopyrightText: © 2026 Carlos Prieto Ortiz
// SPDX-License-Identifier: GPL-3.0-only

//! The parts of SceneFX's scene API that wlroots' does not have. SceneFX
//! keeps wlroots' structs and only appends fields to them, so the
//! zig-wlroots types are used as they are.

const wlr = @import("wlroots");

pub const CornerRadii = extern struct {
    top_left: u16 = 0,
    top_right: u16 = 0,
    bottom_right: u16 = 0,
    bottom_left: u16 = 0,

    pub fn all(radius: u16) CornerRadii {
        return .{ .top_left = radius, .top_right = radius, .bottom_right = radius, .bottom_left = radius };
    }
};

pub const ClippedRegion = extern struct {
    area: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    corners: CornerRadii = .{},
};

extern fn fx_renderer_create(backend: *wlr.Backend) ?*wlr.Renderer;
/// SceneFX's scene graph only draws with its own renderer (GLES2 with the
/// shaders of the effects), not with the one wlroots would pick.
pub fn rendererCreate(backend: *wlr.Backend) !*wlr.Renderer {
    return fx_renderer_create(backend) orelse error.RendererCreateFailed;
}

extern fn wlr_scene_buffer_set_opacity(buffer: *wlr.SceneBuffer, opacity: f32) void;
pub const bufferSetOpacity = wlr_scene_buffer_set_opacity;

extern fn wlr_scene_buffer_set_corner_radii(buffer: *wlr.SceneBuffer, corners: CornerRadii) void;
pub const bufferSetCornerRadii = wlr_scene_buffer_set_corner_radii;

extern fn wlr_scene_rect_set_corner_radii(rect: *wlr.SceneRect, corners: CornerRadii) void;
pub const rectSetCornerRadii = wlr_scene_rect_set_corner_radii;

extern fn wlr_scene_rect_set_clipped_region(rect: *wlr.SceneRect, region: ClippedRegion) void;
/// The part of the rect that is not drawn (node-relative): a rect the size
/// of a window with its borders, minus the window, is a rounded border.
pub const rectSetClippedRegion = wlr_scene_rect_set_clipped_region;

/// A node that draws what is behind it, blurred. Only its first field is
/// declared: it is always used through a pointer SceneFX allocated.
pub const SceneBlur = extern struct {
    node: wlr.SceneNode,

    extern fn wlr_scene_blur_create(parent: *wlr.SceneTree, width: c_int, height: c_int) ?*SceneBlur;
    pub fn create(parent: *wlr.SceneTree, width: c_int, height: c_int) !*SceneBlur {
        return wlr_scene_blur_create(parent, width, height) orelse error.OutOfMemory;
    }

    extern fn wlr_scene_blur_set_size(blur: *SceneBlur, width: c_int, height: c_int) void;
    pub const setSize = wlr_scene_blur_set_size;

    extern fn wlr_scene_blur_set_corner_radii(blur: *SceneBlur, corners: CornerRadii) void;
    pub const setCornerRadii = wlr_scene_blur_set_corner_radii;

    extern fn wlr_scene_blur_set_strength(blur: *SceneBlur, strength: f32) void;
    pub const setStrength = wlr_scene_blur_set_strength;
};

/// A node that draws a blurred, rounded box: a shadow. `width` and `height`
/// include the blur on every side.
pub const SceneShadow = extern struct {
    node: wlr.SceneNode,

    extern fn wlr_scene_shadow_create(
        parent: *wlr.SceneTree,
        width: c_int,
        height: c_int,
        corner_radius: c_int,
        blur_sigma: f32,
        color: *const [4]f32,
    ) ?*SceneShadow;
    pub fn create(parent: *wlr.SceneTree, color: *const [4]f32) !*SceneShadow {
        return wlr_scene_shadow_create(parent, 0, 0, 0, 0, color) orelse error.OutOfMemory;
    }

    extern fn wlr_scene_shadow_set_size(shadow: *SceneShadow, width: c_int, height: c_int) void;
    pub const setSize = wlr_scene_shadow_set_size;

    extern fn wlr_scene_shadow_set_corner_radius(shadow: *SceneShadow, corner_radius: c_int) void;
    pub const setCornerRadius = wlr_scene_shadow_set_corner_radius;

    extern fn wlr_scene_shadow_set_blur_sigma(shadow: *SceneShadow, blur_sigma: f32) void;
    pub const setBlurSigma = wlr_scene_shadow_set_blur_sigma;

    extern fn wlr_scene_shadow_set_color(shadow: *SceneShadow, color: *const [4]f32) void;
    pub const setColor = wlr_scene_shadow_set_color;

    extern fn wlr_scene_shadow_set_clipped_region(shadow: *SceneShadow, region: ClippedRegion) void;
    pub const setClippedRegion = wlr_scene_shadow_set_clipped_region;
};
