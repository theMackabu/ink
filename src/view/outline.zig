const std = @import("std");
const vaxis = @import("vaxis");
const search = @import("search.zig");
const types = @import("types.zig");

const view = @import("../view.zig");
const Tui = view.Tui;
const Key = vaxis.Key;
const HeadingEntry = types.HeadingEntry;

pub const OutlineResult = struct { line_idx: usize };

const Result = enum { none, quit, done };
const Panel = struct { x: u16, y: u16, w: u16, h: u16, list_h: u16 };

const level_labels = [_][]const u8{ "h?", "h1", "h2", "h3", "h4", "h5", "h6" };
const digits = "0123456789";

const Outline = struct {
  alloc: std.mem.Allocator,
  headings: []const HeadingEntry,
  filtered: []usize,
  filtered_len: usize,
  cursor: usize = 0,
  scroll: usize = 0,
  searching: bool = false,
  query: std.ArrayListUnmanaged(u8) = .empty,
  hovered: ?usize = null,
  term_w: u16 = 0,
  term_h: u16 = 0,

  fn panel(self: *const Outline) Panel {
    const w: u16 = @min(60, self.term_w -| 4);
    const max_h: u16 = self.term_h -| 8;
    const list_h: u16 = @min(max_h, @as(u16, @intCast(@min(self.headings.len, max_h))));
    const h: u16 = list_h + 3;
    return .{
      .x = (self.term_w -| w) / 2,
      .y = (self.term_h -| h) / 2,
      .w = w, .h = h, .list_h = list_h,
    };
  }

  fn moveCursor(self: *Outline, delta: i32) void {
    if (self.filtered_len == 0) return;
    const max: i32 = @intCast(self.filtered_len - 1);
    self.cursor = @intCast(std.math.clamp(@as(i32, @intCast(self.cursor)) + delta, 0, max));
    const h = self.panel().list_h;
    if (h > 0) {
      if (self.cursor < self.scroll) self.scroll = self.cursor;
      if (self.cursor >= self.scroll + h) self.scroll = self.cursor - h + 1;
    }
  }

  fn applyFilter(self: *Outline) void {
    if (self.query.items.len == 0) {
      for (0..self.headings.len) |i| self.filtered[i] = i;
      self.filtered_len = self.headings.len;
    } else {
      var n: usize = 0;
      for (self.headings, 0..) |h, i| {
        if (search.containsIgnoreCase(h.raw, self.query.items)) {
          self.filtered[n] = i;
          n += 1;
        }
      }
      self.filtered_len = n;
    }
    self.cursor = 0;
    self.scroll = 0;
  }

  fn handleKey(self: *Outline, key: Key) Result {
    if (key.matches('c', .{ .ctrl = true })) return .quit;

    if (self.searching) return self.handleSearchKey(key);

    if (key.matches(Key.escape, .{}) or key.codepoint == Key.escape or key.matches('t', .{})) return .quit;
    if (key.matches(Key.enter, .{})) return if (self.filtered_len > 0) .done else .quit;
    if (key.matches('/', .{})) { self.searching = true; return .none; }
    if (key.matches('j', .{}) or key.matches(Key.down, .{})) { self.moveCursor(1); return .none; }
    if (key.matches('k', .{}) or key.matches(Key.up, .{})) { self.moveCursor(-1); return .none; }
    if (key.matches('g', .{})) { self.moveCursor(-@as(i32, @intCast(self.cursor))); return .none; }
    if (key.matches('G', .{ .shift = true })) { self.moveCursor(@intCast(self.filtered_len)); return .none; }
    return .none;
  }

  fn handleSearchKey(self: *Outline, key: Key) Result {
    if (key.matches(Key.escape, .{})) {
      self.searching = false;
      self.query.clearRetainingCapacity();
      self.applyFilter();
    } else if (key.matches(Key.enter, .{})) {
      self.searching = false;
    } else if (key.matches('j', .{ .ctrl = true }) or key.matches(Key.down, .{})) {
      self.moveCursor(1);
    } else if (key.matches('k', .{ .ctrl = true }) or key.matches(Key.up, .{})) {
      self.moveCursor(-1);
    } else if (key.matches(Key.backspace, .{})) {
      if (self.query.items.len > 0) { _ = self.query.pop(); self.applyFilter(); }
    } else if (key.text) |text| {
      self.query.appendSlice(self.alloc, text) catch {};
      self.applyFilter();
    }
    return .none;
  }

  fn handleMouse(self: *Outline, mouse: vaxis.Mouse) Result {
    if (mouse.button == .wheel_up) { self.moveCursor(-3); return .none; }
    if (mouse.button == .wheel_down) { self.moveCursor(3); return .none; }

    const pm = self.panel();
    const list_y = pm.y + 2;
    const in_panel = mouse.row >= list_y and mouse.col >= pm.x and mouse.col < pm.x + pm.w;

    if (mouse.type == .motion or mouse.type == .drag) {
      self.hovered = if (in_panel) blk: {
        const idx = @as(usize, @intCast(@as(i32, mouse.row) - @as(i32, list_y))) + self.scroll;
        break :blk if (idx < self.filtered_len) idx else null;
      } else null;
    }

    if (mouse.type == .press and mouse.button == .left and in_panel) {
      const idx = @as(usize, @intCast(@as(i32, mouse.row) - @as(i32, list_y))) + self.scroll;
      if (idx < self.filtered_len) { self.cursor = idx; return .done; }
    }
    return .none;
  }

  fn draw(self: *Outline, win: vaxis.Window) void {
    const pm = self.panel();
    const p = win.child(.{ .x_off = pm.x, .y_off = pm.y, .width = pm.w, .height = pm.h });

    const bg: [3]u8 = .{ 30, 28, 40 };
    const border: [3]u8 = .{ 60, 55, 80 };
    const border_s: vaxis.Style = .{ .bg = .{ .rgb = bg }, .fg = .{ .rgb = border } };
    p.fill(.{ .style = .{ .bg = .{ .rgb = bg } } });

    self.drawBorder(p, pm, border_s);
    _ = writeStr(p, (pm.w -| 7) / 2, 0, "Outline", .{ .bg = .{ .rgb = bg }, .fg = .{ .rgb = .{ 180, 170, 210 } }, .bold = true });
    self.drawSearch(p, bg);
    self.drawList(p, pm, bg);
  }

  fn drawBorder(_: *Outline, p: vaxis.Window, pm: Panel, s: vaxis.Style) void {
    var x: u16 = 0;
    while (x < pm.w) : (x += 1) {
      p.writeCell(x, 0, .{ .char = .{ .grapheme = if (x == 0) "╭" else if (x == pm.w - 1) "╮" else "─", .width = 1 }, .style = s });
      p.writeCell(x, pm.h -| 1, .{ .char = .{ .grapheme = if (x == 0) "╰" else if (x == pm.w - 1) "╯" else "─", .width = 1 }, .style = s });
    }
    var y: u16 = 1;
    while (y < pm.h -| 1) : (y += 1) {
      p.writeCell(0, y, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = s });
      p.writeCell(pm.w -| 1, y, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = s });
    }
  }

  fn drawSearch(self: *Outline, p: vaxis.Window, bg: [3]u8) void {
    const prompt_s: vaxis.Style = .{ .bg = .{ .rgb = bg }, .fg = .{ .rgb = .{ 130, 90, 220 } } };
    const query_s: vaxis.Style = .{ .bg = .{ .rgb = bg }, .fg = .{ .rgb = .{ 220, 210, 240 } } };
    var col = writeStr(p, 2, 1, "/", prompt_s);
    col = writeStr(p, col, 1, self.query.items, query_s);
    p.writeCell(col, 1, .{
      .char = .{ .grapheme = " " },
      .style = .{ .bg = .{ .rgb = if (self.searching) .{ 160, 150, 180 } else bg } },
    });
  }

  fn drawList(self: *Outline, p: vaxis.Window, pm: Panel, bg: [3]u8) void {
    var row: u16 = 0;
    while (row < pm.list_h) : (row += 1) {
      const idx = self.scroll + row;
      if (idx >= self.filtered_len) break;

      const h = self.headings[self.filtered[idx]];
      const sel = idx == self.cursor;
      const hov = if (self.hovered) |hv| hv == idx else false;
      const rbg: [3]u8 = if (sel) .{ 55, 45, 80 } else if (hov) .{ 40, 36, 55 } else bg;
      const y = row + 2;

      var cx: u16 = 1;
      while (cx < pm.w -| 1) : (cx += 1)
        p.writeCell(cx, y, .{ .style = .{ .bg = .{ .rgb = rbg } } });

      if (sel) p.writeCell(1, y, .{
        .char = .{ .grapheme = "▌", .width = 1 },
        .style = .{ .bg = .{ .rgb = rbg }, .fg = .{ .rgb = .{ 130, 90, 220 } } },
      });

      const indent: u16 = (h.h_count -| 1) * 2;
      const lfg = levelColor(h.h_count, sel);
      const label = if (h.h_count <= 6) level_labels[h.h_count] else "h?";
      _ = writeStr(p, 3 + indent, y, label, .{ .bg = .{ .rgb = rbg }, .fg = .{ .rgb = lfg }, .bold = sel });

      const tx: u16 = 6 + indent;
      const max_w = pm.w -| (tx + 8);
      const text = if (h.raw.len > max_w) h.raw[0..max_w] else h.raw;
      const tfg: [3]u8 = if (sel) .{ 240, 230, 255 } else .{ 170, 165, 190 };
      const tc = writeStr(p, tx, y, text, .{ .bg = .{ .rgb = rbg }, .fg = .{ .rgb = tfg }, .bold = sel });

      const nfg: [3]u8 = if (sel) .{ 130, 90, 220 } else .{ 80, 75, 100 };
      self.drawLineNum(p, pm.w, y, h.line_idx + 1, tc, rbg, nfg);
    }
  }

  fn drawLineNum(_: *Outline, p: vaxis.Window, pw: u16, y: u16, num: usize, min_x: u16, bg: [3]u8, fg: [3]u8) void {
    const nd = digitCount(num);
    const lx = pw -| @as(u16, @intCast(nd + 2));
    if (lx <= min_x) return;

    const s: vaxis.Style = .{ .bg = .{ .rgb = bg }, .fg = .{ .rgb = fg } };
    p.writeCell(lx, y, .{ .char = .{ .grapheme = "L", .width = 1 }, .style = s });

    var tmp: [16]u8 = undefined;
    const str = std.fmt.bufPrint(&tmp, "{d}", .{num}) catch return;
    var dx: u16 = lx + 1;
    for (str) |ch| {
      if (dx >= pw -| 1) break;
      p.writeCell(dx, y, .{ .char = .{ .grapheme = digits[ch - '0' ..][0..1], .width = 1 }, .style = s });
      dx += 1;
    }
  }
};

