const std = @import("std");
const vaxis = @import("vaxis");
const search = @import("search.zig");

const types = @import("types.zig");
const Event = types.Event;

const view = @import("../view.zig");
const Tui = view.Tui;

pub const FileEntry = struct {
  path: []const u8,
  mtime: i128,
  size: u64,
};

const FileRow = struct {
  path: []const u8,
  time_str: []const u8,
  size_str: []const u8,
};

pub const Action = enum { view, edit };

pub const PickerResult = struct {
  path: []const u8,
  action: Action,
};

const Picker = struct {
  alloc: std.mem.Allocator,
  files: []FileEntry,
  rows: []FileRow,
  filtered_rows: []FileRow,
  filter_buf: []FileRow,
  cursor: usize = 0,
  scroll: usize = 0,
  search_state: search.SearchState,
  string_allocs: std.ArrayList([]const u8),
  selected: ?[]const u8 = null,
  action: Action = .view,
  show_help: bool = false,
  hovered_idx: ?usize = null,
  term_w: u16 = 0,
  term_h: u16 = 0,
  count_buf: [48]u8 = undefined,
  count_len: usize = 0,

  fn applyFilter(self: *Picker) void {
    const needle = self.search_state.query.items;
    if (needle.len == 0) {
      @memcpy(self.filter_buf[0..self.rows.len], self.rows);
      self.filtered_rows = self.filter_buf[0..self.rows.len];
    } else {
      var count: usize = 0;
      for (self.rows) |row| {
        if (search.containsIgnoreCase(row.path, needle)) {
          self.filter_buf[count] = row;
          count += 1;
        }
      }
      self.filtered_rows = self.filter_buf[0..count];
    }
    self.cursor = 0;
    self.scroll = 0;
    self.updateCount();
  }

  fn refresh(self: *Picker) !void {
    for (self.string_allocs.items) |s| self.alloc.free(s);
    self.string_allocs.clearRetainingCapacity();
    for (self.files) |f| self.alloc.free(f.path);
    self.alloc.free(self.files);
    self.alloc.free(self.rows);
    self.alloc.free(self.filter_buf);

    const files = try collectMarkdownFiles(self.alloc);
    const rows = try self.alloc.alloc(FileRow, files.len);
    const filtered = try self.alloc.alloc(FileRow, files.len);

    for (files, 0..) |f, i| {
      const time_str = try formatTime(self.alloc, f.mtime);
      try self.string_allocs.append(self.alloc, time_str);
      const size_str = try formatSize(self.alloc, f.size);
      try self.string_allocs.append(self.alloc, size_str);
      rows[i] = .{
        .path = f.path,
        .time_str = time_str,
        .size_str = size_str,
      };
    }

    self.files = files;
    self.rows = rows;
    self.filter_buf = filtered;
    self.search_state.clear();
    self.applyFilter();
  }

  fn listHeight(self: *Picker) usize {
    const footer_h: u16 = if (!self.show_help) 1
      else if (self.search_state.active) 3
      else 4;
    return self.term_h -| (2 + footer_h + 1);
  }

  fn ensureScroll(self: *Picker) void {
    const h = self.listHeight();
    if (h == 0) return;
    if (self.cursor < self.scroll) {
      self.scroll = self.cursor;
    } else if (self.cursor >= self.scroll + h) {
      self.scroll = self.cursor - h + 1;
    }
  }

  fn handleKeyPress(self: *Picker, key: vaxis.Key) enum { none, quit, done } {
    if (key.matches('c', .{ .ctrl = true })) return .quit;

    if (self.search_state.active) {
      if (key.matches(vaxis.Key.escape, .{})) {
        self.search_state.active = false;
        self.search_state.clear();
        self.applyFilter();
        return .none;
      }
      if (key.matches(vaxis.Key.enter, .{})) {
        self.search_state.active = false;
        return .none;
      }
      if (key.matches('j', .{ .ctrl = true }) or key.matches(vaxis.Key.down, .{})) {
        self.moveCursor(1);
        return .none;
      }
      if (key.matches('k', .{ .ctrl = true }) or key.matches(vaxis.Key.up, .{})) {
        self.moveCursor(-1);
        return .none;
      }
      if (key.matches(vaxis.Key.backspace, .{})) {
        if (self.search_state.query.items.len > 0) {
          _ = self.search_state.query.pop();
          self.applyFilter();
        }
        return .none;
      }
      if (key.text) |text| {
        self.search_state.query.appendSlice(self.alloc, text) catch {};
        self.applyFilter();
        return .none;
      }
      return .none;
    }

    if (key.matches('q', .{})) return .quit;
    if (key.matches(vaxis.Key.enter, .{})) {
      if (self.cursor < self.filtered_rows.len) {
        self.selected = self.filtered_rows[self.cursor].path;
      }
      return .done;
    }
    if (key.matches('e', .{})) {
      if (self.cursor < self.filtered_rows.len) {
        self.selected = self.filtered_rows[self.cursor].path;
        self.action = .edit;
      }
      return .done;
    }
    if (key.matches('?', .{ .shift = true })) {
      self.show_help = !self.show_help;
      return .none;
    }
    if (key.matches('r', .{})) {
      self.refresh() catch {};
      return .none;
    }
    if (key.matches('/', .{})) {
      self.search_state.active = true;
      return .none;
    }
    if (key.matches('g', .{})) {
      self.cursor = 0;
      self.ensureScroll();
      return .none;
    }
    if (key.matches('G', .{ .shift = true })) {
      if (self.filtered_rows.len > 0) {
        self.cursor = self.filtered_rows.len - 1;
        self.ensureScroll();
      }
      return .none;
    }
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
      self.moveCursor(1);
      return .none;
    }
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
      self.moveCursor(-1);
      return .none;
    }
    return .none;
  }

  fn handleMouse(self: *Picker, mouse: vaxis.Mouse) enum { none, done } {
    if (mouse.button == .wheel_up) {
      self.moveCursor(-3);
      return .none;
    }
    if (mouse.button == .wheel_down) {
      self.moveCursor(3);
      return .none;
    }
    const row_idx = self.mouseToIndex(mouse.row);
    if (mouse.type == .motion or mouse.type == .drag) {
      self.hovered_idx = row_idx;
    }
    if (mouse.type == .press and mouse.button == .left) {
      if (row_idx) |idx| {
        self.cursor = idx;
        self.selected = self.filtered_rows[idx].path;
        return .done;
      }
    }
    return .none;
  }

  fn moveCursor(self: *Picker, delta: i32) void {
    if (self.filtered_rows.len == 0) return;
    const max: i32 = @intCast(self.filtered_rows.len - 1);
    const cur: i32 = @intCast(self.cursor);
    self.cursor = @intCast(std.math.clamp(cur + delta, 0, max));
    self.ensureScroll();
  }

  fn mouseToIndex(self: *Picker, mouse_row: i16) ?usize {
    if (mouse_row < 2) return null;
    const row: usize = @intCast(mouse_row - 2);
    const actual = self.scroll + row;
    if (actual >= self.filtered_rows.len) return null;
    return actual;
  }

  fn draw(self: *Picker, win: vaxis.Window) void {
    win.clear();
    self.drawHeader(win);
    self.drawList(win);
    self.drawFooter(win);
  }

  fn updateCount(self: *Picker) void {
    const result = if (self.search_state.query.items.len > 0)
      std.fmt.bufPrint(&self.count_buf, " {d}/{d} document{s}", .{
        self.filtered_rows.len,
        self.rows.len,
        @as([]const u8, if (self.rows.len != 1) "s" else ""),
      })
    else
      std.fmt.bufPrint(&self.count_buf, " {d} document{s}", .{
        self.rows.len,
        @as([]const u8, if (self.rows.len != 1) "s" else ""),
      });
    self.count_len = if (result) |s| s.len else |_| 0;
  }

  fn drawHeader(self: *Picker, win: vaxis.Window) void {
    if (self.search_state.active) {
      const prompt_style: vaxis.Style = .{ .fg = .{ .rgb = .{ 130, 90, 220 } } };
      const text_style: vaxis.Style = .{ .fg = .{ .rgb = .{ 200, 200, 220 } } };
      var col = writeStr(win, 1, 0, "/", prompt_style);
      col = writeStr(win, col, 0, self.search_state.query.items, text_style);
      win.writeCell(col, 0, .{
        .char = .{ .grapheme = "▏", .width = 1 },
        .style = .{ .fg = .{ .rgb = .{ 130, 90, 220 } } },
      });

      const count_str = self.count_buf[0..self.count_len];
      const count_start = win.width -| @as(u16, @intCast(@min(count_str.len + 1, win.width)));
      _ = writeStr(win, count_start, 0, count_str, .{
        .fg = .{ .rgb = .{ 80, 80, 100 } },
      });
    } else {
      const title_style: vaxis.Style = .{
        .fg = .{ .rgb = .{ 180, 180, 200 } },
        .bold = true,
      };
      _ = writeStr(win, 1, 0, "ink", title_style);

      _ = writeStr(win, 5, 0, self.count_buf[0..self.count_len], .{
        .fg = .{ .rgb = .{ 80, 80, 100 } },
      });
    }

    const sep_style: vaxis.Style = .{ .fg = .{ .rgb = .{ 50, 50, 65 } } };
    var col: u16 = 1;
    while (col < win.width -| 1) : (col += 1) {
      win.writeCell(col, 1, .{
        .char = .{ .grapheme = "─", .width = 1 },
        .style = sep_style,
      });
    }
  }

  fn drawList(self: *Picker, win: vaxis.Window) void {
    const h = self.listHeight();
    const list = win.child(.{ .y_off = 2, .height = @intCast(h) });

    if (self.filtered_rows.len == 0) {
      const msg = if (self.search_state.query.items.len > 0) "No matches found." else "No files found.";
      _ = writeStr(list, 2, 1, msg, .{ .fg = .{ .rgb = .{ 100, 100, 120 } } });
      return;
    }

    var row: u16 = 0;
    while (row < h) : (row += 1) {
      const idx = self.scroll + row;
      if (idx >= self.filtered_rows.len) break;
      const file_row = self.filtered_rows[idx];
      const is_selected = idx == self.cursor;
      const is_hovered = if (self.hovered_idx) |hi| (idx == hi and !is_selected) else false;
      self.drawRow(list, row, file_row, is_selected, is_hovered);
    }
  }

  fn drawRow(self: *Picker, win: vaxis.Window, row: u16, file_row: FileRow, selected: bool, hovered: bool) void {
    _ = self;
    const w = win.width;
    const bg: vaxis.Cell.Color = if (selected) .{ .rgb = .{ 50, 50, 70 } }
      else if (hovered) .{ .rgb = .{ 38, 38, 52 } }
      else .default;

    const bg_style: vaxis.Style = .{ .bg = bg };
    var c: u16 = 0;
    while (c < w) : (c += 1) {
      win.writeCell(c, row, .{ .style = bg_style });
    }

    var col: u16 = 0;
    if (selected) {
      win.writeCell(0, row, .{
        .char = .{ .grapheme = "▌", .width = 1 },
        .style = .{ .fg = .{ .rgb = .{ 130, 90, 220 } }, .bg = bg },
      });
    }
    col = 2;

    const name_style: vaxis.Style = .{
      .fg = if (selected)
        .{ .rgb = .{ 230, 230, 250 } }
      else if (hovered)
        .{ .rgb = .{ 190, 190, 210 } }
      else
        .{ .rgb = .{ 170, 170, 190 } },
      .bg = bg,
      .bold = selected,
    };

    col = writeStr(win, col, row, file_row.path, name_style);

    const meta_style: vaxis.Style = .{
      .fg = .{ .rgb = .{ 80, 80, 100 } },
      .bg = bg,
    };

    const dot_style: vaxis.Style = .{
      .fg = .{ .rgb = .{ 55, 55, 70 } },
      .bg = bg,
    };

    const meta_len: u16 = @intCast(@min(file_row.size_str.len + file_row.time_str.len + 3, w));
    const meta_start = w -| meta_len -| 1;
    if (meta_start > col + 2) {
      var mc = writeStr(win, meta_start, row, file_row.size_str, meta_style);
      mc = writeStr(win, mc + 1, row, "·", dot_style);
      _ = writeStr(win, mc + 1, row, file_row.time_str, meta_style);
    }
  }

  fn drawFooter(self: *Picker, win: vaxis.Window) void {
    const footer_h: u16 = if (!self.show_help) 1
      else if (self.search_state.active) 3
      else 4;
    const footer_y = win.height -| (footer_h + 1);
    const footer = win.child(.{ .y_off = footer_y, .height = footer_h, .x_off = 2 });

    if (self.show_help) {
      self.drawHelp(footer);
      return;
    }

    const key_s: vaxis.Style = .{ .fg = .{ .rgb = .{ 110, 110, 135 } } };
    const desc_s: vaxis.Style = .{ .fg = .{ .rgb = .{ 75, 75, 95 } } };
    const dot_s: vaxis.Style = .{ .fg = .{ .rgb = .{ 55, 55, 70 } } };

    const binds: []const [3][]const u8 = if (self.search_state.active)
      &.{
        .{ "enter", "confirm", " · " },
        .{ "esc", "clear", " · " },
        .{ "e", "edit", " · " },
        .{ "q", "quit", "" },
      }
    else
      &.{
        .{ "/", "find", " · " },
        .{ "r", "refresh", " · " },
        .{ "e", "edit", " · " },
        .{ "q", "quit", " · " },
        .{ "?", "more", "" },
      };

    var col: u16 = 0;
    for (binds) |b| {
      col = writeStr(footer, col, 0, b[0], key_s);
      col = writeStr(footer, col + 1, 0, b[1], desc_s);
      if (b[2].len > 0) col = writeStr(footer, col, 0, b[2], dot_s);
    }
  }

  fn drawHelp(self: *Picker, win: vaxis.Window) void {
    const ks: vaxis.Style = .{ .fg = .{ .rgb = .{ 110, 110, 135 } } };
    const ds: vaxis.Style = .{ .fg = .{ .rgb = .{ 75, 75, 95 } } };

    if (self.search_state.active) {
      var c: u16 = undefined;
      c = writeStr(win, 0, 0, "enter", ks);
      _ = writeStr(win, c + 1, 0, "confirm", ds);
      c = writeStr(win, 0, 1, "esc", ks);
      _ = writeStr(win, c + 1, 1, "cancel", ds);
      c = writeStr(win, 0, 2, "ctrl+j/ctrl+k ↑/↓", ks);
      _ = writeStr(win, c + 1, 2, "choose", ds);
      return;
    }

    const col2: u16 = 22;
    var c: u16 = undefined;

    c = writeStr(win, 0, 0, "enter", ks);
    _ = writeStr(win, c + 1, 0, "open", ds);
    c = writeStr(win, col2, 0, "/", ks);
    _ = writeStr(win, c + 1, 0, "find", ds);

    c = writeStr(win, 0, 1, "j/k ↑/↓", ks);
    _ = writeStr(win, c + 1, 1, "choose", ds);
    c = writeStr(win, col2, 1, "r", ks);
    _ = writeStr(win, c + 1, 1, "refresh", ds);

    c = writeStr(win, 0, 2, "g/G", ks);
    _ = writeStr(win, c + 1, 2, "top/bottom", ds);
    c = writeStr(win, col2, 2, "e", ks);
    _ = writeStr(win, c + 1, 2, "edit", ds);

    _ = writeStr(win, col2, 3, "q", ks);
    _ = writeStr(win, col2 + 2, 3, "quit", ds);

    _ = writeStr(win, col2 + 14, 3, "?", ks);
    _ = writeStr(win, col2 + 16, 3, "close help", ds);
  }
};

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

