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

const Bytes = types.Bytes;
const Event = types.Event;
const SearchState = search.SearchState;
const WrapLayout = wrap.WrapLayout;
const Viewer = viewer.Viewer;
const Memory = memory.Memory;

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

fn refreshContent(alloc: std.mem.Allocator, filename: Bytes, v: *Viewer, prev_rendered: *?[]const u8, prev_arena: *?*node.Arena) void {
  const result = reloadContent(alloc, filename, v.show_urls) catch return;
  const new_parsed = parse.parseAnsiLines(alloc, result.rendered) catch {
    alloc.free(result.rendered);
    result.arena.deinit();
    alloc.destroy(result.arena);
    return;
  };

  if (prev_rendered.*) |r| alloc.free(r);
  if (prev_arena.*) |a| { a.deinit(); alloc.destroy(a); }
  prev_rendered.* = result.rendered;
  prev_arena.* = result.arena;

  const old_scroll = v.scroll;
  v.lines = new_parsed.lines;
  v.headings = new_parsed.headings;
  v.links = new_parsed.links;
  v.num_w = @intCast(viewer.digitCount(new_parsed.lines.len) + 1);
  v.wrap.width = 0;
  v.scroll = old_scroll;
  v.clampScroll();
}

pub fn run(alloc: std.mem.Allocator, rendered: Bytes, filename: Bytes, watching: bool) !void {
  const parsed = try parse.parseAnsiLines(alloc, rendered);
  const mem = Memory.load(alloc);

  var v: Viewer = .{
    .alloc = alloc,
    .lines = parsed.lines,
    .headings = parsed.headings,
    .links = parsed.links,
    .filename = filename,
    .num_w = @intCast(viewer.digitCount(parsed.lines.len) + 1),
    .show_lines = mem.show_lines,
    .show_urls = mem.show_urls,
    .search = SearchState.init(alloc),
    .wrap = WrapLayout.init(alloc),
  };
  
  defer v.search.deinit();
  defer v.wrap.deinit();

  var buffer: [1024]u8 = undefined;
  var tty = try vaxis.Tty.init(&buffer);
  defer tty.deinit();

  var vx = try vaxis.init(alloc, .{});
  defer vx.deinit(alloc, tty.writer());

  var loop: vaxis.Loop(Event) = .{ .tty = &tty, .vaxis = &vx };
  try loop.init();
  try loop.start();
  defer loop.stop();

  var watcher: ?watch.Watcher = null;
  if (watching) {
    watcher = try watch.Watcher.init(filename, &loop);
    _ = try std.Thread.spawn(.{}, watch.Watcher.run, .{&watcher.?});
  }

  var prev_rendered: ?[]const u8 = null;
  var prev_arena: ?*node.Arena = null;
  defer {
    if (prev_rendered) |r| alloc.free(r);
    if (prev_arena) |a| { a.deinit(); alloc.destroy(a); }
  }

  try vx.enterAltScreen(tty.writer());
  try vx.queryTerminal(tty.writer(), 1 * std.time.ns_per_s);
  try vx.setMouseMode(tty.writer(), true);

  while (true) {
    const event = loop.nextEvent();
    switch (event) {
      .file_changed => {
        refreshContent(alloc, filename, &v, &prev_rendered, &prev_arena);
      },
      .key_press => |key| {
        if (v.search.active) {
          try v.handleSearchKey(alloc, key);
        } else {
          const action = v.handleKeyPress(key);
          if (action == .quit) break;
          if (action == .toggle_urls) refreshContent(alloc, filename, &v, &prev_rendered, &prev_arena);
        }
      },
      .mouse => |mouse| v.handleMouse(mouse),
      .winsize => |ws| {
        try vx.resize(alloc, tty.writer(), ws);
        v.term_w = ws.cols;
        v.term_h = ws.rows;
      },
      else => {},
    }

    const win = vx.window();
    v.term_w = win.width;
    v.term_h = win.height;
    try v.rebuildWrap(win);
    v.draw(win);
    try vx.render(tty.writer());
  }
}
