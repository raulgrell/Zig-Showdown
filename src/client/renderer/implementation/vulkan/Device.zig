const std = @import("std");
const vk = @import("vulkan");
const Instance = @import("Instance.zig");
const Allocator = std.mem.Allocator;
const SmallBuf = @import("util.zig").SmallBuf;

const Self = @This();

vkd: DeviceDispatch,
handle: vk.Device,

pdev: PhysicalDevice,
graphics_queue: Queue,
compute_queue: Queue,
present_queue: Queue,

/// Attempt to initialize a vulkan logical device.
pub fn init(
    instance: Instance,
    pdev: PhysicalDevice,
    extensions: []const [*:0]const u8,
    qa: QueueAllocation
) !Self {
    // As some of the queue families may alias, we need to pay mind about handling those.
    const family_indices = [_]u32{qa.graphics_family, qa.compute_family, qa.present_family};
    const priorities = [_]f32{1} ** family_indices.len;

    var qci_buffer: [family_indices.len]vk.DeviceQueueCreateInfo = undefined;
    var n_unique_families: u32 = 0;

    for (family_indices) |family| {
        // Check whether this family is already scheduled for creation.
        for (qci_buffer[0 .. n_unique_families]) |*qci| {
            if (qci.queue_family_index == family) {
                // If so, we can simply increase the queue count if there is room left.
                if (qci.queue_count < qa.families[family].queue_count) {
                    qci.queue_count += 1;
                }
                break;
            }
        } else {
            // If its not already scheduled, schedule it.
            qci_buffer[n_unique_families] = .{
                .flags = .{},
                .queue_family_index = family,
                .queue_count = 1,
                .p_queue_priorities = &priorities,
            };
            n_unique_families += 1;
        }
    }

    const handle = try instance.vki.createDevice(pdev.handle, .{
        .flags = .{},
        .queue_create_info_count = n_unique_families,
        .p_queue_create_infos = &qci_buffer,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = undefined,
        .enabled_extension_count = @intCast(u32, extensions.len),
        .pp_enabled_extension_names = extensions.ptr,
        .p_enabled_features = null,
    }, null);

    // If the following fails, the handle is leaked.
    const vkd = try DeviceDispatch.load(handle, instance.vki.vkGetDeviceProcAddr);
    errdefer vkd.destroyDevice(handle, null);

    // Retrieve the queues
    var queues: [family_indices.len]Queue = undefined;
    for (queues) |*queue, i| {
        const family = family_indices[i];

        // First, find the queue create info for this family
        const qci = for (qci_buffer[0 .. n_unique_families]) |*qci| {
            if (qci.queue_family_index == family) {
                break qci;
            }
        } else unreachable;

        // Use the queue_count field to check how many queues of this family were
        // already allocated. If this reaches zero while there are still queues left,
        // the remainder are shared.
        if (qci.queue_count > 0) {
            qci.queue_count -= 1;
        }

        // The queue_count is now the queue index of the to-be-created queue.
        queue.* = Queue.init(vkd, handle, family, qci.queue_count);
    }

    return Self{
        .vkd = vkd,
        .pdev = pdev,
        .handle = handle,

        // Indices are according to `family_indices`.
        .graphics_queue = queues[0],
        .compute_queue = queues[1],
        .present_queue = queues[2],
    };
}

pub fn deinit(self: *Self) void {
    self.vkd.destroyDevice(self.handle, null);
    self.* = undefined;
}

pub fn uniqueQueueFamilies(self: Self) SmallBuf(3, u32) {
    var buf = SmallBuf(3, u32){};
    const families = [_]u32{
        self.graphics_queue.family,
        self.compute_queue.family,
        self.present_queue.family,
    };

    for (families) |fam| {
        if (std.mem.indexOfScalar(u32, buf.asSlice(), fam) == null) {
            buf.appendAssumeCapacity(fam);
        }
    }

    return buf;
}

pub const Queue = struct {
    handle: vk.Queue,
    family: u32,
    index: u32,

    pub fn init(vkd: DeviceDispatch, dev: vk.Device, family: u32, index: u32) Queue {
        return .{
            .handle = vkd.getDeviceQueue(dev, family, index),
            .family = family,
            .index = index,
        };
    }
};

/// A structure representing all the required information to construct the queues of a
/// device.
pub const QueueAllocation = struct {
    /// Array of all queues available on the device.
    /// This is manually allocated and should be freed by the allocator passed into
    /// PhysicalDevice.allocateQueues.
    families: []vk.QueueFamilyProperties,

    /// Indices into `families`. Beware: these may alias.
    graphics_family: u32,
    compute_family: u32,
    present_family: u32,

    pub fn deinit(self: QueueAllocation, allocator: *Allocator) void {
        allocator.free(self.families);
    }
};

