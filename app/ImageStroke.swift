import CoreGraphics

struct ImageStroke {
    static let widths = 1...30
    static let defaultWidth = 5

    var points: [CGPoint]
    let width: Int

    func draw(in context: CGContext) {
        guard let start = points.first else { return }
        let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let diameter = CGFloat(width)
        context.saveGState()
        defer { context.restoreGState() }
        context.setShouldAntialias(true)

        guard points.count > 1 else {
            context.setFillColor(red)
            context.fillEllipse(in: CGRect(
                x: start.x - diameter / 2, y: start.y - diameter / 2,
                width: diameter, height: diameter
            ))
            return
        }

        context.setStrokeColor(red)
        context.setLineWidth(diameter)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.beginPath()
        context.move(to: start)
        for index in 1..<(points.count - 1) {
            let point = points[index]
            let next = points[index + 1]
            let midpoint = CGPoint(x: (point.x + next.x) / 2, y: (point.y + next.y) / 2)
            context.addQuadCurve(to: midpoint, control: point)
        }
        context.addLine(to: points[points.count - 1])
        context.strokePath()
    }
}
