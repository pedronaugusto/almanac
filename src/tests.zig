//! Every test of almanac, run by `bay dev test`.
test {
    _ = @import("almanac.zig");
    _ = @import("calendar.zig");
    _ = @import("calendar_test.zig");
}
