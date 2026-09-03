// gui.zig - Modern Compositing Window System
// Architecture: Retained-mode scene graph + Immediate-mode widgets + GPU-ready pipeline

const std = @import("std");
const boot_abi = @import("boot_abi");
const pmem = @import("../mm/physical.zig");
const vmem = @import("../mm/virtual.zig");
const font = @import("font_data.zig");
const ftfs = @import("ftfs.zig");
const serial = @import("serial.zig");
const math = @import("math.zig");
const allocator = std.heap.page_allocator;

// ============================================================================
// CORE TYPES & CONSTANTS
// ============================================================================

pub const PixelFormat = enum(u8) {
    RGB888  = 0,  // 0x00RRGGBB
    BGR888  = 1,  // 0x00BBGGRR
    RGBA8888 = 2, // 0xAARRGGBB
    BGRA8888 = 3, // 0xAABBGGRR
    ARGB8888 = 4, // 0xRRGGBBAA
    ABGR8888 = 5, // 0xBBGGRRAA
};

pub const Color = packed struct {
    r: u8, g: u8, b: u8, a: u8 = 255,
    
    pub const Transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const Black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const White = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const Red = Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
    pub const Green = Color{ .r = 0, .g = 255, .b = 0, .a = 255 };
    pub const Blue = Color{ .r = 0, .g = 0, .b = 255, .a = 255 };
    
    pub fn fromU32(c: u32) Color {
        return .{ .r = @truncate(c >> 16), .g = @truncate(c >> 8), .b = @truncate(c), .a = 255 };
    }
    
    pub fn fromU32Alpha(c: u32) Color {
        return .{ .r = @truncate(c >> 24), .g = @truncate(c >> 16), .b = @truncate(c >> 8), .a = @truncate(c) };
    }
    
    pub fn toPremultiplied(self: Color) u32 {
        const a = @as(f32, self.a) / 255.0;
        return (@as(u32, @as(u8, @floatToInt(@as(f32, self.r) * a))) << 24) |
               (@as(u32, @as(u8, @floatToInt(@as(f32, self.g) * a))) << 16) |
               (@as(u32, @as(u8, @floatToInt(@as(f32, self.b) * a))) << 8) |
               @as(u32, self.a);
    }
    
    pub fn blendOver(self: Color, dst: Color) Color {
        if (self.a == 0) return dst;
        if (self.a == 255) return self;
        const src_a = @as(f32, self.a) / 255.0;
        const dst_a = @as(f32, dst.a) / 255.0;
        const out_a = src_a + dst_a * (1.0 - src_a);
        if (out_a == 0.0) return Color.Transparent;
        const inv_out_a = 1.0 / out_a;
        return .{
            .r = @floatToInt((@as(f32, self.r) * src_a + @as(f32, dst.r) * dst_a * (1.0 - src_a)) * inv_out_a),
            .g = @floatToInt((@as(f32, self.g) * src_a + @as(f32, dst.g) * dst_a * (1.0 - src_a)) * inv_out_a),
            .b = @floatToInt((@as(f32, self.b) * src_a + @as(f32, dst.b) * dst_a * (1.0 - src_a)) * inv_out_a),
            .a = @floatToInt(out_a * 255.0),
        };
    }
};

pub const Rect = struct {
    x: i32, y: i32, w: u32, h: u32,
    
    pub fn contains(self: Rect, x: i32, y: i32) bool {
        return x >= self.x and x < self.x + @as(i32, self.w) and
               y >= self.y and y < self.y + @as(i32, self.h);
    }
    
    pub fn intersects(self: Rect, other: Rect) bool {
        return self.x < other.x + @as(i32, other.w) and
               other.x < self.x + @as(i32, self.w) and
               self.y < other.y + @as(i32, other.h) and
               other.y < self.y + @as(i32, self.h);
    }
    
    pub fn intersect(self: Rect, other: Rect) Rect {
        const x1 = @max(self.x, other.x);
        const y1 = @max(self.y, other.y);
        const x2 = @min(self.x + @as(i32, self.w), other.x + @as(i32, other.w));
        const y2 = @min(self.y + @as(i32, self.h), other.y + @as(i32, other.h));
        if (x1 >= x2 or y1 >= y2) return Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
        return .{ .x = x1, .y = y1, .w = @as(u32, x2 - x1), .h = @as(u32, y2 - y1) };
    }
    
    pub fn union(self: Rect, other: Rect) Rect {
        const x1 = @min(self.x, other.x);
        const y1 = @min(self.y, other.y);
        const x2 = @max(self.x + @as(i32, self.w), other.x + @as(i32, other.w));
        const y2 = @max(self.y + @as(i32, self.h), other.y + @as(i32, other.h));
        return .{ .x = x1, .y = y1, .w = @as(u32, x2 - x1), .h = @as(u32, y2 - y1) };
    }
};

pub const Point = struct { x: i32, y: i32 };
pub const Size = struct { w: u32, h: u32 };

// ============================================================================
// FRAMEBUFFER & RENDERING BACKEND
// ============================================================================

