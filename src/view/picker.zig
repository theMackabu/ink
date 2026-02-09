const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const search = @import("search.zig");

pub const FileEntry = struct {
  path: []const u8,
  mtime: i128,
  size: u64,
};

const FileRow = struct {
  path: []const u8,
  time_str: []const u8,
  size_str: []const u8,
  selected: bool = false,
  hovered: bool = false,

  pub fn widget(self: *const FileRow) vxfw.Widget {
    return .{
      .userdata = @constCast(self),
      .drawFn = FileRow.typeErasedDrawFn,
    };
  }

  fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *const FileRow = @ptrCast(@alignCast(ptr));
    const max = ctx.max.size();
    const w = max.width;

    const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = w, .height = 1 });
    const bg: vaxis.Style = if (self.selected) .{ .bg = .{ .rgb = .{ 50, 50, 70 } } }
    else if (self.hovered) .{ .bg = .{ .rgb = .{ 38, 38, 52 } } }
    else .{};

    @memset(surface.buffer, .{ .style = bg });

    var col: u16 = 0;

    if (self.selected) {
      surface.writeCell(0, 0, .{
        .char = .{ .grapheme = "▌", .width = 1 },
        .style = .{ .fg = .{ .rgb = .{ 130, 90, 220 } }, .bg = bg.bg },
      });
    }
    col = 2;

    const name_style: vaxis.Style = .{
      .fg = if (self.selected)
        .{ .rgb = .{ 230, 230, 250 } }
      else if (self.hovered)
        .{ .rgb = .{ 190, 190, 210 } }
      else
        .{ .rgb = .{ 170, 170, 190 } },
      .bg = bg.bg,
      .bold = self.selected,
    };

    col = writeStr(surface, col, 0, self.path, name_style);

    const meta_style: vaxis.Style = .{
      .fg = .{ .rgb = .{ 80, 80, 100 } },
      .bg = bg.bg,
    };
    
    const dot_style: vaxis.Style = .{
      .fg = .{ .rgb = .{ 55, 55, 70 } },
      .bg = bg.bg,
    };

    const meta_len: u16 = @intCast(@min(self.size_str.len + self.time_str.len + 3, w));
    const meta_start = w -| meta_len -| 1;
    if (meta_start > col + 2) {
      var mc = writeStr(surface, meta_start, 0, self.size_str, meta_style);
      mc = writeStr(surface, mc + 1, 0, "·", dot_style);
      _ = writeStr(surface, mc + 1, 0, self.time_str, meta_style);
    }

    return surface;
  }
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
  list_view: vxfw.ListView,
  search_state: search.SearchState,
  string_allocs: std.ArrayList([]const u8),
  selected: ?[]const u8 = null,
  action: Action = .view,
  show_help: bool = false,
  hovered_idx: ?usize = null,

  pub fn widget(self: *Picker) vxfw.Widget {
    return .{
      .userdata = self,
      .eventHandler = Picker.typeErasedEventHandler,
      .drawFn = Picker.typeErasedDrawFn,
    };
  }

  fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *Picker = @ptrCast(@alignCast(ptr));
    switch (event) {
      .init => return ctx.requestFocus(self.list_view.widget()),
      .key_press => |key| {
        if (key.matches('c', .{ .ctrl = true })) {
          ctx.quit = true;
          return;
        }

        if (self.search_state.active) {
          if (key.matches(vaxis.Key.escape, .{})) {
            self.search_state.active = false;
            self.search_state.clear();
            self.applyFilter();
            try ctx.requestFocus(self.list_view.widget());
            return ctx.consumeAndRedraw();
          }
          if (key.matches(vaxis.Key.enter, .{})) {
            self.search_state.active = false;
            try ctx.requestFocus(self.list_view.widget());
            return ctx.consumeAndRedraw();
          }
          if (key.matches('j', .{ .ctrl = true }) or key.matches(vaxis.Key.down, .{})) {
            return self.list_view.handleEvent(ctx, event);
          }
          if (key.matches('k', .{ .ctrl = true }) or key.matches(vaxis.Key.up, .{})) {
            return self.list_view.handleEvent(ctx, event);
          }
          if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.search_state.query.items.len > 0) {
              _ = self.search_state.query.pop();
              self.applyFilter();
            }
            return ctx.consumeAndRedraw();
          }
          if (key.text) |text| {
            self.search_state.query.appendSlice(self.alloc, text) catch {};
            self.applyFilter();
            return ctx.consumeAndRedraw();
          }
          return;
        }

        if (key.matches('q', .{})) {
          ctx.quit = true;
          return;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
          if (self.list_view.cursor < self.filtered_rows.len) {
            self.selected = self.filtered_rows[self.list_view.cursor].path;
          }
          ctx.quit = true;
          return;
        }
        if (key.matches('e', .{})) {
          if (self.list_view.cursor < self.filtered_rows.len) {
            self.selected = self.filtered_rows[self.list_view.cursor].path;
            self.action = .edit;
          }
          ctx.quit = true;
          return;
        }
        if (key.matches('?', .{ .shift = true })) {
          self.show_help = !self.show_help;
          return ctx.consumeAndRedraw();
        }
        if (key.matches('r', .{})) {
          self.refresh() catch {};
          return ctx.consumeAndRedraw();
        }
        if (key.matches('/', .{})) {
          self.search_state.active = true;
          try ctx.requestFocus(self.widget());
          return ctx.consumeAndRedraw();
        }
        if (key.matches('g', .{})) {
          self.list_view.cursor = 0;
          self.list_view.ensureScroll();
          return ctx.consumeAndRedraw();
        }
        if (key.matches('G', .{ .shift = true })) {
          if (self.filtered_rows.len > 0) {
            self.list_view.cursor = @intCast(self.filtered_rows.len - 1);
            self.list_view.ensureScroll();
          }
          return ctx.consumeAndRedraw();
        }
        return self.list_view.handleEvent(ctx, event);
      },
      .focus_in => return ctx.requestFocus(self.list_view.widget()),
      .mouse => |mouse| {
        if (mouse.button == .wheel_up or mouse.button == .wheel_down) {
          return self.list_view.handleEvent(ctx, .{ .mouse = mouse });
        }
        const row_idx = self.mouseToIndex(mouse.row);
        if (mouse.type == .motion or mouse.type == .drag) {
          if (row_idx != self.hovered_idx) {
            self.hovered_idx = row_idx;
            return ctx.consumeAndRedraw();
          }
        }
        if (mouse.type == .press and mouse.button == .left) {
          if (row_idx) |idx| {
            self.list_view.cursor = @intCast(idx);
            self.selected = self.filtered_rows[idx].path;
            ctx.quit = true;
          }
        }
      },
      .mouse_leave => {
        if (self.hovered_idx != null) {
          self.hovered_idx = null;
          return ctx.consumeAndRedraw();
        }
      },
      else => {},
    }
  }

  fn mouseToIndex(self: *Picker, mouse_row: i16) ?usize {
    if (mouse_row < 2) return null;
    const row: usize = @intCast(mouse_row - 2);
    const actual = self.list_view.scroll.top + row;
    if (actual >= self.filtered_rows.len) return null;
    return actual;
  }

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
    self.list_view.item_count = @intCast(self.filtered_rows.len);
    self.list_view.cursor = 0;
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

  fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Picker = @ptrCast(@alignCast(ptr));
    const max = ctx.max.size();

    for (self.filtered_rows, 0..) |*row, i| {
      row.selected = (i == self.list_view.cursor);
      row.hovered = if (self.hovered_idx) |h| (i == h and !row.selected) else false;
    }

    const header = try self.drawHeader(ctx, max.width);
    const footer = try self.drawFooter(ctx, max.width);
    const footer_h: u16 = if (!self.show_help) 1
      else if (self.search_state.active) 3
      else 4;

    const list_height = max.height -| (2 + footer_h + 1);
    const list_surface: vxfw.SubSurface = .{
      .origin = .{ .row = 2, .col = 0 },
      .surface = try self.list_view.draw(ctx.withConstraints(
        .{ .width = max.width, .height = 0 },
        .{ .width = max.width, .height = list_height },
      )),
    };

    const children = try ctx.arena.alloc(vxfw.SubSurface, 3);
    children[0] = .{
      .origin = .{ .row = 0, .col = 0 },
      .surface = header,
    };
    children[1] = list_surface;
    children[2] = .{
      .origin = .{ .row = max.height -| (footer_h + 1), .col = 2 },
      .surface = footer,
    };

    return .{
      .size = max,
      .widget = self.widget(),
      .buffer = &.{},
      .children = children,
    };
  }

  fn drawHeader(self: *Picker, ctx: vxfw.DrawContext, w: u16) std.mem.Allocator.Error!vxfw.Surface {
    const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = w, .height = 2 });

    if (self.search_state.active) {
      const prompt_style: vaxis.Style = .{ .fg = .{ .rgb = .{ 130, 90, 220 } } };
      const text_style: vaxis.Style = .{ .fg = .{ .rgb = .{ 200, 200, 220 } } };
      var col = writeStr(surface, 1, 0, "/", prompt_style);
      col = writeStr(surface, col, 0, self.search_state.query.items, text_style);
      surface.writeCell(col, 0, .{
        .char = .{ .grapheme = "▏", .width = 1 },
        .style = .{ .fg = .{ .rgb = .{ 130, 90, 220 } } },
      });

      const count_str = try std.fmt.allocPrint(ctx.arena, "{d}/{d}", .{
        self.filtered_rows.len,
        self.rows.len,
      });
      const count_start = w -| @as(u16, @intCast(@min(count_str.len + 1, w)));
      _ = writeStr(surface, count_start, 0, count_str, .{
        .fg = .{ .rgb = .{ 80, 80, 100 } },
      });
    } else {
      const title_style: vaxis.Style = .{
        .fg = .{ .rgb = .{ 180, 180, 200 } },
        .bold = true,
      };
      _ = writeStr(surface, 1, 0, "ink", title_style);

      const count_str = if (self.search_state.query.items.len > 0)
        try std.fmt.allocPrint(ctx.arena, " {d}/{d} document{s}", .{
          self.filtered_rows.len,
          self.rows.len,
          if (self.rows.len != 1) "s" else "",
        })
      else
        try std.fmt.allocPrint(ctx.arena, " {d} document{s}", .{
          self.rows.len,
          if (self.rows.len != 1) "s" else "",
        });
      _ = writeStr(surface, 5, 0, count_str, .{
        .fg = .{ .rgb = .{ 80, 80, 100 } },
      });
    }

    const sep_style: vaxis.Style = .{ .fg = .{ .rgb = .{ 50, 50, 65 } } };
    var col: u16 = 1;
    while (col < w -| 1) : (col += 1) {
      surface.writeCell(col, 1, .{
        .char = .{ .grapheme = "─", .width = 1 },
        .style = sep_style,
      });
    }

    return surface;
  }

  fn drawFooter(self: *Picker, ctx: vxfw.DrawContext, w: u16) std.mem.Allocator.Error!vxfw.Surface {
    if (self.show_help) return self.drawHelp(ctx, w);

    const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = w, .height = 1 });
    const key_s: vaxis.Style = .{ .fg = .{ .rgb = .{ 110, 110, 135 } } };
    const desc_s: vaxis.Style = .{ .fg = .{ .rgb = .{ 75, 75, 95 } } };
    const dot_s: vaxis.Style = .{ .fg = .{ .rgb = .{ 55, 55, 70 } } };

    const binds: []const [3][]const u8 = if (self.search_state.active)
      &.{
        .{ "enter", "confirm", " • " },
        .{ "esc", "clear", " • " },
        .{ "e", "edit", " • " },
        .{ "q", "quit", "" },
      }
    else
      &.{
        .{ "/", "find", " • " },
        .{ "r", "refresh", " • " },
        .{ "e", "edit", " • " },
        .{ "q", "quit", " • " },
        .{ "?", "more", "" },
      };

    var col: u16 = 1;
    for (binds) |b| {
      col = writeStr(surface, col, 0, b[0], key_s);
      col = writeStr(surface, col + 1, 0, b[1], desc_s);
      if (b[2].len > 0) col = writeStr(surface, col, 0, b[2], dot_s);
    }
    return surface;
  }

  fn drawHelp(self: *Picker, ctx: vxfw.DrawContext, w: u16) std.mem.Allocator.Error!vxfw.Surface {
    const ks: vaxis.Style = .{ .fg = .{ .rgb = .{ 110, 110, 135 } } };
    const ds: vaxis.Style = .{ .fg = .{ .rgb = .{ 75, 75, 95 } } };

    if (self.search_state.active) {
      const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = w, .height = 3 });
      var c: u16 = undefined;

      c = writeStr(surface, 1, 0, "enter", ks);
      _ = writeStr(surface, c + 1, 0, "confirm", ds);

      c = writeStr(surface, 1, 1, "esc", ks);
      _ = writeStr(surface, c + 1, 1, "cancel", ds);

      c = writeStr(surface, 1, 2, "ctrl+j/ctrl+k ↑/↓", ks);
      _ = writeStr(surface, c + 1, 2, "choose", ds);

      return surface;
    }

    const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = w, .height = 4 });
    const col2: u16 = 22;
    var c: u16 = undefined;

    c = writeStr(surface, 1, 0, "enter", ks);
    _ = writeStr(surface, c + 1, 0, "open", ds);
    c = writeStr(surface, col2, 0, "/", ks);
    _ = writeStr(surface, c + 1, 0, "find", ds);

    c = writeStr(surface, 1, 1, "j/k ↑/↓", ks);
    _ = writeStr(surface, c + 1, 1, "choose", ds);
    c = writeStr(surface, col2, 1, "r", ks);
    _ = writeStr(surface, c + 1, 1, "refresh", ds);

    c = writeStr(surface, 1, 2, "g/G", ks);
    _ = writeStr(surface, c + 1, 2, "top/bottom", ds);
    c = writeStr(surface, col2, 2, "e", ks);
    _ = writeStr(surface, c + 1, 2, "edit", ds);

    _ = writeStr(surface, col2, 3, "q", ks);
    _ = writeStr(surface, col2 + 2, 3, "quit", ds);

    _ = writeStr(surface, col2 + 14, 3, "?", ks);
    _ = writeStr(surface, col2 + 16, 3, "close help", ds);

    return surface;
  }

  fn widgetBuilder(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
    const self: *const Picker = @ptrCast(@alignCast(ptr));
    if (idx >= self.filtered_rows.len) return null;
    return self.filtered_rows[idx].widget();
  }
};

