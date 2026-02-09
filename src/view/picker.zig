const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

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

const Picker = struct {
  alloc: std.mem.Allocator,
  files: []FileEntry,
  rows: []FileRow,
  list_view: vxfw.ListView,
  selected: ?[]const u8 = null,

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
        if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) {
          ctx.quit = true;
          return;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
          if (self.list_view.cursor < self.files.len) {
            self.selected = self.files[self.list_view.cursor].path;
          }
          ctx.quit = true;
          return;
        }
        if (key.matches('g', .{})) {
          self.list_view.cursor = 0;
          self.list_view.ensureScroll();
          return ctx.consumeAndRedraw();
        }
        if (key.matches('G', .{ .shift = true })) {
          if (self.files.len > 0) {
            self.list_view.cursor = @intCast(self.files.len - 1);
            self.list_view.ensureScroll();
          }
          return ctx.consumeAndRedraw();
        }
        return self.list_view.handleEvent(ctx, event);
      },
      .focus_in => return ctx.requestFocus(self.list_view.widget()),
      .mouse => |mouse| return self.list_view.handleEvent(ctx, .{ .mouse = mouse }),
      else => {},
    }
  }

  fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Picker = @ptrCast(@alignCast(ptr));
    const max = ctx.max.size();

    for (self.rows, 0..) |*row, i| {
      row.selected = (i == self.list_view.cursor);
    }

    const header = try self.drawHeader(ctx, max.width);
    const footer = try self.drawFooter(ctx, max.width);

    const list_height = max.height -| 3;
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
      .origin = .{ .row = max.height -| 1, .col = 0 },
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

    const title_style: vaxis.Style = .{
      .fg = .{ .rgb = .{ 180, 180, 200 } },
      .bold = true,
    };
    _ = writeStr(surface, 1, 0, "ink", title_style);

    const count_str = try std.fmt.allocPrint(ctx.arena, " {d} markdown file{s}", .{
      self.files.len,
      if (self.files.len != 1) "s" else "",
    });
    _ = writeStr(surface, 5, 0, count_str, .{
      .fg = .{ .rgb = .{ 80, 80, 100 } },
    });

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
    const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = w, .height = 1 });

    const bg: vaxis.Style = .{
      .bg = .{ .rgb = .{ 40, 40, 50 } },
      .fg = .{ .rgb = .{ 130, 130, 150 } },
    };
    @memset(surface.buffer, .{ .style = bg });

    _ = writeStr(surface, 1, 0, "enter open  j/k up/down  g/G top/end  q quit", bg);

    const pos_str = try std.fmt.allocPrint(ctx.arena, "{d}/{d} ", .{
      if (self.files.len > 0) self.list_view.cursor + 1 else @as(u32, 0),
      self.files.len,
    });
    const pos_start = w -| @as(u16, @intCast(@min(pos_str.len, w)));
    _ = writeStr(surface, pos_start, 0, pos_str, bg);

    return surface;
  }

  fn widgetBuilder(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
    const self: *const Picker = @ptrCast(@alignCast(ptr));
    if (idx >= self.rows.len) return null;
    return self.rows[idx].widget();
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

pub fn run(alloc: std.mem.Allocator) !?[]const u8 {
  const files = try collectMarkdownFiles(alloc);
  defer {
    for (files) |f| alloc.free(f.path);
    alloc.free(files);
  }

  const rows = try alloc.alloc(FileRow, files.len);
  defer alloc.free(rows);

  var string_allocs = std.ArrayList([]const u8).empty;
  defer {
    for (string_allocs.items) |s| alloc.free(s);
    string_allocs.deinit(alloc);
  }

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
  defer alloc.destroy(picker);

  picker.* = .{
    .alloc = alloc,
    .files = files,
    .rows = rows,
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

  var app = try vxfw.App.init(alloc);
  defer app.deinit();

  try app.run(picker.widget(), .{});

  if (picker.selected) |path| {
    return try alloc.dupe(u8, path);
  }
  return null;
}