pub const Framebuffer = struct {
    base: [*]volatile u32,
    width: u32,
    height: u32,
    pitch: u32,           // bytes per scanline
    format: PixelFormat,
    physical_addr: usize,
    
    // Double/triple buffering
    back_buffers: [2]?*BackBuffer,
    current_back: u8 = 0,
    vsync_enabled: bool = true,
    
    // Damage tracking for partial updates
    damage_region: Region,
    
    pub const BackBuffer = struct {
        pixels: []u32,
        damage: Region,
    };
    
    pub fn init(info: *const boot_abi.BootInfo) !Framebuffer {
        if (info.fb_base == 0 or info.fb_width < 640 or info.fb_height < 480) {
            return error.InvalidFramebuffer;
        }
        
        const pitch = info.fb_pitch;
        const size = pitch * info.fb_height;
        const virt = pmem.phys_to_virt(info.fb_base);
        
        var fb = Framebuffer{
            .base = @ptrFromInt(virt),
            .width = info.fb_width,
            .height = info.fb_height,
            .pitch = pitch / 4,
            .format = info.fb_format,
            .physical_addr = info.fb_base,
            .back_buffers = [2]?*BackBuffer{ null, null },
            .damage_region = Region.init(allocator),
        };
        
        // Allocate back buffers
        for (fb.back_buffers) |*bb| {
            const pixels = try allocator.alloc(u32, info.fb_width * info.fb_height);
            bb = try allocator.create(BackBuffer);
            bb.* = .{ .pixels = pixels, .damage = Region.init(allocator) };
        }
        
        return fb;
    }
    
    pub fn deinit(self: *Framebuffer) void {
        for (self.back_buffers) |bb| if (bb) |b| {
            allocator.free(b.pixels);
            b.damage.deinit();
            allocator.destroy(b);
        }
        self.damage_region.deinit();
    }
    
    pub fn beginFrame(self: *Framebuffer) []u32 {
        const bb = self.back_buffers[self.current_back].?;
        bb.damage.clear();
        return bb.pixels;
    }
    
    pub fn endFrame(self: *Framebuffer) void {
        const bb = self.back_buffers[self.current_back].?;
        // Copy damaged regions to front buffer
        self.blitDamage(bb);
        self.current_back = 1 - self.current_back;
    }
    
    fn blitDamage(self: *Framebuffer, bb: *BackBuffer) void {
        // Optimized blit of damaged rectangles
        for (bb.damage.rects.items) |rect| {
            const clipped = rect.intersect(Rect{ .x = 0, .y = 0, .w = self.width, .h = self.height });
            if (clipped.w == 0 or clipped.h == 0) continue;
            
            var y: u32 = 0;
            while (y < clipped.h) : (y += 1) {
                const src_idx = (@as(usize, clipped.y + y) * self.width + clipped.x);
                const dst_idx = (@as(usize, clipped.y + y) * self.pitch + clipped.x);
                @memcpy(self.base[dst_idx .. dst_idx + clipped.w], bb.pixels[src_idx .. src_idx + clipped.w]);
            }
        }
    }
    
    pub fn addDamage(self: *Framebuffer, rect: Rect) void {
        self.damage_region.add(rect);
        if (self.back_buffers[self.current_back]) |bb| {
            bb.damage.add(rect);
        }
    }
};

pub const Region = struct {
    rects: std.ArrayList(Rect),
    
    pub fn init(alloc: std.mem.Allocator) Region {
        return .{ .rects = std.ArrayList(Rect).init(alloc) };
    }
    
    pub fn deinit(self: *Region) void { self.rects.deinit(); }
    
    pub fn clear(self: *Region) void { self.rects.clearRetainingCapacity(); }
    
    pub fn add(self: *Region, rect: Rect) !void {
        // Merge overlapping rects for efficiency
        try self.rects.append(rect);
    }
};

// ============================================================================
// IMAGE & TEXTURE SYSTEM
// ============================================================================

pub const Image = struct {
    pixels: []u32,        // Premultiplied ARGB8888
    width: u32,
    height: u32,
    format: PixelFormat = .ARGB8888,
    ref_count: usize = 1,
    
    pub fn loadFromFile(path: []const u8) !Image {
        // Load PNG/JPEG/BMP/RAW via stb_image or custom decoders
        return loadRawImage(path);
    }
    
    pub fn create(width: u32, height: u32, color: Color) !Image {
        const pixels = try allocator.alloc(u32, width * height);
        const c = color.toPremultiplied();
        for (pixels) |*p| p.* = c;
        return .{ .pixels = pixels, .width = width, .height = height };
    }
    
    pub fn scale(self: *Image, new_w: u32, new_h: u32, filter: Filter) !Image {
        // Bilinear/bicubic/Lanczos scaling
        return error.NotImplemented;
    }
    
    pub fn blit(self: *Image, dst: *mut []u32, dst_w: u32, dst_h: u32, dst_x: i32, dst_y: i32, src_rect: ?Rect, alpha: u8) void {
        // Fast blit with clipping, alpha blending, scaling
    }
    
    pub fn addRef(self: *Image) void { self.ref_count += 1; }
    pub fn release(self: *Image) void {
        self.ref_count -= 1;
        if (self.ref_count == 0) {
            allocator.free(self.pixels);
        }
    }
    
    const Filter = enum { Nearest, Bilinear, Bicubic, Lanczos3 };
};

fn loadRawImage(path: []const u8) !Image {
    const idx = ftfs.resolve_path(path);
    if (idx >= ftfs.MAX_INODES) return error.FileNotFound;
    const inode = ftfs.inode_stat(idx) orelse return error.FileNotFound;
    const size = inode.size;
    
    const frames = (size + 4095) / 4096;
    const phys = pmem.alloc_frames(frames) orelse return error.OutOfMemory;
    const virt = pmem.phys_to_virt(phys);
    const buf = @as([*]u8, @ptrFromInt(virt))[0..size];
    
    const read = ftfs.read_file_at(idx, 0, buf);
    if (read != size) {
        pmem.free_frames(phys, frames);
        return error.IOError;
    }
    
    // Assume RAW RGBA8888 for now; add format detection
    const pixels = @as([]u32, @ptrCast(buf));
    return .{ .pixels = pixels, .width = 1280, .height = 800 }; // TODO: parse header
}

