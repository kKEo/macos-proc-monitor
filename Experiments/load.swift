// Synthetic load generators for the phase 0 probes (seed of pmon-stress). Throwaway code.
import Foundation
import Darwin

/// Spin `threads` busy threads for `seconds` at the given QoS. Blocks until done.
func spin(threads: Int, seconds: Double, qos: QualityOfService) {
    let end = nowNs() + UInt64(seconds * 1e9)
    let g = DispatchGroup()
    for _ in 0..<threads {
        g.enter()
        let t = Thread {
            var x: UInt64 = 1
            while nowNs() < end {
                for _ in 0..<200_000 { x = x &* 6364136223846793005 &+ 1442695040888963407 }
            }
            if x == 0 { print("") }
            g.leave()
        }
        t.qualityOfService = qos
        t.start()
    }
    g.wait()
}

/// Allocate `mb` megabytes of incompressible data (random bytes) so the compressor cannot hide it.
func allocIncompressible(mb: Int) -> UnsafeMutableRawPointer {
    let size = mb << 20
    let p = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16384)
    arc4random_buf(p, size)
    return p
}

/// Read one byte per page to force the memory back in (decompression / swap-in).
func touch(_ p: UnsafeMutableRawPointer, mb: Int) -> UInt64 {
    var sum: UInt64 = 0
    let size = mb << 20
    var off = 0
    while off < size { sum &+= UInt64(p.load(fromByteOffset: off, as: UInt8.self)); off += 16384 }
    return sum
}

/// Sequential uncached write of `mb` megabytes, then fsync. Returns seconds taken.
func writeFile(_ path: String, mb: Int) -> Double {
    let fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0o600)
    _ = fcntl(fd, F_NOCACHE, 1)
    let chunk = 4 << 20
    let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
    arc4random_buf(buf, chunk)
    let t0 = nowNs()
    for _ in 0..<(mb / 4) { _ = write(fd, buf, chunk) }
    fsync(fd)
    let dt = Double(nowNs() - t0) / 1e9
    close(fd); buf.deallocate()
    return dt
}

/// Sequential uncached read of the whole file. Returns seconds taken.
func readFile(_ path: String) -> Double {
    let fd = open(path, O_RDONLY)
    _ = fcntl(fd, F_NOCACHE, 1)
    let chunk = 4 << 20
    let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
    let t0 = nowNs()
    while read(fd, buf, chunk) > 0 {}
    let dt = Double(nowNs() - t0) / 1e9
    close(fd); buf.deallocate()
    return dt
}
