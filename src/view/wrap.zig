const std = @import("std");
const vaxis = @import("vaxis");
const types = @import("types.zig");

const Line = types.Line;
const WrapPoint = types.WrapPoint;

pub const WrapLayout = struct {
  alloc: std.mem.Allocator,
  width: u16 = 0,
  points: std.ArrayListUnmanaged(WrapPoint) = .empty,
  line_starts: std.ArrayListUnmanaged(usize) = .empty,
  line_counts: std.ArrayListUnmanaged(u32) = .empty,
  prefix: std.ArrayListUnmanaged(usize) = .empty,
  total_visual: usize = 0,

  pub fn init(alloc: std.mem.Allocator) WrapLayout {
    return .{ .alloc = alloc };
  }

  pub fn deinit(self: *WrapLayout) void {
    self.points.deinit(self.alloc);
    self.line_starts.deinit(self.alloc);
    self.line_counts.deinit(self.alloc);
    self.prefix.deinit(self.alloc);
  }

  pub fn rebuild(self: *WrapLayout, lines: []const Line, content_w: u16, win: vaxis.Window) !void {
    self.width = content_w;
    self.points.clearRetainingCapacity();
    self.line_starts.clearRetainingCapacity();
    self.line_counts.clearRetainingCapacity();
    self.prefix.clearRetainingCapacity();
    self.total_visual = 0;

    for (lines) |line| {
      const off = self.points.items.len;
      try self.points.append(self.alloc, .{ .seg_idx = 0, .byte_off = 0 });

      if (line.no_wrap) {
        try self.line_starts.append(self.alloc, off);
        try self.line_counts.append(self.alloc, 1);
        try self.prefix.append(self.alloc, self.total_visual);
        self.total_visual += 1;
        continue;
      }

      var row_col: u16 = 0;
      var last_space_seg: u32 = 0;
      var last_space_off: u32 = 0;
      var last_space_col: u16 = 0;
      var has_space = false;

      var giter = line.graphemeIterator(.{ .seg_idx = 0, .byte_off = 0 }, null);
      while (giter.next()) |entry| {
        const gw: u16 = win.gwidth(entry.grapheme);
        if (gw == 0) continue;

        const in_code = entry.style.bg != .default;
        if (entry.grapheme.len == 1 and entry.grapheme[0] == ' ' and !in_code) {
          last_space_seg = entry.seg_idx;
          last_space_off = entry.seg_off + @as(u32, @intCast(entry.grapheme.len));
          last_space_col = row_col + gw;
          has_space = true;
        }

        if (row_col > 0 and row_col + gw > content_w) {
          if (has_space) {
            try self.points.append(self.alloc, .{
              .seg_idx = last_space_seg,
              .byte_off = last_space_off,
            });
            row_col -|= last_space_col;
          } else {
            try self.points.append(self.alloc, .{
              .seg_idx = entry.seg_idx,
              .byte_off = entry.seg_off,
            });
            row_col = 0;
          }
          has_space = false;
        }

        row_col +|= gw;
      }

      const count: u32 = @intCast(self.points.items.len - off);
      try self.line_starts.append(self.alloc, off);
      try self.line_counts.append(self.alloc, count);
      try self.prefix.append(self.alloc, self.total_visual);
      self.total_visual += count;
    }
    try self.prefix.append(self.alloc, self.total_visual);
  }

  pub fn visualToLogical(self: *const WrapLayout, vrow: usize) struct { line_idx: usize, wrap_row: usize } {
    const prefixes = self.prefix.items;
    if (prefixes.len < 2) return .{ .line_idx = 0, .wrap_row = 0 };

    var lo: usize = 0;
    var hi: usize = prefixes.len - 2;
    while (lo < hi) {
      const mid = lo + (hi - lo + 1) / 2;
      if (prefixes[mid] <= vrow) lo = mid else hi = mid - 1;
    }
    return .{ .line_idx = lo, .wrap_row = vrow - prefixes[lo] };
  }

  pub fn logicalToVisual(self: *const WrapLayout, line_idx: usize) usize {
    if (line_idx >= self.prefix.items.len) return self.total_visual;
    return self.prefix.items[line_idx];
  }

  pub fn wrapPoint(self: *const WrapLayout, line_idx: usize, wrap_row: usize) WrapPoint {
    const start = self.line_starts.items[line_idx];
    return self.points.items[start + wrap_row];
  }

  pub fn wrapCount(self: *const WrapLayout, line_idx: usize) u32 {
    return self.line_counts.items[line_idx];
  }
};
