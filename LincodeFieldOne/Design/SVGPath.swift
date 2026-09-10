import CoreGraphics
import Foundation

/// A very small SVG path-data parser.
///
/// The Lincode brand marks ship as SVG. Rather than rasterise them into the
/// asset catalogue at a handful of sizes, the app parses the original path data
/// once and draws it as a resolution-independent `CGPath`.
///
/// Supports the subset the brand files use: M/L/H/V/C/S/Q/T/A/Z, absolute and
/// relative. Unknown commands abort parsing and return what was built so far.
enum SVGPath {
    static func cgPath(from data: String, in viewBox: CGRect, fittingInto rect: CGRect) -> CGPath {
        let raw = parse(data)
        guard viewBox.width > 0, viewBox.height > 0 else { return raw }

        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let drawn = CGSize(width: viewBox.width * scale, height: viewBox.height * scale)
        var transform = CGAffineTransform.identity
            .translatedBy(
                x: rect.minX + (rect.width - drawn.width) / 2,
                y: rect.minY + (rect.height - drawn.height) / 2
            )
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -viewBox.minX, y: -viewBox.minY)

        return raw.copy(using: &transform) ?? raw
    }

    static func parse(_ data: String) -> CGPath {
        let path = CGMutablePath()
        var scanner = TokenScanner(data)
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastControl: CGPoint?
        var lastQuadControl: CGPoint?
        var command: Character?

        func point(_ x: CGFloat, _ y: CGFloat, relative: Bool) -> CGPoint {
            relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        while true {
            if let next = scanner.peekCommand() {
                command = next
                scanner.advanceCommand()
            } else if scanner.isAtEnd {
                break
            } else if command == nil {
                break
            } else if command == "M" {
                command = "L"       // implicit lineto after a moveto
            } else if command == "m" {
                command = "l"
            }

            guard let c = command else { break }
            let relative = c.isLowercase
            switch Character(c.uppercased()) {
            case "M":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = point(x, y, relative: relative)
                subpathStart = current
                path.move(to: current)
                lastControl = nil; lastQuadControl = nil
            case "L":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = point(x, y, relative: relative)
                path.addLine(to: current)
                lastControl = nil; lastQuadControl = nil
            case "H":
                guard let x = scanner.number() else { return path }
                current = relative ? CGPoint(x: current.x + x, y: current.y) : CGPoint(x: x, y: current.y)
                path.addLine(to: current)
                lastControl = nil; lastQuadControl = nil
            case "V":
                guard let y = scanner.number() else { return path }
                current = relative ? CGPoint(x: current.x, y: current.y + y) : CGPoint(x: current.x, y: y)
                path.addLine(to: current)
                lastControl = nil; lastQuadControl = nil
            case "C":
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                      let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let c1 = point(x1, y1, relative: relative)
                let c2 = point(x2, y2, relative: relative)
                current = point(x, y, relative: relative)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastControl = c2; lastQuadControl = nil
            case "S":
                guard let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let c1 = reflect(lastControl, around: current)
                let c2 = point(x2, y2, relative: relative)
                current = point(x, y, relative: relative)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastControl = c2; lastQuadControl = nil
            case "Q":
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let c = point(x1, y1, relative: relative)
                current = point(x, y, relative: relative)
                path.addQuadCurve(to: current, control: c)
                lastQuadControl = c; lastControl = nil
            case "T":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                let c = reflect(lastQuadControl, around: current)
                current = point(x, y, relative: relative)
                path.addQuadCurve(to: current, control: c)
                lastQuadControl = c; lastControl = nil
            case "A":
                guard let rx = scanner.number(), let ry = scanner.number(),
                      let rotation = scanner.number(), let largeArc = scanner.flag(),
                      let sweep = scanner.flag(), let x = scanner.number(),
                      let y = scanner.number() else { return path }
                let end = point(x, y, relative: relative)
                addArc(
                    to: path, from: current, to: end,
                    rx: rx, ry: ry, rotationDegrees: rotation,
                    largeArc: largeArc, sweep: sweep
                )
                current = end
                lastControl = nil; lastQuadControl = nil
            case "Z":
                path.closeSubpath()
                current = subpathStart
                lastControl = nil; lastQuadControl = nil
                // A bare closepath consumes no numbers; clearing the sticky
                // command stops the parser looping on trailing data.
                command = nil
            default:
                return path
            }

            if scanner.isAtEnd { break }
        }
        return path
    }

    private static func reflect(_ control: CGPoint?, around point: CGPoint) -> CGPoint {
        guard let control else { return point }
        return CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
    }

    /// Endpoint-to-centre arc conversion, per the SVG implementation notes.
    private static func addArc(
        to path: CGMutablePath,
        from start: CGPoint,
        to end: CGPoint,
        rx rxIn: CGFloat,
        ry ryIn: CGFloat,
        rotationDegrees: CGFloat,
        largeArc: Bool,
        sweep: Bool
    ) {
        var rx = abs(rxIn), ry = abs(ryIn)
        guard rx > 0, ry > 0, start != end else {
            path.addLine(to: end)
            return
        }

        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx2 = (start.x - end.x) / 2, dy2 = (start.y - end.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let scale = sqrt(lambda)
            rx *= scale
            ry *= scale
        }

        let numerator = max(0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coefficient = denominator > 0 ? sqrt(numerator / denominator) : 0
        if largeArc == sweep { coefficient = -coefficient }

        let cxp = coefficient * rx * y1p / ry
        let cyp = -coefficient * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            guard len > 0 else { return 0 }
            var a = acos(min(1, max(-1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }

        let startAngle = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let transform = CGAffineTransform(translationX: cx, y: cy)
            .rotated(by: phi)
            .scaledBy(x: rx, y: ry)
        path.addArc(
            center: .zero, radius: 1,
            startAngle: startAngle, endAngle: startAngle + delta,
            clockwise: delta < 0,
            transform: transform
        )
    }
}

private struct TokenScanner {
    private let characters: [Character]
    private var index: Int = 0

    init(_ string: String) {
        characters = Array(string)
    }

    var isAtEnd: Bool {
        var i = index
        while i < characters.count, characters[i].isSVGSeparator { i += 1 }
        return i >= characters.count
    }

    mutating func peekCommand() -> Character? {
        skipSeparators()
        guard index < characters.count else { return nil }
        let c = characters[index]
        return c.isLetter ? c : nil
    }

    mutating func advanceCommand() {
        index += 1
    }

    mutating func flag() -> Bool? {
        skipSeparators()
        guard index < characters.count else { return nil }
        let c = characters[index]
        guard c == "0" || c == "1" else { return number().map { $0 != 0 } }
        index += 1
        return c == "1"
    }

    mutating func number() -> CGFloat? {
        skipSeparators()
        let start = index
        if index < characters.count, characters[index] == "+" || characters[index] == "-" { index += 1 }
        var sawDigit = false
        while index < characters.count, characters[index].isNumber { index += 1; sawDigit = true }
        if index < characters.count, characters[index] == "." {
            index += 1
            while index < characters.count, characters[index].isNumber { index += 1; sawDigit = true }
        }
        guard sawDigit else { index = start; return nil }
        if index < characters.count, characters[index] == "e" || characters[index] == "E" {
            let save = index
            index += 1
            if index < characters.count, characters[index] == "+" || characters[index] == "-" { index += 1 }
            var sawExponent = false
            while index < characters.count, characters[index].isNumber { index += 1; sawExponent = true }
            if !sawExponent { index = save }
        }
        let text = String(characters[start..<index])
        return Double(text).map { CGFloat($0) }
    }

    private mutating func skipSeparators() {
        while index < characters.count, characters[index].isSVGSeparator { index += 1 }
    }
}

private extension Character {
    var isSVGSeparator: Bool {
        self == " " || self == "," || self == "\n" || self == "\r" || self == "\t"
    }
}
