import CoreGraphics
import Foundation
// Writes SF Symbol templates for bulge.out / bulge.in into argv[1].
let baseline = 1126.0, capline = 1055.54, cap = baseline - capline
let mid = (baseline + capline) / 2
let rise = 0.62 * cap, width = rise * 20 / 7, thickness = 0.165 * cap, x0 = 1500.0
func curve(_ out: Bool) -> CGPath {
  let f = width / 20
  func p(_ x: Double, _ y: Double) -> CGPoint {
    let dy = (y - 12) * f
    return CGPoint(x: x0 + (x - 2) * f, y: mid + (out ? dy : -dy))
  }
  let path = CGMutablePath()
  path.move(to: p(2, 15.5))
  path.addLine(to: p(4.5, 15.5))
  path.addCurve(to: p(12, 8.5), control1: p(8.1, 15.5), control2: p(7.8, 8.5))
  path.addCurve(to: p(19.5, 15.5), control1: p(16.2, 8.5), control2: p(15.9, 15.5))
  path.addLine(to: p(22, 15.5))
  return path.copy(strokingWithWidth: thickness, lineCap: .round, lineJoin: .round, miterLimit: 10)
}
func d(_ path: CGPath) -> String {
  var s = ""
  func n(_ v: CGFloat) -> String { String(format: "%.3f", Double(v)) }
  path.applyWithBlock { e in
    let pts = e.pointee.points
    switch e.pointee.type {
    case .moveToPoint: s += "M\(n(pts[0].x)) \(n(pts[0].y))"
    case .addLineToPoint: s += "L\(n(pts[0].x)) \(n(pts[0].y))"
    case .addQuadCurveToPoint: s += "Q\(n(pts[0].x)) \(n(pts[0].y)) \(n(pts[1].x)) \(n(pts[1].y))"
    case .addCurveToPoint: s += "C\(n(pts[0].x)) \(n(pts[0].y)) \(n(pts[1].x)) \(n(pts[1].y)) \(n(pts[2].x)) \(n(pts[2].y))"
    case .closeSubpath: s += "Z"
    @unknown default: break
    }
  }
  return s
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
for out in [true, false] {
  let name = out ? "bulge.out" : "bulge.in"
  let path = curve(out), box = path.boundingBoxOfPath
  let guide = "style=\"fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;\""
  let margin = "style=\"fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;\""
  let svg = """
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
  <!-- Sculpting's stroke direction: the surface \(out ? "bulging out" : "pressed in"). Written by release/ios/symbols/generate_symbols.swift. -->
  <svg version="1.1" xmlns="http://www.w3.org/2000/svg" width="3300" height="2200">
   <g id="Notes">
    <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;" transform="matrix(1 0 0 1 263 322)">\(name)</text>
    <text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;" transform="matrix(1 0 0 1 3036 1933)">Template v.3.0</text>
   </g>
   <g id="Guides">
    <line id="Baseline-S" \(guide) x1="263" x2="3036" y1="696" y2="696"/>
    <line id="Capline-S" \(guide) x1="263" x2="3036" y1="625.541" y2="625.541"/>
    <line id="Baseline-M" \(guide) x1="263" x2="3036" y1="1126" y2="1126"/>
    <line id="Capline-M" \(guide) x1="263" x2="3036" y1="1055.54" y2="1055.54"/>
    <line id="Baseline-L" \(guide) x1="263" x2="3036" y1="1556" y2="1556"/>
    <line id="Capline-L" \(guide) x1="263" x2="3036" y1="1485.54" y2="1485.54"/>
    <line id="left-margin-Regular-M" \(margin) x1="\(String(format: "%.3f", box.minX - 3))" x2="\(String(format: "%.3f", box.minX - 3))" y1="1030.79" y2="1150.12"/>
    <line id="right-margin-Regular-M" \(margin) x1="\(String(format: "%.3f", box.maxX + 3))" x2="\(String(format: "%.3f", box.maxX + 3))" y1="1030.79" y2="1150.12"/>
   </g>
   <g id="Symbols">
    <g id="Regular-M">
     <path d="\(d(path))"/>
    </g>
   </g>
  </svg>

  """
  let set = dir.appendingPathComponent("\(name).symbolset")
  try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
  try! svg.write(to: set.appendingPathComponent("\(name).svg"), atomically: true, encoding: .utf8)
  let contents = """
  {
    "info" : {
      "author" : "Blender",
      "version" : 1
    },
    "symbols" : [
      {
        "filename" : "\(name).svg",
        "idiom" : "universal"
      }
    ]
  }

  """
  try! contents.write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}
