pub const FUSE_KERNEL_VERSION: u32 = 7;
pub const FUSE_KERNEL_MINOR_VERSION: u32 = 31;

pub const Opcode = enum(u32) {
    FUSE_LOOKUP = 1,
    FUSE_FORGET = 2,
    FUSE_GETATTR = 3,
    FUSE_OPEN = 14,
    FUSE_READ = 15,
    FUSE_WRITE = 16,
    FUSE_RELEASE = 18,
    FUSE_INIT = 26,
    FUSE_OPENDIR = 27,
    FUSE_READDIR = 28,
    FUSE_RELEASEDIR = 29,
    FUSE_CREATE = 35,
    FUSE_READDIRPLUS = 44,
};

pub const FUSE_ROOT_ID: u64 = 1;

pub const InHeader = extern struct {
    len: u32,
    opcode: u32,
    unique: u64,
    nodeid: u64,
    uid: u32,
    gid: u32,
    pid: u32,
    padding: u32,
};

pub const OutHeader = extern struct {
    len: u32,
    err: i32,
    unique: u64,
};

pub const InitIn = extern struct {
    major: u32,
    minor: u32,
    max_readahead: u32,
    flags: u32,
};

pub const InitOut = extern struct {
    major: u32,
    minor: u32,
    max_readahead: u32,
    flags: u32,
    max_background: u16,
    congestion_threshold: u16,
    max_write: u32,
    time_gran: u32,
    max_pages: u16,
    map_alignment: u16,
    flags2: u32,
    unused: [7]u32,
};

pub const Attr = extern struct {
    ino: u64,
    size: u64,
    blocks: u64,
    atime: u64,
    mtime: u64,
    ctime: u64,
    atimensec: u32,
    mtimensec: u32,
    ctimensec: u32,
    mode: u32,
    nlink: u32,
    uid: u32,
    gid: u32,
    rdev: u32,
    blksize: u32,
    flags: u32,

    pub fn isDir(self: *const Attr) bool {
        return (self.mode & S_IFMT) == S_IFDIR;
    }

    pub fn isRegular(self: *const Attr) bool {
        return (self.mode & S_IFMT) == S_IFREG;
    }
};

pub const S_IFMT: u32 = 0o170000;
pub const S_IFDIR: u32 = 0o040000;
pub const S_IFREG: u32 = 0o100000;

pub const EntryOut = extern struct {
    nodeid: u64,
    generation: u64,
    entry_valid: u64,
    attr_valid: u64,
    entry_valid_nsec: u32,
    attr_valid_nsec: u32,
    attr: Attr,
};

pub const GetattrIn = extern struct {
    getattr_flags: u32,
    dummy: u32,
    fh: u64,
};

pub const AttrOut = extern struct {
    attr_valid: u64,
    attr_valid_nsec: u32,
    dummy: u32,
    attr: Attr,
};

pub const OpenIn = extern struct {
    flags: u32,
    open_flags: u32,
};

pub const OpenOut = extern struct {
    fh: u64,
    open_flags: u32,
    padding: u32,
};

pub const ReadIn = extern struct {
    fh: u64,
    offset: u64,
    size: u32,
    read_flags: u32,
    lock_owner: u64,
    flags: u32,
    padding: u32,
};

pub const WriteIn = extern struct {
    fh: u64,
    offset: u64,
    size: u32,
    write_flags: u32,
    lock_owner: u64,
    flags: u32,
    padding: u32,
};

pub const WriteOut = extern struct {
    size: u32,
    padding: u32,
};

pub const CreateIn = extern struct {
    flags: u32,
    mode: u32,
    umask: u32,
    open_flags: u32,
};

pub const ReleaseIn = extern struct {
    fh: u64,
    flags: u32,
    release_flags: u32,
    lock_owner: u64,
};

pub const ForgetIn = extern struct {
    nlookup: u64,
};

pub const DirentSize = @sizeOf(Dirent);

pub const Dirent = extern struct {
    ino: u64,
    off: u64,
    namelen: u32,
    type_: u32,
    // followed by name[namelen] (not null-terminated, padded to 8-byte boundary)
};

pub const DirentplusSize = @sizeOf(Direntplus);

pub const Direntplus = extern struct {
    entry_out: EntryOut,
    dirent: Dirent,
};

pub fn direntAlignedSize(namelen: u32) u32 {
    return @as(u32, @intCast((@as(usize, DirentSize) + namelen + 7) & ~@as(usize, 7)));
}

pub fn direntplusAlignedSize(namelen: u32) u32 {
    return @as(u32, @intCast((@as(usize, DirentplusSize) + namelen + 7) & ~@as(usize, 7)));
}

pub fn fillInHeader(buf: []u8, len: u32, opcode: Opcode, unique: u64, nodeid: u64) void {
    const header = @as(*InHeader, @ptrCast(@alignCast(buf.ptr)));
    header.* = InHeader{
        .len = len,
        .opcode = @intFromEnum(opcode),
        .unique = unique,
        .nodeid = nodeid,
        .uid = 0,
        .gid = 0,
        .pid = 0,
        .padding = 0,
    };
}