pub fn collectMarkdownFiles(alloc: std.mem.Allocator) ![]FileEntry {
  var files: std.ArrayListUnmanaged(FileEntry) = .empty;
  errdefer {
    for (files.items) |f| alloc.free(f.path);
    files.deinit(alloc);
  }

  try walkDir(alloc, &files, std.fs.cwd(), "");
  std.mem.sort(FileEntry, files.items, {}, struct {
    fn cmp(_: void, a: FileEntry, b: FileEntry) bool {
      return a.mtime > b.mtime;
    }
  }.cmp);

  return try files.toOwnedSlice(alloc);
}

fn walkDir(alloc: std.mem.Allocator, files: *std.ArrayListUnmanaged(FileEntry), base: std.fs.Dir, prefix: []const u8) !void {
  var dir = base.openDir(if (prefix.len > 0) prefix else ".", .{ .iterate = true }) catch return;
  defer dir.close();

  var iter = dir.iterate();
  while (try iter.next()) |entry| {
    if (entry.name.len > 0 and entry.name[0] == '.') continue;

    const rel = if (prefix.len > 0)
      try std.fmt.allocPrint(alloc, "{s}/{s}", .{ prefix, entry.name })
    else
      try alloc.dupe(u8, entry.name);

    switch (entry.kind) {
      .directory => {
        defer alloc.free(rel);
        try walkDir(alloc, files, base, rel);
      },
      .file => {
        if (std.mem.endsWith(u8, entry.name, ".md") or std.mem.endsWith(u8, entry.name, ".markdown")) {
          const stat = dir.statFile(entry.name) catch {
            alloc.free(rel);
            continue;
          };
          try files.append(alloc, .{
            .path = rel,
            .mtime = stat.mtime,
            .size = stat.size,
          });
        } else {
          alloc.free(rel);
        }
      },
      else => alloc.free(rel),
    }
  }
}