fn levelColor(h: u8, sel: bool) [3]u8 {
  return switch (h) {
    1 => if (sel) .{ 255, 130, 130 } else .{ 200, 80, 80 },
    2 => if (sel) .{ 255, 220, 130 } else .{ 200, 170, 80 },
    3 => if (sel) .{ 130, 230, 160 } else .{ 80, 180, 110 },
    4 => if (sel) .{ 130, 220, 240 } else .{ 80, 170, 190 },
    5 => if (sel) .{ 140, 160, 255 } else .{ 90, 110, 200 },
    else => if (sel) .{ 200, 150, 255 } else .{ 150, 100, 200 },
  };
}

fn digitCount(n: usize) usize {
  if (n == 0) return 1;
  var v = n;
  var d: usize = 0;
  while (v > 0) : (v /= 10) d += 1;
  return d;
}

fn writeStr(win: vaxis.Window, start_col: u16, row: u16, text: []const u8, style: vaxis.Style) u16 {
  var col = start_col;
  var giter = vaxis.unicode.graphemeIterator(text);
  while (giter.next()) |g| {
    if (col >= win.width) break;
    const grapheme = g.bytes(text);
    const w = win.gwidth(grapheme);
    if (w == 0) continue;
    win.writeCell(col, row, .{
      .char = .{ .grapheme = grapheme, .width = @intCast(w) },
      .style = style,
    });
    col +|= w;
  }
  return col;
}

