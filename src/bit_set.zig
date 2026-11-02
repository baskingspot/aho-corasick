//! The bit sets the search tables and pattern sets use.
//!
//! Zig 0.17 renamed the static bit-set types and `DynamicBitSetUnmanaged`,
//! and turned `initEmpty` into the `empty` constant. These names are the only
//! place the search code sees that difference.

const bit_set = @import("std").bit_set;

/// The alphabet classes a state has transitions for, one bit per class.
pub fn StateMask(comptime bit_length: u16) type {
    return if (@hasDecl(bit_set, "Integer"))
        bit_set.Integer(bit_length)
    else
        bit_set.IntegerBitSet(bit_length);
}

/// The patterns that occur in a haystack, one bit per pattern.
pub fn PatternSet(comptime pattern_count: usize) type {
    return if (@hasDecl(bit_set, "Static"))
        bit_set.Static(pattern_count)
    else
        bit_set.StaticBitSet(pattern_count);
}

/// The runtime-sized set returned by `Automaton.whichMatches`.
pub const RuntimeSet = if (@hasDecl(bit_set, "Dynamic"))
    bit_set.Dynamic
else
    bit_set.DynamicBitSetUnmanaged;

/// `initEmpty` in Zig 0.16, `empty` in Zig 0.17.
pub fn empty(comptime T: type) T {
    return if (@hasDecl(T, "empty")) T.empty else T.initEmpty();
}
