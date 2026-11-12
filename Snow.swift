import AppKit
import CoreLocation
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
        var water: CGFloat = 0                       // rain on the roof waiting to drip off its edges (in drops)
    }

    /// A raindrop: a fast streak. `wall` is set while it trickles down a window side.
    struct Drop {
        var p: CGPoint, v: CGVector
        var s: CGFloat                  // its terminal speed
        var behind = false              // falls behind the windows, like part of the snow
        var wall: CGFloat? = nil        // x of the window wall it runs down
        var wallEnd: CGFloat = 0        // ... until here, the bottom of that window
    }
    enum Weather: String { case snow, rain, sun, fog }
    var weather = Weather.snow
    var rain: Bool { weather == .rain }
    private var clouds: [(x: CGFloat, y: CGFloat, w: CGFloat, path: CGPath)] = []  // sun mode
    private var fogBanks: [(path: CGPath, y: CGFloat, speed: CGFloat, alpha: CGFloat)] = []
    private var time: CGFloat = 0       // seconds since start, for drifting fog
    private var hiddenUntil: CGFloat = 0  // overlay hidden while a Space switch slides the windows around
    private var slideSeen = -CGFloat.infinity  // when the slide itself was last spotted

    /// Space switch: macOS slides the windows but this overlay stays put, so its snow would sit on the old
    /// windows' outlines for a moment. Hide it for the slide and fade it back in on the new Space, once:
    /// macOS's own notice comes after the slide, so it only counts when the slide went unnoticed.
    func spaceChanged(bySystem: Bool = false) {
        if bySystem && time - slideSeen < 1.5 { return }
        if !bySystem { slideSeen = time }
        // ponytail: 0.45 s covers the switch animation; Reduce Motion makes it shorter
        hiddenUntil = time + 0.45
        window?.alphaValue = 0
    }
    private var drops: [Drop] = []
    private var splashes: [(p: CGPoint, v: CGVector, life: CGFloat)] = []
    private var puddle: CGFloat = 0     // water at the bottom of the screen, as an average depth
    private var bolts: [(trunk: CGPath, branches: CGPath, life: CGFloat)] = []  // lightning on screen
    private var flash: CGFloat = 0      // sky lit up by the last strike, fading
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
    func refreshWindows(dt: CGFloat) {
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
        // a Space switch slides all the windows sideways together, before macOS says anything: hide the
        // overlay right away so the snow and sky don't sweep along with them, and don't shake any roof
        let shifts = seen.compactMap { num, r in ledges[num].map { (dx: r.minX - $0.frame.minX, dy: r.minY - $0.frame.minY) } }
            .filter { abs($0.dx) > 8 }
        let sliding = shifts.count >= 2 && shifts.allSatisfy { abs($0.dx - shifts[0].dx) < 2 && abs($0.dy) < 2 }
        if sliding { spaceChanged() }

        var moved: [(Ledge, CGRect?)] = []  // snow to shake off, and where that window is now
        for (num, l) in ledges where seen[num] != l.frame {
            ledges[num] = nil
            // gone from view but still alive (other Space, minimized): keep its snow for when it's back
            if seen[num] == nil && windowExists(num) { parked[num] = l; continue }
            if let nf = seen[num], nf.size == l.frame.size {
                // dragged: the roof carries its snow along like a tray; a fast move shakes some of it off
                // ponytail: nothing falls below 300 pt/s; at 1800 pt/s about half of it per tenth of a second
                let speed = hypot(nf.minX - l.frame.minX, nf.minY - l.frame.minY) / dt
                let jolt = sliding ? 0 : min(0.5, max(0, (speed - 300) / 3000) * dt / 0.1)
                var carried = l, shaken = Ledge(frame: l.frame, pile: l.pile)
                carried.frame = nf
                carried.pile.cap = max(0, min(50, nf.minY - menuBar))
                for c in carried.pile.h.indices {
                    shaken.pile.h[c] = carried.pile.h[c] * jolt
                    carried.pile.h[c] -= shaken.pile.h[c]
                }
                ledges[num] = carried
                moved.append((shaken, nf))  // what shook off falls from where the roof just was
                continue
            }
            moved.append((l, seen[num]))
        }
        for (num, r) in seen where ledges[num] == nil {
            if let p = parked.removeValue(forKey: num), p.frame == r { ledges[num] = p; continue }
            ledges[num] = Ledge(frame: r, pile: Pile(width: r.width, cap: max(0, min(50, r.minY - menuBar))))  // never pile over the menu bar
        }
        for (l, now) in moved { spill(l, now: now) }  // moved, resized or closed: shake the snow off (after the new roofs exist)
        if frameCount % 300 == 0 { parked = parked.filter { windowExists($0.key) } }  // forget windows closed meanwhile
    }

    /// Does the window still exist anywhere (any Space, minimized), even if it isn't on screen now?
    private func windowExists(_ num: Int) -> Bool {
        var id = UnsafeRawPointer(bitPattern: UInt(num))  // this CFArray holds raw CGWindowIDs, not objects
        guard let ids = CFArrayCreate(nil, &id, 1, nil),
              let found = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]] else { return false }
        return !found.isEmpty
    }

    /// `now` is where that window is now, if it's still open: snow can only land back on its own roof.
    private func spill(_ l: Ledge, now: CGRect?) {
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
                // the window moved up or sideways under this spot: the snow stays on its new roof; inside any other
                // window it's simply behind that one (never teleported onto someone else's roof)
                if let w = order.first(where: { $0.contains(p) }) { if w == now { settle(on: w, x: p.x, r: fr) }; continue }
                flakes.append(Flake(p: p, r: fr, phase: 0, heavy: true, vy: .random(in: 0...40)))
            }
        }
    }

    /// Rain: streaks that splash instead of piling up. Roofs shed their water off the edges, side walls get
    /// rivulets, the water collects in a puddle at the bottom that stays level with real gravity, and the
    /// snow that's there melts away.
    private func stepRain(dt: CGFloat, g: CGFloat, gy: CGFloat) {
        let ledgeList = ledges.map { (num: $0.key, frame: $0.value.frame, idx: order.firstIndex(of: $0.value.frame) ?? 0) }
        func splash(_ p: CGPoint) {
            guard splashes.count < 1500 else { return }
            for _ in 0..<Int.random(in: 1...3) {
                splashes.append((p, CGVector(dx: .random(in: -70...70), dy: .random(in: -150 ... -50)), .random(in: 0.15...0.3)))
            }
        }
        var i = 0
        while i < drops.count {
            var d = drops[i]
            let old = d.p
            var done = false
            if let wx = d.wall {
                d.p.x = wx
                d.p.y += 160 * dt  // trickles down the wall, then drips off the bottom corner
                if d.p.y >= d.wallEnd { d.wall = nil; d.v = CGVector(dx: 0, dy: 40) }
            } else {
                // drops barely feel the wind; drips leaving a roof start slow and speed up
                let target = CGVector(dx: g * d.s + wind.dx * 0.4 * shelter(d.p), dy: gy * d.s + wind.dy * 0.3)
                let k = min(1, 5 * dt)
                d.v.dx += (target.dx - d.v.dx) * k
                d.v.dy += (target.dy - d.v.dy) * k
                d.p.x += d.v.dx * dt
                d.p.y += d.v.dy * dt
                if !d.behind {
                    for l in ledgeList where d.p.x >= l.frame.minX && d.p.x < l.frame.maxX {
                        let c = min(Int((d.p.x - l.frame.minX) / colW), ledges[l.num]!.pile.h.count - 1)
                        let top = l.frame.minY - ledges[l.num]!.pile.h[c]
                        if old.y <= l.frame.minY && d.p.y >= top && !covered(CGPoint(x: d.p.x, y: l.frame.minY + 1), before: l.idx) {
                            splash(CGPoint(x: d.p.x, y: top))
                            // most of the water runs off the front and back of the roof, out of this side view;
                            // only some reaches the ends and drips from the corners
                            ledges[l.num]!.water += 0.12
                            done = true
                            break
                        }
                    }
                    if !done, let w = order.first(where: { $0.contains(d.p) }) {
                        let left = old.y > w.minY && old.x <= w.minX, right = old.y > w.minY && old.x >= w.maxX
                        if left || right { d.wall = left ? w.minX - 1 : w.maxX + 1; d.wallEnd = w.maxY; d.p.x = d.wall! }
                        else { done = true }  // under a roof hidden by another window
                    }
                }
            }
            let surface = max(surface(at: d.p.x), waterLevel(at: d.p.x))
            if !done && d.p.y >= bounds.maxY - surface {
                splash(CGPoint(x: d.p.x, y: bounds.maxY - surface))
                puddle += 0.0015
                done = true
            }
            if done || d.p.y > bounds.maxY + 20 || d.p.x < -bounds.width * 0.5 || d.p.x > bounds.width * 1.5 {
                drops.swapAt(i, drops.count - 1); drops.removeLast()
            } else {
                drops[i] = d; i += 1
            }
        }
        splashes = splashes.compactMap { s in
            var s = s
            s.p.x += s.v.dx * dt; s.p.y += s.v.dy * dt; s.v.dy += 900 * dt; s.life -= dt
            return s.life > 0 ? s : nil
        }

        // water runs off each roof and drips from its edges, the downhill one when the laptop is tilted
        for (num, l) in ledges where l.water >= 1 {
            var w = l.water
            for _ in 0..<min(howMany(w * 3, dt), Int(w)) {
                let right = abs(g) > 0.05 ? g > 0 : Bool.random()
                let off = CGFloat.random(in: 1...4)
                drops.append(Drop(p: CGPoint(x: right ? l.frame.maxX + off : l.frame.minX - off, y: l.frame.minY + .random(in: 0...4)),
                                  v: CGVector(dx: 0, dy: .random(in: 0...30)), s: .random(in: 650...850)))
                w -= 1
            }
            ledges[num]!.water = w
        }

        // lightning: every couple of seconds in a thunderstorm, and in heavy rain too
        // ponytail: 0.4 strikes/s at full storm; rain alone from half intensity, up to one every ~4 s at full
        let strikes = stormLevel * 0.4 + max(0, intensity - 0.5) * 0.5
        if rain && CGFloat.random(in: 0..<1) < strikes * dt { strike() }
        bolts = bolts.compactMap { b in b.life > dt ? (b.trunk, b.branches, b.life - dt) : nil }
        flash = max(0, flash - 4 * dt)

        // ponytail: the puddle drains ~6%/s and tops out at 30 pt
        puddle = min(30, puddle * (1 - 0.06 * dt))

        // rain and sun melt the snow: roofs shed it as dripping water, the ground's runs into the puddle;
        // the sun also dries the puddle up. Clouds and night slow the sun down.
        let sun = weather == .sun ? daylight() * (1 - 0.7 * intensity) : 0
        puddle *= 1 - 0.12 * sun * dt
        guard rain || sun > 0 else { return }
        let melt = (rain ? 0.1 + 0.3 * intensity + 0.4 * stormLevel : 0.6 * sun) * dt
        var melted: CGFloat = 0
        for c in ground.h.indices where ground.h[c] > 0 { let m = min(ground.h[c], melt); ground.h[c] -= m; melted += m }
        puddle += melted * colW / bounds.width * 0.5
        for num in ledges.keys {
            var roof: CGFloat = 0
            for c in ledges[num]!.pile.h.indices where ledges[num]!.pile.h[c] > 0 {
                let m = min(ledges[num]!.pile.h[c], melt); ledges[num]!.pile.h[c] -= m; roof += m
            }
            ledges[num]!.water += roof * colW / 8
            ledges[num]!.stuck.removeAll { _ in CGFloat.random(in: 0..<1) < dt / 4 }
        }
    }

    /// A lightning strike from the sky to the first thing below it: a visible window roof (on its snow) or
    /// the ground, snow or puddle. Jagged trunk with a few forks, sparks where it hits, and the sky flashes.
    private func strike() {
        let x = CGFloat.random(in: bounds.width * 0.05...bounds.width * 0.95)
        var hit = bounds.maxY - max(surface(at: x), waterLevel(at: x))
        for (i, w) in order.enumerated() where x >= w.minX && x < w.maxX && !covered(CGPoint(x: x, y: w.minY + 1), before: i) {
            let snow = ledges.values.first { $0.frame == w }.map { $0.pile.h[min(Int((x - w.minX) / colW), $0.pile.h.count - 1)] } ?? 0
            hit = min(hit, w.minY - snow)
        }
        // midpoint displacement: each halving adds a smaller sideways kink
        func jag(_ a: CGPoint, _ b: CGPoint, _ spread: CGFloat, _ levels: Int) -> [CGPoint] {
            var pts = [a, b], s = spread
            for _ in 0..<levels {
                var next = [pts[0]]
                for (p, q) in zip(pts, pts.dropFirst()) {
                    next += [CGPoint(x: (p.x + q.x) / 2 + .random(in: -s...s), y: (p.y + q.y) / 2 + .random(in: -s...s) * 0.3), q]
                }
                pts = next; s *= 0.55
            }
            return pts
        }
        let trunk = jag(CGPoint(x: x + .random(in: -160...160), y: 0), CGPoint(x: x, y: hit), 90, 7)
        let t = CGMutablePath(); t.addLines(between: trunk)
        let forks = CGMutablePath()
        for _ in 0..<Int.random(in: 1...3) {
            let from = trunk[Int.random(in: trunk.count / 5...trunk.count * 3 / 5)]
            let to = CGPoint(x: from.x + .random(in: -140...140), y: min(hit, from.y + .random(in: 80...240)))
            forks.addLines(between: jag(from, to, 35, 5))
        }
        bolts.append((t, forks, 0.4))
        flash = 1
        for _ in 0..<14 where splashes.count < 1500 {  // sparks
            splashes.append((CGPoint(x: x, y: hit), CGVector(dx: .random(in: -220...220), dy: .random(in: -320 ... -60)), .random(in: 0.2...0.45)))
        }
    }

    /// Sun mode: clouds (as many as the intensity asks) drift across on a slow breeze; fog just flows.
    private func stepSky(dt: CGFloat) {
        time += dt
        if let w = window, time >= hiddenUntil, w.alphaValue < 1 { w.alphaValue = min(1, w.alphaValue + dt / 0.35) }
        if weather == .sun {
            let target = Int(intensity * 10)
            if clouds.isEmpty && target > 0 {
                for _ in 0..<target { clouds.append(makeCloud(x: .random(in: -150...bounds.width))) }
            } else if clouds.count < target && CGFloat.random(in: 0..<1) < 0.25 * dt {
                clouds.append(makeCloud(x: -400))
            }
        }
        for i in clouds.indices { clouds[i].x += (8 + clouds[i].w * 0.02 + wind.dx * 0.2) * dt }
        clouds.removeAll { $0.x > bounds.width + 20 }  // leaving sun mode, they just drift away
    }

    /// A cloud: a flat, rounded base with a few puffs on top, as a path at the origin.
    private func makeCloud(x: CGFloat) -> (x: CGFloat, y: CGFloat, w: CGFloat, path: CGPath) {
        let w = CGFloat.random(in: 160...380), h = w * 0.32
        let p = CGMutablePath()
        p.addRoundedRect(in: CGRect(x: 0, y: h * 0.55, width: w, height: h * 0.45), cornerWidth: h * 0.22, cornerHeight: h * 0.22)
        for _ in 0..<Int.random(in: 3...5) {
            let r = CGFloat.random(in: h * 0.3...h * 0.6), cx = CGFloat.random(in: r...(w - r))
            p.addEllipse(in: CGRect(x: cx - r, y: h * 0.6 - r, width: 2 * r, height: 2 * r))
        }
        return (x == -400 ? -w - 20 : x, .random(in: 45...bounds.height * 0.3), w, p)
    }

    /// Where the sun (or, at night, the moon) is along its arc, 0 at rise to 1 at set, from the local clock:
    /// the sun from 6:00 to 20:00, the moon the rest of the night.
    private func skyArc() -> (t: CGFloat, day: Bool) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let h = CGFloat(c.hour ?? 12) + CGFloat(c.minute ?? 0) / 60
        return (6...20).contains(h) ? ((h - 6) / 14, true) : ((h - 20 + (h < 6 ? 24 : 0)) / 10, false)
    }
    /// 0 at night, 1 at midday.
    private func daylight() -> CGFloat {
        let a = skyArc()
        return a.day ? sin(.pi * a.t) : 0
    }

    private func drawSky(_ ctx: CGContext) {
        if weather == .sun {
            let a = skyArc()
            let c = CGPoint(x: bounds.width * (0.08 + 0.84 * a.t), y: 70 + (1 - sin(.pi * a.t)) * bounds.height * 0.3)
            let hidden = clouds.contains { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.w * 0.32).insetBy(dx: 12, dy: 6).contains(c) }
            let glow: CGFloat = hidden ? 0.35 : 1
            let (core, halo, r): (CGColor, CGColor, CGFloat) = a.day
                ? (CGColor(red: 1, green: 0.95, blue: 0.72, alpha: 1), CGColor(red: 1, green: 0.88, blue: 0.55, alpha: 0.55 * glow), 34)
                : (CGColor(red: 0.93, green: 0.94, blue: 0.98, alpha: 1), CGColor(red: 0.8, green: 0.85, blue: 1, alpha: 0.25 * glow), 24)
            let fade = CGGradient(colorsSpace: nil, colors: [halo, halo.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(fade, startCenter: c, startRadius: 0, endCenter: c, endRadius: r * (a.day ? 5 : 3), options: [])
            ctx.setFillColor(core); ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            if !a.day {  // a couple of craters
                ctx.setFillColor(CGColor(gray: 0.5, alpha: 0.12))
                ctx.fillEllipse(in: CGRect(x: c.x - 10, y: c.y - 8, width: 9, height: 9))
                ctx.fillEllipse(in: CGRect(x: c.x + 4, y: c.y + 3, width: 6, height: 6))
            }
        }
        for c in clouds {
            // shaded from a bright top to a greyer base, opaque so a cloud in front covers the one behind
            ctx.saveGState()
            ctx.translateBy(x: c.x, y: c.y)
            ctx.addPath(c.path); ctx.clip()
            let shade = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 1, alpha: 1), CGColor(red: 0.82, green: 0.85, blue: 0.9, alpha: 1)] as CFArray,
                                   locations: [0, 1])!
            ctx.drawLinearGradient(shade, start: .zero, end: CGPoint(x: 0, y: c.w * 0.32), options: [])
            ctx.restoreGState()
        }
    }

    /// Fog: a haze that thickens toward the ground plus soft banks flowing past at different speeds.
    private func drawFog(_ ctx: CGContext) {
        guard weather == .fog, intensity > 0 else { return }
        if fogBanks.isEmpty {
            fogBanks = [(0.82, 9.0, 0.16), (0.62, 15.0, 0.12), (0.42, 6.0, 0.08)].map { y, speed, alpha in
                let p = CGMutablePath()
                for i in 0..<14 {
                    let w = CGFloat.random(in: 260...480), h = CGFloat.random(in: 70...150)
                    p.addEllipse(in: CGRect(x: CGFloat(i) * bounds.width / 14 - w / 2, y: -h / 2, width: w, height: h))
                }
                return (p, bounds.height * y, speed, alpha)
            }
        }
        let haze = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 0.85, alpha: 0), CGColor(gray: 0.85, alpha: 0.5 * intensity)] as CFArray,
                              locations: [0, 1])!
        ctx.drawLinearGradient(haze, start: CGPoint(x: 0, y: bounds.height * 0.25), end: CGPoint(x: 0, y: bounds.maxY), options: [])
        for b in fogBanks {
            let off = (time * b.speed).truncatingRemainder(dividingBy: bounds.width)
            for dx in [off - bounds.width, off] {  // tiles seamlessly as it scrolls
                ctx.saveGState()
                ctx.translateBy(x: dx, y: b.y)
                ctx.setFillColor(CGColor(gray: 0.9, alpha: b.alpha * intensity)); ctx.addPath(b.path); ctx.fillPath()
                ctx.restoreGState()
            }
        }
    }

    /// Spreads a rate over frames: how many of something happen in this dt.
    private func howMany(_ perSecond: CGFloat, _ dt: CGFloat) -> Int {
        let k = perSecond * dt
        return Int(k) + (CGFloat.random(in: 0..<1) < k.truncatingRemainder(dividingBy: 1) ? 1 : 0)
    }

    /// Height of the puddle's surface at x: level with real gravity, so tilting sends the water downhill.
    private func waterLevel(at x: CGFloat) -> CGFloat {
        guard puddle > 0.05 else { return 0 }
        var g = tilt.map { invertTilt ? -$0.x : $0.x } ?? 0
        g = max(-0.9, min(0.9, g))
        return max(0, puddle + (x - bounds.midX) * g / (1 - g * g).squareRoot())
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
        do {  // every frame: the snow's clip follows windows being dragged without lagging behind
            refreshWindows(dt: dt)
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
        if rain {
            let n = min(howMany(intensity * intensity * 1200 + stormLevel * 2500, dt), max(0, 6000 - drops.count))
            for _ in 0..<n {
                let s = CGFloat.random(in: 650...900)
                drops.append(Drop(p: CGPoint(x: .random(in: -bounds.width * 0.3...bounds.width * 1.3), y: -20),
                                  v: CGVector(dx: g * s, dy: gy * s), s: s, behind: CGFloat.random(in: 0..<1) < 0.3))
            }
        }
        var n = weather != .snow ? 0 : howMany(intensity * intensity * 400 + stormLevel * 2000, dt)  // flakes per second
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
                // the window was dragged onto it: right at the roof it lands there, deeper it's just behind the window
                if f.p.y - w.minY < 30 { settle(on: w, x: f.p.x, r: f.r) }
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

        stepRain(dt: dt, g: g, gy: gy)
        stepSky(dt: dt)

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

        // the sky, behind the windows
        ctx.saveGState()
        clipOut(ctx, order[...])
        drawSky(ctx)
        ctx.restoreGState()

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
        if puddle > 0.05 {
            let pool = CGMutablePath(), surface = CGMutablePath()
            pool.move(to: CGPoint(x: 0, y: bounds.maxY))
            for x in stride(from: 0, through: bounds.maxX, by: 8) {
                let p = CGPoint(x: x, y: bounds.maxY - waterLevel(at: x))
                pool.addLine(to: p)
                if x == 0 { surface.move(to: p) } else { surface.addLine(to: p) }
            }
            pool.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY)); pool.closeSubpath()
            ctx.setFillColor(CGColor(red: 0.38, green: 0.55, blue: 0.85, alpha: 0.45)); ctx.addPath(pool); ctx.fillPath()
            ctx.setStrokeColor(CGColor(red: 0.85, green: 0.93, blue: 1, alpha: 0.8)); ctx.setLineWidth(1.4); ctx.addPath(surface); ctx.strokePath()
        }
        drawFog(ctx)
        // lightning lights up the sky and strikes, both behind the windows like everything outside
        if flash > 0 {
            ctx.setFillColor(CGColor(red: 0.85, green: 0.88, blue: 1, alpha: 0.22 * flash)); ctx.fill(bounds)
        }
        for b in bolts where Int(b.life * 40) % 3 != 1 {  // flickers while it lasts
            for (width, alpha) in [(9.0, 0.12), (4.0, 0.3), (1.8, 1.0)] as [(CGFloat, CGFloat)] {
                ctx.setStrokeColor(CGColor(red: 0.85, green: 0.9, blue: 1, alpha: alpha))
                ctx.setLineWidth(width); ctx.setLineJoin(.round)
                ctx.addPath(b.trunk); ctx.strokePath()
                ctx.setLineWidth(width * 0.55); ctx.addPath(b.branches); ctx.strokePath()
            }
        }
        // rain falling behind the windows
        let backRain = CGMutablePath()
        for d in drops where d.behind { backRain.move(to: d.p); backRain.addLine(to: CGPoint(x: d.p.x - d.v.dx * 0.02, y: d.p.y - d.v.dy * 0.02)) }
        ctx.setStrokeColor(CGColor(red: 0.8, green: 0.88, blue: 1, alpha: 0.3)); ctx.setLineWidth(1); ctx.addPath(backRain); ctx.strokePath()
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

        // rain: streaks along their motion, rivulets on walls, splashes
        let streaks = CGMutablePath(), rivulets = CGMutablePath(), spl = CGMutablePath()
        for d in drops where !d.behind {
            if d.wall != nil { rivulets.move(to: d.p); rivulets.addLine(to: CGPoint(x: d.p.x, y: d.p.y - 9)) }
            else { streaks.move(to: d.p); streaks.addLine(to: CGPoint(x: d.p.x - d.v.dx * 0.022, y: d.p.y - d.v.dy * 0.022)) }
        }
        for s in splashes { spl.addEllipse(in: CGRect(x: s.p.x - 0.9, y: s.p.y - 0.9, width: 1.8, height: 1.8)) }
        ctx.setStrokeColor(CGColor(red: 0.82, green: 0.9, blue: 1, alpha: 0.6)); ctx.setLineWidth(1.1); ctx.addPath(streaks); ctx.strokePath()
        ctx.setStrokeColor(CGColor(red: 0.82, green: 0.9, blue: 1, alpha: 0.75)); ctx.setLineWidth(1.6); ctx.addPath(rivulets); ctx.strokePath()
        ctx.setFillColor(CGColor(red: 0.85, green: 0.92, blue: 1, alpha: 0.7)); ctx.addPath(spl); ctx.fillPath()

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
    /// Restricts drawing to outside these windows (each clip intersects, so overlaps are handled),
    /// following their rounded corners so nothing behind leaves a notch of wallpaper there.
    private func clipOut(_ ctx: CGContext, _ windows: ArraySlice<CGRect>) {
        // ponytail: macOS doesn't expose the window corner radius; 12 pt matches standard windows
        for w in windows {
            ctx.addRect(bounds)
            ctx.addPath(CGPath(roundedRect: w, cornerWidth: 12, cornerHeight: 12, transform: nil))
            ctx.clip(using: .evenOdd)
        }
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

final class App: NSObject, NSApplicationDelegate, CLLocationManagerDelegate {
    let tilt = Tilt()
    var overlays: [(window: NSWindow, view: SnowView)] = []
    var item: NSStatusItem!
    var timer: Timer?
    var intensity: CGFloat = 0.4, invertTilt = false
    var allScreens = UserDefaults.standard.bool(forKey: "allScreens")
    var autoPlow = UserDefaults.standard.object(forKey: "autoPlow") as? Bool ?? true
    var weather = SnowView.Weather(rawValue: UserDefaults.standard.string(forKey: "weather") ?? "")
        ?? (UserDefaults.standard.bool(forKey: "rain") ? .rain : .snow)
    var weatherItems: [(SnowView.Weather, NSMenuItem)] = []
    var autoWeather = UserDefaults.standard.bool(forKey: "autoWeather")  // follow the weather where you are
    var autoItem: NSMenuItem!, slider: NSSlider!
    let locator = CLLocationManager()
    var autoTimer: Timer?

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
            // on every Space, but hidden while Mission Control is open (.stationary drew over it)
            w.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
            let v = SnowView(frame: CGRect(origin: .zero, size: screen.frame.size), origin: CGDisplayBounds(id).origin,
                             tilt: CGDisplayIsBuiltin(id) != 0 ? tilt : nil)
            v.intensity = intensity
            v.invertTilt = invertTilt
            v.autoPlow = autoPlow
            v.weather = weather
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
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: "Meteo"))
        autoItem = menu.addItem(withTitle: "Automatico", action: #selector(chooseAuto), keyEquivalent: "")
        autoItem.target = self
        for (w, title) in [(SnowView.Weather.snow, "Neve"), (.rain, "Pioggia"), (.sun, "Sole"), (.fog, "Nebbia")] {
            let it = menu.addItem(withTitle: title, action: #selector(chooseWeather(_:)), keyEquivalent: "")
            it.target = self
            weatherItems.append((w, it))
        }
        menu.addItem(.sectionHeader(title: "Intensità"))
        slider = NSSlider(value: Double(intensity), minValue: 0, maxValue: 1, target: self, action: #selector(level(_:)))
        slider.frame = CGRect(x: 18, y: 4, width: 180, height: 22)
        let holder = NSView(frame: CGRect(x: 0, y: 0, width: 216, height: 30))
        holder.addSubview(slider)
        let sliderItem = NSMenuItem(); sliderItem.view = holder
        menu.addItem(sliderItem)
        menu.addItem(.sectionHeader(title: "Neve"))
        menu.addItem(withTitle: "Tormenta di neve", action: #selector(blizzard), keyEquivalent: "t").target = self
        menu.addItem(withTitle: "Chiama lo spazzaneve", action: #selector(plow), keyEquivalent: "p").target = self
        let auto = menu.addItem(withTitle: "Spazzaneve automatico", action: #selector(toggleAutoPlow(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = autoPlow ? .on : .off
        menu.addItem(.sectionHeader(title: "Pioggia"))
        menu.addItem(withTitle: "Temporale", action: #selector(thunderstorm), keyEquivalent: "y").target = self
        menu.addItem(.separator())
        let screens = menu.addItem(withTitle: "Tutti gli schermi", action: #selector(toggleScreens(_:)), keyEquivalent: "")
        screens.target = self
        screens.state = allScreens ? .on : .off
        menu.addItem(withTitle: "Inverti inclinazione", action: #selector(invert(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Esci", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        showWeather()
        if autoWeather { setAuto(true) }

        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.overlays.forEach { $0.view.step(dt: 1.0 / 30) } }
        RunLoop.main.add(t, forMode: .common)  // keep snowing while the menu is open
        timer = t

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.tilt.wake()
            if self?.autoWeather == true { self?.locator.requestLocation() }  // the weather may have changed overnight
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.overlays.forEach { $0.view.spaceChanged(bySystem: true) }
        }
        // monitor plugged/unplugged or rearranged
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.buildOverlays()
        }
    }

    func applicationWillTerminate(_ n: Notification) { tilt.sleep() }

    @objc func level(_ s: NSSlider) { intensity = CGFloat(s.doubleValue); overlays.forEach { $0.view.intensity = intensity }; showWeather() }
    @objc func plow() { overlays.forEach { $0.view.callPlow() } }
    // each storm switches to its own weather first, so both work from either mode (and leave automatic mode)
    @objc func blizzard() { setAuto(false); setWeather(.snow); overlays.forEach { $0.view.startStorm() } }
    @objc func thunderstorm() { setAuto(false); setWeather(.rain); overlays.forEach { $0.view.startStorm() } }
    @objc func invert(_ m: NSMenuItem) {
        invertTilt.toggle(); m.state = invertTilt ? .on : .off
        overlays.forEach { $0.view.invertTilt = invertTilt }
    }
    @objc func chooseWeather(_ m: NSMenuItem) { setAuto(false); setWeather(weatherItems.first { $0.1 === m }!.0) }
    func setWeather(_ w: SnowView.Weather) {
        weather = w
        if !autoWeather { UserDefaults.standard.set(w.rawValue, forKey: "weather") }  // the manual choice is what's remembered
        overlays.forEach { $0.view.weather = w }
        showWeather()
    }
    /// Menu ticks and the menu-bar icon follow the weather; in automatic mode the one picked for you gets a dash.
    func showWeather() {
        autoItem.state = autoWeather ? .on : .off
        for (w, it) in weatherItems { it.state = w != weather ? .off : autoWeather ? .mixed : .on }
        let icon = switch weather {
        case .snow: "snowflake"
        case .rain: "cloud.rain"
        case .sun: intensity > 0.5 ? "cloud.sun" : "sun.max"
        case .fog: "cloud.fog"
        }
        item.button?.image = NSImage(systemSymbolName: icon, accessibilityDescription: weatherItems.first { $0.0 == weather }?.1.title)
    }
    // MARK: Automatic weather: Location Services for where you are, Open-Meteo for the weather there

    @objc func chooseAuto() { setAuto(true) }

    func setAuto(_ on: Bool) {
        autoWeather = on
        UserDefaults.standard.set(on, forKey: "autoWeather")
        autoTimer?.invalidate(); autoTimer = nil
        if on {
            locator.delegate = self
            locator.requestWhenInUseAuthorization()  // asks the first time
            locator.requestLocation()
            // ponytail: every 15 min; Open-Meteo's current conditions don't change faster than that
            autoTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in self?.locator.requestLocation() }
        } else {
            autoItem.title = "Automatico"
            weather = SnowView.Weather(rawValue: UserDefaults.standard.string(forKey: "weather") ?? "") ?? weather
        }
        showWeather()
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        // once answered, ask again: allowed gets the weather, denied ends in didFailWithError
        if autoWeather && m.authorizationStatus != .notDetermined { m.requestLocation() }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        autoItem.title = "Automatico (posizione non disponibile)"
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard autoWeather, let c = locations.last?.coordinate else { return }
        autoItem.title = "Automatico"
        // rounded to ~10 km: plenty for the weather, and it's all that leaves this Mac
        let lat = (c.latitude * 10).rounded() / 10, lon = (c.longitude * 10).rounded() / 10
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=weather_code,cloud_cover") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let now = json["current"] as? [String: Any], let code = now["weather_code"] as? Int else { return }
            let (w, level) = App.local(code: code, cloud: now["cloud_cover"] as? Double ?? 50)
            DispatchQueue.main.async {
                guard let self, self.autoWeather else { return }
                self.intensity = level
                self.slider.doubleValue = Double(level)
                self.overlays.forEach { $0.view.intensity = level }
                self.setWeather(w)
            }
        }.resume()
    }

    /// WMO weather code (as Open-Meteo reports it) → what to show and how hard.
    static func local(code: Int, cloud: Double) -> (SnowView.Weather, CGFloat) {
        switch code {
        case 45, 48: (.fog, 0.7)
        case 51, 56, 61, 66, 80: (.rain, 0.4)                // drizzle, light rain, light showers
        case 53, 63, 81: (.rain, 0.65)
        case 55, 57, 65, 67, 82: (.rain, 0.9)
        case 95, 96, 99: (.rain, 1)                          // thunderstorm: heavy rain brings the lightning
        case 71, 77, 85: (.snow, 0.4)
        case 73: (.snow, 0.65)
        case 75, 86: (.snow, 0.9)
        default: (.sun, CGFloat(max(0, min(100, cloud))) / 100)  // 0–3: clear to overcast, as cloudy as it is
        }
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
    // automatic weather: WMO codes map onto the four modes
    precondition(App.local(code: 0, cloud: 0) == (.sun, 0) && App.local(code: 3, cloud: 100) == (.sun, 1), "clear to overcast")
    precondition(App.local(code: 45, cloud: 100).0 == .fog && App.local(code: 63, cloud: 100).0 == .rain, "fog, rain")
    precondition(App.local(code: 95, cloud: 100) == (.rain, 1) && App.local(code: 75, cloud: 100).0 == .snow, "storm, snow")
    print("selftest ok")
}

if CommandLine.arguments.contains("--selftest") { selftest(); exit(0) }
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
