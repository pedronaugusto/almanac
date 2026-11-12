//! Every test of almanac, run by `bay dev test`.
test {
    _ = @import("almanac.zig");
    _ = @import("calendar.zig");
    _ = @import("calendar_test.zig");
    _ = @import("round.zig");
    _ = @import("arithmetic.zig");
    _ = @import("span_test.zig");
    _ = @import("instant_test.zig");
    _ = @import("zone_test.zig");
    _ = @import("zoned_test.zig");
    _ = @import("database_test.zig");
}
