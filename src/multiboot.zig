// https://www.gnu.org/software/grub/manual/multiboot/multiboot.html#Boot-information-format
pub const BootInfo = packed struct {
    // Multiboot info version number.
    flags: u32,

    // Available memory from BIOS.
    mem_lower: u32,
    mem_upper: u32,

    // "root" partition.
    boot_device: u32,

    // Kernel command line.
    cmdline: u32,

    // Boot-Module list.
    mods_count: u32,
    mods_addr: u32,

    // TODO: use the real types here.
    u: u128,

    // Memory Mapping buffer.
    mmap_length: u32,
    mmap_addr: u32,

    // Drive Info buffer.
    drives_length: u32,
    drives_addr: u32,

    // ROM configuration table.
    config_table: u32,

    // Boot Loader Name.
    boot_loader_name: u32,

    // APM table.
    apm_table: u32,

    // Video.
    vbe_control_info: u32,
    vbe_mode_info: u32,
    vbe_mode: u16,
    vbe_interface_seg: u16,
    vbe_interface_off: u16,
    vbe_interface_len: u16,
};

//         +-------------------+
// -4      | size              |
//         +-------------------+
// 0       | base_addr         |
// 8       | length            |
// 16      | type              |
//         +-------------------+
// from: https://www.gnu.org/software/grub/manual/multiboot/multiboot.html#Boot-information-format
pub const MemoryMap = packed struct {
    size: u32,
    base: u64,
    length: u64,
    type: MemoryType,
};

pub const MemoryType = enum(u32) {
    available = 1,
    reserved = 2,
    acpi_reclamable = 3,
    nvs = 4,
    bad_memory = 5,
};