// ============================================================================
// FONT & TEXT RENDERING (FreeType-style)
// ============================================================================

pub const Glyph = struct {
    advance: i16,
    bearing_x: i16,
    bearing_y: i16,
    width: u16,
    height: u16,
    atlas_x: u16,
    atlas_y: u16,
};

pub const FontFace = struct {
    name: []const u8,
    size: f32,
    ascent: i16,
    descent: i16,
    line_gap: i16,
    glyphs: std.HashMap(u32, Glyph, std.hash_map.DefaultHashContext, allocator),
    atlas: Image,          // Glyph texture atlas
    fallback: ?*FontFace = null,
    
    pub fn loadFromFile(path: []const u8, size: f32) !FontFace {
        // Parse TTF/OTF, rasterize glyphs to atlas
        return loadBitmapFont(size);
    }
    
    pub fn getGlyph(self: *FontFace, codepoint: u32) Glyph {
        if (self.glyphs.get(codepoint)) |g| return g.*;
        if (self.fallback) |fb| return fb.getGlyph(codepoint);
        return self.glyphs.get('?'.?) orelse Glyph{ .advance = 8 };
    }
    
    pub fn measureText(self: *FontFace, text: []const u8) Size {
        var advance: i32 = 0;
        var max_h: u32 = 0;
        for (text) |cp| {
            const g = self.getGlyph(cp);
            advance += g.advance;
            max_h = @max(max_h, @as(u32, g.height));
        }
        return .{ .w = @as(u32, advance), .h = max_h };
    }
};

fn loadBitmapFont(size: f32) !FontFace {
    // Use embedded 8x16 font as fallback
    var glyphs = std.HashMap(u32, Glyph, std.hash_map.DefaultHashContext, allocator).init(allocator);
    defer glyphs.deinit();
    
    for (0..256) |i| {
        const g = Glyph{
            .advance = 8,
            .bearing_x = 0,
            .bearing_y = 12,
            .width = 8,
            .height = 16,
            .atlas_x = @truncate((i % 16) * 8),
            .atlas_y = @truncate((i / 16) * 16),
        };
        try glyphs.put(@intCast(i), g);
    }
    
    // Create atlas from font_data.zig
    const atlas_w = 128;
    const atlas_h = 256;
    var atlas_pixels = try allocator.alloc(u32, atlas_w * atlas_h);
    for (atlas_pixels) |*p| p.* = 0;
    
    for (0..256) |i| {
        const glyph_data = font.FONT_DATA[i];
        const gx = (i % 16) * 8;
        const gy = (i / 16) * 16;
        var row: u8 = 0;
        while (row < 16) : (row += 1) {
            var col: u8 = 0;
            while (col < 8) : (col += 1) {
                if ((glyph_data[row] >> (7 - col)) & 1 == 1) {
                    atlas_pixels[(gy + row) * atlas_w + (gx + col)] = 0xFFFFFFFF;
                }
            }
        }
    }
    
    return FontFace{
        .name = "builtin",
        .size = size,
        .ascent = 12,
        .descent = 4,
        .line_gap = 2,
        .glyphs = glyphs,
        .atlas = .{ .pixels = atlas_pixels, .width = atlas_w, .height = atlas_h },
    };
}

pub const TextLayout = struct {
    runs: []Run,
    bounds: Rect,
    
    pub const Run = struct {
        text: []const u8,
        font: *FontFace,
        color: Color,
        x: i32,
        y: i32,
        width: u32,
    };
    
    pub fn draw(self: *TextLayout, ctx: *DrawContext, x: i32, y: i32) void {
        for (self.runs) |run| {
            ctx.drawTextRun(run, x + run.x, y + run.y);
        }
    }
};

// ============================================================================
// DRAW CONTEXT (Immediate Mode Rendering)
// ============================================================================

