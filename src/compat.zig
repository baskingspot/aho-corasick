//! Shims for the Zig 0.16 and 0.17 APIs. Private to the module.

const std = @import("std");

/// Zig 0.17 renamed the static bit-set types (`IntegerBitSet` and
/// `StaticBitSet` became `Integer` and `Static`).
pub const Integer = if (@hasDecl(std.bit_set, "Integer"))
    std.bit_set.Integer
else
    std.bit_set.IntegerBitSet;

pub const Static = if (@hasDecl(std.bit_set, "Static"))
    std.bit_set.Static
else
    std.bit_set.StaticBitSet;

/// Zig 0.17 turned `initEmpty` into the `empty` constant.
pub fn empty(comptime T: type) T {
    return if (@hasDecl(T, "empty")) T.empty else T.initEmpty();
}