pub fn run(tui: *Tui, headings: []const HeadingEntry) !?OutlineResult {
  if (headings.len == 0) return null;

  const alloc = tui.alloc;
  var filtered = try alloc.alloc(usize, headings.len);
  defer alloc.free(filtered);
  for (0..headings.len) |i| filtered[i] = i;

  var ol: Outline = .{
    .alloc = alloc,
    .headings = headings,
    .filtered = filtered,
    .filtered_len = headings.len,
  };
  defer ol.query.deinit(alloc);

  {
    const win = tui.vx.window();
    ol.term_w = win.width;
    ol.term_h = win.height;
    ol.draw(win);
    try tui.vx.render(tui.tty.writer());
  }

  while (true) {
    const event = tui.loop.nextEvent();
    switch (event) {
      .key_press => |key| switch (ol.handleKey(key)) {
        .quit => return null,
        .done => return .{ .line_idx = headings[ol.filtered[ol.cursor]].line_idx },
        .none => {},
      },
      .mouse => |mouse| switch (ol.handleMouse(mouse)) {
        .done => return .{ .line_idx = headings[ol.filtered[ol.cursor]].line_idx },
        .quit => return null,
        .none => {},
      },
      .winsize => |ws| try tui.vx.resize(alloc, tui.tty.writer(), ws),
      else => {},
    }

    const win = tui.vx.window();
    ol.term_w = win.width;
    ol.term_h = win.height;
    ol.draw(win);
    try tui.vx.render(tui.tty.writer());
  }
}