fn writeStr(surface: vxfw.Surface, start_col: u16, row: u16, text: []const u8, style: vaxis.Style) u16 {
  var col = start_col;
  var giter = vaxis.unicode.graphemeIterator(text);
  while (giter.next()) |g| {
    if (col >= surface.size.width) break;
    const grapheme = g.bytes(text);
    const w: u8 = @intCast(vaxis.gwidth.gwidth(grapheme, .unicode));
    if (w == 0) continue;
    surface.writeCell(col, row, .{
      .char = .{ .grapheme = grapheme, .width = w },
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

pub fn run(alloc: std.mem.Allocator) !?PickerResult {
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

  const picker = try alloc.create(Picker);
  defer {
    for (picker.string_allocs.items) |s| alloc.free(s);
    picker.string_allocs.deinit(alloc);
    for (picker.files) |f| alloc.free(f.path);
    alloc.free(picker.files);
    alloc.free(picker.rows);
    alloc.free(picker.filter_buf);
    picker.search_state.deinit();
    alloc.destroy(picker);
  }

  picker.* = .{
    .alloc = alloc,
    .files = files,
    .rows = rows,
    .filtered_rows = filtered[0..rows.len],
    .filter_buf = filtered,
    .search_state = search.SearchState.init(alloc),
    .string_allocs = string_allocs,
    .list_view = .{
      .draw_cursor = false,
      .wheel_scroll = 3,
      .item_count = @intCast(files.len),
      .children = .{
        .builder = .{
          .userdata = picker,
          .buildFn = Picker.widgetBuilder,
        },
      },
    },
  };

  @memcpy(picker.filtered_rows, rows);

  var app = try vxfw.App.init(alloc);
  defer app.deinit();

  try app.run(picker.widget(), .{});

  if (picker.selected) |path| {
    return .{
      .path = try alloc.dupe(u8, path),
      .action = picker.action,
    };
  }
  return null;
}
