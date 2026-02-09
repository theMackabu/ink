const std = @import("std");
const types = @import("types.zig");

const Line = types.Line;

pub fn containsIgnoreCase(haystack: types.Bytes, needle: []const u8) bool {
  if (needle.len == 0 or needle.len > haystack.len) return false;
  outer: for (0..haystack.len - needle.len + 1) |i| {
    for (0..needle.len) |j| {
      if (toLower(haystack[i + j]) != toLower(needle[j])) continue :outer;
    } return true;
  }
  return false;
}

pub fn toLower(c: u8) u8 {
  return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

pub const SearchState = struct {
  active: bool = false,
  query: std.ArrayListUnmanaged(u8) = .empty,
  matches: std.ArrayListUnmanaged(usize) = .empty,
  current: usize = 0,
  alloc: std.mem.Allocator,

  pub fn init(alloc: std.mem.Allocator) SearchState {
    return .{ .alloc = alloc };
  }

  pub fn deinit(self: *SearchState) void {
    self.query.deinit(self.alloc);
    self.matches.deinit(self.alloc);
  }

  pub fn clear(self: *SearchState) void {
    self.query.clearRetainingCapacity();
    self.matches.clearRetainingCapacity();
    self.current = 0;
  }

  pub fn find(self: *SearchState, lines: []const Line) void {
    self.matches.clearRetainingCapacity();
    if (self.query.items.len == 0) return;
    for (lines, 0..) |line, i| {
      if (containsIgnoreCase(line.raw, self.query.items)) 
        self.matches.append(self.alloc, i) catch {};
    }
    self.current = 0;
  }
};