pub const DrawContext = struct {
    target: []u32,
    target_w: u32,
    target_h: u32,
    clip: Rect,
    transform: Transform2D,
    font: *FontFace,
    
    pub fn init(target: []u32, w: u32, h: u32, font: *FontFace) DrawContext {
        return .{
            .target = target,
            .target_w = w,
            .target_h = h,
            .clip = Rect{ .x = 0, .y = 0, .w = w, .h = h },
            .transform = Transform2D.identity(),
            .font = font,
        };
    }
    
    pub fn pushClip(self: *DrawContext, rect: Rect) Rect {
        const old = self.clip;
        self.clip = self.clip.intersect(rect);
        return old;
    }
    
    pub fn popClip(self: *DrawContext, old: Rect) void { self.clip = old; }
    
    pub fn fillRect(self: *DrawContext, rect: Rect, color: Color) void {
        const r = rect.intersect(self.clip);
        if (r.w == 0 or r.h == 0) return;
        const c = color.toPremultiplied();
        var y: u32 = 0;
        while (y < r.h) : (y += 1) {
            const idx = (@as(usize, r.y + y) * self.target_w + r.x);
            for (self.target[idx .. idx + r.w]) |*p| p.* = c;
        }
    }
    
    pub fn drawRect(self: *DrawContext, rect: Rect, color: Color, thickness: u32) void {
        // Draw four filled rects for border
        self.fillRect(Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = thickness }, color);
        self.fillRect(Rect{ .x = rect.x, .y = rect.y + @as(i32, rect.h) - @as(i32, thickness), .w = rect.w, .h = thickness }, color);
        self.fillRect(Rect{ .x = rect.x, .y = rect.y, .w = thickness, .h = rect.h }, color);
        self.fillRect(Rect{ .x = rect.x + @as(i32, rect.w) - @as(i32, thickness), .y = rect.y, .w = thickness, .h = rect.h }, color);
    }
    
    pub fn drawImage(self: *DrawContext, img: *Image, dst: Rect, src: ?Rect) void {
        // Blit with clipping, scaling, alpha
    }
    
    pub fn drawTextRun(self: *DrawContext, run: TextLayout.Run, x: i32, y: i32) void {
        var cx = x;
        const baseline = y + run.font.ascent;
        for (run.text) |cp| {
            const glyph = run.font.getGlyph(cp);
            const gx = cx + glyph.bearing_x;
            const gy = baseline - glyph.bearing_y;
            if (glyph.width > 0 and glyph.height > 0) {
                self.blitGlyph(run.font.atlas, glyph, gx, gy, run.color);
            }
            cx += glyph.advance;
        }
    }
    
    fn blitGlyph(self: *DrawContext, atlas: Image, glyph: Glyph, x: i32, y: i32, color: Color) void {
        const src = Rect{ .x = @as(i32, glyph.atlas_x), .y = @as(i32, glyph.atlas_y), .w = @as(u32, glyph.width), .h = @as(u32, glyph.height) };
        const dst = Rect{ .x = x, .y = y, .w = @as(u32, glyph.width), .h = @as(u32, glyph.height) };
        self.drawImage(&atlas, dst, src);
    }
    
    pub fn drawRoundedRect(self: *DrawContext, rect: Rect, radius: u32, color: Color) void {
        // 9-slice or shader-based rounded rect
    }
    
    pub fn drawGradient(self: *DrawContext, rect: Rect, c1: Color, c2: Color, vertical: bool) void {
        // Linear gradient fill
    }
};

pub const Transform2D = struct {
    m: [6]f32, // [a, b, c, d, tx, ty]
    
    pub fn identity() Transform2D {
        return .{ .m = [1, 0, 0, 1, 0, 0] };
    }
    
    pub fn translate(self: Transform2D, x: f32, y: f32) Transform2D {
        return .{ .m = [self.m[0], self.m[1], self.m[2], self.m[3], self.m[4] + x, self.m[5] + y] };
    }
    
    pub fn scale(self: Transform2D, x: f32, y: f32) Transform2D {
        return .{ .m = [self.m[0] * x, self.m[1] * x, self.m[2] * y, self.m[3] * y, self.m[4], self.m[5]] };
    }
};

// ============================================================================
// SCENE GRAPH (Retained Mode)
// ============================================================================

pub const NodeId = u32;

pub const Node = struct {
    id: NodeId,
    parent: ?NodeId,
    children: std.ArrayList(NodeId),
    bounds: Rect,
    global_bounds: Rect,
    visible: bool = true,
    opacity: f32 = 1.0,
    clip_children: bool = true,
    z_index: i32 = 0,
    needs_redraw: bool = true,
    needs_layout: bool = true,
    
    // Virtual methods (via interface)
    vtable: *VTable,
    
    pub const VTable = struct {
        layout: fn(*Node, *LayoutContext) void,
        paint: fn(*Node, *DrawContext) void,
        hit_test: fn(*Node, Point) bool,
        on_event: fn(*Node, *Event) EventResult,
    };
    
    pub fn layout(self: *Node, ctx: *LayoutContext) void {
        if (self.vtable.layout) self.vtable.layout(self, ctx);
    }
    
    pub fn paint(self: *Node, ctx: *DrawContext) void {
        if (!self.visible or self.opacity == 0.0) return;
        if (self.vtable.paint) self.vtable.paint(self, ctx);
    }
    
    pub fn hitTest(self: *Node, p: Point) bool {
        if (!self.visible) return false;
        if (!self.global_bounds.contains(p.x, p.y)) return false;
        if (self.vtable.hit_test) return self.vtable.hit_test(self, p);
        return true;
    }
    
    pub fn dispatchEvent(self: *Node, event: *Event) EventResult {
        if (self.vtable.on_event) return self.vtable.on_event(self, event);
        return .ignored;
    }
};

pub const LayoutContext = struct {
    constraints: Size,
    dpi_scale: f32,
};

pub const EventResult = enum { handled, ignored, propagate };

// ============================================================================
// WIDGET TOOLKIT
// ============================================================================

pub const Widget = struct {
    node: Node,
    style: Style,
    state: State,
    tooltip: ?[]const u8 = null,
    cursor: Cursor = .default,
    
    pub const State = struct {
        focused: bool = false,
        hovered: bool = false,
        pressed: bool = false,
        disabled: bool = false,
        selected: bool = false,
    };
    
    pub const Cursor = enum { default, pointer, text, crosshair, move, resize_n, resize_s, resize_e, resize_w, resize_ne, resize_nw, resize_se, resize_sw, not_allowed };
};

