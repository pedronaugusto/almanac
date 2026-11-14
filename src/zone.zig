//! The zone readers and data under zone/: TZif files, POSIX TZ strings, the embedded copy of the
//! IANA database and Windows' zone names.
pub const tzif = @import("zone/tzif.zig");
pub const posix = @import("zone/posix.zig");
pub const embedded = @import("zone/embedded.zig");
pub const windows = @import("zone/windows.zig");
