//! Sample module documentation.
//! It exercises the golden fixture paths.

/// Single-line documentation for `single`.
pub const single = 1;

/// Multi-line documentation
/// spans two lines.
pub const multiLine = 2;

/// First paragraph of `multiParagraph`.
///
/// Second paragraph of `multiParagraph`.
pub const multiParagraph = 3;

/// A doc comment separated from its declaration
/// by a blank line in the source.

pub const detached = 4;

/// Top-level helper function.
pub fn helper(value: u32) u32 {
    return value + 1;
}

/// A sample struct.
pub const Widget = struct {
    /// The widget name.
    name: []const u8,
    /// The widget size.
    size: u32 = 0,

    /// Creates a widget with the given name and size.
    pub fn create(
        /// The name for the widget.
        name: []const u8,
        /// How large the widget is.
        size: u32,
    ) Widget {
        return .{ .name = name, .size = size };
    }
};

/// Errors a widget operation can produce.
pub const WidgetError = error{
    /// The name was empty.
    EmptyName,
    /// The size was too large.
    TooLarge,
};

/// Outer container.
pub const Outer = struct {
    /// Inner container.
    pub const Inner = struct {
        /// A deeply nested value.
        pub const deep = 42;
    };
};

/// This trailing doc comment is unattached and must be dropped.
