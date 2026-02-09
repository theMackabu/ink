const node = @import("node.zig");
const parser = @import("parser.zig");
const output = @import("output.zig");
const hl = @import("highlight.zig");

pub const kitty = @import("kitty.zig");
pub const tui = @import("view.zig");

pub const Highlighter = hl.Highlighter;

pub const Node = node.Node;
pub const Writer = node.Writer;
pub const Arena = node.Arena;
pub const Bytes = node.Bytes;

pub const newNode = node.newNode;
pub const appendNode = node.appendNode;
pub const appendChild = node.appendChild;

pub const parse = parser.parse;
pub const parseInline = parser.parseInline;

pub const Config = output.Config;
pub const render = output.render;
pub const toJson = output.toJson;