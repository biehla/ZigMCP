//! Fixture file containing a syntax error.
//! Its usable records must still be extracted.

/// Still documented despite the error below.
pub const usable = 7;

pub const broken = ;

/// Also usable after the syntax error.
pub fn stillWorks() void {}