fn formatTime(alloc: std.mem.Allocator, mtime: i128) ![]const u8 {
  if (mtime < 0) return try alloc.dupe(u8, "unknown");

  const epoch_secs: u64 = @intCast(@divFloor(mtime, std.time.ns_per_s));
  const now_secs: u64 = @intCast(std.time.timestamp());
  const age = if (now_secs > epoch_secs) now_secs - epoch_secs else 0;

  if (age < 60) return try alloc.dupe(u8, "just now");
  if (age < 3600) return try std.fmt.allocPrint(alloc, "{d}m ago", .{age / 60});
  if (age < 86400) return try std.fmt.allocPrint(alloc, "{d}h ago", .{age / 3600});
  if (age < 2592000) return try std.fmt.allocPrint(alloc, "{d}d ago", .{age / 86400});
  if (age < 31536000) return try std.fmt.allocPrint(alloc, "{d}mo ago", .{age / 2592000});
  return try std.fmt.allocPrint(alloc, "{d}y ago", .{age / 31536000});
}

fn formatSize(alloc: std.mem.Allocator, size: u64) ![]const u8 {
  if (size < 1024) return try std.fmt.allocPrint(alloc, "{d} B", .{size});
  if (size < 1024 * 1024) {
    const kb = @as(f64, @floatFromInt(size)) / 1024.0;
    return try std.fmt.allocPrint(alloc, "{d:.1} KB", .{kb});
  }
  const mb = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0);
  return try std.fmt.allocPrint(alloc, "{d:.1} MB", .{mb});
}

