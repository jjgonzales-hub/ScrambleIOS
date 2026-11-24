import UIKit

/// A hole is defined in scene points. 2 points = 1 yard.
struct Hole {
    static let pointsPerYard: CGFloat = 2

    let number: Int
    let name: String
    let par: Int
    let sceneSize: CGSize
    let tee: CGPoint
    let pin: CGPoint
    let greenRadius: CGFloat
    let fringeWidth: CGFloat
    /// Sampled fairway centerline, tee → green.
    let fairwayLine: [CGPoint]
    let fairwayWidth: CGFloat
    let bunkers: [(center: CGPoint, radius: CGFloat)]
    let waterRects: [CGRect]          // rendered + tested as ellipses
    let treeMarginX: CGFloat          // outside this margin = trees
    let treeZones: [CGRect]           // extra stands of trees (ellipses)
    let greenSlope: CGVector          // pts/s² drift applied to rolling balls
    /// Trees line the hole: anything farther than this from the fairway
    /// centerline (and away from the tee and green) is in the woods.
    let corridor: CGFloat
    /// Real cup-to-ball proportions (cup is ~2.5× the ball's width).
    let cupRadius: CGFloat = 1.1
    /// Contours on the green: bumps (+) and hollows (−) on top of the tilt.
    let greenFeatures: [(center: CGPoint, radius: CGFloat, height: CGFloat)]
    /// Converts green height gradient into rolling acceleration.
    static let slopeK: CGFloat = 60

    let fairwayPath: CGPath

    var yards: Int {
        // Played length along the fairway, like a scorecard.
        var total: CGFloat = 0
        var prev = tee
        for p in fairwayLine + [pin] {
            total += prev.distance(to: p)
            prev = p
        }
        return Int(total / Hole.pointsPerYard)
    }

    init(number: Int, name: String, par: Int, sceneSize: CGSize,
         tee: CGPoint, pin: CGPoint, greenRadius: CGFloat, fringeWidth: CGFloat,
         fairway: [(CGPoint, CGPoint, CGPoint, CGPoint)], fairwayWidth: CGFloat,
         bunkers: [(center: CGPoint, radius: CGFloat)], waterRects: [CGRect],
         treeMarginX: CGFloat, treeZones: [CGRect] = [], greenSlope: CGVector,
         greenFeatures: [(center: CGPoint, radius: CGFloat, height: CGFloat)] = [],
         corridor: CGFloat = 78) {
        self.number = number
        self.name = name
        self.par = par
        self.sceneSize = sceneSize
        self.tee = tee
        self.pin = pin
        self.greenRadius = greenRadius
        self.fringeWidth = fringeWidth
        self.fairwayWidth = fairwayWidth
        self.bunkers = bunkers
        self.waterRects = waterRects
        self.treeMarginX = treeMarginX
        self.treeZones = treeZones
        self.greenSlope = greenSlope
        self.corridor = corridor
        self.greenFeatures = greenFeatures

        let path = UIBezierPath()
        var samples: [CGPoint] = []
        for (i, seg) in fairway.enumerated() {
            if i == 0 { path.move(to: seg.0) }
            path.addCurve(to: seg.3, controlPoint1: seg.1, controlPoint2: seg.2)
            for s in 0...24 where !(i > 0 && s == 0) {
                samples.append(Hole.cubic(seg.0, seg.1, seg.2, seg.3, CGFloat(s) / 24))
            }
        }
        self.fairwayLine = samples
        self.fairwayPath = path.cgPath.copy(
            strokingWithWidth: fairwayWidth, lineCap: .round,
            lineJoin: .round, miterLimit: 10)
    }

    // MARK: - Rules

    func lie(at p: CGPoint) -> Lie {
        for rect in waterRects where Hole.inEllipse(p, rect) { return .water }
        let pinDist = p.distance(to: pin)
        if pinDist <= greenRadius { return .green }
        if pinDist <= greenRadius + fringeWidth { return .fringe }
        for b in bunkers where p.distance(to: b.center) <= b.radius { return .bunker }
        if p.distance(to: tee) <= 26 { return .tee }
        if fairwayPath.contains(p) { return .fairway }
        if p.x < treeMarginX || p.x > sceneSize.width - treeMarginX { return .trees }
        for zone in treeZones where Hole.inEllipse(p, zone) { return .trees }
        if pinDist > greenRadius + 46 && p.distance(to: tee) > 46
            && distanceToCenterline(p) > corridor { return .trees }
        return .rough
    }

