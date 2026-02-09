const std = @import("std");
const vaxis = @import("vaxis");
const ink = @import("../node.zig");

pub const Bytes = ink.Bytes;
pub const Cell = vaxis.Cell;
pub const Key = vaxis.Key;
pub const Mouse = vaxis.Mouse;

pub const Event = union(enum) {
  key_press: Key,
  mouse: Mouse,
  winsize: vaxis.Winsize,
  focus_in,
  focus_out,
  file_changed,
  toast_dismiss,
};

pub const FragmentLink = struct {
  line_idx: usize,
  col_start: u16,
  col_end: u16,
  slug: Bytes,
};

pub const HeadingEntry = struct {
  slug: Bytes,
  line_idx: usize,
};

pub const Line = struct {
  raw: Bytes,
  segments: []const Segment,
  no_wrap: bool = false,
};

pub const Segment = struct {
  text: Bytes,
  style: vaxis.Style,
};

pub const ParseResult = struct {
  lines: []const Line,
  headings: []const HeadingEntry,
  links: []const FragmentLink,

  pub fn deinit(self: ParseResult, alloc: std.mem.Allocator) void {
    for (self.lines) |line| {
      alloc.free(line.raw);
      alloc.free(line.segments);
    }
    alloc.free(self.lines);
    alloc.free(self.headings);
    alloc.free(self.links);
  }
};

pub const WrapPoint = struct {
  seg_idx: u32,
  byte_off: u32,
};
