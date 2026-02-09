const std = @import("std");
const vaxis = @import("vaxis");
const types = @import("types.zig");
const search = @import("search.zig");
const wrap_mod = @import("wrap.zig");

const Bytes = types.Bytes;
const Key = types.Key;
const Line = types.Line;
const HeadingEntry = types.HeadingEntry;
const FragmentLink = types.FragmentLink;
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

pub const Viewer = struct {
  lines: []const Line,
  headings: []const HeadingEntry,
  links: []const FragmentLink,
  scroll: usize = 0,
  search: SearchState,
  filename: Bytes,
  num_w: u16,
  term_h: u16 = 24,
  term_w: u16 = 80,
  dragging: bool = false,
  wrap: WrapLayout,

  info_buf: [32]u8 = undefined,
  info_slice: []const u8 = "",
  footer_buf: [128]u8 = undefined,
  footer_slice: []const u8 = "",
  pos_buf: [32]u8 = undefined,
  pos_slice: []const u8 = "",

  pub fn contentHeight(self: *const Viewer) u16 {
    return self.term_h -| 1;
  }

  pub fn contentWidth(self: *const Viewer) u16 {
    const taken = self.num_w + 1 + 1;
    const full = @max(1, self.term_w -| taken);
    return @max(1, @as(u16, @intFromFloat(@as(f64, @floatFromInt(full)) * 0.9)));
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

    const text_col = if (mouse_col >= self.num_w + 1)
      @as(u16, @intCast(mouse_col)) - self.num_w - 1
    else
      return null;

    for (self.links) |link| {
      if (link.line_idx == pos.line_idx and text_col >= link.col_start and text_col < link.col_end) {
        return link.slug;
      }
    }
    return null;
  }

  pub fn draw(self: *Viewer, win: vaxis.Window) void {
    win.clear();
    self.drawContent(win);
    self.drawScrollbar(win);
    self.drawFooter(win);
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

      if (pos.wrap_row == 0) {
        self.drawLineNumber(content, row, pos.line_idx, is_current_match);
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
    var col: u16 = self.num_w + 1 + indent;
    const max_col = self.num_w + 1 + self.contentWidth();

    const query = self.search.query.items;
    const raw = line.raw;

    var seg_i: u32 = start.seg_idx;
    var raw_byte: u32 = 0;
    {
      var si: u32 = 0;
      while (si < start.seg_idx) : (si += 1) {
        raw_byte += @intCast(line.segments[si].text.len);
      }
      raw_byte += start.byte_off;
    }

    while (seg_i < line.segments.len) : (seg_i += 1) {
      const seg = &line.segments[seg_i];
      const base_style = seg.style;

      const byte_start: u32 = if (seg_i == start.seg_idx) start.byte_off else 0;
      const text = seg.text[byte_start..];

      var giter = vaxis.unicode.graphemeIterator(text);
      while (giter.next()) |g| {
        if (end) |e| {
          const abs_pos = byte_start + @as(u32, @intCast(g.start));
          if (seg_i > e.seg_idx or (seg_i == e.seg_idx and abs_pos >= e.byte_off))
            return;
        }
        if (col >= max_col) return;

        const grapheme = g.bytes(text);
        const w = win.gwidth(grapheme);
        if (w == 0) {
          raw_byte += @intCast(grapheme.len);
          continue;
        }

        var style = base_style;
        if ((is_match or is_current) and query.len > 0 and raw_byte < raw.len) {
          if (isInQueryMatch(raw, query, raw_byte)) {
            if (is_current) {
              style.bg = .{ .rgb = .{ 200, 170, 0 } };
              style.fg = .{ .rgb = .{ 0, 0, 0 } };
            } else {
              const base_rgb = switch (base_style.bg) {
                .rgb => |rgb| rgb,
                else => [3]u8{ 20, 20, 30 },
              };
              style.bg = .{ .rgb = blend(base_rgb, .{ 160, 160, 180 }, 0.35) };
            }
          }
        }

        win.writeCell(col, row, .{
          .char = .{ .grapheme = grapheme, .width = @intCast(w) },
          .style = style,
        });
        col +|= w;
        raw_byte += @intCast(grapheme.len);
      }
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
    const y = self.term_h -| 1;
    const bar = win.child(.{ .y_off = y, .height = 1 });
    const bg: vaxis.Style = .{
      .bg = .{ .rgb = .{ 40, 40, 50 } },
      .fg = .{ .rgb = .{ 130, 130, 150 } },
    };
    bar.fill(.{ .style = bg });

    const name_style: vaxis.Style = .{
      .bg = .{ .rgb = .{ 40, 40, 50 } },
      .fg = .{ .rgb = .{ 180, 180, 200 } },
    };
    var left = writeStr(bar, 1, 0, self.filename, name_style);
    left = writeStr(bar, left + 1, 0, " ", bg);

    if (self.search.active) {
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
      left = writeStr(bar, left + 1, 0, "n/N/enter next/prev  esc clear", bg);
    } else {
      left = writeStr(bar, left, 0, "q quit  / search  g/G top/end", bg);
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

  const SearchAction = enum { cancel, submit, delete };

  pub const Action = enum {
    none,
    quit,
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
  };

  const Binding = struct { u21, Key.Modifiers, Action };

  const key_bindings = [_]Binding{
    .{ 'q',          .{},             .quit },
    .{ 'c',          .{ .ctrl = true }, .quit },
    .{ '/',          .{},             .start_search },
    .{ 'n',          .{},             .next_match },
    .{ Key.enter,    .{},             .next_match },
    .{ 'N',          .{ .shift = true }, .prev_match },
    .{ 'g',          .{},             .scroll_top },
    .{ 'G',          .{ .shift = true }, .scroll_bottom },
    .{ Key.up,       .{},             .scroll_up },
    .{ 'k',          .{},             .scroll_up },
    .{ Key.down,     .{},             .scroll_down },
    .{ 'j',          .{},             .scroll_down },
    .{ Key.page_up,  .{},             .page_up },
    .{ ' ',          .{ .shift = true }, .page_up },
    .{ Key.page_down, .{},            .page_down },
    .{ ' ',          .{},             .page_down },
    .{ 'd',          .{ .ctrl = true }, .half_page_down },
    .{ 'u',          .{ .ctrl = true }, .half_page_up },
  };

  pub fn handleKeyPress(self: *Viewer, key: Key) Action {
    if (key.matches(Key.escape, .{}) or key.codepoint == Key.escape) {
      if (self.search.matches.items.len > 0) {
        self.search.clear();
        return .none;
      }
      return .quit;
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
      .quit, .none => {},
    }
  }

  pub fn handleMouse(self: *Viewer, mouse: vaxis.Mouse) void {
    const sb_col: i16 = @intCast(self.term_w -| 1);
    switch (mouse.type) {
      .press => {
        if (mouse.button == .left and mouse.col < sb_col - 1) {
          if (self.hitTestLink(mouse.col, mouse.row)) |slug| {
            self.scrollToSlug(slug);
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
