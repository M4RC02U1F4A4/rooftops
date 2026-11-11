import AppKit
import IOKit
import IOKit.hid

// MARK: - Pile: heightmap of settled snow on a horizontal ledge

let colW: CGFloat = 2  // width of one heightmap column, in points

struct Pile {
    var h: [CGFloat]
    var cap: CGFloat
    var overhang: (l: CGFloat, r: CGFloat) = (0, 0)  // snow slid past each edge, waiting to drop as a clump

    init(width: CGFloat, cap: CGFloat) {
        h = Array(repeating: 0, count: max(1, Int(width / colW)))
        self.cap = cap
    }

    /// Deposits a flake of radius r centred at local x, spread over the columns it covers.
    /// Returns false if the pile is full there (or x is off the pile).
    mutating func add(x: CGFloat, r: CGFloat) -> Bool {
        let c = Int(x / colW)
        guard x >= 0, h.indices.contains(c), h[c] < cap else { return false }
        let lo = max(0, Int((x - r) / colW)), hi = min(h.count - 1, Int((x + r) / colW))
        // ponytail: 0.6 = fluffiness; volume per flake is the "how fast it piles up" knob
        let dh = .pi * r * r * 0.6 / (CGFloat(hi - lo + 1) * colW)
        for i in lo...hi { h[i] += dh }
        return true
    }

    /// Snow slides toward lower neighbours; `tilt` (-1...1) biases it downhill.
    /// `spills` = whether snow falls off the ends (ledge) or piles against them (screen walls).
    /// Returns the amount that fell off each end (left, right).
    mutating func relax(tilt: CGFloat, spills: Bool) -> (CGFloat, CGFloat) {
        let repose: CGFloat = 1.6, bias = tilt * 4
        var off: (CGFloat, CGFloat) = (0, 0)
        let n = h.count
        for i in 0..<n {
            let l: CGFloat = i > 0 ? h[i - 1] : (spills ? 0 : .infinity)
            let r: CGFloat = i < n - 1 ? h[i + 1] : (spills ? 0 : .infinity)
            let dr = h[i] - r + bias, dl = h[i] - l - bias
            if dr > repose, dr >= dl {
                let m = min(h[i], (dr - repose) / 2)
                h[i] -= m
                if i < n - 1 { h[i + 1] += m } else { off.1 += m }
            } else if dl > repose {
                let m = min(h[i], (dl - repose) / 2)
                h[i] -= m
                if i > 0 { h[i - 1] += m } else { off.0 += m }
            }
        }
        return off
    }

    var total: CGFloat { h.reduce(0, +) }

    var v: CGFloat = 0, shift: CGFloat = 0  // slab slide: velocity (pt/s) and sub-column offset

    /// Once the slope beats static friction the whole layer slides as one slab, accelerating
    /// (snow on a smooth roof). s = sin(tilt), + = right side down.
    /// Returns snow that slid off each end and the thickest column that left.
    mutating func slide(s: CGFloat, dt: CGFloat) -> (l: CGFloat, r: CGFloat, thick: CGFloat) {
        // ponytail: G ≈ 1400 pt/s² matches the falling clumps; μ static 0.4 (≈22°), kinetic 0.3 — snow on glass/metal
        let G: CGFloat = 1400, muS: CGFloat = 0.4, muK: CGFloat = 0.3
        let c = (1 - s * s).squareRoot()
        if v == 0 && abs(s) <= muS * c { return (0, 0, 0) }  // static friction holds
        let dir: CGFloat = v != 0 ? (v > 0 ? 1 : -1) : (s > 0 ? 1 : -1)
        let nv = v + G * (s - muK * c * dir) * dt
        v = nv * dir <= 0 ? 0 : nv  // kinetic friction can stop it, never reverse it
        shift += v * dt
        var out: (l: CGFloat, r: CGFloat, thick: CGFloat) = (0, 0, 0)
        while shift >= colW { let e = h.removeLast(); out.r += e; out.thick = max(out.thick, e); h.insert(0, at: 0); shift -= colW }
        while shift <= -colW { let e = h.removeFirst(); out.l += e; out.thick = max(out.thick, e); h.append(0); shift += colW }
        if v == 0 || total < 0.5 { v = 0; shift = 0 }  // stopped, or nothing left to slide
        return out
    }
}

// MARK: - Accelerometer (Apple Silicon MacBooks expose it as a vendor HID device)

final class Tilt {
    private(set) var x: CGFloat = 0  // low-passed sideways gravity, -1...1
    private var services: [io_service_t] = []
    private var manager: IOHIDManager?
    private let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    init() {
        var it: io_iterator_t = 0
        IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &it)
        while case let s = IOIteratorNext(it), s != 0 {
            // only wake the accelerometer service (usage page 0xFF00, usage 3)
            let page = IORegistryEntryCreateCFProperty(s, "PrimaryUsagePage" as CFString, nil, 0)?.takeRetainedValue() as? Int
            let usage = IORegistryEntryCreateCFProperty(s, "PrimaryUsage" as CFString, nil, 0)?.takeRetainedValue() as? Int
            if page == 0xFF00 && usage == 3 { services.append(s) } else { IOObjectRelease(s) }
        }
        IOObjectRelease(it)
        wake()

        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(m, ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 3] as CFDictionary)
        guard IOHIDManagerOpen(m, 0) == kIOReturnSuccess,
              let devs = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> else { return }
        manager = m
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        for d in devs {
            IOHIDDeviceRegisterInputReportCallback(d, buf, 64, { ctx, _, _, _, _, report, len in
                guard len >= 18, let ctx else { return }
                let me = Unmanaged<Tilt>.fromOpaque(ctx).takeUnretainedValue()
                let raw = CGFloat(UnsafeRawPointer(report).loadUnaligned(fromByteOffset: 6, as: Int32.self)) / 65536
                me.x += (max(-1, min(1, raw)) - me.x) * 0.1
            }, ctx)
            IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
    }

    private func set(_ on: Bool) {
        let props: [(String, Int)] = [("SensorPropertyReportingState", on ? 1 : 0),
                                      ("SensorPropertyPowerState", on ? 1 : 0),
                                      ("ReportInterval", on ? 20000 : 0)]  // µs; sensor supports 50/100/200/400/800 Hz
        for s in services { for (k, v) in props { IORegistryEntrySetCFProperty(s, k as CFString, v as CFNumber) } }
    }

    func wake() { set(true) }
    func sleep() { set(false) }
}

