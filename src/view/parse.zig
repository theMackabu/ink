const std = @import("std");
const vaxis = @import("vaxis");
const types = @import("types.zig");

const Bytes = types.Bytes;
const Segment = types.Segment;
const Line = types.Line;
const HeadingEntry = types.HeadingEntry;
const FragmentLink = types.FragmentLink;
const ImageEntry = types.ImageEntry;
const ParseResult = types.ParseResult;

pub fn parseSgr(seq: Bytes, current: vaxis.Style) vaxis.Style {
  var style = current;
  if (seq.len < 3) return style;
  const params = seq[2 .. seq.len - 1];
  if (params.len == 0) return .{};

  var iter = std.mem.splitScalar(u8, params, ';');
  while (iter.next()) |param| {
    const code = std.fmt.parseInt(u8, param, 10) catch continue;
    switch (code) {
      0 => style = .{},
      1 => style.bold = true,
      2 => style.dim = true,
      3 => style.italic = true,
      4 => style.ul_style = .single,
      7 => style.reverse = true,
      9 => style.strikethrough = true,
      22 => { style.bold = false; style.dim = false; },
      23 => style.italic = false,
      24 => style.ul_style = .off,
      27 => style.reverse = false,
      29 => style.strikethrough = false,
      31 => style.fg = .{ .index = 1 },
      32 => style.fg = .{ .index = 2 },
      33 => style.fg = .{ .index = 3 },
      34 => style.fg = .{ .index = 4 },
      35 => style.fg = .{ .index = 5 },
      36 => style.fg = .{ .index = 6 },
      37 => style.fg = .{ .index = 7 },
      38 => { if (parseSgrColor(&iter)) |c| style.fg = c; },
      39 => style.fg = .default,
      48 => { if (parseSgrColor(&iter)) |c| style.bg = c; },
      49 => style.bg = .default,
      90 => style.fg = .{ .index = 8 },
      91 => style.fg = .{ .index = 9 },
      92 => style.fg = .{ .index = 10 },
      93 => style.fg = .{ .index = 11 },
      94 => style.fg = .{ .index = 12 },
      95 => style.fg = .{ .index = 13 },
      96 => style.fg = .{ .index = 14 },
      97 => style.fg = .{ .index = 15 },
      else => {},
    }
  }
  return style;
}

pub fn parseSgrColor(iter: *std.mem.SplitIterator(u8, .scalar)) ?vaxis.Cell.Color {
  const kind = iter.next() orelse return null;
  const kind_val = std.fmt.parseInt(u8, kind, 10) catch return null;
  switch (kind_val) {
    5 => {
      const idx = iter.next() orelse return null;
      const val = std.fmt.parseInt(u8, idx, 10) catch return null;
      return .{ .index = val };
    },
    2 => {
      const r_s = iter.next() orelse return null;
      const g_s = iter.next() orelse return null;
      const b_s = iter.next() orelse return null;
      const r = std.fmt.parseInt(u8, r_s, 10) catch return null;
      const g = std.fmt.parseInt(u8, g_s, 10) catch return null;
      const bv = std.fmt.parseInt(u8, b_s, 10) catch return null;
      return .{ .rgb = .{ r, g, bv } };
    },
    else => return null,
  }
}

pub fn parseApc(data: Bytes, i: *usize) ?Bytes {
  const start = i.*;
  if (start + 1 >= data.len) return null;
  if (data[start] != 0x1b or data[start + 1] != '_') return null;

  var p = start + 2;
  while (p + 1 < data.len) : (p += 1) {
    if (data[p] == 0x1b and data[p + 1] == '\\') {
      const payload = data[start + 2 .. p];
      i.* = p + 2;
      return payload;
    }
  }
  return null;
}

fn parseApcPayload(
  payload: Bytes,
  line_idx: usize,
  headings: *std.ArrayListUnmanaged(HeadingEntry),
  links: *std.ArrayListUnmanaged(FragmentLink),
  images: *std.ArrayListUnmanaged(ImageEntry),
  link_state: *LinkState,
  no_wrap: *bool,
  alloc: std.mem.Allocator,
) !void {
  if (payload.len < 2) {
    if (payload.len == 1) {
      switch (payload[0]) {
        'R' => no_wrap.* = true,
        'E' => try finishLink(link_state, line_idx, links, alloc),
        else => {},
      }
    }
    return;
  }

  const tag = payload[0];
  if (payload[1] != ';') return;

  const data = payload[2..];
  switch (tag) {
    'H' => {
      var iter = std.mem.splitScalar(u8, data, ';');
      const level_str = iter.next() orelse data;
      const raw_text = iter.next() orelse data;
      const slug = iter.next() orelse data;
      const h_count = std.fmt.parseInt(u8, level_str, 10) catch 1;
      try headings.append(alloc, .{ 
        .slug = slug, .line_idx = line_idx, 
        .raw = raw_text, .h_count = h_count 
      });
    },
    'I' => {
      if (std.mem.indexOfScalar(u8, data, ';')) |sep| {
        try images.append(alloc, .{
          .line_idx = line_idx,
          .url = data[0..sep],
          .alt = data[sep + 1 ..],
        });
      }
    },
    'L' => {
      link_state.slug = data;
      link_state.col_start = link_state.current_col;
      link_state.active = true;
    },
    else => {},
  }
}

