const std = @import("std");
const node = @import("node.zig");

const Bytes = node.Bytes;
const Writer = node.Writer;

const base64 = std.base64.standard.Encoder;
const chunk_size: usize = 4096;

pub const ImageInfo = struct {
  width: u32,
  height: u32,
};

fn readPngDimensions(data: Bytes) ?ImageInfo {
  if (data.len < 24) return null;
  if (!std.mem.eql(u8, data[0..4], &.{ 0x89, 'P', 'N', 'G' })) return null;
  if (!std.mem.eql(u8, data[12..16], "IHDR")) return null;
  const width = std.mem.readInt(u32, data[16..20], .big);
  const height = std.mem.readInt(u32, data[20..24], .big);
  return .{ .width = width, .height = height };
}

fn termSize() struct { cols: u16, rows: u16, xpixel: u16, ypixel: u16 } {
  var ws: std.posix.winsize = .{ .col = 80, .row = 24, .xpixel = 0, .ypixel = 0 };
  const err = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
  if (err != 0) return .{ .cols = 80, .rows = 24, .xpixel = 0, .ypixel = 0 };
  return .{ .cols = ws.col, .rows = ws.row, .xpixel = ws.xpixel, .ypixel = ws.ypixel };
}

fn scaledCols(img: ImageInfo, ts: anytype, max_cols: u16) u16 {
  if (ts.xpixel == 0 or ts.ypixel == 0 or ts.cols == 0 or ts.rows == 0)
    return @min(max_cols, 60);

  const pix_per_col: u32 = @as(u32, ts.xpixel) / @as(u32, ts.cols);
  const pix_per_row: u32 = @as(u32, ts.ypixel) / @as(u32, ts.rows);
  if (pix_per_col == 0 or pix_per_row == 0) return @min(max_cols, 60);

  const img_cols = std.math.divCeil(u32, img.width, pix_per_col) catch 1;
  const img_rows = std.math.divCeil(u32, img.height, pix_per_row) catch 1;

  if (img_cols <= max_cols) return @intCast(img_cols);

  const scale: f64 = @as(f64, @floatFromInt(max_cols)) / @as(f64, @floatFromInt(img_cols));
  const scaled_rows: u32 = @intFromFloat(@as(f64, @floatFromInt(img_rows)) * scale);
  _ = scaled_rows;
  return max_cols;
}

pub fn renderInline(w: Writer, file_data: Bytes, margin: u16) anyerror!void {
  const info = readPngDimensions(file_data);

  const ts = termSize();
  const max_cols = if (ts.cols > margin * 2 + 4) ts.cols - margin * 2 else ts.cols;

  var cols_param: u16 = @min(max_cols, 80);
  if (info) |img| {
    cols_param = scaledCols(img, ts, max_cols);
  }

  const encoded_size = base64.calcSize(file_data.len);
  const encoded_buf = std.heap.page_allocator.alloc(u8, encoded_size) catch return;
  defer std.heap.page_allocator.free(encoded_buf);
  const encoded = base64.encode(encoded_buf, file_data);

  try w.writeAll("\n");
  var i: u16 = 0;
  while (i < margin) : (i += 1) try w.writeAll(" ");

  if (encoded.len <= chunk_size) {
    try w.print("\x1b_Gf=100,a=T,t=d,c={d},m=0;{s}\x1b\\", .{ cols_param, encoded });
  } else {
    var off: usize = 0;
    var first = true;
    while (off < encoded.len) {
      const end = @min(off + chunk_size, encoded.len);
      const more: u1 = if (end < encoded.len) 1 else 0;

      if (first) {
        try w.print("\x1b_Gf=100,a=T,t=d,c={d},m={d};{s}\x1b\\", .{ cols_param, more, encoded[off..end] });
        first = false;
      } else {
        try w.print("\x1b_Gm={d};{s}\x1b\\", .{ more, encoded[off..end] });
      }
      off = end;
    }
  }
  try w.writeAll("\n");
}

pub fn renderFile(w: Writer, path: Bytes, base_dir: Bytes, margin: u16) anyerror!bool {
  if (path.len == 0) return false;
  if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://"))
    return false;

  const full_path = if (std.fs.path.isAbsolute(path))
    path
  else blk: {
    if (base_dir.len == 0) break :blk path;
    const joined = std.fs.path.join(std.heap.page_allocator, &.{ base_dir, path }) catch return false;
    break :blk joined;
  };

  const file = std.fs.cwd().openFile(full_path, .{}) catch return false;
  defer file.close();

  const stat = file.stat() catch return false;
  if (stat.size == 0 or stat.size > 10 * 1024 * 1024) return false;

  const data = file.readToEndAlloc(std.heap.page_allocator, 10 * 1024 * 1024) catch return false;
  defer std.heap.page_allocator.free(data);

  if (!isPng(data) and !isJpeg(data) and !isGif(data)) return false;

  renderInline(w, data, margin) catch return false;
  return true;
}

fn isPng(data: Bytes) bool {
  return data.len >= 4 and std.mem.eql(u8, data[0..4], &.{ 0x89, 'P', 'N', 'G' });
}

fn isJpeg(data: Bytes) bool {
  return data.len >= 2 and data[0] == 0xFF and data[1] == 0xD8;
}

fn isGif(data: Bytes) bool {
  return data.len >= 4 and std.mem.eql(u8, data[0..3], "GIF");
}
