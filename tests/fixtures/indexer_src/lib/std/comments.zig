pub const noDocsAtAll = 0;

// Plain line comment for plain.
pub const plain = 1;

// Shadowed plain comment.
/// Doc comment for documented.
pub const documented = 2;

// Separated from its declaration by a blank line.

pub const separated = 3;

pub const trailing = 4; // not documentation for afterTrailing
pub const afterTrailing = 5;

//
//
pub const bare = 6;

// First fallback line.
// Second fallback line.
pub fn twoLines() void {}

pub fn withParams(
    // The fallback parameter doc.
    name: []const u8,
    /// The doc parameter doc.
    size: u32,
) void {
    _ = name;
    _ = size;
}

pub const Holder = struct {
    // The fallback field doc.
    inner: u32,
};

pub const PlainErrors = error{
    // The fallback error doc.
    Fallback,
    /// The doc error doc.
    Documented,
};