fn finishLink(
  state: *LinkState,
  line_idx: usize,
  links: *std.ArrayListUnmanaged(FragmentLink),
  alloc: std.mem.Allocator,
) !void {
  if (!state.active) return;
  try links.append(alloc, .{
    .line_idx = line_idx,
    .col_start = state.col_start,
    .col_end = state.current_col,
    .slug = state.slug,
  });
  state.active = false;
}

const LinkState = struct {
  active: bool = false,
  slug: Bytes = &.{},
  col_start: u16 = 0,
  current_col: u16 = 0,
};

fn skipOscSequence(data: Bytes, i: *usize) void {
  while (i.* < data.len) : (i.* += 1) {
    if (data[i.*] == 0x1b and i.* + 1 < data.len and data[i.* + 1] == '\\') { 
      i.* += 2; return;
    } if (data[i.*] == 0x07) { i.* += 1; return; }
  }
}

fn findNextEscape(data: Bytes, start: usize) usize {
  var i = start;
  while (i < data.len and data[i] != 0x1b) : (i += 1) {}
  return i;
}

fn processEscapeSequence(
  data: Bytes,
  i: *usize,
  style: *vaxis.Style,
  link_state: *LinkState,
  line_idx: usize,
  headings: *std.ArrayListUnmanaged(HeadingEntry),
  links: *std.ArrayListUnmanaged(FragmentLink),
  images: *std.ArrayListUnmanaged(ImageEntry),
  no_wrap: *bool,
  alloc: std.mem.Allocator,
) !void {
  if (i.* + 1 >= data.len) {
    i.* += 1;
    return;
  }

  const next = data[i.* + 1];

  if (next == '_') {
    if (parseApc(data, i)) |payload| {
      try parseApcPayload(payload, line_idx, headings, links, images, link_state, no_wrap, alloc);
    } else {
      i.* += 1;
    } return;
  }

  if (next == '[') {
    i.* += 2;
    const param_start = i.*;
    while (i.* < data.len and data[i.*] != 'm') : (i.* += 1) {}
    if (i.* < data.len) {
      style.* = parseSgr(data[param_start - 2 .. i.* + 1], style.*);
      i.* += 1;
    }
    return;
  }

  if (next == ']') {
    skipOscSequence(data, i);
    return;
  }

  i.* += 1;
}

fn processLine(
  alloc: std.mem.Allocator,
  line_data: Bytes,
  line_idx: usize,
  style: *vaxis.Style,
  headings: *std.ArrayListUnmanaged(HeadingEntry),
  links: *std.ArrayListUnmanaged(FragmentLink),
  images: *std.ArrayListUnmanaged(ImageEntry),
) !Line {
  var segments: std.ArrayListUnmanaged(Segment) = .empty;
  var raw: std.ArrayListUnmanaged(u8) = .empty;
  var i: usize = 0;
  var no_wrap = false;
  var link_state = LinkState{ .current_col = 0 };

  while (i < line_data.len) {
    if (line_data[i] == 0x1b) {
      try processEscapeSequence(
        line_data, &i,
        style, &link_state,
        line_idx, headings,
        links, images, &no_wrap, alloc,
      ); continue;
    }

    const text_start = i;
    const text_end = findNextEscape(line_data, i);
    i = text_end;

    const text = line_data[text_start..text_end];
    if (text.len == 0) continue;

    try segments.append(alloc, .{ .text = text, .style = style.* });
    try raw.appendSlice(alloc, text);
    link_state.current_col += @intCast(text.len);
  }

  if (link_state.active) {
    try finishLink(&link_state, line_idx, links, alloc);
  }

  return .{
    .raw = try raw.toOwnedSlice(alloc),
    .segments = try segments.toOwnedSlice(alloc),
    .no_wrap = no_wrap,
  };
}

pub fn parseAnsiLines(alloc: std.mem.Allocator, input: Bytes) !ParseResult {
  var lines: std.ArrayListUnmanaged(Line) = .empty;
  var headings: std.ArrayListUnmanaged(HeadingEntry) = .empty;
  var links: std.ArrayListUnmanaged(FragmentLink) = .empty;
  var images: std.ArrayListUnmanaged(ImageEntry) = .empty;
  var pos: usize = 0;
  var style: vaxis.Style = .{};

  while (pos <= input.len) {
    const line_start = pos;
    while (pos < input.len and input[pos] != '\n') : (pos += 1) {}
    const line_data = input[line_start..pos];

    const at_end = pos == input.len;
    if (pos < input.len) pos += 1;
    if (at_end and line_start == pos) break;

    const line_idx = lines.items.len;
    const line = try processLine(
      alloc, line_data, line_idx, 
      &style, &headings, &links, &images
    );
    
    try lines.append(alloc, line);
    if (at_end and line_data.len > 0) break;
  }

  return .{
    .lines = try lines.toOwnedSlice(alloc),
    .headings = try headings.toOwnedSlice(alloc),
    .links = try links.toOwnedSlice(alloc),
    .images = try images.toOwnedSlice(alloc),
  };
}