    func distanceToCenterline(_ p: CGPoint) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        var prev = tee
        for q in fairwayLine + [pin] {
            best = min(best, Hole.segmentDistance(p, prev, q))
            prev = q
        }
        return best
    }

    static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = CGVector(from: a, to: b)
        let len2 = ab.dx * ab.dx + ab.dy * ab.dy
        guard len2 > 0.0001 else { return p.distance(to: a) }
        let t = max(0, min(1, ((p.x - a.x) * ab.dx + (p.y - a.y) * ab.dy) / len2))
        return p.distance(to: CGPoint(x: a.x + ab.dx * t, y: a.y + ab.dy * t))
    }

    func distanceToPinYards(from p: CGPoint) -> Double {
        Double(p.distance(to: pin) / Hole.pointsPerYard)
    }

    /// The physics view of this hole.
    var course: BallPhysics.Course {
        let h = self
        return BallPhysics.Course(
            lie: { h.lie(at: $0) },
            pin: pin, cupRadius: cupRadius, slope: { h.slope(at: $0) },
            bounds: CGRect(origin: .zero, size: sceneSize).insetBy(dx: 12, dy: 12))
    }

    // MARK: - Green contours
    //
    // One height field drives both the physics (the ball rolls down its
    // gradient) and the rendered green, so what you see is how it breaks.

    /// Green surface height (pts) relative to the cup.
    func greenHeight(at p: CGPoint) -> CGFloat {
        var h = -(greenSlope.dx * (p.x - pin.x) + greenSlope.dy * (p.y - pin.y)) / Hole.slopeK
        for f in greenFeatures {
            let d2 = (p.x - f.center.x) * (p.x - f.center.x) + (p.y - f.center.y) * (p.y - f.center.y)
            h += f.height * exp(-d2 / (f.radius * f.radius))
        }
        return h
    }

    /// Downhill acceleration on the green at `p`.
    func slope(at p: CGPoint) -> CGVector {
        var s = greenSlope
        for f in greenFeatures {
            let dx = p.x - f.center.x, dy = p.y - f.center.y
            let r2 = f.radius * f.radius
            let k = Hole.slopeK * f.height * exp(-(dx * dx + dy * dy) / r2) * 2 / r2
            s = s + CGVector(dx: k * dx, dy: k * dy)
        }
        return s
    }

    /// Caddie aim: at the pin when it's in range, otherwise at the spot on
    /// the fairway this club reaches (so doglegs aim down the fairway, not
    /// over the trees).
    func target(from p: CGPoint, carryYards: Double) -> CGPoint {
        let reach = CGFloat(carryYards) * Hole.pointsPerYard
        let pinDist = p.distance(to: pin)
        if pinDist <= reach * 1.08 { return pin }
        var best: CGPoint?
        var bestErr = CGFloat.greatestFiniteMagnitude
        for q in fairwayLine where q.distance(to: pin) < pinDist {
            let err = abs(p.distance(to: q) - reach * 0.97)
            if err < bestErr { bestErr = err; best = q }
        }
        return best ?? pin
    }

    // MARK: - Helpers

    static func inEllipse(_ p: CGPoint, _ rect: CGRect) -> Bool {
        let rx = rect.width / 2, ry = rect.height / 2
        guard rx > 0, ry > 0 else { return false }
        let nx = (p.x - rect.midX) / rx
        let ny = (p.y - rect.midY) / ry
        return nx * nx + ny * ny <= 1
    }

    static func cubic(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint,
                      _ t: CGFloat) -> CGPoint {
        let mt = 1 - t
        let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p1.x,
                       y: a * p0.y + b * c1.y + c * c2.y + d * p1.y)
    }

    // MARK: - The course: three holes

    static let course: [Hole] = [.one(), .two(), .three()]

    /// Hole 1 — "The Opener". Par 4, gentle S-curve, pond right, three
    /// bunkers.
    static func one() -> Hole {
        Hole(
            number: 1, name: "The Opener", par: 4,
            sceneSize: CGSize(width: 600, height: 1000),
            tee: CGPoint(x: 300, y: 90),
            pin: CGPoint(x: 300, y: 850),
            greenRadius: 70, fringeWidth: 14,
            fairway: [(CGPoint(x: 300, y: 130), CGPoint(x: 240, y: 340),
                       CGPoint(x: 365, y: 560), CGPoint(x: 300, y: 770))],
            fairwayWidth: 86,
            bunkers: [(CGPoint(x: 226, y: 800), 26),
                      (CGPoint(x: 376, y: 818), 22),
                      (CGPoint(x: 262, y: 455), 22)],
            waterRects: [CGRect(x: 376, y: 505, width: 84, height: 140)],
            treeMarginX: 62,
            greenSlope: CGVector(dx: 2.6, dy: -1.0),
            greenFeatures: [(CGPoint(x: 262, y: 882), 26, 1.8),
                            (CGPoint(x: 332, y: 820), 22, -1.2)]
        )
    }

    /// Hole 2 — "Glass Pond". Par 3, all carry over water to a green
    /// guarded by sand.
    static func two() -> Hole {
        Hole(
            number: 2, name: "Glass Pond", par: 3,
            sceneSize: CGSize(width: 560, height: 560),
            tee: CGPoint(x: 280, y: 80),
            pin: CGPoint(x: 305, y: 410),
            greenRadius: 58, fringeWidth: 12,
            fairway: [(CGPoint(x: 280, y: 110), CGPoint(x: 282, y: 130),
                       CGPoint(x: 285, y: 150), CGPoint(x: 288, y: 172)),
                      (CGPoint(x: 288, y: 172), CGPoint(x: 296, y: 280),
                       CGPoint(x: 300, y: 320), CGPoint(x: 302, y: 345))],
            fairwayWidth: 80,
            bunkers: [(CGPoint(x: 236, y: 432), 24),
                      (CGPoint(x: 372, y: 446), 22),
                      (CGPoint(x: 318, y: 486), 18)],
            waterRects: [CGRect(x: 150, y: 190, width: 290, height: 130)],
            treeMarginX: 70,
            treeZones: [CGRect(x: 400, y: 70, width: 110, height: 110)],
            greenSlope: CGVector(dx: -2.2, dy: 1.8),
            greenFeatures: [(CGPoint(x: 280, y: 442), 24, 1.6),
                            (CGPoint(x: 336, y: 386), 18, -1.0)]
        )
    }

    /// Hole 3 — "The Long Way Home". Par 5 dogleg left around a stand of
    /// trees, pond short-right of the green. Cut the corner if you dare.
    static func three() -> Hole {
        Hole(
            number: 3, name: "The Long Way Home", par: 5,
            sceneSize: CGSize(width: 760, height: 1160),
            tee: CGPoint(x: 540, y: 90),
            pin: CGPoint(x: 230, y: 1050),
            greenRadius: 70, fringeWidth: 14,
            fairway: [(CGPoint(x: 540, y: 130), CGPoint(x: 560, y: 330),
                       CGPoint(x: 560, y: 520), CGPoint(x: 470, y: 690)),
                      (CGPoint(x: 470, y: 690), CGPoint(x: 400, y: 820),
                       CGPoint(x: 260, y: 880), CGPoint(x: 235, y: 975))],
            fairwayWidth: 86,
            bunkers: [(CGPoint(x: 588, y: 600), 24),
                      (CGPoint(x: 296, y: 1012), 22),
                      (CGPoint(x: 166, y: 1004), 22),
                      (CGPoint(x: 512, y: 470), 20)],
            waterRects: [CGRect(x: 300, y: 905, width: 100, height: 90)],
            treeMarginX: 60,
            treeZones: [CGRect(x: 110, y: 300, width: 300, height: 470)],
            greenSlope: CGVector(dx: 1.8, dy: 2.4),
            greenFeatures: [(CGPoint(x: 198, y: 1014), 26, 1.7),
                            (CGPoint(x: 262, y: 1080), 22, -1.3)]
        )
    }
}