// MARK: - Simulation + rendering

struct Flake {
    var p: CGPoint, r: CGFloat, phase: CGFloat
    /// Packed snow sliding off a roof: no flutter, accelerates like a falling object. Velocity in pt/s.
    var heavy = false, vx: CGFloat = 0, vy: CGFloat = 0
    var behind = false  // falls behind the windows (past the "house"): no roofs or walls, hidden by windows
}

final class SnowView: NSView {
    var intensity: CGFloat = 0.4          // 0...1, set from the menu
    var invertTilt = false
    var autoPlow = true                   // send snowplows on their own when the ground snow gets high
    let tilt: Tilt?        // nil on external monitors: they don't tilt with the laptop
    let origin: CGPoint    // this screen's top-left in global CG coordinates

    private var flakes: [Flake] = []
    private var ground: Pile
    /// Everything a window carries: snow on its roof and snow plastered on its side walls.
    struct Ledge {
        var frame: CGRect
        var pile: Pile
        var stuck: [(p: CGPoint, r: CGFloat)] = []  // on the walls, relative to the frame origin
    }
    private var ledges: [Int: Ledge] = [:]  // keyed by CG window number
    private var parked: [Int: Ledge] = [:]  // snow of windows on another Space or minimized
    private var order: [CGRect] = []                              // window frames, front to back
    struct Plow {
        var x: CGFloat               // truck rear, in view x
        var ride: CGFloat = 0        // snow height under the front wheels (the truck drives on what it packs)
        var rear: CGFloat = 0        // ... and under the rear wheels; the difference tilts the truck
        var load: CGFloat = 0        // snow being pushed in front of the blade
        var scrapes = false          // last truck of its convoy: scrapes down to the road
        var bite = SnowView.bite     // deepest layer the blade takes off in one pass
        var floor: CGFloat = 0       // snow it leaves on the road
    }
    private var plows: [Plow] = []   // convoy, leader first
    private var storm: CGFloat = 0           // seconds of blizzard left
    private var stormLevel: CGFloat = 0      // 0...1, ramps in and out so nothing changes abruptly
    private var wind = CGVector.zero, gust = CGVector.zero, gustTimer: CGFloat = 0

    // ponytail: 15 s blizzard; change the duration here
    func startStorm() { storm = 15 }
    private var spray: [(p: CGPoint, v: CGVector, r: CGFloat)] = []  // snow thrown off the plow blade
    private var frameCount = 0

    override var isFlipped: Bool { true }  // y grows downward, same as CGWindowList

