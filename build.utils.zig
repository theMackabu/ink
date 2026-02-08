const std = @import("std");

pub fn getGitCommit(b: *std.Build) ?[]const u8 {
  var exit_code: u8 = undefined;
  const result = b.runAllowFail(
    &.{"git", "rev-parse", "HEAD"}, &exit_code, .Ignore
  ) catch return null;
  if (exit_code != 0) return null;
  return std.mem.trim(u8, result, &std.ascii.whitespace);
}

pub fn getGitBranch(b: *std.Build) ?[]const u8 {
  var exit_code: u8 = undefined;
  const result = b.runAllowFail(
    &.{"git", "rev-parse", "--abbrev-ref", "HEAD"}, &exit_code, .Ignore
  ) catch return null;
  if (exit_code != 0) return null;
  return std.mem.trim(u8, result, &std.ascii.whitespace);
}

pub fn isGitDirty(b: *std.Build) bool {
  var exit_code: u8 = undefined;
  const result = b.runAllowFail(
    &.{"git", "status", "--porcelain"}, &exit_code, .Ignore
  ) catch return false;
  if (exit_code != 0) return false;
  return result.len > 0;
}