/// This structure represents a physical device (GPU) on the host system, along with its
/// (memory) properties.
pub const PhysicalDevice = struct {
    handle: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    mem_props: vk.PhysicalDeviceMemoryProperties,

    pub fn init(instance: Instance, handle: vk.PhysicalDevice) PhysicalDevice {
        return PhysicalDevice{
            .handle = handle,
            .props = instance.vki.getPhysicalDeviceProperties(handle),
            .mem_props = instance.vki.getPhysicalDeviceMemoryProperties(handle),
        };
    }

    /// Return the name of the device, as reported by Vulkan.
    pub fn name(self: PhysicalDevice) []const u8 {
        // device_name is guaranteed to be zero-terminated
        const len = std.mem.indexOfScalar(u8, &self.props.device_name, 0).?;
        return self.props.device_name[0 .. len];
    }

    /// Returns an array of extensions that is supported by this physical device.
    pub fn supportedExtensions(self: PhysicalDevice, instance: Instance, allocator: *Allocator) ![]vk.ExtensionProperties {
        var count: u32 = undefined;
        _ = try instance.vki.enumerateDeviceExtensionProperties(self.handle, null, &count, null);

        const extensions = try allocator.alloc(vk.ExtensionProperties, count);
        errdefer allocator.free(extensions);

        _ = try instance.vki.enumerateDeviceExtensionProperties(self.handle, null, &count, extensions.ptr);
        return extensions;
    }

    /// Query whether this physical device is likely to support the given `surface` at all.
    pub fn supportsSurface(self: PhysicalDevice, instance: Instance, surface: vk.SurfaceKHR) !bool {
        var format_count: u32 = undefined;
        _ = try instance.vki.getPhysicalDeviceSurfaceFormatsKHR(self.handle, surface, &format_count, null);

        var present_mode_count: u32 = undefined;
        _ = try instance.vki.getPhysicalDeviceSurfacePresentModesKHR(self.handle, surface, &present_mode_count, null);

        return format_count > 0 and present_mode_count > 0;
    }

    /// Try to find a graphics, compute and present queue of this device. It is more efficient if different queues can be
    /// used, however, if the device doesn't support that some queues may be aliased.
    pub fn allocateQueues(
        self: PhysicalDevice,
        allocator: *Allocator,
        instance: Instance,
        surface: vk.SurfaceKHR,
    ) !QueueAllocation {
        var family_count: u32 = undefined;
        instance.vki.getPhysicalDeviceQueueFamilyProperties(self.handle, &family_count, null);

        var families = try allocator.alloc(vk.QueueFamilyProperties, family_count);
        errdefer allocator.free(families);
        instance.vki.getPhysicalDeviceQueueFamilyProperties(self.handle, &family_count, families.ptr);

        const graphics_family = blk: {
            // There are often more families that support compute than there are that
            // support graphics, so first look for a graphics family.
            for (families) |props, family| {
                if (props.queue_flags.graphics_bit) {
                    break :blk @intCast(u32, family);
                }
            }

            return error.NoGraphicsQueue;
        };

        const compute_family = blk: {
            // Try to find a dedicated compute family.
            for (families) |props, family| {
                if (family != graphics_family and props.queue_flags.compute_bit) {
                    break :blk @intCast(u32, family);
                }
            }

            // If that fails, check whether the graphics family also supports compute.
            if (families[graphics_family].queue_flags.contains(.{.compute_bit = true})) {
                break :blk graphics_family;
            }

            return error.NoComputeQueue;
        };

        const present_family = blk: {
            // Try to look for a dedicated family
            for (families) |props, i| {
                const family = @intCast(u32, i);
                if (family == graphics_family or family == compute_family) {
                    continue;
                }

                if ((try instance.vki.getPhysicalDeviceSurfaceSupportKHR(self.handle, family, surface)) == vk.TRUE) {
                    break :blk family;
                }
            }

            // if there is no dedicated family, prefer the one with the most queues
            const shared_family_indices = if (families[graphics_family].queue_count < families[compute_family].queue_count)
                    [_]u32{compute_family, graphics_family}
                else
                    [_]u32{graphics_family, compute_family};

            for (shared_family_indices) |family| {
                if ((try instance.vki.getPhysicalDeviceSurfaceSupportKHR(self.handle, family, surface)) == vk.TRUE) {
                    break :blk family;
                }
            }

            return error.NoPresentQueue;
        };

        return QueueAllocation{
            .families = families,
            .graphics_family = graphics_family,
            .compute_family = compute_family,
            .present_family = present_family,
        };
    }
};

const DeviceDispatch = struct {
    vkDestroyDevice: vk.PfnDestroyDevice,
    vkGetDeviceQueue: vk.PfnGetDeviceQueue,
    vkQueuePresentKHR: vk.PfnQueuePresentKHR,
    vkCreateSwapchainKHR: vk.PfnCreateSwapchainKHR,
    vkDestroySwapchainKHR: vk.PfnDestroySwapchainKHR,
    vkGetSwapchainImagesKHR: vk.PfnGetSwapchainImagesKHR,
    vkCreateImageView: vk.PfnCreateImageView,
    vkDestroyImageView: vk.PfnDestroyImageView,

    usingnamespace vk.DeviceWrapper(@This());
};