    init(frame: NSRect, origin: CGPoint, tilt: Tilt?) {
        self.origin = origin
        self.tilt = tilt
        ground = Pile(width: frame.width, cap: frame.height * 0.6)
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Sends a convoy: each truck bites one layer, so deep snow gets as many trucks as layers (max 10).
    /// Another convoy can follow one already on the road once the start of the road is clear.
    func callPlow() {
        guard plows.allSatisfy({ $0.x > 200 }) else { return }
        let n = min(10, max(1, Int(((ground.h.max() ?? 0) / Self.bite).rounded(.up))))
        plows += (0..<n).map { Plow(x: -Self.plowLen - 60 - CGFloat($0) * (Self.plowLen + 180), scrapes: $0 == n - 1) }
    }

    /// The automatic plow: one truck that takes everything above `floor` off in a single pass,
    /// lowering the snow rather than clearing the road.
    private func sendAutoPlow(leaving floor: CGFloat) {
        guard plows.allSatisfy({ $0.x > 200 }) else { return }
        plows.append(Plow(x: -Self.plowLen - 60, bite: .infinity, floor: floor))
    }
    static let plowLen: CGFloat = 152  // truck rear to blade tip
    static let bladeH: CGFloat = 40
    static let bite = bladeH * 0.8     // deepest layer one blade takes off
    static let heapMax: CGFloat = .pi / 4 * bladeH * 80  // a blade-high bank 160pt long; more is thrown aside

    // Called ~10 Hz: track the windows snow can sit on.
    func refreshWindows() {
        let me = ProcessInfo.processInfo.processIdentifier
        let menuBar = (window?.screen).map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 40  // notch-aware
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var seen: [Int: CGRect] = [:]
        order = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,  // invisible windows are no roof
                  let num = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b)?.offsetBy(dx: -origin.x, dy: -origin.y),
                  r.width > 60, r.height > 40, r.intersects(bounds) else { continue }
            order.append(r)
            seen[num] = r
        }
        var moved: [Ledge] = []
        for (num, l) in ledges where seen[num] != l.frame {
            ledges[num] = nil
            // gone from view but still alive (other Space, minimized): keep its snow for when it's back
            if seen[num] == nil && windowExists(num) { parked[num] = l; continue }
            moved.append(l)
        }
        for (num, r) in seen where ledges[num] == nil {
            if let p = parked.removeValue(forKey: num), p.frame == r { ledges[num] = p; continue }
            ledges[num] = Ledge(frame: r, pile: Pile(width: r.width, cap: max(0, min(50, r.minY - menuBar))))  // never pile over the menu bar
        }
        moved.forEach(spill)  // window moved, resized or closed: shake the snow off (after the new roofs exist)
        if frameCount % 300 == 0 { parked = parked.filter { windowExists($0.key) } }  // forget windows closed meanwhile
    }

    /// Does the window still exist anywhere (any Space, minimized), even if it isn't on screen now?
    private func windowExists(_ num: Int) -> Bool {
        var id = UnsafeRawPointer(bitPattern: UInt(num))  // this CFArray holds raw CGWindowIDs, not objects
        guard let ids = CFArrayCreate(nil, &id, 1, nil),
              let found = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]] else { return false }
        return !found.isEmpty
    }

    private func spill(_ l: Ledge) {
        let r = l.frame
        for s in l.stuck {
            flakes.append(Flake(p: CGPoint(x: r.minX + s.p.x, y: r.minY + s.p.y), r: s.r, phase: 0, heavy: true))
        }
        // same volume as the roof snow (add() deposits π·r²·0.6 per flake), at most ~3000 flakes: bigger chunks if needed
        let volume = l.pile.total * colW
        let fr = max(1.8, (volume / (3000 * .pi * 0.6)).squareRoot())
        let per = .pi * fr * fr * 0.6
        var carry: CGFloat = 0
        for (i, h) in l.pile.h.enumerated() where h > 0 {
            carry += h * colW
            while carry >= per {
                carry -= per
                let p = CGPoint(x: r.minX + (CGFloat(i) + .random(in: 0...1)) * colW, y: r.minY - .random(in: 0...h))
                // a window is now under this spot (moved up or sideways): the snow stays on its new roof
                if let w = order.first(where: { $0.contains(p) }) { settle(on: w, x: p.x, r: fr); continue }
                flakes.append(Flake(p: p, r: fr, phase: 0, heavy: true, vy: .random(in: 0...40)))
            }
        }
    }

    /// Puts a flake's worth of snow straight onto window w's roof (lost if the roof is full).
    private func settle(on w: CGRect, x: CGFloat, r: CGFloat) {
        guard let num = ledges.first(where: { $0.value.frame == w })?.key else { return }
        _ = ledges[num]!.pile.add(x: x - w.minX, r: r)
    }

    /// Snow leaving a roof edge: keeps the slab's momentum, then free-falls; the spread makes it crumble apart.
    private func dropClump(_ amount: CGFloat, x: CGFloat, y: CGFloat, dir: CGFloat, speed: CGFloat, thick: CGFloat) {
        for _ in 0..<min(40, 2 + Int(amount / 4)) {
            flakes.append(Flake(p: CGPoint(x: x + dir * .random(in: 1...7), y: y - .random(in: 0...max(6, thick))),
                                r: .random(in: 1.2...3), phase: 0, heavy: true,
                                vx: dir * (speed + .random(in: 15...60)), vy: .random(in: 0...40)))
        }
    }

    /// Windows break the wind like houses: right behind one (downwind) the air is nearly still,
    /// recovering over a distance about as long as the window is tall.
    private func shelter(_ p: CGPoint) -> CGFloat {
        guard abs(wind.dx) > 1 else { return 1 }
        var s: CGFloat = 1
        for w in order where p.y >= w.minY - 20 && p.y <= w.maxY {
            let d = wind.dx > 0 ? p.x - w.maxX : w.minX - p.x  // how far downwind of the wall
            let len = min(400, w.height)
            if d >= 0 && d < len { s = min(s, 0.1 + 0.9 * d / len) }
        }
        return s
    }

    /// Snow height around x, averaged over a few columns (0 off screen).
    private func surface(at x: CGFloat) -> CGFloat {
        let c = Int((x / colW).rounded(.down))
        let lo = max(0, c - 3), hi = min(ground.h.count - 1, c + 3)
        return lo <= hi ? ground.h[lo...hi].reduce(0, +) / CGFloat(hi - lo + 1) : 0
    }

    /// Is point p hidden behind any window that is in front of window index `idx` in `order`?
    private func covered(_ p: CGPoint, before idx: Int) -> Bool {
        order.prefix(idx).contains { $0.contains(p) }
    }

    func step(dt: CGFloat) {
        frameCount += 1
        if frameCount % 3 == 0 {
            refreshWindows()
            // one snowplow sets off by itself once a quarter of the screen width has snow above half the Dock
            // (one lone drift isn't enough) and lowers it all to half that level in a single pass; if that
            // much builds up again where it already passed, another truck follows
            let dock = (window?.screen).map { $0.visibleFrame.minY - $0.frame.minY } ?? 0
            let limit = (dock > 20 ? dock : 70) / 2  // hidden, side or no Dock: assume a standard 70 pt one
            let passed = min(ground.h.count, max(0, plows.map { Int(($0.x + Self.plowLen) / colW) }.min() ?? ground.h.count))
            let deep = ground.h[..<passed].lazy.filter { $0 > limit }.count
            // ponytail: 25% of the width; lower it to plow sooner, raise it to let more snow build up
            if autoPlow && deep * 4 >= ground.h.count { sendAutoPlow(leaving: limit / 2) }
        }

        var g = tilt.map { invertTilt ? -$0.x : $0.x } ?? 0  // sin of the real sideways tilt, no amplification
        g = max(-0.9, min(0.9, g))
        let gy = (1 - g * g).squareRoot()

        // blizzard: gusts of random strength and direction every second or two, eased in and out
        if storm > 0 {
            storm -= dt
            gustTimer -= dt
            if gustTimer <= 0 {
                gustTimer = .random(in: 0.8...2.5)
                gust = CGVector(dx: .random(in: -340...340), dy: .random(in: -30...70))
            }
        } else {
            gust = .zero
        }
        stormLevel += ((storm > 0 ? 1 : 0) - stormLevel) * min(1, 0.8 * dt)
        wind.dx += (gust.dx - wind.dx) * min(1, 1.5 * dt)
        wind.dy += (gust.dy - wind.dy) * min(1, 1.5 * dt)

        // spawn
        let rate = intensity * intensity * 400 + stormLevel * 2000  // flakes per second
        var n = Int(rate * dt) + (CGFloat.random(in: 0...1) < (rate * dt).truncatingRemainder(dividingBy: 1) ? 1 : 0)
        n = min(n, max(0, (stormLevel > 0.05 ? 5500 : 4000) - flakes.count))
        let fromSide = abs(wind.dx) / (abs(wind.dx) + 80)  // strong wind blows snow in from the upwind edge
        for _ in 0..<n {
            let p = CGFloat.random(in: 0...1) < fromSide
                ? CGPoint(x: wind.dx > 0 ? -5 : bounds.maxX + 5, y: .random(in: 0...bounds.maxY))
                : CGPoint(x: .random(in: -bounds.width * 0.3...bounds.width * 1.3), y: -5)
            // ponytail: 30% of the snow falls behind windows, so under them the ground gets about a third
            flakes.append(Flake(p: p, r: .random(in: 0.8...3.2), phase: .random(in: 0...6), behind: CGFloat.random(in: 0..<1) < 0.3))
        }

        // move + collide
        let ledgeList = ledges.map { (num: $0.key, frame: $0.value.frame, idx: order.firstIndex(of: $0.value.frame) ?? 0) }
        var i = 0
        while i < flakes.count {
            var f = flakes[i]
            let old = f.p
            if f.heavy {
                // ponytail: 1400 pt/s² ≈ gravity at desk scale, 900 pt/s ≈ drag limit; tune by eye
                f.vy = min(900, f.vy + (1300 + f.r * 50) * dt)
                f.vx *= 1 - 1.5 * dt
                f.p.x += (f.vx + g * f.vy) * dt
                f.p.y += gy * f.vy * dt
            } else {
                let speed = (25 + f.r * 18) * (1 + 0.6 * stormLevel)
                let blow = (1.3 - f.r * 0.15) * shelter(f.p)  // small flakes are pushed more; windows block it
                f.phase += dt * 1.5
                f.p.x += (g * speed + sin(f.phase) * 12 + wind.dx * blow) * dt
                f.p.y += (gy * speed + wind.dy * blow) * dt
            }

            var landed = false
            // window ledges
            for l in ledgeList where !f.behind && f.p.x >= l.frame.minX && f.p.x < l.frame.maxX {
                let c = Int((f.p.x - l.frame.minX) / colW)
                let top = l.frame.minY - ledges[l.num]!.pile.h[min(c, ledges[l.num]!.pile.h.count - 1)]
                // was above the roof and is now in or under the snow surface (which can rise past it when lots lands at once)
                if old.y <= l.frame.minY && f.p.y >= top && !covered(CGPoint(x: f.p.x, y: l.frame.minY + 1), before: l.idx) {
                    landed = ledges[l.num]!.pile.add(x: f.p.x - l.frame.minX, r: f.r)
                    break
                }
            }
            // windows are solid, like a house: a flake that hits a side wall loses its sideways push and slides
            // down along it; anything else inside a window (full roof, hidden roof) is gone, never drawn over an app
            if !landed, !f.behind, let w = order.first(where: { $0.contains(f.p) }), w.contains(old) {
                settle(on: w, x: f.p.x, r: f.r)  // the window was dragged onto it: it ends up on the roof
                landed = true
            }
            if !landed, !f.behind, let w = order.first(where: { $0.contains(f.p) }) {
                let left = old.y > w.minY && old.x <= w.minX, right = old.y > w.minY && old.x >= w.maxX
                if left || right {
                    f.p.x = left ? w.minX - f.r - .random(in: 0...2) : w.maxX + f.r + .random(in: 0...2)
                    f.vx = 0
                    // about a third sticks like wet snow on a house wall, whatever the wind does next;
                    // the rest, or anything once a window's walls are plastered, just slides down them
                    if CGFloat.random(in: 0..<1) < 0.35,
                       let num = ledges.first(where: { $0.value.frame == w })?.key, ledges[num]!.stuck.count < 200 {
                        ledges[num]!.stuck.append((CGPoint(x: f.p.x - w.minX, y: f.p.y - w.minY), f.r))
                        landed = true
                    }
                }
                if !landed && order.contains(where: { $0.contains(f.p) }) { landed = true }  // from above, or wedged between windows
            }
            // screen bottom
            if !landed, f.p.y >= bounds.maxY - ground.h[max(0, min(ground.h.count - 1, Int(f.p.x / colW)))] {
                _ = ground.add(x: f.p.x, r: f.r)
                landed = true
            }
            if landed || f.p.y > bounds.maxY + 10 || f.p.x < -bounds.width * 0.5 || f.p.x > bounds.width * 1.5 {
                flakes.swapAt(i, flakes.count - 1); flakes.removeLast()
            } else {
                flakes[i] = f; i += 1
            }
        }

        // snow plastered on walls creeps down slowly and now and then a bit lets go and drops
        for (num, l) in ledges where !l.stuck.isEmpty {
            var keep: [(p: CGPoint, r: CGFloat)] = []
            for var w in l.stuck {
                w.p.y += .random(in: 0...5) * dt
                let at = CGPoint(x: l.frame.minX + w.p.x, y: l.frame.minY + w.p.y)
                // buried by the drift growing at the foot of the wall: it's part of that snow now
                if at.y >= bounds.maxY - surface(at: at.x) { _ = ground.add(x: at.x, r: w.r); continue }
                // ponytail: ~15 s average grip; raise to make wet snow cling longer
                if w.p.y > l.frame.height || CGFloat.random(in: 0..<1) < dt / 15 {
                    flakes.append(Flake(p: CGPoint(x: l.frame.minX + w.p.x, y: l.frame.minY + w.p.y), r: w.r, phase: 0, heavy: true))
                } else {
                    keep.append(w)
                }
            }
            ledges[num]!.stuck = keep
        }

        // settled snow slides with tilt; ledges spill over their edges
        for _ in 0..<3 { _ = ground.relax(tilt: g, spills: false) }  // the ground pile avalanches against the walls
        for (num, l) in ledges {
            var pile = l.pile
            let slab = pile.slide(s: g, dt: dt)
            let (lo, ro) = pile.relax(tilt: g, spills: true)
            pile.overhang.l += lo + slab.l; pile.overhang.r += ro + slab.r
            // drop it as an irregular clump now and then, not one identical flake per frame (that draws a streak)
            let speed = abs(pile.v), thick = slab.thick
            if pile.overhang.l > .random(in: 6...20) {
                dropClump(pile.overhang.l, x: l.frame.minX, y: l.frame.minY, dir: -1, speed: speed, thick: thick); pile.overhang.l = 0
            }
            if pile.overhang.r > .random(in: 6...20) {
                dropClump(pile.overhang.r, x: l.frame.maxX, y: l.frame.minY, dir: 1, speed: speed, thick: thick); pile.overhang.r = 0
            }
            ledges[num]!.pile = pile
        }

        // snowplows: each blade bites at most one layer off the top and its truck drives on the packed snow
        // it leaves, so the leader rides high on deep snow and each truck behind takes the next layer down
        for i in plows.indices {
            let x = plows[i].x, nx = x + 200 * dt
            let from = Int((x + Self.plowLen - 2) / colW), to = Int((nx + Self.plowLen - 2) / colW)
            if from < to {
                for c in (from + 1)...to where ground.h.indices.contains(c) {
                    let cut = min(max(0, ground.h[c] - plows[i].floor), plows[i].bite)
                    ground.h[c] -= cut
                    plows[i].load += cut
                }
            }
            if plows[i].scrapes {
                // the last truck scrapes down to the road everything under it, including what slumped
                // back off the uncut bank after the trucks ahead passed
                let a = max(0, Int(nx / colW)), b = min(ground.h.count, to + 1)
                if a < b { for c in a..<b { plows[i].load += ground.h[c]; ground.h[c] = 0 } }
            }
            // more than the blade can push rolls over it and is thrown aside (out of this side view)
            let cast = max(0, plows[i].load - Self.heapMax)
            plows[i].load -= cast
            for _ in 0..<min(5, Int(cast / 6)) {
                spray.append((CGPoint(x: nx + Self.plowLen - .random(in: 0...6),
                                      y: bounds.maxY - plows[i].ride - .random(in: Self.bladeH - 10 ... Self.bladeH)),
                              CGVector(dx: 200 + .random(in: 50...240), dy: .random(in: -320 ... -100)), .random(in: 1...2.6)))
            }
            // wheels follow the snow under them, smoothed so the truck doesn't jitter
            plows[i].rear += (surface(at: nx + 24) - plows[i].rear) * 0.4
            plows[i].ride += (surface(at: nx + 112) - plows[i].ride) * 0.4
            plows[i].x = nx
        }
        plows.removeAll { $0.x > bounds.maxX + 100 }  // off screen, its load goes with it
        spray = spray.compactMap { s in
            var s = s
            s.p.x += s.v.dx * dt; s.p.y += s.v.dy * dt; s.v.dy += 700 * dt
            return s.p.y > bounds.maxY - surface(at: s.p.x) ? nil : s  // lands on the snow
        }

        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // ponytail: one CPU path redrawn per frame; move to CAShapeLayer/Metal if CPU matters

        // snow sits behind windows: clipped exactly at their edges, never hidden column by column
        for l in ledges.values {
            ctx.saveGState()
            clipOut(ctx, order.prefix(order.firstIndex(of: l.frame) ?? 0))  // windows in front of this one
            drawDrift(ctx, l.pile.h, x0: l.frame.minX, base: l.frame.minY)
            ctx.restoreGState()
        }
        ctx.saveGState()
        clipOut(ctx, order[...])
        let (gh, heaps) = groundWithHeaps()
        let groundPeak = gh.max() ?? 0
        drawDrift(ctx, gh, x0: 0, base: bounds.maxY, peak: groundPeak)
        ctx.restoreGState()
        // snowplows and the heaps they push drive in front of everything, windows included
        // (same gradient span as the ground, so a heap blends into the snow it rests on)
        for h in heaps where !h.isEmpty {
            drawDrift(ctx, Array(gh[h]), x0: CGFloat(h.lowerBound) * colW, base: bounds.maxY, peak: groundPeak)
        }
        for p in plows {
            ctx.saveGState()
            // pivot on the rear wheels' contact point and tilt to where the front wheels touch
            ctx.translateBy(x: p.x + 24, y: bounds.maxY - p.rear)
            ctx.rotate(by: -atan2(p.ride - p.rear, 88))
            ctx.translateBy(x: -24, y: 0)
            drawPlow(ctx, spin: p.x / 11)
            ctx.restoreGState()
        }

        // flakes: grey copy 1pt lower = cheap outline on white windows (a blurred shadow costs ~50% CPU);
        // small flakes are dimmer, so they read as farther away
        // snow falling behind the windows, hidden wherever a window is in front of it
        ctx.saveGState()
        clipOut(ctx, order[...])
        let back = CGMutablePath()
        for f in flakes where f.behind { back.addEllipse(in: CGRect(x: f.p.x - f.r, y: f.p.y - f.r, width: f.r * 2, height: f.r * 2)) }
        ctx.setFillColor(NSColor(white: 1, alpha: 0.75).cgColor)
        ctx.addPath(back); ctx.fillPath()
        ctx.restoreGState()

        let plastered = ledges.values.flatMap { l in
            l.stuck.map { (p: CGPoint(x: l.frame.minX + $0.p.x, y: l.frame.minY + $0.p.y), r: $0.r) }
        }.filter { s in !order.contains { $0.contains(s.p) } }  // hidden behind a window in front
        for far in [true, false] {
            let p = CGMutablePath()
            for f in flakes where !f.behind && (f.r < 1.7) == far {
                p.addEllipse(in: CGRect(x: f.p.x - f.r, y: f.p.y - f.r, width: f.r * 2, height: f.r * 2))
            }
            if !far { for s in plastered { p.addEllipse(in: CGRect(x: s.p.x - s.r, y: s.p.y - s.r, width: s.r * 2, height: s.r * 2)) } }
            if !far {  // far flakes skip the outline: barely visible, and it doubles the fill cost
                ctx.saveGState(); ctx.translateBy(x: 0, y: 1)
                ctx.setFillColor(NSColor(white: 0.45, alpha: 0.45).cgColor)
                ctx.addPath(p); ctx.fillPath(); ctx.restoreGState()
            }
            ctx.setFillColor(NSColor(white: 1, alpha: far ? 0.7 : 1).cgColor)
            ctx.addPath(p); ctx.fillPath()
        }

        // snow thrown off the blade
        let thrown = CGMutablePath()
        for s in spray { thrown.addEllipse(in: CGRect(x: s.p.x - s.r, y: s.p.y - s.r, width: s.r * 2, height: s.r * 2)) }
        ctx.saveGState(); ctx.translateBy(x: 0, y: 1)
        ctx.setFillColor(CGColor(gray: 0.45, alpha: 0.45)); ctx.addPath(thrown); ctx.fillPath()
        ctx.restoreGState()
        ctx.setFillColor(.white); ctx.addPath(thrown); ctx.fillPath()
    }

    private static let driftGradient = CGGradient(colorsSpace: nil, colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        CGColor(red: 0.93, green: 0.96, blue: 1, alpha: 1),
        CGColor(red: 0.78, green: 0.85, blue: 0.95, alpha: 1)] as CFArray, locations: [0, 0.35, 1])!

    /// Draws a heightmap as a soft drift: smoothed outline, white top fading to blue shade at the base.
    /// Restricts drawing to outside these windows (each clip intersects, so overlaps are handled).
    private func clipOut(_ ctx: CGContext, _ windows: ArraySlice<CGRect>) {
        for w in windows { ctx.addRect(bounds); ctx.addRect(w); ctx.clip(using: .evenOdd) }
    }

    /// `peak` fixes the gradient's span, so separately drawn pieces of the same snow match.
    private func drawDrift(_ ctx: CGContext, _ h: [CGFloat], x0: CGFloat, base: CGFloat, peak fixed: CGFloat? = nil) {
        let n = h.count
        var s = h  // smoothed copy for drawing only; the simulation keeps the raw heights
        for _ in 0..<5 { s = (0..<n).map { i in (s[max(0, i - 1)] + 2 * s[i] + s[min(n - 1, i + 1)]) / 4 } }
        let body = CGMutablePath(), edge = CGMutablePath()
        var i = 0, peak: CGFloat = 0
        while i < n {
            guard s[i] > 0.4 else { i += 1; continue }
            body.move(to: CGPoint(x: x0 + CGFloat(i) * colW, y: base))
            edge.move(to: CGPoint(x: x0 + (CGFloat(i) + 0.5) * colW, y: base - s[i]))  // outline the top only
            while i < n, s[i] > 0.4 {
                let p = CGPoint(x: x0 + (CGFloat(i) + 0.5) * colW, y: base - s[i])
                body.addLine(to: p); edge.addLine(to: p)
                peak = max(peak, s[i]); i += 1
            }
            body.addLine(to: CGPoint(x: x0 + CGFloat(i) * colW, y: base))
            body.closeSubpath()
        }
        guard peak > 0 else { return }
        if let fixed { peak = max(peak, fixed) }
        ctx.saveGState()
        ctx.addPath(body); ctx.clip()
        ctx.drawLinearGradient(Self.driftGradient, start: CGPoint(x: 0, y: base - peak), end: CGPoint(x: 0, y: base), options: [])
        ctx.restoreGState()
        ctx.setStrokeColor(CGColor(red: 0.55, green: 0.63, blue: 0.75, alpha: 0.6))
        ctx.setLineWidth(1)
        ctx.addPath(edge); ctx.strokePath()
    }

    /// Ground heights with each plow's pushed heap merged in: a rounded mound, blade-high at the face,
    /// sitting on whatever lies ahead.
    /// Also returns the column ranges each heap covers.
    private func groundWithHeaps() -> ([CGFloat], [Range<Int>]) {
        var gh = ground.h
        var heaps: [Range<Int>] = []
        for p in plows where p.load > 1 {
            let n = Int(max(15, p.load * 4 / (.pi * Self.bladeH)))   // columns; area of a quarter-ellipse = π/4·H·len
            let H = min(Self.bladeH, p.load * 4 / (.pi * CGFloat(n)))
            let tip = Int((p.x + Self.plowLen - 4) / colW)
            var last = tip
            let blade = p.ride + (p.ride - p.rear) * 40 / 88  // where the blade edge is on a slope
            for k in 0..<n {
                let c = tip + k
                guard c < gh.count else { break }
                guard c >= 0 else { continue }
                let t = CGFloat(k) / CGFloat(n)
                let lump = sin(CGFloat(c) * 0.7) * 1.2 + sin(CGFloat(c) * 2.3) * 0.8
                // the heap rests on what's ahead: wedged at blade height against a higher bank, or
                // tumbling onto lower ground when the road drops away (never a made-up slope down to it)
                let below = gh[c]
                gh[c] = max(below, min(blade, below) + H * (1 - t * t).squareRoot() + lump)
                last = c
            }
            let lo = max(0, tip), hi = min(gh.count, last + 1)
            if lo < hi { heaps.append(lo..<hi) }
        }
        return (gh, heaps)
    }

    /// Side view of a municipal snowplow facing right, origin = truck rear on the road.
    private func drawPlow(_ ctx: CGContext, spin: CGFloat) {
        let x: CGFloat = 0, y: CGFloat = 0
        let bob = sin(CGFloat(frameCount) * 0.9) * 0.6  // engine/road shake on the body, not the wheels
        func rr(_ r: CGRect, _ rad: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil) }
        func fill(_ c: CGColor, _ p: CGPath) { ctx.setFillColor(c); ctx.addPath(p); ctx.fillPath() }
        let orange = CGColor(red: 0.95, green: 0.50, blue: 0.10, alpha: 1)
        let orangeDark = CGColor(red: 0.72, green: 0.33, blue: 0.05, alpha: 1)
        let steel = CGColor(gray: 0.25, alpha: 1)

        ctx.saveGState()
        ctx.translateBy(x: x, y: y + bob)
        // chassis + exhaust stack
        fill(steel, rr(CGRect(x: 4, y: -26, width: 128, height: 8), 2))
        fill(CGColor(gray: 0.35, alpha: 1), rr(CGRect(x: 83, y: -70, width: 3, height: 44), 1))
        // salt-spreader body: flared hopper with ribs and a stripe
        let body = CGMutablePath()
        body.addLines(between: [CGPoint(x: 2, y: -58), CGPoint(x: 82, y: -58), CGPoint(x: 78, y: -26), CGPoint(x: 8, y: -26)])
        body.closeSubpath()
        fill(orange, body)
        ctx.setStrokeColor(orangeDark); ctx.setLineWidth(1.5)
        for rx in [14, 28, 42, 56, 70] as [CGFloat] { ctx.move(to: CGPoint(x: rx, y: -56)); ctx.addLine(to: CGPoint(x: rx, y: -28)) }
        ctx.strokePath()
        fill(CGColor(gray: 0.95, alpha: 1), CGPath(rect: CGRect(x: 6, y: -42, width: 74, height: 3), transform: nil))
        fill(CGColor(gray: 1, alpha: 0.85), CGPath(rect: CGRect(x: 1, y: -60, width: 82, height: 2.5), transform: nil))  // snow on the hopper
        // cab with hood
        let cab = CGMutablePath()
        cab.move(to: CGPoint(x: 88, y: -24))
        cab.addLine(to: CGPoint(x: 88, y: -60))
        cab.addQuadCurve(to: CGPoint(x: 94, y: -64), control: CGPoint(x: 88, y: -64))
        cab.addLine(to: CGPoint(x: 112, y: -64))
        cab.addLine(to: CGPoint(x: 118, y: -42))
        cab.addLine(to: CGPoint(x: 132, y: -40))
        cab.addQuadCurve(to: CGPoint(x: 134, y: -34), control: CGPoint(x: 134, y: -40))
        cab.addLine(to: CGPoint(x: 134, y: -24))
        cab.closeSubpath()
        fill(orange, cab)
        // window with a glare stripe
        let glass = CGMutablePath()
        glass.addLines(between: [CGPoint(x: 94, y: -59), CGPoint(x: 109, y: -59), CGPoint(x: 114, y: -43), CGPoint(x: 94, y: -43)])
        glass.closeSubpath()
        fill(CGColor(red: 0.55, green: 0.72, blue: 0.85, alpha: 1), glass)
        ctx.saveGState(); ctx.addPath(glass); ctx.clip()
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.5)); ctx.setLineWidth(3)
        ctx.move(to: CGPoint(x: 98, y: -40)); ctx.addLine(to: CGPoint(x: 108, y: -62)); ctx.strokePath()
        ctx.restoreGState()
        ctx.setStrokeColor(orangeDark); ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: 104, y: -41)); ctx.addLine(to: CGPoint(x: 104, y: -26)); ctx.strokePath()  // door seam
        fill(steel, rr(CGRect(x: 97, y: -38, width: 5, height: 1.5), 0.7))                              // door handle
        fill(steel, rr(CGRect(x: 129, y: -30, width: 6, height: 5), 1))                                 // bumper
        // headlight + beam
        fill(CGColor(red: 1, green: 0.97, blue: 0.8, alpha: 1), CGPath(ellipseIn: CGRect(x: 130, y: -38, width: 4, height: 4), transform: nil))
        // amber beacon, rotating = pulsing glow
        let pulse = (sin(CGFloat(frameCount) * 0.5) + 1) / 2
        fill(CGColor(red: 1, green: 0.65, blue: 0, alpha: 0.25 * pulse), CGPath(ellipseIn: CGRect(x: 92, y: -78, width: 18, height: 18), transform: nil))
        fill(CGColor(red: 1, green: 0.55 + 0.3 * pulse, blue: 0, alpha: 1), rr(CGRect(x: 97, y: -70, width: 8, height: 6), 2))
        // blade: push frame + curved moldboard with steel cutting edge
        ctx.setStrokeColor(steel); ctx.setLineWidth(3)
        ctx.move(to: CGPoint(x: 132, y: -22)); ctx.addLine(to: CGPoint(x: 143, y: -14))
        ctx.move(to: CGPoint(x: 132, y: -30)); ctx.addLine(to: CGPoint(x: 142, y: -30))
        ctx.strokePath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.translateBy(x: x, y: y)  // blade and wheels stay on the road
        let blade = CGMutablePath()
        blade.move(to: CGPoint(x: 140, y: -2))
        blade.addQuadCurve(to: CGPoint(x: 146, y: -44), control: CGPoint(x: 136, y: -26))
        blade.addLine(to: CGPoint(x: 152, y: -42))
        blade.addQuadCurve(to: CGPoint(x: 148, y: -2), control: CGPoint(x: 143, y: -24))
        blade.closeSubpath()
        fill(CGColor(red: 0.98, green: 0.78, blue: 0.10, alpha: 1), blade)
        fill(CGColor(gray: 0.6, alpha: 1), CGPath(rect: CGRect(x: 139, y: -3, width: 10, height: 3), transform: nil))
        // wheels: tyre, rim, rotating spokes
        for wx in [24, 50, 112] as [CGFloat] {
            let c = CGPoint(x: wx, y: -11)
            fill(CGColor(gray: 0.08, alpha: 1), CGPath(ellipseIn: CGRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22), transform: nil))
            fill(CGColor(gray: 0.55, alpha: 1), CGPath(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12), transform: nil))
            ctx.setStrokeColor(CGColor(gray: 0.3, alpha: 1)); ctx.setLineWidth(1.5)
            for k in 0..<5 {
                let a = spin + CGFloat(k) * .pi * 2 / 5
                ctx.move(to: c); ctx.addLine(to: CGPoint(x: c.x + cos(a) * 5.5, y: c.y + sin(a) * 5.5))
            }
            ctx.strokePath()
            fill(CGColor(gray: 0.2, alpha: 1), CGPath(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4), transform: nil))
        }
        ctx.restoreGState()

    }
}

