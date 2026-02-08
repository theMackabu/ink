const std = @import("std");
const ink = @import("ink");
const clap = @import("clap");
const config = @import("config");
const cli = @import("cli.zig");

pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  defer _ = gpa.deinit();
    
  const allocator = gpa.allocator();
  const ctx = cli.Ctx.init(allocator);
    
  const params = comptime clap.parseParamsComptime(
    \\-h, --help     Display this help and exit.
    \\-V, --version  Display version information and exit.
    \\-j, --json     Output AST as JSON.
    \\-v, --view     View rendered markdown in TUI.
    \\<str>
    \\
  );
  
  var diag = clap.Diagnostic{};
  var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
    .diagnostic = &diag,
    .allocator = std.heap.page_allocator,
  }) catch |err| {
    try diag.reportToFile(.stderr(), err);
    return err;
  }; defer res.deinit();
  
  
  if (res.args.help != 0) return clap.helpToFile(.stderr(), clap.Help, &params, .{});
  if (res.args.version != 0) return try ctx.version();
  
  const path = res.positionals[0] orelse {
    ctx.printf("usage: ink [--json] [--view] <file.md>\n", .{});
    std.process.exit(1);
  };
    
  const file = std.fs.cwd().openFile(path, .{}) catch |err| {
    ctx.printf("error: cannot open '{s}': {s}\n", .{ path, @errorName(err) });
    std.process.exit(1);
  }; defer file.close();
  
  var arena = ink.Arena.init(std.heap.page_allocator);
  defer arena.deinit();
    
  const markdown = file.readToEndAlloc(arena.allocator(), std.math.maxInt(usize)) catch |err| {
    ctx.printf("error: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
    std.process.exit(1);
  };
    
  const start = try std.time.Instant.now();
  const root = try ink.parse(&arena, markdown);
  const end = try std.time.Instant.now();
  const elapsed: f64 = @floatFromInt(end.since(start));
    
  if (res.args.json != 0) {
    const stdout_file = std.fs.File.stdout();
    const buf = try arena.allocator().alloc(u8, markdown.len * 4);
    
    var stdout_writer = stdout_file.writer(buf);
    const w = &stdout_writer.interface;
    
    defer w.flush() catch {};
    try ink.toJson(w, root);
    
    return;
  }
    
  if (res.args.view != 0) {
    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer aw.deinit();
    
    var highlighter = try ink.Highlighter.init(std.heap.page_allocator);
    try ink.render(&aw.writer, root, .{ 
      .highlighter = &highlighter,
      .show_urls = false, 
      .tui = true 
    });
    
    try aw.writer.flush();
    const rendered = aw.writer.buffer[0..aw.writer.end];
    try ink.tui.run(allocator, rendered, path);
    
    return;
  } 
  
  const buf = try arena.allocator().alloc(u8, markdown.len * 4);
  var stdout = std.fs.File.stdout().writer(buf);

  const w = &stdout.interface;
  defer stdout.interface.flush() catch {};
  
  var highlighter = try ink.Highlighter.init(std.heap.page_allocator);
  try ink.render(w, root, .{ .highlighter = &highlighter });
  
  const secs = elapsed / std.time.ns_per_s;
  const mb = @as(f64, @floatFromInt(markdown.len)) / (1024.0 * 1024.0);
  
  try w.print("\nparsed in {d:.6}s ({d:.2} MB/s)\n", .{ secs, mb / secs });
}