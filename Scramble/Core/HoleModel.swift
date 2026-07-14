import UIKit

/// A hole is defined in scene points. 2 points = 1 yard.
struct Hole {
    static let pointsPerYard: CGFloat = 2

    let number: Int
    let par: Int
    let sceneSize: CGSize
    let tee: CGPoint
    let pin: CGPoint
    let greenRadius: CGFloat
    let fringeWidth: CGFloat
    let fairwayCenterline: UIBezierPath
    let fairwayWidth: CGFloat
    let bunkers: [(center: CGPoint, radius: CGFloat)]
    let waterRects: [CGRect]          // rendered + tested as ellipses
    let treeMarginX: CGFloat          // outside this margin = trees
    let greenSlope: CGVector          // pts/s² drift applied to rolling putts
    let cupRadius: CGFloat = 7

    let fairwayPath: CGPath

    var yards: Int { Int(tee.distance(to: pin) / Hole.pointsPerYard) }

    init(number: Int, par: Int, sceneSize: CGSize, tee: CGPoint, pin: CGPoint,
         greenRadius: CGFloat, fringeWidth: CGFloat,
         fairwayCenterline: UIBezierPath, fairwayWidth: CGFloat,
         bunkers: [(center: CGPoint, radius: CGFloat)],
         waterRects: [CGRect], treeMarginX: CGFloat, greenSlope: CGVector) {
        self.number = number
        self.par = par
        self.sceneSize = sceneSize
        self.tee = tee
        self.pin = pin
        self.greenRadius = greenRadius
        self.fringeWidth = fringeWidth
        self.fairwayCenterline = fairwayCenterline
        self.fairwayWidth = fairwayWidth
        self.bunkers = bunkers
        self.waterRects = waterRects
        self.treeMarginX = treeMarginX
        self.greenSlope = greenSlope
        self.fairwayPath = fairwayCenterline.cgPath.copy(
            strokingWithWidth: fairwayWidth,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 10
        )
    }

    func lie(at p: CGPoint) -> Lie {
        for rect in waterRects where pointInEllipse(p, rect) { return .water }
        let pinDist = p.distance(to: pin)
        if pinDist <= greenRadius { return .green }
        if pinDist <= greenRadius + fringeWidth { return .fringe }
        for b in bunkers where p.distance(to: b.center) <= b.radius { return .bunker }
        if fairwayPath.contains(p) { return .fairway }
        if p.x < treeMarginX || p.x > sceneSize.width - treeMarginX { return .trees }
        return .rough
    }

    func distanceToPinYards(from p: CGPoint) -> Double {
        Double(p.distance(to: pin) / Hole.pointsPerYard)
    }

    private func pointInEllipse(_ p: CGPoint, _ rect: CGRect) -> Bool {
        let rx = rect.width / 2, ry = rect.height / 2
        guard rx > 0, ry > 0 else { return false }
        let nx = (p.x - rect.midX) / rx
        let ny = (p.y - rect.midY) / ry
        return nx * nx + ny * ny <= 1
    }

    /// Hole 1 — "The Opener". Par 4, ~380 yards, gentle S-curve fairway,
    /// pond guarding the right side, three bunkers.
    static func one() -> Hole {
        let center = UIBezierPath()
        center.move(to: CGPoint(x: 300, y: 130))
        center.addCurve(
            to: CGPoint(x: 300, y: 760),
            controlPoint1: CGPoint(x: 240, y: 340),
            controlPoint2: CGPoint(x: 365, y: 560)
        )
        return Hole(
            number: 1,
            par: 4,
            sceneSize: CGSize(width: 600, height: 1000),
            tee: CGPoint(x: 300, y: 90),
            pin: CGPoint(x: 300, y: 850),
            greenRadius: 74,
            fringeWidth: 16,
            fairwayCenterline: center,
            fairwayWidth: 170,
            bunkers: [
                (CGPoint(x: 210, y: 780), 36),
                (CGPoint(x: 392, y: 812), 30),
                (CGPoint(x: 226, y: 470), 38)
            ],
            waterRects: [CGRect(x: 385, y: 470, width: 150, height: 190)],
            treeMarginX: 65,
            greenSlope: CGVector(dx: 5.5, dy: -1.7)
        )
    }
}