pub const Style = struct {
    // Box model
    padding: EdgeInsets = .{ .top = 4, .right = 8, .bottom = 4, .left = 8 },
    margin: EdgeInsets = .{},
    border: Border = .{ .width = 1, .color = Color{ .r = 128, .g = 128, .b = 128 } },
    border_radius: u32 = 0,
    
    // Colors
    background: Color = Color{ .r = 40, .g = 40, .b = 40 },
    foreground: Color = Color.White,
    accent: Color = Color{ .r = 0, .g = 120, .b = 215 },
    
    // Typography
    font_size: f32 = 14.0,
    font_weight: u16 = 400,
    text_align: Align = .left,
    
    // Effects
    box_shadow: ?Shadow = null,
    
    pub const EdgeInsets = struct { top: i32, right: i32, bottom: i32, left: i32 };
    pub const Border = struct { width: u32, color: Color };
    pub const Shadow = struct { offset: Point, blur: u32, color: Color };
    pub const Align = enum { left, center, right, justify };
};

// Standard Widgets
pub const Button = struct {
    widget: Widget,
    text: []const u8,
    icon: ?*Image = null,
    on_click: fn(*Button) void = {} => void,
    
    pub const vtable = Node.VTable{
        .layout = layoutButton,
        .paint = paintButton,
        .hit_test = hitTestButton,
        .on_event = onEventButton,
    };
};

fn layoutButton(btn: *Node, ctx: *LayoutContext) void {
    // Measure text + icon + padding
}

fn paintButton(btn: *Node, ctx: *DrawContext) void {
    const b = @fieldParentPtr(Button, "node", btn);
    const style = b.widget.style;
    const state = b.widget.state;
    
    var bg = style.background;
    if (state.pressed) bg = bg.blendOver(Color{ .r = 0, .g = 0, .b = 0, .a = 50 });
    else if (state.hovered) bg = bg.blendOver(Color{ .r = 255, .g = 255, .b = 255, .a = 20 });
    if (state.focused) bg = style.accent;
    
    ctx.fillRect(btn.bounds, bg);
    if (style.border.width > 0) {
        ctx.drawRect(btn.bounds, style.border.color, style.border.width);
    }
    
    // Draw text centered
    const text_size = ctx.font.measureText(b.text);
    const tx = btn.bounds.x + @as(i32, (btn.bounds.w - text_size.w) / 2);
    const ty = btn.bounds.y + @as(i32, (btn.bounds.h - text_size.h) / 2);
    ctx.drawTextRun(.{ .text = b.text, .font = ctx.font, .color = style.foreground, .x = tx, .y = ty, .width = text_size.w }, tx, ty);
}

fn hitTestButton(btn: *Node, p: Point) bool { return btn.bounds.contains(p.x, p.y); }

fn onEventButton(btn: *Node, e: *Event) EventResult {
    const b = @fieldParentPtr(Button, "node", btn);
    switch (e.type) {
        .mouse_down => if (e.mouse.button == .left) { b.widget.state.pressed = true; btn.needs_redraw = true; return .handled; },
        .mouse_up => if (e.mouse.button == .left and b.widget.state.pressed) { b.widget.state.pressed = false; btn.needs_redraw = true; if (btn.bounds.contains(e.mouse.x, e.mouse.y)) b.on_click(b); return .handled; },
        .mouse_enter => { b.widget.state.hovered = true; btn.needs_redraw = true; return .handled; },
        .mouse_leave => { b.widget.state.hovered = false; b.widget.state.pressed = false; btn.needs_redraw = true; return .handled; },
        .focus_gained => { b.widget.state.focused = true; btn.needs_redraw = true; return .handled; },
        .focus_lost => { b.widget.state.focused = false; btn.needs_redraw = true; return .handled; },
        else => {},
    }
    return .ignored;
}

// ... similar for Label, TextInput, Slider, CheckBox, RadioButton, ComboBox, ListView, TreeView, TableView, TabView, SplitView, ScrollView, ProgressBar, Spinner, Tooltip, Menu, MenuBar, ContextMenu, Dialog, Window

// ============================================================================
// WINDOW MANAGEMENT & COMPOSITOR
// ============================================================================

pub const Window = struct {
    node: Node,
    title: []const u8,
    icon: ?*Image,
    state: WindowState,
    flags: WindowFlags,
    decoration: DecorationStyle,
    content_root: NodeId,
    
    // Window-specific
    min_size: Size = .{ .w = 200, .h = 150 },
    max_size: Size = .{ .w = 0xFFFF, .h = 0xFFFF },
    on_close: fn(*Window) bool = {} => true, // return false to prevent close
    
    pub const WindowState = enum { normal, minimized, maximized, fullscreen, tiled_left, tiled_right };
    pub const WindowFlags = packed struct {
        resizable: bool = true,
        closable: bool = true,
        minimizable: bool = true,
        maximizable: bool = true,
        always_on_top: bool = false,
        skip_taskbar: bool = false,
        no_decoration: bool = false,
        transparent: bool = false,
        tool_window: bool = false,
    };
    pub const DecorationStyle = enum { system, custom, none };
};

