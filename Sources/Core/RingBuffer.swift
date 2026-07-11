import Foundation
import os

public final class RingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let buffer: UnsafeMutablePointer<UInt8>
    private let lock: UnsafeMutablePointer<os_unfair_lock_s>
    
    private var writeOffset: Int = 0
    private var readOffset: Int = 0
    
    public init(capacity: Int) {
        self.capacity = capacity
        self.buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        self.buffer.initialize(repeating: 0, count: capacity)
        
        self.lock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock_s())
    }
    
    deinit {
        buffer.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
    
    public var bytesAvailableForRead: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let w = writeOffset
        let r = readOffset
        if w >= r {
            return w - r
        } else {
            return capacity - r + w
        }
    }
    
    public var bytesAvailableForWrite: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let w = writeOffset
        let r = readOffset
        let used = w >= r ? (w - r) : (capacity - r + w)
        return capacity - 1 - used
    }
    
    @discardableResult
    public func write(_ data: UnsafeRawPointer, byteCount: Int) -> Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        
        let w = writeOffset
        let r = readOffset
        
        let available = capacity - 1 - (w >= r ? (w - r) : (capacity - r + w))
        guard available >= byteCount else {
            return 0 // Buffer full / not enough space
        }
        
        let rawBuffer = UnsafeMutableRawPointer(buffer)
        let firstPart = min(byteCount, capacity - w)
        rawBuffer.advanced(by: w).copyMemory(from: data, byteCount: firstPart)
        
        if firstPart < byteCount {
            let secondPart = byteCount - firstPart
            rawBuffer.copyMemory(from: data.advanced(by: firstPart), byteCount: secondPart)
        }
        
        writeOffset = (w + byteCount) % capacity
        return byteCount
    }
    
    /// Write data into the ring buffer, overwriting oldest unread data when full.
    @discardableResult
    public func writeOverwriting(_ data: UnsafeRawPointer, byteCount: Int) -> Int {
        guard byteCount > 0 && byteCount < capacity else { return 0 }
        
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        
        let w = writeOffset
        let r = readOffset
        let used = w >= r ? (w - r) : (capacity - r + w)
        let available = capacity - 1 - used
        
        var newR = r
        if available < byteCount {
            let deficit = byteCount - available
            newR = (r + deficit) % capacity
        }
        
        // Now write the data
        let rawBuffer = UnsafeMutableRawPointer(buffer)
        let firstPart = min(byteCount, capacity - w)
        rawBuffer.advanced(by: w).copyMemory(from: data, byteCount: firstPart)
        
        if firstPart < byteCount {
            let secondPart = byteCount - firstPart
            rawBuffer.copyMemory(from: data.advanced(by: firstPart), byteCount: secondPart)
        }
        
        readOffset = newR
        writeOffset = (w + byteCount) % capacity
        return byteCount
    }
    
    /// Read data from the ring buffer.
    @discardableResult
    public func read(_ dest: UnsafeMutableRawPointer, byteCount: Int) -> Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        
        let r = readOffset
        let w = writeOffset
        
        let available = w >= r ? (w - r) : (capacity - r + w)
        guard available >= byteCount else {
            return 0 // Not enough data
        }
        
        let rawBuffer = UnsafeRawPointer(buffer)
        let firstPart = min(byteCount, capacity - r)
        dest.copyMemory(from: rawBuffer.advanced(by: r), byteCount: firstPart)
        
        if firstPart < byteCount {
            let secondPart = byteCount - firstPart
            dest.advanced(by: firstPart).copyMemory(from: rawBuffer, byteCount: secondPart)
        }
        
        readOffset = (r + byteCount) % capacity
        return byteCount
    }
    
    public func clear() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        writeOffset = 0
        readOffset = 0
    }
}