// MARK: - App, overlay window, menu bar

final class App: NSObject, NSApplicationDelegate {
    let tilt = Tilt()
    var overlays: [(window: NSWindow, view: SnowView)] = []
    var item: NSStatusItem!
    var timer: Timer?
    var intensity: CGFloat = 0.4, invertTilt = false
    var allScreens = UserDefaults.standard.bool(forKey: "allScreens")
    var autoPlow = UserDefaults.standard.object(forKey: "autoPlow") as? Bool ?? true

    /// One transparent click-through overlay per screen (or just the menu-bar one). Screens that keep the
    /// same frame keep their overlay and its snow; only added, moved or resized screens start fresh.
    func buildOverlays() {
        let next = (allScreens ? NSScreen.screens : Array(NSScreen.screens.prefix(1))).map { screen in
            if let kept = overlays.first(where: { $0.window.frame == screen.frame }) { return kept }
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)  // above the Dock
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            let v = SnowView(frame: CGRect(origin: .zero, size: screen.frame.size), origin: CGDisplayBounds(id).origin,
                             tilt: CGDisplayIsBuiltin(id) != 0 ? tilt : nil)
            v.intensity = intensity
            v.invertTilt = invertTilt
            v.autoPlow = autoPlow
            w.contentView = v
            w.setFrame(screen.frame, display: false)
            w.orderFrontRegardless()
            return (w, v)
        }
        for o in overlays where !next.contains(where: { $0.window === o.window }) { o.window.orderOut(nil) }
        overlays = next
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildOverlays()

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Neve")
        let menu = NSMenu()
        menu.addItem(withTitle: "Nevicata", action: nil, keyEquivalent: "")
        let slider = NSSlider(value: Double(intensity), minValue: 0, maxValue: 1, target: self, action: #selector(level(_:)))
        slider.frame = CGRect(x: 18, y: 4, width: 180, height: 22)
        let holder = NSView(frame: CGRect(x: 0, y: 0, width: 216, height: 30))
        holder.addSubview(slider)
        let sliderItem = NSMenuItem(); sliderItem.view = holder
        menu.addItem(sliderItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Tormenta di neve", action: #selector(blizzard), keyEquivalent: "t").target = self
        menu.addItem(withTitle: "Chiama lo spazzaneve", action: #selector(plow), keyEquivalent: "p").target = self
        let auto = menu.addItem(withTitle: "Spazzaneve automatico", action: #selector(toggleAutoPlow(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = autoPlow ? .on : .off
        let screens = menu.addItem(withTitle: "Tutti gli schermi", action: #selector(toggleScreens(_:)), keyEquivalent: "")
        screens.target = self
        screens.state = allScreens ? .on : .off
        menu.addItem(withTitle: "Inverti inclinazione", action: #selector(invert(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Esci", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu

        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.overlays.forEach { $0.view.step(dt: 1.0 / 30) } }
        RunLoop.main.add(t, forMode: .common)  // keep snowing while the menu is open
        timer = t

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.tilt.wake()
        }
        // monitor plugged/unplugged or rearranged
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.buildOverlays()
        }
    }

    func applicationWillTerminate(_ n: Notification) { tilt.sleep() }

    @objc func level(_ s: NSSlider) { intensity = CGFloat(s.doubleValue); overlays.forEach { $0.view.intensity = intensity } }
    @objc func plow() { overlays.forEach { $0.view.callPlow() } }
    @objc func blizzard() { overlays.forEach { $0.view.startStorm() } }
    @objc func invert(_ m: NSMenuItem) {
        invertTilt.toggle(); m.state = invertTilt ? .on : .off
        overlays.forEach { $0.view.invertTilt = invertTilt }
    }
    @objc func toggleAutoPlow(_ m: NSMenuItem) {
        autoPlow.toggle(); m.state = autoPlow ? .on : .off
        UserDefaults.standard.set(autoPlow, forKey: "autoPlow")
        overlays.forEach { $0.view.autoPlow = autoPlow }
    }
    @objc func toggleScreens(_ m: NSMenuItem) {
        allScreens.toggle(); m.state = allScreens ? .on : .off
        UserDefaults.standard.set(allScreens, forKey: "allScreens")
        buildOverlays()
    }
}

// MARK: - Self-check: `Snow --selftest`

func selftest() {
    var p = Pile(width: 20, cap: 100)       // 10 columns
    p.h[5] = 20
    for _ in 0..<500 { _ = p.relax(tilt: 0, spills: false) }
    precondition(abs(p.total - 20) < 0.001, "walls keep the snow")
    precondition(zip(p.h, p.h.dropFirst()).allSatisfy { abs($0 - $1) <= 1.6 + 0.001 }, "flat tilt settles to repose")

    var q = Pile(width: 20, cap: 100)
    q.h = Array(repeating: 3, count: 10)
    var spilled: CGFloat = 0
    for _ in 0..<500 { let (l, r) = q.relax(tilt: 0.8, spills: true); assert(l == 0); spilled += r }
    precondition(spilled > 0 && abs(q.total + spilled - 30) < 0.001, "tilted ledge spills only downhill, mass conserved")

    var c = Pile(width: 4, cap: 0.1)
    precondition(c.add(x: 1, r: 1) && !c.add(x: 1, r: 1) && !c.add(x: 99, r: 1) && !c.add(x: -1, r: 1), "cap and bounds")
    precondition(abs(c.total * colW - .pi * 0.6) < 0.001, "deposit keeps the flake's volume")
    // slab slide: 45° clears a 300pt roof in about a second; 10° is held by friction
    var slab = Pile(width: 300, cap: 100); slab.h = Array(repeating: 10, count: 150)
    var t: CGFloat = 0, off: CGFloat = 0
    while slab.total > 0.5 && t < 5 { off += slab.slide(s: sin(.pi / 4), dt: 1.0 / 30).r; t += 1.0 / 30 }
    precondition(t < 1.5 && abs(off - 1500) < 0.01, "45°: slab slides off fast, mass conserved (t=\(t))")
    var held = Pile(width: 300, cap: 100); held.h = Array(repeating: 10, count: 150)
    for _ in 0..<90 { _ = held.slide(s: sin(10 * .pi / 180), dt: 1.0 / 30) }
    precondition(held.total == 1500 && held.v == 0, "10°: static friction holds")
    print("selftest ok")
}

if CommandLine.arguments.contains("--selftest") { selftest(); exit(0) }
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