pub const Compositor = struct {
    fb: *Framebuffer,
    root: NodeId,
    windows: std.ArrayList(*Window),
    focus_stack: std.ArrayList(NodeId), // Top to bottom
    hover_node: ?NodeId = null,
    focus_node: ?NodeId = null,
    capture_node: ?NodeId = null,
    
    // Animation
    animations: std.ArrayList(Animation),
    
    // Cursor
    cursor_pos: Point = .{ .x = 0, .y = 0 },
    cursor_image: ?*Image = null,
    cursor_hotspot: Point = .{ .x = 0, .y = 0 },
    cursor_visible: bool = true,
    
    // Input
    modifiers: Modifiers = .{},
    double_click_time: u64 = 300_000_000, // ns
    last_click: ?ClickInfo = null,
    
    pub const Modifiers = packed struct {
        shift: bool, ctrl: bool, alt: bool, super: bool, caps: bool, num: bool,
    };
    
    pub const ClickInfo = struct { time: u64, pos: Point, button: MouseButton, count: u32 };
    
    pub fn init(fb: *Framebuffer) !Compositor {
        const root_node = try Node.alloc(.{ .bounds = Rect{ .x = 0, .y = 0, .w = fb.width, .h = fb.height } });
        return .{ .fb = fb, .root = root_node.id, .windows = std.ArrayList(*Window).init(allocator), .focus_stack = std.ArrayList(NodeId).init(allocator), .animations = std.ArrayList(Animation).init(allocator) };
    }
    
    pub fn createWindow(self: *Compositor, title: []const u8, bounds: Rect, flags: Window.WindowFlags) !*Window {
        const win = try allocator.create(Window);
        win.* = .{
            .node = try Node.alloc(.{ .bounds = bounds, .vtable = &Window.vtable }),
            .title = try allocator.dupe(u8, title),
            .flags = flags,
            .decoration = if (flags.no_decoration) .none else .system,
        };
        try self.windows.append(win);
        try self.addChild(self.root, win.node.id);
        self.raiseWindow(win);
        return win;
    }
    
    pub fn destroyWindow(self: *Compositor, win: *Window) void {
        if (win.on_close(win)) {
            self.removeChild(self.root, win.node.id);
            // Remove from focus stack, free resources
        }
    }
    
    pub fn raiseWindow(self: *Compositor, win: *Window) void {
        // Move to top of focus stack, restack
    }
    
    pub fn handleInput(self: *Compositor, event: *Event) void {
        // Hit test, focus management, event dispatch
        const target = self.hitTest(self.cursor_pos);
        self.dispatchEvent(target, event);
    }
    
    pub fn hitTest(self: *Compositor, pos: Point) ?NodeId {
        // Traverse focus stack top-down
        for (self.focus_stack.items) |id| {
            const node = Node.get(id);
            if (node.hitTest(pos)) return id;
        }
        return null;
    }
    
    pub fn dispatchEvent(self: *Compositor, target: ?NodeId, event: *Event) void {
        // Bubble up from target to root
    }
    
    pub fn render(self: *Compositor) void {
        const back = self.fb.beginFrame();
        const ctx = DrawContext.init(back, self.fb.width, self.fb.height, default_font);
        self.paintNode(self.root, ctx);
        self.drawCursor(ctx);
        self.fb.endFrame();
    }
    
    fn paintNode(self: *Compositor, id: NodeId, ctx: DrawContext) void {
        const node = Node.get(id);
        if (!node.visible) return;
        
        // Paint self
        node.paint(&ctx);
        
        // Paint children in z-order
        var sorted = node.children.items;
        std.sort.sort(sorted, {}, struct { fn cmp(a: NodeId, b: NodeId) i32 { return @as(i32, Node.get(a).z_index) - @as(i32, Node.get(b).z_index); } });
        for (sorted) |child_id| self.paintNode(child_id, ctx);
    }
    
    fn drawCursor(self: *Compositor, ctx: DrawContext) void {
        if (self.cursor_visible) if (self.cursor_image) |img| {
            ctx.drawImage(img, Rect{ .x = self.cursor_pos.x - self.cursor_hotspot.x, .y = self.cursor_pos.y - self.cursor_hotspot.y, .w = img.width, .h = img.height }, null);
        }
    }
};

// ============================================================================
// EVENT SYSTEM
// ============================================================================

pub const Event = struct {
    type: Type,
    time: u64,
    modifiers: Compositor.Modifiers,
    
    pub const Type = enum {
        none,
        mouse_move, mouse_down, mouse_up, mouse_wheel, mouse_enter, mouse_leave,
        key_down, key_up, key_repeat, text_input,
        focus_gained, focus_lost,
        window_resize, window_move, window_close, window_minimize, window_maximize,
        touch_down, touch_up, touch_move, touch_cancel,
        gesture_pan, gesture_zoom, gesture_rotate,
        timer, idle, custom,
    };
    
    mouse: MouseEvent,
    key: KeyEvent,
    text: []const u8,
    window: WindowEvent,
    touch: TouchEvent,
    gesture: GestureEvent,
    
    pub const MouseEvent = struct { x: i32, y: i32, button: MouseButton, clicks: u32, wheel_x: i32, wheel_y: i32 };
    pub const KeyEvent = struct { key: Key, code: KeyCode, repeat: bool };
    pub const WindowEvent = struct { width: u32, height: u32, x: i32, y: i32 };
    pub const TouchEvent = struct { id: u64, x: i32, y: i32, pressure: f32 };
    pub const GestureEvent = struct { x: i32, y: i32, delta_x: f32, delta_y: f32, scale: f32, rotation: f32 };
    
    pub const MouseButton = enum { left, right, middle, x1, x2 };
    pub const Key = enum { unknown, a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z, num0, num1, num2, num3, num4, num5, num6, num7, num8, num9, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, escape, tab, space, enter, backspace, insert, delete, home, end, page_up, page_down, left, right, up, down, shift_left, shift_right, ctrl_left, ctrl_right, alt_left, alt_right, super_left, super_right, menu };
    pub const KeyCode = u32; // Physical key code (USB HID usage)
};

// ============================================================================
// ANIMATION SYSTEM
// ============================================================================

