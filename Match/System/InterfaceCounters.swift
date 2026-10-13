import Darwin
import Foundation

/// How many bytes an interface has carried since it came up.
struct InterfaceByteCounts: Equatable, Sendable {
    var received: UInt64
    var sent: UInt64
}

protocol ByteCounting: Sendable {
    func counts(for interface: String) -> InterfaceByteCounts?
}

/// Reads an interface's byte counters from the kernel's routing table.
///
/// This asks for the 64-bit counters (`NET_RT_IFLIST2`). The more familiar
/// `getifaddrs` exposes 32-bit ones, which wrap around after 4 GB.
struct InterfaceCounters: ByteCounting {
    func counts(for interface: String) -> InterfaceByteCounts? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        return buffer.withUnsafeBytes { raw in
            Self.find(interface, in: UnsafeRawBufferPointer(rebasing: raw.prefix(length)))
        }
    }

    /// Walks the list of routing messages looking for `interface`'s statistics.
    private static func find(_ interface: String, in messages: UnsafeRawBufferPointer) -> InterfaceByteCounts? {
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= messages.count {
            let header = messages.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
            let messageLength = Int(header.ifm_msglen)
            guard messageLength > 0 else { break }

            if Int32(header.ifm_type) == RTM_IFINFO2,
               offset + MemoryLayout<if_msghdr2>.size <= messages.count {
                let info = messages.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                if name(ofInterfaceAt: UInt32(info.ifm_index)) == interface {
                    return InterfaceByteCounts(received: info.ifm_data.ifi_ibytes, sent: info.ifm_data.ifi_obytes)
                }
            }
            offset += messageLength
        }
        return nil
    }

    private static func name(ofInterfaceAt index: UInt32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        return buffer.withUnsafeMutableBufferPointer { pointer -> String? in
            guard let base = pointer.baseAddress, if_indextoname(index, base) != nil else { return nil }
            return String(cString: base)
        }
    }
}

/// Turns a series of counter readings into a current speed and a running total.
struct UsageMeter: Equatable, Sendable {
    /// Bytes per second, from the two most recent readings.
    private(set) var downloadRate: Double = 0
    private(set) var uploadRate: Double = 0
    /// Bytes since the last `reset`.
    private(set) var downloaded: UInt64 = 0
    private(set) var uploaded: UInt64 = 0

    private var lastCounts: InterfaceByteCounts?
    private var lastTime: Date?

    mutating func record(_ counts: InterfaceByteCounts, at time: Date) {
        defer {
            lastCounts = counts
            lastTime = time
        }
        guard let lastCounts, let lastTime else { return }

        // A counter that went backwards was reset (the interface went down and came
        // back). That reading starts a new baseline and counts for nothing.
        guard counts.received >= lastCounts.received, counts.sent >= lastCounts.sent else {
            downloadRate = 0
            uploadRate = 0
            return
        }
        let received = counts.received - lastCounts.received
        let sent = counts.sent - lastCounts.sent
        downloaded += received
        uploaded += sent

        let elapsed = time.timeIntervalSince(lastTime)
        if elapsed > 0 {
            downloadRate = Double(received) / elapsed
            uploadRate = Double(sent) / elapsed
        }
    }

    /// Starts a new total. The next reading becomes the baseline.
    mutating func reset() {
        self = UsageMeter()
    }

    /// Forgets the speed, for when sampling stops.
    mutating func clearRates() {
        downloadRate = 0
        uploadRate = 0
        lastCounts = nil
        lastTime = nil
    }
}
