const stream = @import("../stream.zig");
const Stream = stream.Stream;

pub const WasiError = enum(i32) {
    //No error occurred. System call completed successfully.
    SUCCESS = 0,
    //Argument list too long.
    TOOBIG = 1,
    //Permission denied.
    ACCES = 2,
    //Address in use.
    ADDRINUSE = 3,
    //Address not available.
    ADDRNOTAVAIL = 4,
    //Address family not supported.
    AFNOSUPPORT = 5,
    //Resource unavailable, or operation would block.
    AGAIN = 6,
    //Connection already in progress.
    ALREADY = 7,
    //Bad file descriptor.
    BADF = 8,
    //Bad message.
    BADMSG = 9,
    //Device or resource busy.
    BUSY = 10,
    //Operation canceled.
    CANCELED = 11,
    //No child processes.
    CHILD = 12,
    //Connection aborted.
    CONNABORTED = 13,
    //Connection refused.
    CONNREFUSED = 14,
    //Connection reset.
    CONNRESET = 15,
    //Resource deadlock would occur.
    DEADLK = 16,
    //Destination address required.
    DESTADDRREQ = 17,
    //Mathematics argument out of domain of function.
    DOM = 18,
    //Reserved.
    DQUOT = 19,
    //File exists.
    EXIST = 20,
    //Bad address.
    FAULT = 21,
    //File too large.
    FBIG = 22,
    //Host is unreachable.
    HOSTUNREACH = 23,
    //Identifier removed.
    IDRM = 24,
    //Illegal byte sequence.
    ILSEQ = 25,
    //Operation in progress.
    INPROGRESS = 26,
    //Interrupted function.
    INTR = 27,
    //Invalid argument.
    INVAL = 28,
    //I/O error.
    IO = 29,
    //Socket is connected.
    ISCONN = 30,
    //Is a directory.
    ISDIR = 31,
    //Too many levels of symbolic links.
    LOOP = 32,
    //File descriptor value too large.
    MFILE = 33,
    //Too many links.
    MLINK = 34,
    //Message too large.
    MSGSIZE = 35,
    //Reserved.
    MULTIHOP = 36,
    //Filename too long.
    NAMETOOLONG = 37,
    //Network is down.
    NETDOWN = 38,
    //Connection aborted by network.
    NETRESET = 39,
    //Network unreachable.
    NETUNREACH = 40,
    //Too many files open in system.
    NFILE = 41,
    //No buffer space available.
    NOBUFS = 42,
    //No such device.
    NODEV = 43,
    //No such file or directory.
    NOENT = 44,
    //Executable file format error.
    NOEXEC = 45,
    //No locks available.
    NOLCK = 46,
    //Reserved.
    NOLINK = 47,
    //Not enough space.
    NOMEM = 48,
    //No message of the desired type.
    NOMSG = 49,
    //Protocol not available.
    NOPROTOOPT = 50,
    //No space left on device.
    NOSPC = 51,
    //Function not supported.
    NOSYS = 52,
    //The socket is not connected.
    NOTCONN = 53,
    //Not a directory or a symbolic link to a directory.
    NOTDIR = 54,
    //Directory not empty.
    NOTEMPTY = 55,
    //State not recoverable.
    NOTRECOVERABLE = 56,
    //Not a socket.
    NOTSOCK = 57,
    //Not supported, or operation not supported on socket.
    NOTSUP = 58,
    //Inappropriate I/O control operation.
    NOTTY = 59,
    //No such device or address.
    NXIO = 60,
    //Value too large to be stored in data type.
    OVERFLOW = 61,
    //Previous owner died.
    OWNERDEAD = 62,
    //Operation not permitted.
    PERM = 63,
    //Broken pipe.
    PIPE = 64,
    //Protocol error.
    PROTO = 65,
    //Protocol not supported.
    PROTONOSUPPORT = 66,
    //Protocol wrong type for socket.
    PROTOTYPE = 67,
    //Result too large.
    RANGE = 68,
    //Read-only file system.
    ROFS = 69,
    //Invalid seek.
    SPIPE = 70,
    //No such process.
    SRCH = 71,
    //Reserved.
    STALE = 72,
    //Connection timed out.
    TIMEDOUT = 73,
    //Text file busy.
    TXTBSY = 74,
    //Cross-device link.
    XDEV = 75,
    //Extension: Capabilities insufficient.
    NOTCAPABLE = 76,
    //The specified network host does not have any network addresses in the
    //requested address family.
    AIADDRFAMILY = 77,
    //Try again later.
    AIAGAIN = 78,
    //Hints.ai_flags contains invalid flags
    AIBADFLAG = 79,
    //The name server returned a permanent failure indication.
    AIFAIL = 80,
    //The requested address family is not supported.
    AIFAMILY = 81,
    //Addrinfo out of memory.
    AIMEMORY = 82,
    //Network host exists, but does not have any network addresses defined.
    AINODATA = 83,
    //Node or service is not known; or both node and service are NULL
    AINONAME = 84,
    //Service is not available for the requested socket type.
    AISERVICE = 85,
    //The requested socket type is not supported.
    AISOCKTYPE = 86,
    //Other system error;
    AISYSTEM = 87,

    const Self = @This();

    pub fn toU16(self: Self) u16 {
        return @as(u16, @intCast(@intFromEnum(self)));
    }
};

