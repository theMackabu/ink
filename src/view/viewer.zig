const std = @import("std");
const vaxis = @import("vaxis");
const types = @import("types.zig");
const search = @import("search.zig");
const wrap_mod = @import("wrap.zig");
const mem = @import("memory.zig");

const Bytes = types.Bytes;
const Key = types.Key;
const Line = types.Line;
const HeadingEntry = types.HeadingEntry;
const FragmentLink = types.FragmentLink;
const ImageEntry = types.ImageEntry;
const WrapPoint = types.WrapPoint;
const SearchState = search.SearchState;
const WrapLayout = wrap_mod.WrapLayout;

pub fn writeStr(win: vaxis.Window, start_col: u16, row: u16, text: Bytes, style: vaxis.Style) u16 {
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

pub fn digitCount(n: usize) usize {
  if (n == 0) return 1;
  var v = n;
  var d: usize = 0;
  while (v > 0) : (v /= 10) d += 1;
  return d;
}

pub const LoadedImage = struct {
  image: vaxis.Image,
  url: Bytes,
};

pub const Viewer = struct {
  alloc: std.mem.Allocator,
  lines: []const Line,
  headings: []const HeadingEntry,
  links: []const FragmentLink,
  images: []const ImageEntry = &.{},
  scroll: usize = 0,
  search: SearchState,
  filename: Bytes,
  num_w: u16,
  show_lines: bool = false,
  show_urls: bool = false,
  line_wrap_percent: u8 = 90,
  term_h: u16 = 24,
  term_w: u16 = 80,
  dragging: bool = false,
  show_help: bool = false,
  has_picker: bool = false,
  yank_active: bool = false,
  yank_ready: bool = false,
  yank_target: ?usize = null,
  yank_input: [8]u8 = undefined,
  yank_input_len: u8 = 0,
  yank_restore_lines: bool = false,
  wrap: WrapLayout,
  toast_msg: ?[]const u8 = null,
  toast_time: ?std.time.Instant = null,
  vx: ?*vaxis.Vaxis = null,
  tty_writer: ?*std.Io.Writer = null,
  loaded_images: std.ArrayListUnmanaged(LoadedImage) = .empty,

  info_buf: [32]u8 = undefined,
  info_slice: []const u8 = "",
  footer_buf: [128]u8 = undefined,
  footer_slice: []const u8 = "",
  pos_buf: [32]u8 = undefined,
  pos_slice: []const u8 = "",

  pub fn contentHeight(self: *const Viewer) u16 {
    const footer_h: u16 = if (self.show_help) 9 else 1;
    return self.term_h -| footer_h;
  }

  pub fn gutterWidth(self: *const Viewer) u16 {
    return if (self.show_lines or self.yank_active) self.num_w else 0;
  }

  pub fn contentWidth(self: *const Viewer) u16 {
    const gw = self.gutterWidth();
    const taken = gw + @as(u16, if (gw > 0) 1 else 0) + 1;
    const full = @max(1, self.term_w -| taken);
    const pct: f64 = @as(f64, @floatFromInt(@min(self.line_wrap_percent, 100))) / 100.0;
    return @max(1, @as(u16, @intFromFloat(@as(f64, @floatFromInt(full)) * pct)));
  }

  pub fn totalVisualRows(self: *const Viewer) usize {
    return self.wrap.total_visual;
  }

  pub fn maxScroll(self: *const Viewer) usize {
    const ch = self.contentHeight();
    const total = self.totalVisualRows();
    const pad: usize = @min(ch / 3, 5);
    if (total + pad <= ch) return 0;
    return total + pad - ch;
  }

  pub fn clampScroll(self: *Viewer) void {
    const ms = self.maxScroll();
    if (self.scroll > ms) self.scroll = ms;
  }

  pub fn rebuildWrap(self: *Viewer, win: vaxis.Window) !void {
    const cw = self.contentWidth();
    if (self.wrap.width == cw and self.wrap.line_counts.items.len == self.lines.len) return;

    const anchor = self.wrap.visualToLogical(self.scroll);

    try self.wrap.rebuild(self.lines, cw, win);

    self.scroll = self.wrap.logicalToVisual(anchor.line_idx) + @min(anchor.wrap_row, self.wrap.wrapCount(anchor.line_idx) -| 1);
    self.clampScroll();
  }

  pub fn scrollToMatch(self: *Viewer) void {
    if (self.search.matches.items.len == 0) return;
    const line = self.search.matches.items[self.search.current];
    const vrow = self.wrap.logicalToVisual(line);
    const ch = self.contentHeight();
    if (vrow < self.scroll or vrow >= self.scroll + ch) {
      self.scroll = if (vrow > ch / 2) vrow - ch / 2 else 0;
      self.clampScroll();
    }
  }

  pub fn nextMatch(self: *Viewer) void {
    if (self.search.matches.items.len == 0) return;
    self.search.current = (self.search.current + 1) % self.search.matches.items.len;
    self.scrollToMatch();
  }

  pub fn prevMatch(self: *Viewer) void {
    if (self.search.matches.items.len == 0) return;
    if (self.search.current == 0)
      self.search.current = self.search.matches.items.len - 1
    else
      self.search.current -= 1;
    self.scrollToMatch();
  }

  pub fn nextHeading(self: *Viewer) void {
    if (self.headings.len == 0) return;
    for (self.headings) |h| {
      const vrow = self.wrap.logicalToVisual(h.line_idx);
      const target = if (vrow > 2) vrow - 2 else 0;
      if (target > self.scroll) {
        self.scroll = target;
        self.clampScroll();
        return;
      }
    }
  }

  pub fn prevHeading(self: *Viewer) void {
    if (self.headings.len == 0) return;
    var i: usize = self.headings.len;
    while (i > 0) {
      i -= 1;
      const vrow = self.wrap.logicalToVisual(self.headings[i].line_idx);
      const target = if (vrow > 2) vrow - 2 else 0;
      if (target < self.scroll) {
        self.scroll = target;
        self.clampScroll();
        return;
      }
    }
  }

  pub fn scrollToRow(self: *Viewer, row: i16) void {
    const ch: f64 = @floatFromInt(self.contentHeight() -| 1);
    const total: f64 = @floatFromInt(self.totalVisualRows());
    const max_s: f64 = @floatFromInt(self.maxScroll());
    if (ch == 0 or total <= ch or max_s == 0) return;
    const thumb_h = @max(1.0, (ch / total) * ch);
    const track = ch - thumb_h;
    if (track <= 0) return;
    const r: f64 = @floatFromInt(@max(0, row));
    const top = @min(@max(r - thumb_h / 2.0, 0.0), track);
    self.scroll = @intFromFloat(@round((top / track) * max_s));
    self.clampScroll();
  }

  pub fn scrollToSlug(self: *Viewer, slug: Bytes) void {
    for (self.headings) |h| {
      if (std.mem.eql(u8, h.slug, slug)) {
        const vrow = self.wrap.logicalToVisual(h.line_idx);
        self.scroll = if (vrow > 2) vrow - 2 else 0;
        self.clampScroll();
        return;
      }
    }
  }

  pub fn hitTestLink(self: *const Viewer, mouse_col: i16, mouse_row: i16) ?Bytes {
    if (mouse_row < 0) return null;
    const vrow = self.scroll + @as(usize, @intCast(mouse_row));
    if (vrow >= self.totalVisualRows()) return null;
    const pos = self.wrap.visualToLogical(vrow);
    if (pos.wrap_row != 0) return null;

    const gw = self.gutterWidth();
    const gutter_end = gw + @as(u16, if (gw > 0) 1 else 0);
    const text_col = if (mouse_col >= gutter_end)
      @as(u16, @intCast(mouse_col)) - gutter_end
    else return null;

    for (self.links) |link| {
      if (
        link.line_idx == pos.line_idx 
        and text_col >= link.col_start 
        and text_col < link.col_end
      ) return link.slug;
    } return null;
  }

  pub fn showToast(self: *Viewer, msg: []const u8) void {
    self.toast_msg = msg;
    self.toast_time = std.time.Instant.now() catch null;
  }

  pub fn deinitImages(self: *Viewer) void {
    if (self.vx) |vx| {
      if (self.tty_writer) |tw| {
        for (self.loaded_images.items) |li| vx.freeImage(tw, li.image.id);
      }
    }
    self.loaded_images.deinit(self.alloc);
  }

  fn getLoadedImage(self: *const Viewer, url: Bytes) ?vaxis.Image {
    for (self.loaded_images.items) |li| {
      if (std.mem.eql(u8, li.url, url)) return li.image;
    }
    return null;
  }

  fn loadImageFor(self: *Viewer, url: Bytes) ?vaxis.Image {
    if (self.getLoadedImage(url)) |img| return img;
    const vx = self.vx orelse return null;
    const tw = self.tty_writer orelse return null;

    const base_dir = std.fs.path.dirname(self.filename) orelse ".";
    const full_path = if (std.fs.path.isAbsolute(url))
      url
    else
      std.fs.path.join(self.alloc, &.{ base_dir, url }) catch return null;

    const img = vx.loadImage(self.alloc, tw, .{ .path = full_path }) catch return null;
    self.loaded_images.append(self.alloc, .{ .image = img, .url = url }) catch return null;
    return img;
  }

  fn isImageLine(self: *Viewer, line_idx: usize) bool {
    for (self.images) |img| {
      if (img.line_idx == line_idx) {
        return self.loadImageFor(img.url) != null;
      }
    }
    return false;
  }

  fn drawImage(self: *Viewer, win: vaxis.Window, row: u16, line_idx: usize) u16 {
    for (self.images) |img| {
      if (img.line_idx == line_idx) {
        const loaded = self.loadImageFor(img.url) orelse return 1;
        const gw = self.gutterWidth();
        const gutter_end = gw + @as(u16, if (gw > 0) 1 else 0);
        const cw = self.contentWidth();
        const cell_size = loaded.cellSize(win) catch return 1;
        const img_h = @min(cell_size.rows, win.height -| row);
        const img_w = @min(cell_size.cols, cw);
        const child = win.child(.{
          .x_off = gutter_end,
          .y_off = row,
          .width = img_w,
          .height = img_h,
        });
        loaded.draw(child, .{ .scale = .contain }) catch return 1;

        var total_h = @max(1, img_h);
        if (img.alt.len > 0 and row + total_h < win.height) {
          const alt_style: vaxis.Style = .{
            .fg = .{ .rgb = .{ 120, 120, 130 } },
            .italic = true,
            .dim = true,
          };
          _ = writeStr(win, gutter_end, row + total_h, img.alt, alt_style);
          total_h += 1;
        }
        return total_h;
      }
    }
    return 1;
  }

  pub fn draw(self: *Viewer, win: vaxis.Window) void {
    win.clear();
    self.drawContent(win);
    self.drawScrollbar(win);
    self.drawFooter(win);
    self.drawToast(win);
  }

  fn drawContent(self: *Viewer, win: vaxis.Window) void {
    const ch = self.contentHeight();
    const content = win.child(.{ .y_off = 0, .height = ch });

    var row: u16 = 0;
    while (row < ch) : (row += 1) {
      const vrow = self.scroll + row;
      if (vrow >= self.totalVisualRows()) break;

      const pos = self.wrap.visualToLogical(vrow);
      const line = &self.lines[pos.line_idx];
      const is_match = self.isMatchLine(pos.line_idx);
      const is_current_match = self.isCurrentMatch(pos.line_idx);

      const is_yank_target = self.yank_active and self.yank_target != null and pos.line_idx == self.yank_target.?;
      if ((self.show_lines or self.yank_active) and pos.wrap_row == 0) {
        self.drawLineNumber(content, row, pos.line_idx, is_current_match or is_yank_target);
      }

      if (pos.wrap_row == 0 and self.isImageLine(pos.line_idx)) {
        const img_rows = self.drawImage(content, row, pos.line_idx);
        row += img_rows -| 1;
        continue;
      }

      const wp = self.wrap.wrapPoint(pos.line_idx, pos.wrap_row);
      const next_wp = if (pos.wrap_row + 1 < self.wrap.wrapCount(pos.line_idx))
        self.wrap.wrapPoint(pos.line_idx, pos.wrap_row + 1)
      else
        null;
      const indent: u16 = if (pos.wrap_row > 0) 2 else 0;
      self.drawWrappedContent(content, row, line, wp, next_wp, is_match, is_current_match, indent);
    }
  }

  fn drawLineNumber(self: *Viewer, win: vaxis.Window, row: u16, line_idx: usize, is_current: bool) void {
    const digits = "0123456789";
    var tmp: [16]u8 = undefined;
    const num = std.fmt.bufPrint(&tmp, "{d}", .{line_idx + 1}) catch return;

    const fg: vaxis.Cell.Color = if (is_current)
      .{ .rgb = .{ 255, 200, 60 } }
    else
      .{ .rgb = .{ 80, 80, 90 } };

    var col: u16 = 0;
    const pad = self.num_w -| @as(u16, @intCast(@min(num.len, self.num_w)));
    while (col < pad) : (col += 1) {
      win.writeCell(col, row, .{ .style = .{ .fg = fg, .dim = !is_current } });
    }
    for (num) |ch| {
      if (col >= self.num_w) break;
      const d = ch - '0';
      win.writeCell(col, row, .{
        .char = .{ .grapheme = digits[d..][0..1], .width = 1 },
        .style = .{ .fg = fg, .dim = !is_current },
      }); col += 1;
    }
  }

  fn drawWrappedContent(
    self: *Viewer,
    win: vaxis.Window,
    row: u16,
    line: *const Line,
    start: WrapPoint,
    end: ?WrapPoint,
    is_match: bool,
    is_current: bool,
    indent: u16,
  ) void {
    const gw = self.gutterWidth();
    const gutter_end = gw + @as(u16, if (gw > 0) 1 else 0);
    var col: u16 = gutter_end + indent;
    const max_col = gutter_end + self.contentWidth();

    const query = self.search.query.items;
    const raw = line.raw;

    var giter = line.graphemeIterator(start, end);
    while (giter.next()) |entry| {
      if (col >= max_col) return;

      const w = win.gwidth(entry.grapheme);
      if (w == 0) continue;

      var style = entry.style;
      if ((is_match or is_current) and query.len > 0 and entry.raw_byte < raw.len) {
        if (isInQueryMatch(raw, query, entry.raw_byte)) {
          if (is_current) {
            style.bg = .{ .rgb = .{ 200, 170, 0 } };
            style.fg = .{ .rgb = .{ 0, 0, 0 } };
          } else {
            const base_rgb = switch (entry.style.bg) {
              .rgb => |rgb| rgb,
              else => [3]u8{ 20, 20, 30 },
            };
            style.bg = .{ .rgb = blend(base_rgb, .{ 160, 160, 180 }, 0.35) };
          }
        }
      }

      win.writeCell(col, row, .{
        .char = .{ .grapheme = entry.grapheme, .width = @intCast(w) },
        .style = style,
      });
      col +|= w;
    }
  }

  fn blend(base: [3]u8, overlay: [3]u8, alpha: f64) [3]u8 {
    var result: [3]u8 = undefined;
    for (0..3) |i| {
      const b: f64 = @floatFromInt(base[i]);
      const o: f64 = @floatFromInt(overlay[i]);
      result[i] = @intFromFloat(b * (1.0 - alpha) + o * alpha);
    }
    return result;
  }

  fn isInQueryMatch(raw: Bytes, query: []const u8, pos: u32) bool {
    const qlen = query.len;
    if (qlen == 0) return false;
    const start_check = if (pos >= qlen - 1) pos - @as(u32, @intCast(qlen - 1)) else 0;
    const end_check = @min(pos, raw.len -| qlen);
    var i = start_check;
    while (i <= end_check) : (i += 1) {
      if (i + qlen > raw.len) break;
      var ok = true;
      for (0..qlen) |j| {
        if (search.toLower(raw[i + j]) != search.toLower(query[j])) {
          ok = false;
          break;
        }
      }
      if (ok and pos >= i and pos < i + qlen) return true;
    }
    return false;
  }

  fn drawScrollbar(self: *Viewer, win: vaxis.Window) void {
    const ch = self.contentHeight();
    const total = self.totalVisualRows();
    if (total <= ch or ch == 0) return;

    const sb_col = self.term_w -| 1;
    const total_f: f64 = @floatFromInt(total);
    const visible: f64 = @floatFromInt(ch);
    const thumb_h_f = @max(1.0, (visible / total_f) * visible);
    const thumb_h: u16 = @intFromFloat(thumb_h_f);
    const scroll_f: f64 = @floatFromInt(self.scroll);
    const max_s: f64 = @floatFromInt(self.maxScroll());
    const track = ch -| thumb_h;
    const thumb_top: u16 = if (max_s > 0)
      @intFromFloat((scroll_f / max_s) * @as(f64, @floatFromInt(track)))
    else
      0;

    const track_style: vaxis.Style = .{ .fg = .{ .rgb = .{ 40, 40, 50 } } };
    const thumb_style: vaxis.Style = .{ .fg = .{ .rgb = .{ 100, 100, 120 } } };

    var row: u16 = 0;
    while (row < ch) : (row += 1) {
      const in_thumb = row >= thumb_top and row < thumb_top + thumb_h;
      win.writeCell(sb_col, row, .{
        .char = .{ .grapheme = if (in_thumb) "▐" else "│", .width = 1 },
        .style = if (in_thumb) thumb_style else track_style,
      });
    }
  }

  fn drawFooter(self: *Viewer, win: vaxis.Window) void {
    const bar_y = self.contentHeight();
    const bar = win.child(.{ .y_off = bar_y, .height = 1 });
    const bg: vaxis.Style = .{
      .bg = .{ .rgb = .{ 40, 40, 50 } },
      .fg = .{ .rgb = .{ 130, 130, 150 } },
    };
    bar.fill(.{ .style = bg });

    const brand_style: vaxis.Style = .{
      .bg = .{ .rgb = .{ 130, 90, 220 } },
      .fg = .{ .rgb = .{ 240, 240, 255 } },
      .bold = true,
    };
    var left = writeStr(bar, 0, 0, " Ink ", brand_style);

    const name_style: vaxis.Style = .{
      .bg = .{ .rgb = .{ 40, 40, 50 } },
      .fg = .{ .rgb = .{ 180, 180, 200 } },
    };
    left = writeStr(bar, left + 1, 0, self.filename, name_style);
    left = writeStr(bar, left + 1, 0, " ", bg);

    if (self.yank_active) {
      const prompt_style: vaxis.Style = .{
        .bg = .{ .rgb = .{ 40, 40, 50 } },
        .fg = .{ .rgb = .{ 255, 200, 60 } },
      };
      left = writeStr(bar, left, 0, ":", prompt_style);
      left = writeStr(bar, left, 0, self.yank_input[0..self.yank_input_len], .{
        .bg = .{ .rgb = .{ 40, 40, 50 } },
        .fg = .{ .rgb = .{ 255, 255, 255 } },
      });
      if (!self.yank_ready) {
        bar.writeCell(left, 0, .{
          .char = .{ .grapheme = " " },
          .style = .{ .bg = .{ .rgb = .{ 200, 200, 200 } } },
        });
      }
    } else if (self.search.active) {
      const prompt_style: vaxis.Style = .{
        .bg = .{ .rgb = .{ 40, 40, 50 } },
        .fg = .{ .rgb = .{ 255, 200, 60 } },
      };
      left = writeStr(bar, left, 0, "/", prompt_style);
      left = writeStr(bar, left, 0, self.search.query.items, .{
        .bg = .{ .rgb = .{ 40, 40, 50 } },
        .fg = .{ .rgb = .{ 255, 255, 255 } },
      });
      bar.writeCell(left, 0, .{
        .char = .{ .grapheme = " " },
        .style = .{ .bg = .{ .rgb = .{ 200, 200, 200 } } },
      });
    } else if (self.search.matches.items.len > 0) {
      self.footer_slice = std.fmt.bufPrint(&self.footer_buf, "[{d}/{d}] \"{s}\"", .{
        self.search.current + 1,
        self.search.matches.items.len,
        self.search.query.items,
      }) catch return;
      left = writeStr(bar, left, 0, self.footer_slice, .{
        .bg = .{ .rgb = .{ 40, 40, 50 } },
        .fg = .{ .rgb = .{ 255, 200, 60 } },
      });
    }

    if (!self.show_help) {
      const ik: vaxis.Style = .{ .bg = bg.bg, .fg = .{ .rgb = .{ 143, 143, 176 } } };
      const id: vaxis.Style = .{ .bg = bg.bg, .fg = .{ .rgb = .{ 98, 98, 124 } } };
      const it: vaxis.Style = .{ .bg = bg.bg, .fg = .{ .rgb = .{ 72, 72, 91 } } };
      if (self.yank_active) {
        left += 2;
        if (self.yank_ready) {
          left = writeStr(bar, left, 0, "enter", ik);
          left = writeStr(bar, left + 1, 0, "copy", id);
          left = writeStr(bar, left, 0, " • ", it);
        } else {
          left = writeStr(bar, left, 0, "enter", ik);
          left = writeStr(bar, left + 1, 0, "go to line", id);
          left = writeStr(bar, left, 0, " • ", it);
        }
        left = writeStr(bar, left, 0, "esc", ik);
        _ = writeStr(bar, left + 1, 0, "cancel", id);
      } else if (self.search.matches.items.len > 0) {
        left += 2;
        left = writeStr(bar, left, 0, "n/N", ik);
        left = writeStr(bar, left + 1, 0, "next/prev", id);
        left = writeStr(bar, left, 0, " • ", it);
        left = writeStr(bar, left, 0, "esc", ik);
        left = writeStr(bar, left + 1, 0, "clear", id);
      } else if (!self.search.active) {
        left = writeStr(bar, left, 0, "/", ik);
        left = writeStr(bar, left + 1, 0, "find", id);
        left = writeStr(bar, left, 0, " • ", it);
        left = writeStr(bar, left, 0, "?", ik);
        _ = writeStr(bar, left + 1, 0, "more", id);
      }
    }

    if (self.totalVisualRows() <= self.contentHeight()) {
      self.pos_slice = "All ";
    } else if (self.scroll == 0) {
      self.pos_slice = "Top ";
    } else if (self.scroll >= self.maxScroll()) {
      self.pos_slice = "End ";
    } else {
      const pct = (self.scroll * 100) / self.maxScroll();
      self.pos_slice = std.fmt.bufPrint(&self.pos_buf, "{d}% ", .{pct}) catch return;
    }

    self.info_slice = std.fmt.bufPrint(&self.info_buf, "{d}L ", .{self.lines.len}) catch return;
    const right_len = self.pos_slice.len + self.info_slice.len;
    const right_start = self.term_w -| @as(u16, @intCast(@min(right_len, self.term_w)));
    const rc = writeStr(bar, right_start, 0, self.pos_slice, bg);
    _ = writeStr(bar, rc, 0, self.info_slice, bg);

    if (self.show_help) {
      self.drawHelp(win, bar_y + 2);
    }
  }

  fn drawHelp(self: *Viewer, win: vaxis.Window, y: u16) void {
    const ks: vaxis.Style = .{ .fg = .{ .rgb = .{ 110, 110, 135 } } };
    const ds: vaxis.Style = .{ .fg = .{ .rgb = .{ 75, 75, 95 } } };

    if (self.search.active or self.search.matches.items.len > 0) {
      const help = win.child(.{ .x_off = 1, .y_off = y, .height = 3 });
      var c: u16 = undefined;

      c = writeStr(help, 1, 0, "enter/n", ks);
      _ = writeStr(help, c + 1, 0, "next match", ds);

      c = writeStr(help, 1, 1, "N", ks);
      _ = writeStr(help, c + 1, 1, "prev match", ds);

      c = writeStr(help, 1, 2, "esc", ks);
      _ = writeStr(help, c + 1, 2, "clear search", ds);
    } else {
      const help = win.child(.{ .x_off = 1, .y_off = y, .height = 6 });
      const col2: u16 = 21;
      const col3: u16 = 40;
      const col4: u16 = 59;
      var c: u16 = undefined;

      c = writeStr(help, 1, 0, "k/↑", ks);
      _ = writeStr(help, c + 1, 0, "up", ds);
      c = writeStr(help, col2, 0, "g/home", ks);
      _ = writeStr(help, c + 1, 0, "top", ds);
      c = writeStr(help, col3, 0, "/", ks);
      _ = writeStr(help, c + 1, 0, "find", ds);

      c = writeStr(help, 1, 1, "j/↓", ks);
      _ = writeStr(help, c + 1, 1, "down", ds);
      c = writeStr(help, col2, 1, "G/end", ks);
      _ = writeStr(help, c + 1, 1, "bottom", ds);
      c = writeStr(help, col3, 1, "t", ks);
      _ = writeStr(help, c + 1, 1, "outline", ds);

      c = writeStr(help, 1, 2, "b/pgup", ks);
      _ = writeStr(help, c + 1, 2, "page up", ds);
      c = writeStr(help, col2, 2, "u", ks);
      _ = writeStr(help, c + 1, 2, "½ page up", ds);
      c = writeStr(help, col3, 2, "c", ks);
      _ = writeStr(help, c + 1, 2, "copy document", ds);

      c = writeStr(help, 1, 3, "f/pgdn", ks);
      _ = writeStr(help, c + 1, 3, "page down", ds);
      c = writeStr(help, col2, 3, "d", ks);
      _ = writeStr(help, c + 1, 3, "½ page down", ds);
      c = writeStr(help, col3, 3, "y", ks);
      _ = writeStr(help, c + 1, 3, "yank mode", ds);
      if (self.has_picker) {
        c = writeStr(help, col4, 3, "esc", ks);
        _ = writeStr(help, c + 1, 3, "back to files", ds);
      }

      c = writeStr(help, 1, 4, "]", ks);
      _ = writeStr(help, c + 1, 4, "next heading", ds);
      c = writeStr(help, col2, 4, "U", ks);
      _ = writeStr(help, c + 1, 4, "urls", ds);
      c = writeStr(help, col3, 4, "e", ks);
      _ = writeStr(help, c + 1, 4, "edit", ds);
      c = writeStr(help, col4, 4, "q", ks);
      _ = writeStr(help, c + 1, 4, "quit", ds);

      c = writeStr(help, 1, 5, "[", ks);
      _ = writeStr(help, c + 1, 5, "prev heading", ds);
      c = writeStr(help, col2, 5, "l", ks);
      _ = writeStr(help, c + 1, 5, "line numbers", ds);
      c = writeStr(help, col3, 5, "r", ks);
      _ = writeStr(help, c + 1, 5, "reload", ds);
      c = writeStr(help, col4, 5, "?", ks);
      _ = writeStr(help, c + 1, 5, "close help", ds);
    }
  }

  fn isMatchLine(self: *const Viewer, idx: usize) bool {
    for (self.search.matches.items) |m| {
      if (m == idx) return true;
    }
    return false;
  }

  fn isCurrentMatch(self: *const Viewer, idx: usize) bool {
    if (self.search.matches.items.len == 0) return false;
    return self.search.matches.items[self.search.current] == idx;
  }

  pub fn handleSearchKey(self: *Viewer, alloc: std.mem.Allocator, key: Key) !void {
    const search_keys = [_]struct { u21, Key.Modifiers, SearchAction }{
      .{ Key.escape,    .{},  .cancel },
      .{ Key.enter,     .{},  .submit },
      .{ Key.backspace, .{},  .delete },
    };

    for (search_keys) |bind| {
      if (key.matches(bind[0], bind[1]) or (bind[2] == .cancel and key.codepoint == Key.escape)) {
        switch (bind[2]) {
          .cancel => { self.search.active = false; self.search.clear(); },
          .submit => {
            self.search.active = false;
            self.search.find(self.lines);
            if (self.search.matches.items.len > 0) self.scrollToMatch();
          },
          .delete => { if (self.search.query.items.len > 0) _ = self.search.query.pop(); },
        }
        return;
      }
    }

    if (key.text) |text|
      try self.search.query.appendSlice(alloc, text)
    else if (key.codepoint >= 0x20 and key.codepoint < 0x7f)
      try self.search.query.append(alloc, @intCast(key.codepoint));
  }

  pub fn handleYankKey(self: *Viewer, key: Key) Action {
    if (key.matches(Key.escape, .{}) or key.codepoint == Key.escape) {
      self.exitYankMode();
      return .none;
    }
    if (key.matches(Key.enter, .{})) {
      if (self.yank_ready) {
        self.copyYankTarget();
        self.exitYankMode();
        return .copy_line;
      }
      const num = std.fmt.parseInt(usize, self.yank_input[0..self.yank_input_len], 10) catch 0;
      if (num > 0 and num <= self.lines.len) {
        self.yank_target = num - 1;
        self.scrollToLine(num - 1);
        self.yank_ready = true;
      }
      return .none;
    }
    if (key.matches(Key.backspace, .{})) {
      if (self.yank_input_len > 0) {
        self.yank_input_len -= 1;
        self.yank_ready = false;
        self.yank_target = null;
      }
      return .none;
    }
    if (key.codepoint >= '0' and key.codepoint <= '9') {
      if (self.yank_input_len < self.yank_input.len) {
        self.yank_input[self.yank_input_len] = @intCast(key.codepoint);
        self.yank_input_len += 1;
        self.yank_ready = false;
        self.yank_target = null;
      }
      return .none;
    }
    return .none;
  }

  fn exitYankMode(self: *Viewer) void {
    self.yank_active = false;
    self.yank_ready = false;
    self.yank_target = null;
    self.yank_input_len = 0;
    if (self.yank_restore_lines) {
      self.show_lines = false;
      self.yank_restore_lines = false;
    }
    self.wrap.width = 0;
  }

  fn scrollToLine(self: *Viewer, line_idx: usize) void {
    const vrow = self.wrap.logicalToVisual(line_idx);
    const ch = self.contentHeight();
    self.scroll = if (vrow > ch / 2) vrow - ch / 2 else 0;
    self.clampScroll();
  }

  fn copyYankTarget(self: *Viewer) void {
    const idx = self.yank_target orelse return;
    if (idx >= self.lines.len) return;
    const line = self.lines[idx];
    const cmd: []const []const u8 = switch (@import("builtin").os.tag) {
      .macos => &.{"pbcopy"},
      .windows => &.{ "cmd", "/c", "clip" },
      else => &.{"xclip", "-selection", "clipboard"},
    };
    var child = std.process.Child.init(cmd, self.alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return;
    if (child.stdin) |stdin| {
      stdin.writeAll(line.raw) catch {};
      stdin.close();
      child.stdin = null;
    }
    _ = child.wait() catch {};
    self.showToast("Line copied");
  }

  const SearchAction = enum { cancel, submit, delete };

  pub const Action = enum {
    none,
    quit,
    back_to_picker,
    edit,
    reload,
    copy_contents,
    start_search,
    next_match,
    prev_match,
    scroll_top,
    scroll_bottom,
    scroll_up,
    scroll_down,
    page_up,
    page_down,
    half_page_down,
    half_page_up,
    toggle_lines,
    toggle_urls,
    toggle_help,
    next_heading,
    prev_heading,
    outline,
    copy_line,
  };

  const Binding = struct { u21, Key.Modifiers, Action };

  const key_bindings = [_]Binding{
    .{ 'q',           .{},                .quit },
    .{ 'c',           .{ .ctrl = true },  .quit },
    .{ '/',           .{},                .start_search },
    .{ 'n',           .{},                .next_match },
    .{ Key.enter,     .{},                .next_match },
    .{ 'N',           .{ .shift = true }, .prev_match },
    .{ 'g',           .{},                .scroll_top },
    .{ Key.home,      .{},                .scroll_top },
    .{ 'G',           .{ .shift = true }, .scroll_bottom },
    .{ Key.end,       .{},                .scroll_bottom },
    .{ Key.up,        .{},                .scroll_up },
    .{ 'k',           .{},                .scroll_up },
    .{ Key.down,      .{},                .scroll_down },
    .{ 'j',           .{},                .scroll_down },
    .{ Key.page_up,   .{},                .page_up },
    .{ 'b',           .{},                .page_up },
    .{ ' ',           .{ .shift = true }, .page_up },
    .{ Key.page_down, .{},               .page_down },
    .{ 'f',           .{},                .page_down },
    .{ ' ',           .{},                .page_down },
    .{ 'd',           .{},                .half_page_down },
    .{ 'u',           .{},                .half_page_up },
    .{ 'c',           .{},                .copy_contents },
    .{ 'e',           .{},                .edit },
    .{ 'r',           .{},                .reload },
    .{ ']',           .{},                .next_heading },
    .{ '[',           .{},                .prev_heading },
    .{ 't',           .{},                .outline },
    .{ 'y',           .{},                .copy_line },
    .{ 'l',           .{},                .toggle_lines },
    .{ 'U',           .{ .shift = true }, .toggle_urls },
    .{ '?',           .{ .shift = true }, .toggle_help },
  };

  pub fn handleKeyPress(self: *Viewer, key: Key) Action {
    if (key.matches(Key.escape, .{}) or key.codepoint == Key.escape) {
      if (self.search.matches.items.len > 0) {
        self.search.clear();
        return .none;
      }
      return if (self.has_picker) .back_to_picker else .quit;
    }

    for (key_bindings) |bind| {
      if (key.matches(bind[0], bind[1])) {
        self.execAction(bind[2]);
        return bind[2];
      }
    }
    return .none;
  }

  fn execAction(self: *Viewer, action: Action) void {
    switch (action) {
      .start_search => { self.search.active = true; self.search.clear(); },
      .next_match => self.nextMatch(),
      .prev_match => self.prevMatch(),
      .scroll_top => self.scroll = 0,
      .scroll_bottom => self.scroll = self.maxScroll(),
      .scroll_up => { if (self.scroll > 0) self.scroll -= 1; },
      .scroll_down => { if (self.scroll < self.maxScroll()) self.scroll += 1; },
      .page_up => self.scroll -|= self.contentHeight(),
      .page_down => self.scroll = @min(self.scroll + self.contentHeight(), self.maxScroll()),
      .half_page_down => self.scroll = @min(self.scroll + self.contentHeight() / 2, self.maxScroll()),
      .half_page_up => self.scroll -|= self.contentHeight() / 2,
      .toggle_lines => {
        self.show_lines = !self.show_lines;
        self.wrap.width = 0;
        self.saveMemory();
      },
      .toggle_urls => {
        self.show_urls = !self.show_urls;
        self.saveMemory();
      },
      .toggle_help => self.show_help = !self.show_help,
      .copy_contents => self.copyContents(),
      .copy_line => {
        self.yank_active = true;
        self.yank_ready = false;
        self.yank_target = null;
        self.yank_input_len = 0;
        if (!self.show_lines) {
          self.yank_restore_lines = true;
          self.wrap.width = 0;
        }
      },
      .next_heading => self.nextHeading(),
      .prev_heading => self.prevHeading(),
      .quit, .none, .back_to_picker, .edit, .reload, .outline => {},
    }
  }

  fn saveMemory(self: *Viewer) void {
    const m: mem.Memory = .{
      .show_lines = self.show_lines,
      .show_urls = self.show_urls,
    };
    m.save(self.alloc);
  }

  fn copyContents(self: *Viewer) void {
    var raw_parts: std.ArrayListUnmanaged(u8) = .empty;
    defer raw_parts.deinit(self.alloc);
    for (self.lines) |line| {
      raw_parts.appendSlice(self.alloc, line.raw) catch return;
      raw_parts.append(self.alloc, '\n') catch return;
    }
    const cmd: []const []const u8 = switch (@import("builtin").os.tag) {
      .macos => &.{"pbcopy"},
      .windows => &.{ "cmd", "/c", "clip" },
      else => &.{"xclip", "-selection", "clipboard"},
    };
    var child = std.process.Child.init(cmd, self.alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return;
    if (child.stdin) |stdin| {
      stdin.writeAll(raw_parts.items) catch {};
      stdin.close();
      child.stdin = null;
    }
    _ = child.wait() catch {};
    self.showToast("Copied to clipboard");
  }

  fn drawToast(self: *Viewer, win: vaxis.Window) void {
    const start = self.toast_time orelse return;
    const msg = self.toast_msg orelse return;
    const now = std.time.Instant.now() catch return;
    const elapsed = now.since(start);
    if (elapsed > 2 * std.time.ns_per_s) {
      self.toast_msg = null;
      self.toast_time = null;
      return;
    }

    const len: u16 = @intCast(@min(msg.len + 4, win.width));
    const x = win.width -| len;
    const toast = win.child(.{ .x_off = x, .y_off = 0, .width = len, .height = 1 });

    const fade = elapsed > 1_500_000_000;
    const bg_rgb: [3]u8 = if (fade) .{ 45, 40, 55 } else .{ 55, 45, 70 };
    const fg_rgb: [3]u8 = if (fade) .{ 140, 130, 160 } else .{ 220, 210, 240 };
    const icon_rgb: [3]u8 = if (fade) .{ 90, 70, 140 } else .{ 130, 90, 220 };
    const style: vaxis.Style = .{ .bg = .{ .rgb = bg_rgb }, .fg = .{ .rgb = fg_rgb } };

    toast.fill(.{ .style = style });
    const col = writeStr(toast, 1, 0, "✓", .{ .bg = .{ .rgb = bg_rgb }, .fg = .{ .rgb = icon_rgb }, .bold = true });
    _ = writeStr(toast, col + 1, 0, msg, style);
  }

  fn isExternalUrl(slug: Bytes) bool {
    return std.mem.startsWith(u8, slug, "http://") 
      or std.mem.startsWith(u8, slug, "https://");
  }

  fn openUrl(_: *Viewer, url: Bytes) void {
    const cmd: []const []const u8 = switch (@import("builtin").os.tag) {
      .macos => &.{ "open", url },
      .windows => &.{ "cmd", "/c", "start", url },
      else => &.{ "xdg-open", url },
    };
    var child = std.process.Child.init(cmd, std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return;
  }

  pub fn handleMouse(self: *Viewer, mouse: vaxis.Mouse) void {
    const sb_col: i16 = @intCast(self.term_w -| 1);
    switch (mouse.type) {
      .press => {
        if (mouse.button == .left and mouse.col < sb_col - 1) {
          if (self.hitTestLink(mouse.col, mouse.row)) |slug| {
            if (isExternalUrl(slug)) self.openUrl(slug)
            else self.scrollToSlug(slug);
          }
        } else if (mouse.button == .left and mouse.col >= sb_col - 1) {
          self.dragging = true;
          self.scrollToRow(mouse.row);
        } else if (mouse.button == .wheel_up) {
          self.scroll -|= 1;
        } else if (mouse.button == .wheel_down) {
          self.scroll = @min(self.scroll + 1, self.maxScroll());
        }
      },
      .drag => {
        if (self.dragging) self.scrollToRow(mouse.row);
      },
      .release => {
        self.dragging = false;
      },
      else => {},
    }
  }
};