pub fn run(tui: *Tui) !?PickerResult {
  const alloc = tui.alloc;
  const files = try collectMarkdownFiles(alloc);
  const rows = try alloc.alloc(FileRow, files.len);
  const filtered = try alloc.alloc(FileRow, files.len);

  var string_allocs = std.ArrayList([]const u8).empty;
  for (files, 0..) |f, i| {
    const time_str = try formatTime(alloc, f.mtime);
    try string_allocs.append(alloc, time_str);
    const size_str = try formatSize(alloc, f.size);
    try string_allocs.append(alloc, size_str);
    rows[i] = .{
      .path = f.path,
      .time_str = time_str,
      .size_str = size_str,
    };
  }

  var picker: Picker = .{
    .alloc = alloc,
    .files = files,
    .rows = rows,
    .filtered_rows = filtered[0..rows.len],
    .filter_buf = filtered,
    .search_state = search.SearchState.init(alloc),
    .string_allocs = string_allocs,
  };
  defer {
    for (picker.string_allocs.items) |s| alloc.free(s);
    picker.string_allocs.deinit(alloc);
    for (picker.files) |f| alloc.free(f.path);
    alloc.free(picker.files);
    alloc.free(picker.rows);
    alloc.free(picker.filter_buf);
    picker.search_state.deinit();
  }

  @memcpy(picker.filtered_rows, rows);
  picker.updateCount();

  {
    const win = tui.vx.window();
    picker.term_w = win.width;
    picker.term_h = win.height;
    picker.draw(win);
    try tui.vx.render(tui.tty.writer());
  }

  while (true) {
    const event = tui.loop.nextEvent();
    switch (event) {
      .key_press => |key| {
        switch (picker.handleKeyPress(key)) {
          .quit => return null,
          .done => break,
          .none => {},
        }
      },
      .mouse => |mouse| {
        switch (picker.handleMouse(mouse)) {
          .done => break,
          .none => {},
        }
      },
      .winsize => |ws| {
        try tui.vx.resize(alloc, tui.tty.writer(), ws);
      },
      else => {},
    }

    const win = tui.vx.window();
    picker.term_w = win.width;
    picker.term_h = win.height;
    picker.draw(win);
    try tui.vx.render(tui.tty.writer());
  }

  if (picker.selected) |path| {
    return .{
      .path = try alloc.dupe(u8, path),
      .action = picker.action,
    };
  }
  return null;
}
