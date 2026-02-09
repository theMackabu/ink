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
  scan_update: ScanUpdate,
};

pub const ScanUpdate = struct {
  done: bool,
  count: usize,
  scanned: usize,
};

pub const FragmentLink = struct {
  line_idx: usize,
  col_start: u16,
  col_end: u16,
  slug: Bytes,
};

pub const ImageEntry = struct {
  line_idx: usize,
  url: Bytes,
  alt: Bytes,
};

pub const HeadingEntry = struct {
  slug: Bytes,
  line_idx: usize,
  raw: Bytes,
  h_count: u8,
};

pub const Line = struct {
  raw: Bytes,
  segments: []const Segment,
  no_wrap: bool = false,

  pub const GraphemeEntry = struct {
    grapheme: Bytes,
    style: vaxis.Style,
    raw_byte: u32,
    seg_idx: u32,
    seg_off: u32,
  };

  pub const GraphemeIterator = struct {
    line: *const Line,
    seg_i: u32,
    byte_off: u32,
    raw_byte: u32,
    end: ?WrapPoint,
    giter: ?vaxis.unicode.GraphemeIterator,

    pub fn next(self: *GraphemeIterator) ?GraphemeEntry {
      while (self.seg_i < self.line.segments.len) {
        const gi = &(self.giter orelse {
          self.advanceSegment();
          continue;
        });

        const g = gi.next() orelse {
          self.advanceSegment();
          continue;
        };

        const seg = &self.line.segments[self.seg_i];
        const text = seg.text[self.byte_off..];
        const grapheme = g.bytes(text);
        const abs_off = self.byte_off + @as(u32, @intCast(g.start));

        if (self.end) |e| {
          if (self.seg_i > e.seg_idx or (self.seg_i == e.seg_idx and abs_off >= e.byte_off))
            return null;
        }

        const entry: GraphemeEntry = .{
          .grapheme = grapheme,
          .style = seg.style,
          .raw_byte = self.raw_byte,
          .seg_idx = self.seg_i,
          .seg_off = abs_off,
        };
        self.raw_byte += @intCast(grapheme.len);
        return entry;
      }
      return null;
    }

    fn advanceSegment(self: *GraphemeIterator) void {
      self.seg_i += 1;
      if (self.seg_i < self.line.segments.len) {
        self.byte_off = 0;
        self.giter = vaxis.unicode.graphemeIterator(self.line.segments[self.seg_i].text);
      }
    }
  };

  pub fn graphemeIterator(self: *const Line, start: WrapPoint, end: ?WrapPoint) GraphemeIterator {
    var raw_byte: u32 = 0;
    var si: u32 = 0;
    while (si < start.seg_idx) : (si += 1) {
      raw_byte += @intCast(self.segments[si].text.len);
    }
    raw_byte += start.byte_off;

    const giter = if (start.seg_idx < self.segments.len)
      vaxis.unicode.graphemeIterator(self.segments[start.seg_idx].text[start.byte_off..])
    else
      null;

    return .{
      .line = self,
      .seg_i = start.seg_idx,
      .byte_off = start.byte_off,
      .raw_byte = raw_byte,
      .end = end,
      .giter = giter,
    };
  }
};

pub const Segment = struct {
  text: Bytes,
  style: vaxis.Style,
};

pub const ParseResult = struct {
  lines: []const Line,
  headings: []const HeadingEntry,
  links: []const FragmentLink,
  images: []const ImageEntry,

  pub fn deinit(self: ParseResult, alloc: std.mem.Allocator) void {
    for (self.lines) |line| {
      alloc.free(line.raw);
      alloc.free(line.segments);
    }
    alloc.free(self.lines);
    alloc.free(self.headings);
    alloc.free(self.links);
    alloc.free(self.images);
  }
};

pub const WrapPoint = struct {
  seg_idx: u32,
  byte_off: u32,
};
