const std = @import("std");
const vaxis = @import("vaxis");
const node = @import("node.zig");
const parser = @import("parser.zig");
const output = @import("output.zig");
const hl = @import("highlight.zig");


pub const types = @import("view/types.zig");
pub const parse = @import("view/parse.zig");
pub const search = @import("view/search.zig");
pub const wrap = @import("view/wrap.zig");
pub const viewer = @import("view/viewer.zig");
pub const watch = @import("view/watch.zig");
pub const memory = @import("view/memory.zig");
pub const picker = @import("view/picker.zig");
pub const outline = @import("view/outline.zig");

const Bytes = types.Bytes;
const Event = types.Event;
const SearchState = search.SearchState;
const WrapLayout = wrap.WrapLayout;
const Viewer = viewer.Viewer;
const Memory = memory.Memory;

pub const RunResult = enum { quit, back_to_picker, edit };

fn reloadContent(alloc: std.mem.Allocator, path: Bytes, show_urls: bool) !struct { rendered: Bytes, arena: *node.Arena } {
  var arena = try alloc.create(node.Arena);
  arena.* = node.Arena.init(std.heap.page_allocator);

  const file = try std.fs.cwd().openFile(path, .{});
  defer file.close();

  const markdown = try file.readToEndAlloc(arena.allocator(), std.math.maxInt(usize));
  const root = try parser.parse(arena, markdown);

  var highlighter = try hl.Highlighter.init(std.heap.page_allocator);

  var aw: std.Io.Writer.Allocating = .init(alloc);
  try output.render(&aw.writer, root, .{
    .highlighter = &highlighter,
    .show_urls = show_urls,
    .tui = true,
  });
  try aw.writer.flush();

  const rendered = try alloc.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
  aw.deinit();

  return .{ .rendered = rendered, .arena = arena };
}

fn refreshContent(alloc: std.mem.Allocator, filename: Bytes, v: *Viewer, prev_rendered: *?[]const u8, prev_arena: *?*node.Arena, prev_parsed: *types.ParseResult) void {
  const result = reloadContent(alloc, filename, v.show_urls) catch return;
  const new_parsed = parse.parseAnsiLines(alloc, result.rendered) catch {
    alloc.free(result.rendered);
    result.arena.deinit();
    alloc.destroy(result.arena);
    return;
  };

  prev_parsed.deinit(alloc);

  if (prev_rendered.*) |r| alloc.free(r);
  if (prev_arena.*) |a| { a.deinit(); alloc.destroy(a); }
  prev_rendered.* = result.rendered;
  prev_arena.* = result.arena;

  prev_parsed.* = new_parsed;
  const old_scroll = v.scroll;
  v.lines = new_parsed.lines;
  v.headings = new_parsed.headings;
  v.links = new_parsed.links;
  v.images = new_parsed.images;
  v.num_w = @intCast(viewer.digitCount(new_parsed.lines.len) + 1);
  v.wrap.width = 0;
  v.scroll = old_scroll;
  v.clampScroll();
}

fn scheduleToastDismiss(loop: *vaxis.Loop(Event)) void {
  std.Thread.sleep(2 * std.time.ns_per_s);
  loop.postEvent(.toast_dismiss);
}

pub const Options = struct {
  watching: bool = false,
  has_picker: bool = false,
};

pub const Tui = struct {
  alloc: std.mem.Allocator,
  tty: vaxis.Tty,
  vx: vaxis.Vaxis,
  loop: vaxis.Loop(Event),
  buffer: [1024]u8 = undefined,

  pub fn init(alloc: std.mem.Allocator) !*Tui {
    const self = try alloc.create(Tui);
    self.* = .{
      .alloc = alloc,
      .tty = undefined,
      .vx = try vaxis.init(alloc, .{}),
      .loop = undefined,
    };
    self.tty = try vaxis.Tty.init(&self.buffer);
    self.loop = .{ .tty = &self.tty, .vaxis = &self.vx };
    try self.loop.init();
    try self.loop.start();
    try self.vx.enterAltScreen(self.tty.writer());
    try self.vx.queryTerminal(self.tty.writer(), 1 * std.time.ns_per_s);
    try self.vx.setMouseMode(self.tty.writer(), true);

    while (self.loop.tryEvent()) |event| {
      switch (event) {
        .winsize => |ws| try self.vx.resize(alloc, self.tty.writer(), ws),
        else => {},
      }
    }

    return self;
  }

  pub fn suspendForEditor(self: *Tui) void {
    self.vx.resetState(self.tty.writer()) catch {};
    self.loop.stop();
    std.posix.tcsetattr(self.tty.fd, .FLUSH, self.tty.termios) catch {};
  }

  pub fn resumeFromEditor(self: *Tui) void {
    _ = vaxis.Tty.makeRaw(self.tty.fd) catch {};
    self.loop.start() catch {};
    self.vx.enterAltScreen(self.tty.writer()) catch {};
    self.vx.setMouseMode(self.tty.writer(), true) catch {};
    if (vaxis.Tty.getWinsize(self.tty.fd)) |ws| {
      self.vx.resize(self.alloc, self.tty.writer(), ws) catch {};
    } else |_| {}
  }

  pub fn deinit(self: *Tui) void {
    self.vx.setMouseMode(self.tty.writer(), false) catch {};
    self.vx.exitAltScreen(self.tty.writer()) catch {};
    self.loop.stop();
    self.vx.deinit(self.alloc, self.tty.writer());
    self.tty.deinit();
    self.alloc.destroy(self);
  }
};

