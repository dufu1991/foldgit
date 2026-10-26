import CoreGraphics
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let assets = destination.appendingPathComponent("Assets", isDirectory: true)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

let number: (CGFloat) -> String = { String(format: "%.4f", Double($0)) }
let svgPath: (CGPath) -> String = { path in
    var commands: [String] = []
    path.applyWithBlock { pointer in
        let element = pointer.pointee
        let point: (Int) -> String = { index in
            "\(number(element.points[index].x)) \(number(element.points[index].y))"
        }
        switch element.type {
        case .moveToPoint: commands.append("M\(point(0))")
        case .addLineToPoint: commands.append("L\(point(0))")
        case .addQuadCurveToPoint: commands.append("Q\(point(0)) \(point(1))")
        case .addCurveToPoint: commands.append("C\(point(0)) \(point(1)) \(point(2))")
        case .closeSubpath: commands.append("Z")
        @unknown default: break
        }
    }
    return commands.joined(separator: " ")
}

let graph: (CGPoint, CGPoint, CGPoint, CGFloat, CGFloat) -> CGPath = { top, joint, tip, radius, width in
    let connector = CGMutablePath()
    connector.move(to: top)
    connector.addLine(to: joint)
    connector.addLine(to: tip)
    var result = connector.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 2)
    for node in [top, joint, tip] {
        result = result.union(CGPath(ellipseIn: CGRect(x: node.x - radius, y: node.y - radius,
                                                     width: radius * 2, height: radius * 2), transform: nil))
    }
    return result
}

let save: (String, String, String) throws -> Void = { filename, path, color in
    let colors: [String: (String, String)] = [
        "01-Pink-Repository.svg": ("#FF55B9", "#E52387"),
        "02-Orange-Repository.svg": ("#FFC35B", "#F78A28"),
        "03-Violet-Repository.svg": ("#9146FF", "#4324DD"),
        "04-Glass-Folder.svg": ("#FFFFFF", "#FFFFFF"),
    ]
    let stops = colors[filename]!
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
      <defs>
        <linearGradient id="color" x1="0" y1="0" x2="0.3" y2="1">
          <stop offset="0" stop-color="\(stops.0)"/>
          <stop offset="1" stop-color="\(stops.1)"/>
        </linearGradient>
      </defs>
      <path fill="url(#color)" fill-rule="evenodd" d="\(path)"/>
    </svg>
    """
    try svg.write(to: assets.appendingPathComponent(filename), atomically: true, encoding: .utf8)
}

let card: (String, CGRect, CGFloat, CGPoint, CGPoint, CGPoint, CGFloat, CGFloat, CGFloat, String) throws -> Void = {
    filename, bounds, corner, top, joint, tip, radius, width, angle, color in
    let panel = CGPath(roundedRect: bounds, cornerWidth: corner, cornerHeight: corner, transform: nil)
    let aperture = graph(top, joint, tip, radius, width)
    let perforated = panel.subtracting(aperture)
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    var transform = CGAffineTransform(translationX: center.x, y: center.y)
        .rotated(by: angle * .pi / 180)
        .translatedBy(x: -center.x, y: -center.y)
    let rotated = perforated.copy(using: &transform)!
    try save(filename, svgPath(rotated), color)
}

try card("01-Pink-Repository.svg", CGRect(x: 166, y: 307, width: 224, height: 450), 28,
         CGPoint(x: 228, y: 366), CGPoint(x: 228, y: 461), CGPoint(x: 286, y: 405), 18, 13, -3, "#F22C9A")
try card("02-Orange-Repository.svg", CGRect(x: 650, y: 307, width: 208, height: 450), 28,
         CGPoint(x: 710, y: 366), CGPoint(x: 710, y: 461), CGPoint(x: 768, y: 405), 18, 13, 3, "#F78A28")
try card("03-Violet-Repository.svg", CGRect(x: 365, y: 202, width: 294, height: 630), 30,
         CGPoint(x: 458, y: 318), CGPoint(x: 458, y: 478), CGPoint(x: 550, y: 380), 27, 18, 0, "#6B32E6")

let folder = CGMutablePath()
folder.move(to: CGPoint(x: 180, y: 480))
folder.addLine(to: CGPoint(x: 245, y: 480))
folder.addCurve(to: CGPoint(x: 350, y: 545), control1: CGPoint(x: 280, y: 480), control2: CGPoint(x: 302, y: 545))
folder.addLine(to: CGPoint(x: 674, y: 545))
folder.addCurve(to: CGPoint(x: 779, y: 480), control1: CGPoint(x: 722, y: 545), control2: CGPoint(x: 744, y: 480))
folder.addLine(to: CGPoint(x: 844, y: 480))
folder.addCurve(to: CGPoint(x: 900, y: 545), control1: CGPoint(x: 886, y: 480), control2: CGPoint(x: 907, y: 501))
folder.addLine(to: CGPoint(x: 874, y: 785))
folder.addCurve(to: CGPoint(x: 786, y: 864), control1: CGPoint(x: 868, y: 840), control2: CGPoint(x: 843, y: 864))
folder.addLine(to: CGPoint(x: 238, y: 864))
folder.addCurve(to: CGPoint(x: 150, y: 785), control1: CGPoint(x: 181, y: 864), control2: CGPoint(x: 156, y: 840))
folder.addLine(to: CGPoint(x: 124, y: 545))
folder.addCurve(to: CGPoint(x: 180, y: 480), control1: CGPoint(x: 117, y: 501), control2: CGPoint(x: 138, y: 480))
folder.closeSubpath()
try save("04-Glass-Folder.svg", svgPath(folder), "#FFFFFF")
let gridLines = [128, 320, 512, 704, 896].map { coordinate in
    "M\(coordinate) 0 V1024 M0 \(coordinate) H1024"
}.joined(separator: " ")
let grid = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="wash" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.08"/>
      <stop offset="1" stop-color="#3166DA" stop-opacity="0.10"/>
    </linearGradient>
  </defs>
  <path d="M0 0 H1024 V1024 H0 Z" fill="url(#wash)"/>
  <path d="\(gridLines)" fill="none" stroke="#FFFFFF" stroke-opacity="0.30" stroke-width="2.4"/>
</svg>
"""
try grid.write(to: assets.appendingPathComponent("00-Blueprint-Grid.svg"), atomically: true, encoding: .utf8)
print("Created five vector layers with three actual Git-shaped apertures.")