pub const ShutdownFlag = enum(i32) {
    READ = 1,
    WRITE = 2,
    BOTH = 3,

    const Self = @This();

    pub fn isRead(self: Self) bool {
        return self == Self.READ or self == Self.BOTH;
    }

    pub fn isWrite(self: Self) bool {
        return self == Self.WRITE or self == Self.BOTH;
    }
};

pub const IoVec = extern struct {
    buf: u32,
    buf_len: u32,
};

pub const FileStat = extern struct {
    dev: u64,
    ino: u64,
    file_type: FileType,
    nlink: u64,
    size: u64,
    atim: u64,
    mtim: u64,
    ctim: u64,
};

pub const FdStat = extern struct {
    file_type: FileType,
    flags: u16,
    rights_base: u64,
    rights_inheriting: u64,
};

pub const Prestat = extern struct {
    tag: u8,
    pr_name_len: u32,
};

pub const FileType = enum(u8) {
    Unknown = 0,
    BlockDevice = 1,
    CharacterDevice = 2,
    Directory = 3,
    RegularFile = 4,
    SocketDgram = 5,
    SocketStream = 6,
    SymbolicLink = 7,

    const Self = @This();

    pub fn fromStream(s: *Stream) Self {
        return switch (s.*) {
            Stream.uart => Self.CharacterDevice,
            Stream.socket => Self.SocketStream,
            Stream.opened_file => Self.RegularFile,
            Stream.dir => Self.Directory,
        };
    }
};

pub const FdFlag = enum(u16) {
    Append = 1, // O_APPEND
    Dsync = 2, // O_DSYNC
    NonBlock = 4, // O_NONBLOCK
    Rsync = 8, // O_RSYNC
    Sync = 16, // O_SYNC

    const Self = @This();

    pub fn toInt(self: Self) u16 {
        return @intFromEnum(self);
    }
};

pub const FULL_RIGHTS: u64 = 0x3fffffff;

pub const Subscription = extern struct {
    userdata: u64,
    content: SubscriptionContent,
};

pub const SubscriptionContent = extern struct {
    tag: u8, // EventType
    type: SubscriptionType,
};

pub const SubscriptionType = extern union {
    clock: SubscriptionClock,
    fd_read: SubscriptionFdReadwrite,
    fd_write: SubscriptionFdReadwrite,
};

pub const SubscriptionClock = extern struct {
    identifier: u32,
    timeout: u64,
    precision: u64,
    flags: u16,

    const Self = @This();

    pub fn isAbsolute(self: Self) bool {
        return (self.flags & 1) == 1;
    }
};

pub const SubscriptionFdReadwrite = extern struct {
    fd: i32,
};

pub const Event = extern struct {
    userdata: u64,
    err: u16,
    eventtype: u8,
    event_fd_readwrite: EventFdReadwrite,
};

pub const EventFdReadwrite = extern struct {
    nbytes: u64,
    flags: u16,
};

pub const EventType = enum(u8) {
    clock = 0,
    fd_read = 1,
    fd_write = 2,

    const Self = @This();

    pub fn fromInt(i: u8) ?Self {
        return switch (i) {
            0 => Self.clock,
            1 => Self.fd_read,
            2 => Self.fd_write,
            else => null,
        };
    }

    pub fn toInt(self: Self) u8 {
        return @intFromEnum(self);
    }
};

pub const AddressFamily = enum(i32) {
    Unspec = 0,
    INET4 = 1,
    INET6 = 2,
};

pub const SocketType = enum(i32) {
    Any = 0,
    Datagram = 1,
    Stream = 2,
};