pub fn run(tui: *Tui, rendered: Bytes, filename: Bytes, opts: Options) !RunResult {
  const alloc = tui.alloc;
  var parsed = try parse.parseAnsiLines(alloc, rendered);
  const mem = Memory.load(alloc);

  var v: Viewer = .{
    .alloc = alloc,
    .lines = parsed.lines,
    .headings = parsed.headings,
    .links = parsed.links,
    .images = parsed.images,
    .filename = filename,
    .num_w = @intCast(viewer.digitCount(parsed.lines.len) + 1),
    .show_lines = mem.show_lines,
    .show_urls = mem.show_urls,
    .line_wrap_percent = mem.line_wrap_percent,
    .has_picker = opts.has_picker,
    .search = SearchState.init(alloc),
    .wrap = WrapLayout.init(alloc),
    .vx = &tui.vx,
    .tty_writer = tui.tty.writer(),
  };
  
  defer v.search.deinit();
  defer v.wrap.deinit();
  defer v.deinitImages();
  defer parsed.deinit(alloc);

  var watcher: ?watch.Watcher = null;
  if (opts.watching) {
    watcher = try watch.Watcher.init(filename, &tui.loop);
    _ = try std.Thread.spawn(.{}, watch.Watcher.run, .{&watcher.?});
  }

  var prev_rendered: ?[]const u8 = null;
  var prev_arena: ?*node.Arena = null;
  defer {
    if (prev_rendered) |r| alloc.free(r);
    if (prev_arena) |a| { a.deinit(); alloc.destroy(a); }
  }

  {
    const win = tui.vx.window();
    v.term_w = win.width;
    v.term_h = win.height;
    try v.rebuildWrap(win);
    v.draw(win);
    try tui.vx.render(tui.tty.writer());
  }

  while (true) {
    const event = tui.loop.nextEvent();
    switch (event) {
      .file_changed => {
        refreshContent(alloc, filename, &v, &prev_rendered, &prev_arena, &parsed);
      },
      .key_press => |key| {
        if (v.yank_active) {
          const action = v.handleYankKey(key);
          if (action == .copy_line) {
            _ = std.Thread.spawn(.{}, scheduleToastDismiss, .{&tui.loop}) catch {};
          }
        } else if (v.search.active) {
          try v.handleSearchKey(alloc, key);
        } else {
          const action = v.handleKeyPress(key);
          if (action == .quit) return .quit;
          if (action == .back_to_picker) return .back_to_picker;
          if (action == .edit) return .edit;
          if (action == .reload) {
            refreshContent(alloc, filename, &v, &prev_rendered, &prev_arena, &parsed);
          }
          if (action == .toggle_urls) refreshContent(alloc, filename, &v, &prev_rendered, &prev_arena, &parsed);
          if (action == .outline) {
            if (outline.run(tui, v.headings) catch null) |result| {
              const vrow = v.wrap.logicalToVisual(result.line_idx);
              v.scroll = if (vrow > 2) vrow - 2 else 0;
              v.clampScroll();
            }
          }
          if (action == .copy_contents) {
            _ = std.Thread.spawn(.{}, scheduleToastDismiss, .{&tui.loop}) catch {};
          }
        }
      },
      .mouse => |mouse| v.handleMouse(mouse),
      .toast_dismiss => {
        v.toast_msg = null;
        v.toast_time = null;
      },
      .winsize => |ws| {
        try tui.vx.resize(alloc, tui.tty.writer(), ws);
        v.term_w = ws.cols;
        v.term_h = ws.rows;
      },
      else => {},
    }

    const win = tui.vx.window();
    v.term_w = win.width;
    v.term_h = win.height;
    try v.rebuildWrap(win);
    v.draw(win);
    try tui.vx.render(tui.tty.writer());
  }
}