pub const Animation = struct {
    target: NodeId,
    property: Property,
    from: f32,
    to: f32,
    duration: u64,        // nanoseconds
    start_time: u64,
    easing: Easing,
    on_complete: fn() void = {} => void,
    
    pub const Property = enum { opacity, x, y, width, height, scale_x, scale_y, rotation, color_r, color_g, color_b, color_a };
    pub const Easing = enum { linear, ease_in, ease_out, ease_in_out, ease_out_back, ease_out_elastic, ease_out_bounce, custom(fn(f32) f32) };
    
    pub fn update(self: *Animation, now: u64) bool {
        const elapsed = now - self.start_time;
        if (elapsed >= self.duration) return true; // Done
        const t = @as(f32, elapsed) / @as(f32, self.duration);
        const eased = self.easing.apply(t);
        const value = self.from + (self.to - self.from) * eased;
        // Apply to node property
        return false;
    }
};

// ============================================================================
// THEME SYSTEM
// ============================================================================

pub const Theme = struct {
    name: []const u8,
    colors: ColorScheme,
    fonts: FontSet,
    metrics: Metrics,
    shapes: ShapeSet,
    
    pub const ColorScheme = struct {
        // Base
        background: Color,
        surface: Color,
        surface_variant: Color,
        outline: Color,
        outline_variant: Color,
        // Brand
        primary: Color,
        on_primary: Color,
        primary_container: Color,
        on_primary_container: Color,
        secondary: Color,
        on_secondary: Color,
        // Semantic
        error: Color,
        on_error: Color,
        success: Color,
        warning: Color,
        info: Color,
        // State
        hover_overlay: Color,
        press_overlay: Color,
        focus_ring: Color,
        disabled_overlay: Color,
    };
    
    pub const FontSet = struct {
        display_large: *FontFace,
        display_medium: *FontFace,
        display_small: *FontFace,
        headline_large: *FontFace,
        headline_medium: *FontFace,
        headline_small: *FontFace,
        title_large: *FontFace,
        title_medium: *FontFace,
        title_small: *FontFace,
        body_large: *FontFace,
        body_medium: *FontFace,
        body_small: *FontFace,
        label_large: *FontFace,
        label_medium: *FontFace,
        label_small: *FontFace,
        mono: *FontFace,
    };
    
    pub const Metrics = struct {
        corner_radius_small: u32 = 4,
        corner_radius_medium: u32 = 8,
        corner_radius_large: u32 = 16,
        corner_radius_full: u32 = 9999,
        spacing_xs: u32 = 4,
        spacing_sm: u32 = 8,
        spacing_md: u32 = 16,
        spacing_lg: u32 = 24,
        spacing_xl: u32 = 32,
        icon_size_sm: u32 = 16,
        icon_size_md: u32 = 24,
        icon_size_lg: u32 = 32,
        icon_size_xl: u32 = 48,
    };
    
    pub const ShapeSet = struct {
        // 9-slice images for complex shapes
    };
    
    pub fn defaultDark() Theme { /* ... */ }
    pub fn defaultLight() Theme { /* ... */ }
    
    pub fn resolveStyle(self: *Theme, widget_type: []const u8, state: Widget.State) Style { /* ... */ }
};

// ============================================================================
// RESOURCE MANAGEMENT
// ============================================================================

pub const ResourceManager = struct {
    images: std.HashMap([]const u8, *Image, std.hash_map.StringContext, allocator),
    fonts: std.HashMap([]const u8, *FontFace, std.hash_map.StringContext, allocator),
    cursors: std.HashMap([]const u8, *Cursor, std.hash_map.StringContext, allocator),
    themes: std.HashMap([]const u8, *Theme, std.hash_map.StringContext, allocator),
    
    pub fn getImage(self: *ResourceManager, path: []const u8) !*Image {
        if (self.images.get(path)) |img| return img;
        const img = try Image.loadFromFile(path);
        const stored = try allocator.create(Image);
        stored.* = img;
        try self.images.put(try allocator.dupe(u8, path), stored);
        return stored;
    }
    
    pub fn getFont(self: *ResourceManager, name: []const u8, size: f32) !*FontFace {
        const key = try std.fmt.allocPrint(allocator, "{s}:{d}", .{name, @intCast(size)});
        if (self.fonts.get(key)) |f| return f;
        const font = try FontFace.loadFromFile(name, size);
        const stored = try allocator.create(FontFace);
        stored.* = font;
        try self.fonts.put(key, stored);
        return stored;
    }
};

// ============================================================================
// DESKTOP SHELL (Taskbar, Start Menu, Desktop Icons)
// ============================================================================

pub const DesktopShell = struct {
    compositor: *Compositor,
    taskbar: *Taskbar,
    start_menu: *StartMenu,
    desktop_icons: std.ArrayList(DesktopIcon),
    wallpaper: ?*Image = null,
    
    pub fn init(comp: *Compositor) !DesktopShell {
        const shell = DesktopShell{ .compositor = comp, .taskbar = null, .start_menu = null, .desktop_icons = std.ArrayList(DesktopIcon).init(allocator) };
        shell.taskbar = try Taskbar.init(comp);
        shell.start_menu = try StartMenu.init(comp);
        shell.loadWallpaper();
        shell.createDefaultIcons();
        return shell;
    }
    
    fn loadWallpaper(self: *DesktopShell) void {
        self.wallpaper = ResourceManager.global.getImage("/wallpaper.png") catch null;
    }
    
    fn createDefaultIcons(self: *DesktopShell) void {
        const defaults = [_]DesktopIcon{
            .{ .name = "Computer", .icon = "computer", .target = "computer://" },
            .{ .name = "Network", .icon = "network", .target = "network://" },
            .{ .name = "Trash", .icon = "trash", .target = "trash://" },
            .{ .name = "ZIDE", .icon = "zide", .target = "app://zide" },
            .{ .name = "Settings", .icon = "settings", .target = "app://settings" },
        };
        var y = 20;
        for (defaults) |d| {
            var icon = d;
            icon.bounds = Rect{ .x = 20, .y = y, .w = 64, .h = 64 };
            y += 90;
            self.desktop_icons.append(icon) catch {};
        }
    }
    
    pub fn render(self: *DesktopShell, ctx: *DrawContext) void {
        // Draw wallpaper
        if (self.wallpaper) |wp| {
            ctx.drawImage(wp, Rect{ .x = 0, .y = 0, .w = self.compositor.fb.width, .h = self.compositor.fb.height }, null);
        } else {
            ctx.fillRect(Rect{ .x = 0, .y = 0, .w = self.compositor.fb.width, .h = self.compositor.fb.height }, Color{ .r = 0, .g = 0, .b = 64 });
        }
        
        // Draw desktop icons
        for (self.desktop_icons.items) |icon| {
            icon.paint(ctx);
        }
        
        // Taskbar draws itself via compositor
    }
};

pub const DesktopIcon = struct {
    name: []const u8,
    icon_name: []const u8,
    target: []const u8,
    bounds: Rect,
    selected: bool = false,
    
    pub fn paint(self: *DesktopIcon, ctx: *DrawContext) void {
        const img = ResourceManager.global.getImage("/icon_" ++ self.icon_name ++ ".png") catch null;
        if (img) |i| {
            ctx.drawImage(i, Rect{ .x = self.bounds.x, .y = self.bounds.y, .w = 48, .h = 48 }, null);
        }
        // Draw label
        const label_y = self.bounds.y + 52;
        ctx.drawTextRun(.{ .text = self.name, .font = ctx.font, .color = Color.White, .x = self.bounds.x, .y = label_y, .width = 64 }, self.bounds.x, label_y);
        
        if (self.selected) {
            ctx.drawRect(self.bounds, Color{ .r = 0, .g = 120, .b = 215 }, 2);
        }
    }
};

// Taskbar, StartMenu implementations...

// ============================================================================
// GLOBAL STATE & INITIALIZATION
// ============================================================================

var g_fb: ?Framebuffer = null;
var g_compositor: ?Compositor = null;
var g_shell: ?DesktopShell = null;
var g_resource_mgr: ResourceManager = ResourceManager{
    .images = std.HashMap([]const u8, *Image, std.hash_map.StringContext, allocator).init(allocator),
    .fonts = std.HashMap([]const u8, *FontFace, std.hash_map.StringContext, allocator).init(allocator),
    .cursors = std.HashMap([]const u8, *Cursor, std.hash_map.StringContext, allocator).init(allocator),
    .themes = std.HashMap([]const u8, *Theme, std.hash_map.StringContext, allocator).init(allocator),
};

var default_font: *FontFace = null;

pub fn init(info: *const boot_abi.BootInfo) !void {
    serial.log("GUI: Initializing modern compositor...\n");
    
    // 1. Framebuffer
    g_fb = try Framebuffer.init(info);
    serial.log("GUI: Framebuffer {}x{}@{}\n", .{g_fb.?.width, g_fb.?.height, g_fb.?.format});
    
    // 2. Default font
    default_font = try FontFace.loadFromFile("/fonts/notosans.ttf", 14.0) catch loadBitmapFont(14.0) catch |err| {
        serial.log("GUI: Failed to load font: {}\n", .{err});
        return err;
    };
    
    // 3. Theme
    const theme = Theme.defaultDark();
    g_resource_mgr.themes.put("default", try allocator.create(Theme)) catch {};
    
    // 4. Compositor
    g_compositor = try Compositor.init(g_fb.?);
    
    // 5. Desktop Shell
    g_shell = try DesktopShell.init(g_compositor.?);
    
    // 6. Load cursors
    g_compositor.?.cursor_image = g_resource_mgr.getImage("/cursor_arrow.png") catch null;
    
    // 7. Initial render
    renderFrame();
    
    serial.log("GUI: Initialization complete\n");
}

pub fn renderFrame() void {
    if (g_compositor) |comp| comp.render();
}

pub fn handleMouseMove(x: i32, y: i32) void {
    if (g_compositor) |comp| {
        comp.cursor_pos = .{ .x = x, .y = y };
        comp.handleInput(&.{ .type = .mouse_move, .mouse = .{ .x = x, .y = y } });
    }
}

pub fn handleMouseButton(x: i32, y: i32, button: Event.MouseButton, down: bool) void {
    if (g_compositor) |comp| {
        comp.cursor_pos = .{ .x = x, .y = y };
        comp.handleInput(&.{ .type = if (down) .mouse_down else .mouse_up, .mouse = .{ .x = x, .y = y, .button = button } });
    }
}

pub fn handleKey(key: Event.Key, down: bool) void {
    if (g_compositor) |comp| {
        comp.handleInput(&.{ .type = if (down) .key_down else .key_up, .key = .{ .key = key, .code = 0 } });
    }
}

pub fn handleTextInput(text: []const u8) void {
    if (g_compositor) |comp| {
        comp.handleInput(&.{ .type = .text_input, .text = text });
    }
}

pub fn shutdown() void {
    if (g_shell) |s| s.deinit();
    if (g_compositor) |c| c.deinit();
    if (g_fb) |f| f.deinit();
    default_font.?.deinit();
    g_resource_mgr.deinit();
}
