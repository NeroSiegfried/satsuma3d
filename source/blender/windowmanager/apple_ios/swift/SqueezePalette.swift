/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The palette a squeeze of Apple Pencil Pro opens by the Pencil: the tools, and in modes that
 * paint with them the brushes, their size and strength, which way they stroke and their color,
 * Blender's commands for what is selected, and undo and redo.
 *
 * Everything in it turns with the Pencil's barrel roll. Rolling turns the part of the palette the
 * Pencil hovers: the brushes or tools click from one to the next, sliders slide, the color goes
 * around the hues, and over undo and redo, rolling steps back and forth through the history.
 * Away from the palette, rolling turns the brushes, or the tools where there are none. A tap does
 * the same for a Pencil that can't roll, or a finger.
 *
 * Drawing anywhere else closes it, and the stroke draws; squeezing again closes it too.
 */

#if !os(visionOS) /* No Apple Pencil on Apple Vision Pro. */

import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/** What squeezing Apple Pencil Pro shows, see the iPad page of Settings: this palette, or
 * Blender's context menu around the Pencil. GHOST reads it too. */
enum PencilSqueeze {
  static let key = "BlenderPencilSqueeze"
  static var showsPalette: Bool { UserDefaults.standard.string(forKey: key) != "menu" }
}

/* -------------------------------------------------------------------- */
/** \name State
 * \{ */

@MainActor
@Observable
final class SqueezePalette {
  static let shared = SqueezePalette()

  /** The parts the Pencil's roll turns. */
  enum Part: Hashable {
    case history, tools, brushes, size, strength, weight, direction, color, commands
  }

  /** The slider a part is, by its brush value's key. */
  static func part(_ key: String) -> Part {
    switch key {
      case "size": .size
      case "weight": .weight
      default: .strength
    }
  }

  enum Page: Hashable {
    /** The tools, the brushes and the brush's settings. */
    case main
    /** Blender's commands for what is selected, in place of the brush's settings. */
    case commands
  }

  /** What sits at an end of the tools' and brushes' arc: undo and redo, and the commands. */
  enum Accessory: Hashable {
    case undo, redo, more
  }

  /** The tools' or the brushes' stretch of their arc: grown to turn through many, or shrunk to
   * the one in use. The tools always come first, the brushes after them. */
  struct Section: Hashable {
    var part: Part
    var start: Double
    var end: Double
    var collapsed: Bool
    /** From one to the next, a little more than the arc's own so whole places fill the section. */
    var step: Double = 0

    var middle: Double { (start + end) / 2 }
  }

  /** One of the places on the commands' arc: undo and redo, Blender's context menu's commands
   * for what is selected, Back out of a submenu, or the full menu where they do not all fit. */
  enum CommandEntry: Equatable {
    case undo, redo, back
    /** The full menu at \a route, for those that did not fit. */
    case menu(String)
    case item(BlenderMenuItem)
    /** Commands that go together, such as Duplicate and Duplicate Linked, in one place. */
    case group(CommandGroup)
    /** A quick action, where the context menu has only the mode's settings, as painting does. */
    case action(QuickAction)
  }

  /** Commands of one kind side by side in one place, each by the words that tell it apart:
   * "Duplicate | Linked", "Shade Smooth | Auto Smooth | Flat". */
  struct CommandGroup: Equatable {
    var items: [BlenderMenuItem]
    var labels: [String]
  }

  /** Icons more than one of the menu's commands have, such as an edge's for its seams and sharp
   * edges, which do not tell them apart: those show their titles. */
  static var sharedIcons = Set<String>()

  /** A command with an icon of its own is that icon alone, as Copy and Paste are. */
  static func iconOnly(_ item: BlenderMenuItem) -> UIImage? {
    if item.destructive { return UIImage(systemName: "trash") }
    guard !item.submenu, !["", "NONE", "BLANK1"].contains(item.icon), !sharedIcons.contains(item.icon) else { return nil }
    return BlenderIcon.image(item.icon)
  }

  /** A stretch of an arc, holding one part. */
  struct Piece: Hashable {
    var part: Part
    var start: Double
    var end: Double
  }

  /** One of the arcs around the tip, nearest first: the tools, the brushes, then the brush's
   * settings or the commands. All run between the same angles, their ends rounded. */
  struct Ring: Identifiable {
    /** The tools' and brushes' arcs, and the settings' and commands'. */
    static let wide: CGFloat = 56
    static let narrow: CGFloat = 44
    static let gap: CGFloat = 6

    var id: Int
    var radius: CGFloat
    var thickness: CGFloat
    var start: Double
    var end: Double
    /** The tools and brushes along it. */
    var sections: [Section] = []
    /** Commands in equal places along it. */
    var commands: [CommandEntry] = []

    var middleAngle: Double { (start + end) / 2 }
    var leading: [Accessory] = []
    var trailing: [Accessory] = []
    var pieces: [Piece] = []

    /** From one tool or brush to the next along it, in radians. */
    var step: Double { Double(thickness - 2) / Double(radius) }

    func angle(_ accessory: Accessory) -> Double {
      if trailing.isEmpty, sections.isEmpty, pieces.isEmpty, let index = leading.firstIndex(of: accessory) {
        /* Alone on their arc: spread along it. */
        return start + (end - start) * (Double(index) + 0.5) / Double(leading.count)
      }
      if let index = leading.firstIndex(of: accessory) { return start + Double(index) * step }
      let index = trailing.firstIndex(of: accessory) ?? 0
      return end - Double(trailing.count - 1 - index) * step
    }

    /** Between what is at its ends, where the tools and brushes go. */
    var middle: ClosedRange<Double> {
      let low = start + (leading.isEmpty ? 0 : (Double(leading.count) - 0.4) * step)
      let high = end - (trailing.isEmpty ? 0 : (Double(trailing.count) - 0.4) * step)
      return low...max(low, high)
    }

    enum Hit: Equatable {
      case accessory(Accessory)
      case part(Part)
    }

    func hit(_ point: CGPoint, around arc: Arc) -> Hit? {
      let dx = Double(point.x - arc.center.x), dy = Double(point.y - arc.center.y)
      guard abs(CGFloat(hypot(dx, dy)) - radius) <= thickness / 2 + Self.gap / 2 else { return nil }
      let angle = middleAngle + SqueezePalette.wrapped(atan2(dy, dx) - middleAngle)
      let cap = Double(thickness / 2) / Double(radius)
      guard angle >= start - cap, angle <= end + cap else { return nil }
      if !commands.isEmpty { return .part(.commands) }
      if let accessory = (leading + trailing).first(where: { abs(self.angle($0) - angle) < step / 2 }) {
        return .accessory(accessory)
      }
      if let section = sections.first(where: { angle >= $0.start && angle <= $0.end }) { return .part(section.part) }
      return pieces.first { angle >= $0.start - cap && angle <= $0.end + cap }.map { .part($0.part) }
    }
  }

  /** Where the arcs are: around the Pencil's tip, facing away from it. In the window. */
  struct Arc {
    /** The arcs run this far each side of where they face. */
    static let half = 1.42
    /** The nearest arc's middle, from the tip. */
    static let inner: CGFloat = 122

    var center: CGPoint
    /** Where the middle of the arcs faces, from the center. */
    var facing: Double

    var start: Double { facing - Self.half }
    var end: Double { facing + Self.half }

    func point(_ angle: Double, radius: CGFloat) -> CGPoint {
      CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
    }

    /** The bounds of the arcs out to \a outer, their rounded ends too. */
    func bounds(outer: CGFloat) -> CGRect {
      let half = Ring.wide / 2
      var rect = CGRect.null
      for i in 0...24 {
        let a = start + (end - start) * Double(i) / 24
        for radius in [Self.inner, outer - half] {
          let p = point(a, radius: radius)
          rect = rect.union(CGRect(x: p.x, y: p.y, width: 0, height: 0).insetBy(dx: -half, dy: -half))
        }
      }
      return rect
    }
  }

  struct Direction: Equatable {
    var inverted: Bool
    var add: String
    var subtract: String
    var addSymbol = "plus"
    var subtractSymbol = "minus"
  }

  /* Blender's state, from the rails. */

  /** Every tool, those of each group too. */
  private(set) var tools: [RailItem] = []
  private(set) var activeTool = ""
  private(set) var brushes: [RailItem] = []
  private(set) var activeBrush = ""
  /** The brush's size, strength and color, where Blender paints with brushes. */
  var brush: JSON?
  private(set) var direction: Direction?
  private(set) var canUndo = false
  private(set) var canRedo = false
  @ObservationIgnored var chooseTool: ((RailItem) -> Void)?
  @ObservationIgnored var chooseBrush: ((RailItem) -> Void)?
  @ObservationIgnored var setDirection: ((Bool) -> Void)?
  @ObservationIgnored var showSettings: (() -> Void)?
  /** Blender's window, for commands to start where the Pencil is. */
  @ObservationIgnored var blenderWindow: UnsafeMutableRawPointer?

  /** The quick actions for what is selected, and how one runs. */
  var actions: [QuickAction] = []
  @ObservationIgnored var runAction: ((QuickAction) -> Void)?

  /* Showing. */

  /** Where the Pencil was squeezed, in the window, while open. */
  private(set) var tip: CGPoint?
  /** Grown out of the Pencil's tip. */
  private(set) var shown = false
  /** Where the arcs are, around where the Pencil was squeezed. */
  private(set) var arc: Arc?
  /** Which way the Pencil's barrel leaned as it was squeezed. */
  @ObservationIgnored private var lean: Double?
  var page = Page.main {
    didSet { if page != oldValue { pageChanged() } }
  }
  @ObservationIgnored private(set) weak var window: UIWindow?
  @ObservationIgnored private var input: PaletteInput?
  @ObservationIgnored private var generation = 0

  var isOpen: Bool { tip != nil }

  /* The Pencil. */

  /** What rolling turns now, while the Pencil hovers or touches. */
  private(set) var target: Part?
  @ObservationIgnored private var hoverRoll: Double?
  /** Where something was just tapped: the roll turns nothing until the Pencil moves well away or
   * lifts, so a choice is not rolled off again by the hand that made it. */
  @ObservationIgnored private var rollLock: CGPoint?
  @ObservationIgnored private var touchRoll: Double?
  @ObservationIgnored private var lastPoint: CGPoint?

  /* Turning. */

  /** Where each strip has turned to, in items: between two while it turns. */
  private(set) var toolPosition: Double = 0
  private(set) var brushPosition: Double = 0
  /** A finger or the Pencil drags a strip: it follows at once, without springing. */
  private(set) var scrubbing: Part?
  /** Size and strength set here, shown until Blender has them. */
  private(set) var values: [String: Double] = [:]
  /** The color wheel, open where the arcs center. */
  var colorWheel = false
  /** The color wheel's disc, and the brightness ring around it. */
  static let wheelRadius: CGFloat = 70
  static let wheelRing: CGFloat = 12

  /** The size or strength being changed, shown as the brush where the arcs center. */
  var previewing: String?
  @ObservationIgnored private var previewGeneration = 0
  private(set) var localColor: [Double]?
  /** What each part does once it stops turning. */
  @ObservationIgnored private var settling: [Part: (task: Task<Void, Never>, action: @MainActor () -> Void)] = [:]
  @ObservationIgnored private var lastSent = Date.distantPast

  /* Commands. */

  /** The menus opened, the context menu first. */
  private(set) var commandPath: [(route: String, title: String)] = []
  private(set) var commandIndex: Double?
  var commandRoute: String { commandPath.last?.route ?? BlenderMenus.contextRoute }
  var commandTitle: String { commandPath.last?.title ?? "Commands" }

  /** The roll from one item to the next, as the rails' dial has it. */
  static let step = Double.pi / 9

  @ObservationIgnored private var squeezeObserver: NSObjectProtocol?

  private init() {
    squeezeObserver = NotificationCenter.default.addObserver(forName: Notification.Name("BlenderPencilSqueeze"), object: nil,
                                           queue: .main) { note in
      let info = note.userInfo
      let point = (info?["x"] as? Double).flatMap { x in
        (info?["y"] as? Double).map { CGPoint(x: x, y: $0) }
      }
      let roll = info?["roll"] as? Double
      /* Leaning well over, the Pencil's barrel points somewhere: the arcs open away from it. */
      let lean = (info?["azimuth"] as? Double).flatMap { azimuth in
        ((info?["altitude"] as? Double) ?? .pi / 2) < 1.2 ? azimuth : nil
      }
      let window = note.object as? UIWindow
      MainActor.assumeIsolated { SqueezePalette.shared.squeezed(at: point, roll: roll, lean: lean, in: window) }
    }
  }

  /** Started early, so the first squeeze is seen. */
  static func start() { _ = shared }

  /* -------------------------------------------------------------------- */
  /* Blender */

  func update(tools rail: [RailItem], activeTool: String, brushes: [RailItem], activeBrush: String,
              direction: Direction?, canUndo: Bool, canRedo: Bool)
  {
    let tools = Self.flatten(rail)
    if !Self.same(tools, self.tools) {
      self.tools = tools
      follow(.tools)
    }
    if !Self.same(brushes, self.brushes) {
      self.brushes = brushes
      follow(.brushes)
    }
    if activeTool != self.activeTool {
      self.activeTool = activeTool
      follow(.tools)
    }
    if activeBrush != self.activeBrush {
      self.activeBrush = activeBrush
      follow(.brushes)
    }
    if direction != self.direction { self.direction = direction }
    if canUndo != self.canUndo { self.canUndo = canUndo }
    if canRedo != self.canRedo { self.canRedo = canRedo }
  }

  /** The same items, with the same images: brushes' previews arrive after their names. */
  private static func same(_ a: [RailItem], _ b: [RailItem]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.id == $1.id && $0.image === $1.image }
  }

  /** The tools of each group beside each other, the group's gap before its first. */
  private static func flatten(_ rail: [RailItem]) -> [RailItem] {
    var seen = Set<String>()
    var result: [RailItem] = []
    for item in rail {
      let members = item.grouped ? item.group : [item]
      for (index, member) in members.enumerated() where seen.insert(member.id).inserted {
        result.append(RailItem(id: member.id, title: member.title, image: member.image,
                               selectedImage: member.selectedImage, gapBefore: index == 0 && item.gapBefore,
                               group: [], groupBreaks: [], detail: member.detail))
      }
    }
    return result
  }

  /** Whichever of the tools and brushes is grown on their arc; the tools where there are no
   * brushes. What rolling away from the arcs turns. */
  var band: Part { brushes.isEmpty ? .tools : expanded }
  /** Which of the two is grown, where there are brushes. */
  var expanded = Part.brushes

  var primary: Part { page == .commands ? .commands : band }

  /* -------------------------------------------------------------------- */
  /* Opening and closing */

  private func squeezed(at point: CGPoint?, roll: Double?, lean: Double? = nil, in window: UIWindow?) {
    guard PencilSqueeze.showsPalette else { return }
    if isOpen && (window == nil || window === self.window) {
      /* Squeezing on a command rolled to runs it. */
      if commandRolled, let item = highlightedCommand {
        activate(item)
        return
      }
      close()
      return
    }
    guard let window, window.rootViewController?.presentedViewController == nil else { return }
    let fallback = lastPoint.flatMap { window.bounds.contains($0) ? $0 : nil } ??
      CGPoint(x: window.bounds.midX, y: window.bounds.midY)
    open(at: point ?? fallback, roll: roll, lean: lean, in: window)
  }

  private func open(at point: CGPoint, roll: Double?, lean: Double?, in window: UIWindow) {
    generation += 1
    self.window = window
    page = .main
    commandPath = []
    commandIndex = nil
    commandRolled = false
    commandPage = 0
    values = [:]
    localColor = nil
    scrubbing = nil
    rollGathered = nil
    Self.sharedIcons = []
    hoverRoll = roll
    touchRoll = nil
    rollLock = nil
    colorWheel = false
    toolPosition = Double(tools.firstIndex { $0.id == activeTool } ?? 0)
    brushPosition = Double(brushes.firstIndex { $0.id == activeBrush } ?? 0)
    expanded = .brushes
    self.lean = lean
    let arc = Self.arc(around: point, in: window, outer: outer, lean: lean)
    var instant = Transaction()
    instant.disablesAnimations = true
    withTransaction(instant) {
      shown = false
      self.arc = arc
      tip = point
      /* Lit only once the Pencil hovers something. */
      target = nil
    }
    input = PaletteInput(window: window)
    Haptics.impact(.light)
    RollDial.shared.pencilTick(at: point)
    /* Ready for when the commands are opened. */
    Task { _ = await BlenderMenus.shared.fetch(BlenderMenus.contextRoute) }
    DispatchQueue.main.async {
      withAnimation(Self.motion(.spring(response: 0.36, dampingFraction: 0.78))) { self.shown = true }
    }
  }

  func close() {
    guard isOpen else { return }
    flushSettling()
    input?.remove()
    input = nil
    generation += 1
    let current = generation
    withAnimation(Self.motion(.spring(response: 0.26, dampingFraction: 0.92))) { shown = false }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
      guard self.generation == current else { return }
      self.tip = nil
      self.arc = nil
      self.target = nil
      self.page = .main
    }
  }

  /** Around the tip, facing up, or down from near the top, leaning towards the middle of the
   * window, and moved in only as far as it must to fit. */
  private static func arc(around tip: CGPoint, in window: UIWindow, outer: CGFloat, lean azimuth: Double?) -> Arc {
    let safe = window.bounds.inset(by: window.safeAreaInsets).insetBy(dx: 12, dy: 12)
    let up = tip.y > safe.minY + safe.height * 0.38
    let lean = Double(min(1, max(-1, (safe.midX - tip.x) / max(1, safe.width / 2)))) * 0.5
    /* Away from the Pencil's barrel, which would cover them; held upright, up, or down from near
     * the top, leaning towards the middle of the window. */
    let facing = azimuth.map { SqueezePalette.wrapped($0 + .pi) } ?? (up ? -.pi / 2 + lean : .pi / 2 - lean)
    var arc = Arc(center: tip, facing: facing)
    let bounds = arc.bounds(outer: outer)
    var shift = CGPoint.zero
    if bounds.minX < safe.minX { shift.x = safe.minX - bounds.minX }
    if bounds.maxX > safe.maxX { shift.x = safe.maxX - bounds.maxX }
    if bounds.minY < safe.minY { shift.y = safe.minY - bounds.minY }
    if bounds.maxY > safe.maxY { shift.y = safe.maxY - bounds.maxY }
    arc.center = CGPoint(x: tip.x + shift.x, y: tip.y + shift.y)
    return arc
  }

  static func motion(_ animation: Animation) -> Animation? {
    UIAccessibility.isReduceMotionEnabled ? nil : animation
  }

  private func pageChanged() {
    commandIndex = page == .commands ? 0 : nil
    guard isOpen, let tip, let window else { return }
    target = nil
    if page == .commands { Task { _ = await BlenderMenus.shared.fetch(commandRoute) } }
    /* Moved in, if the rings coming out would leave the window, back again as they go. */
    let moved = Self.arc(around: tip, in: window, outer: outer, lean: lean)
    if let arc, moved.center != arc.center || moved.facing != arc.facing {
      withAnimation(Self.motion(.spring(response: 0.34, dampingFraction: 0.86))) { self.arc = moved }
    }
  }

  /** How far out the arcs reach, which does not depend on where they face. */
  private var outer: CGFloat {
    let rings = rings(for: Arc(center: .zero, facing: -.pi / 2))
    return rings.map { $0.radius + $0.thickness / 2 }.max() ?? Arc.inner + Ring.wide / 2
  }

  var rings: [Ring] { arc.map { rings(for: $0) } ?? [] }

  /** The arcs, nearest first: the tools or brushes, with undo and redo and the other of the two
   * at its start and the commands at its end; then the brush's settings on one arc, or the
   * commands in their place. */
  private func rings(for arc: Arc) -> [Ring] {
    var result: [Ring] = []
    var radius: CGFloat = 0
    /* Every arc the whole sweep; what it holds spaced out to fill it. */
    func add(_ thickness: CGFloat, length points: CGFloat, _ make: (inout Ring) -> Void) {
      /* With brushes, further out, for the room their settings and the brushes take. */
      radius = result.last.map { radius + $0.thickness / 2 + Ring.gap + thickness / 2 } ??
        (brush != nil ? Arc.inner + 26 : Arc.inner - 10)
      var ring = Ring(id: result.count, radius: radius, thickness: thickness, start: arc.start, end: arc.end)
      make(&ring)
      result.append(ring)
    }
    /* Nearest, the brush's settings, each as long as it needs: the sliders the most, the color by
     * how many colors it holds. */
    var parts: [(part: Part, share: Double)] = []
    if brush?.dict("size") != nil { parts.append((.size, 140)) }
    if brush?.dict("strength") != nil { parts.append((.strength, 140)) }
    if brush?.dict("weight") != nil { parts.append((.weight, 140)) }
    if direction != nil { parts.append((.direction, 96)) }
    if color != nil { parts.append((.color, 40 + 36 * Double(min(5, recentColors.count)))) }
    let commands = !contextCommands(BlenderMenus.contextRoute).isEmpty
    if brush != nil, !parts.isEmpty {
      let accessories = CGFloat((commands ? 2 : 1) + (canRedo ? 1 : 0)) * (Ring.narrow - 2)
      let length = accessories + CGFloat(parts.reduce(0) { $0 + $1.share }) + CGFloat(parts.count - 1) * (Ring.narrow + 6)
      add(Ring.narrow, length: length) { ring in
        /* Undo and redo at its start, the commands' button at its end, leaving the brushes their
         * arc. */
        /* Redo only once there is something to redo. */
        ring.leading = canRedo ? [.undo, .redo] : [.undo]
        ring.trailing = commands ? [.more] : []
        let middle = ring.middle
        let gap = Double(Ring.narrow + 6) / Double(ring.radius)
        let room = (middle.upperBound - middle.lowerBound) - gap * Double(parts.count - 1)
        let total = parts.reduce(0) { $0 + $1.share }
        var angle = middle.lowerBound
        for entry in parts {
          let length = room * entry.share / total
          ring.pieces.append(Piece(part: entry.part, start: angle, end: angle + length))
          angle += length + gap
        }
      }
    }
    /* Then the tools and brushes, with the room to show many. */
    let shown = brushes.isEmpty ? tools.count : (expanded == .tools ? tools.count : brushes.count) + 1
    add(Ring.wide, length: CGFloat(Double(shown) + (brushes.isEmpty ? 0 : 0.3)) * (Ring.wide - 2)) { ring in
      let start = ring.middle.lowerBound, end = ring.middle.upperBound
      defer {
        for index in ring.sections.indices {
          let length = ring.sections[index].end - ring.sections[index].start
          let places = max(1, (length / ring.step).rounded(.down))
          ring.sections[index].step = length / places
        }
      }
      if brushes.isEmpty {
        ring.sections = [Section(part: .tools, start: start, end: end, collapsed: false)]
      }
      else {
        /* The shrunk one takes a place, the grown one the rest. */
        let one = ring.step * 1.1, gap = ring.step * 0.2
        let tools = expanded == .tools
        let split = tools ? end - one - gap : start + one
        ring.sections = [
          Section(part: .tools, start: start, end: split, collapsed: !tools),
          Section(part: .brushes, start: split + gap, end: end, collapsed: tools),
        ]
      }
    }
    /* Then the commands for what is selected, with undo and redo, without brush settings, or
     * once asked for. */
    if page == .commands || brush == nil {
      for row in commandRows(arc: arc, from: radius + Ring.wide / 2 + Ring.gap + Ring.narrow / 2) {
        add(Ring.narrow, length: .infinity) { $0.commands = row }
      }
    }
    return result
  }

  /** Undo and redo, then the context menu's commands for what is selected, along up to two arcs
   * from \a first outwards, each as long as its title. An arc takes them in order and fills what
   * room is left with the next that fit; where they do not all fit, the full menu is last. With
   * the brush's settings, undo and redo are there instead. */
  private func commandRows(arc: Arc, from first: CGFloat) -> [[CommandEntry]] {
    let history: [CommandEntry] = canRedo ? [.undo, .redo] : [.undo]
    var rows: [[CommandEntry]] = []
    var radius = first
    /* Packs \a pending along up to \a arcs arcs, the full menu at \a route last where they do not
     * all fit. */
    func pack(_ pending: [CommandEntry], arcs: Int, route: String) {
      var pending = pending
      for row in 0..<arcs {
        var room = CGFloat(arc.end - arc.start) * radius + Ring.narrow - 8
        let last = row == arcs - 1
        var line: [CommandEntry] = []
        var rest: [CommandEntry] = []
        for entry in pending {
          let width = Self.commandWidth(entry) + Self.commandGap
          if width <= room { line.append(entry); room -= width } else { rest.append(entry) }
        }
        if last && !rest.isEmpty {
          /* The full menu in the last place, giving up what it must for the room. */
          let menu = Self.commandWidth(.menu(route)) + Self.commandGap
          while room < menu, let dropped = line.popLast() {
            room += Self.commandWidth(dropped) + Self.commandGap
          }
          line.append(.menu(route))
        }
        if !line.isEmpty {
          rows.append(line)
          radius += Ring.narrow + Ring.gap
        }
        pending = rest
        if pending.isEmpty { break }
      }
    }
    /* The context menu's, then each submenu opened from it on an arc of its own, further out. */
    pack((brush == nil ? history : []) + contextCommands(BlenderMenus.contextRoute), arcs: 2,
         route: BlenderMenus.contextRoute)
    for level in commandPath {
      pack(contextCommands(level.route), arcs: 1, route: level.route)
    }
    return rows
  }

  /** A submenu opened on an arc further out, whose title then shows lit where it was tapped. */
  func isOpen(_ item: BlenderMenuItem) -> Bool { commandPath.contains { $0.route == item.route } }

  /** The context menu's commands for what is selected; where it has only the mode's settings, as
   * painting's does, the mode's quick actions instead. */
  func contextCommands(_ route: String) -> [CommandEntry] {
    let items = (BlenderMenus.shared.items[route] ?? []).filter { !$0.disabled || $0.submenu }
    var counts: [String: Int] = [:]
    for item in items { counts[item.icon, default: 0] += 1 }
    Self.sharedIcons.formUnion(counts.filter { $0.value > 1 }.map(\.key))
    if items.contains(where: { !$0.route.contains("\"panel\"") }) || route != BlenderMenus.contextRoute {
      /* Those that are icons alone together first, as Copy and Paste belong side by side. */
      let entries = Self.grouped(items)
      let icon = { (entry: CommandEntry) -> Bool in
        if case .item(let item) = entry { return Self.iconOnly(item) != nil }
        return false
      }
      return entries.filter(icon) + entries.filter { !icon($0) }
    }
    return actions.map { .action($0) }
  }

  /** Commands whose titles begin with the same word, as one place where the first of them is:
   * every kind of Extrude together, every kind of Subdivide, Duplicate and Duplicate Linked. */
  static func grouped(_ items: [BlenderMenuItem]) -> [CommandEntry] {
    let first = { (item: BlenderMenuItem) -> String? in
      iconOnly(item) == nil && !item.submenu ? item.title.split(separator: " ").first.map(String.init) : nil
    }
    var counts: [String: Int] = [:]
    for item in items { if let word = first(item) { counts[word, default: 0] += 1 } }
    var result: [CommandEntry] = []
    var placed = Set<String>()
    for item in items {
      guard let word = first(item), counts[word, default: 0] > 1 else {
        result.append(.item(item))
        continue
      }
      guard placed.insert(word).inserted else { continue }
      let members = items.filter { first($0) == word }
      let rests = members.map { String($0.title.dropFirst(word.count)).trimmingCharacters(in: .whitespaces) }
      /* The first by the shared word alone where the rest of its title only names what it acts on,
       * as Duplicate Objects does. */
      let plain = rests[0].isEmpty || (!rests[0].contains(" ") && rests[0].hasSuffix("s"))
      let labels = [plain ? word : members[0].title] + rests.dropFirst().map { $0.isEmpty ? word : $0 }
      result.append(.group(CommandGroup(items: members, labels: labels)))
    }
    return result
  }

  static let commandGap: CGFloat = 4

  /** Along an arc, in points: a title's length, capped, or the menu's round button. */
  static func commandWidth(_ entry: CommandEntry) -> CGFloat {
    let font = UIFont.systemFont(ofSize: 12, weight: .semibold)
    func text(_ title: String) -> CGFloat {
      min(150, ceil((title as NSString).size(withAttributes: [.font: font]).width) + 18)
    }
    switch entry {
      case .undo, .redo, .menu: return Ring.narrow - 4
      case .back: return text("‹ Back")
      case .item(let item):
        return iconOnly(item) != nil ? Ring.narrow - 4 : text(item.submenu ? item.title + " ›" : item.title)
      case .group(let group): return group.labels.reduce(0) { $0 + text($1) - 6 } + 6
      case .action(let action): return text(action.title)
    }
  }

  /** How many places of about 110 points an arc at \a radius has. */
  private static func places(arc: Arc, radius: CGFloat) -> Int {
    max(3, Int(CGFloat(arc.end - arc.start) * radius / 110))
  }

  /** Which of the commands that do not all fit show. */
  var commandPage = 0

  /** A touch anywhere in the window: away from the palette, it closes, and the touch goes on to
   * what is under it. */
  fileprivate func touched(at point: CGPoint) {
    guard isOpen, shown, !contains(point) else { return }
    /* The color picker the palette opened: a tap away from it closes it, not the palette. */
    if window?.rootViewController?.presentedViewController != nil { return }
    close()
  }

  /* -------------------------------------------------------------------- */
  /* The Pencil */

  fileprivate func pencilHovered(at point: CGPoint?, roll: Double?) {
    guard isOpen else { return }
    guard let point else {
      hoverRoll = nil
      rollLock = nil
      if target != nil { target = nil }
      return
    }
    lastPoint = point
    if let lock = rollLock, hypot(point.x - lock.x, point.y - lock.y) > 30 { rollLock = nil }
    let next = part(at: point) ?? primary
    if next != target { target = next }
    if rollLock == nil, let roll, let last = hoverRoll { rolled(by: Self.wrapped(roll - last), on: next, at: point) }
    hoverRoll = roll
  }

  fileprivate func pencilTouched(down: Bool, angle: Double, at point: CGPoint) {
    lastPoint = point
    guard isOpen, down else {
      touchRoll = nil
      return
    }
    /* Touching, the Pencil works the palette directly, as a finger does: its roll would move
     * things out from under it. */
    touchRoll = nil
  }

  nonisolated fileprivate static func wrapped(_ angle: Double) -> Double { atan2(sin(angle), cos(angle)) }

  /** On one of the arcs, not the tip inside them, where drawing goes on. */
  private func contains(_ point: CGPoint) -> Bool {
    guard let arc else { return false }
    if colorWheel, inWheel(point, arc: arc) { return true }
    return rings.contains { $0.hit(point, around: arc) != nil }
  }

  /** The part under \a point in the window, or none away from them all. */
  private func inWheel(_ point: CGPoint, arc: Arc) -> Bool {
    hypot(point.x - arc.center.x, point.y - arc.center.y) <= Self.wheelRadius + Self.wheelRing + 4
  }

  private func part(at point: CGPoint) -> Part? {
    guard let arc else { return nil }
    if colorWheel, inWheel(point, arc: arc) { return .color }
    for ring in rings {
      switch ring.hit(point, around: arc) {
        case .accessory(.undo), .accessory(.redo): return .history
        case .accessory(.more): return nil
        /* Commands are tapped, not turned. */
        case .part(.commands): return nil
        case .part(let part): return part
        case nil: continue
      }
    }
    return nil
  }

  /** How far the Pencil rolls for one step of what it turns: an item along an arc, a twentieth of
   * a slider, one of 24 hues, one step of the history. Far enough that a hand holding still
   * turns nothing. */
  static let rollStep = Double.pi / 3
  static let sliderRollStep = Double.pi / 6
  static let hueRollStep = Double.pi / 4

  /** The roll gathered towards the next step of what it turns. */
  @ObservationIgnored private var rollGathered: (part: Part, angle: Double)?

  /** Whole steps of \a size from the roll gathered on \a part, the rest kept for the next. */
  private func steps(_ delta: Double, on part: Part, size: Double) -> Int {
    var gathered = rollGathered?.part == part ? rollGathered!.angle : 0
    gathered += delta
    let whole = Int(gathered / size)
    gathered -= Double(whole) * size
    rollGathered = (part, gathered)
    return whole
  }

  /** The Pencil rolled by \a delta radians on \a part: it turns in whole steps only, so nothing
   * wavers between them. */
  private func rolled(by delta: Double, on part: Part, at point: CGPoint) {
    guard delta != 0, shown else { return }
    switch part {
      case .tools, .brushes:
        let count = steps(delta, on: part, size: Self.rollStep)
        if count != 0 { turn(part, by: Double(count), at: point) }
      case .size, .strength, .weight:
        let count = steps(delta, on: part, size: Self.sliderRollStep)
        guard count != 0 else { return }
        let key = part == .size ? "size" : part == .weight ? "weight" : "strength"
        let before = fraction(key)
        let after = min(1, max(0, ((before * 20).rounded() + Double(count)) / 20))
        guard after != before else { return }
        setFraction(key, after, settles: true)
        tick(at: point)
      case .color:
        let count = steps(delta, on: part, size: Self.hueRollStep)
        if count != 0 { turnHue(by: Double(count) / 24, at: point) }
      case .direction:
        guard let direction else { return }
        let count = steps(delta, on: part, size: Self.sliderRollStep)
        guard count != 0 else { return }
        let inverted = count > 0
        if inverted != direction.inverted {
          chooseDirection(inverted)
          tick(at: point)
        }
      case .history:
        let count = steps(delta, on: part, size: Self.rollStep)
        for _ in 0..<abs(count) {
          Engine.operatorCall(count > 0 ? "ED_OT_redo" : "ED_OT_undo")
          tick(at: point)
        }
      case .commands:
        let count = steps(delta, on: part, size: Self.rollStep)
        if count != 0 { turnCommands(by: Double(count), at: point) }
    }
  }

  /** Felt through the Pencil as something clicks from one step to the next. */
  private func tick(at point: CGPoint) {
    RollDial.shared.pencilTick(at: point)
    Haptics.selection()
  }

  /* -------------------------------------------------------------------- */
  /* Strips */

  func position(_ part: Part) -> Double { part == .tools ? toolPosition : brushPosition }

  private func setPosition(_ part: Part, _ value: Double) {
    if part == .tools { toolPosition = value } else { brushPosition = value }
  }

  private func items(_ part: Part) -> [RailItem] { part == .tools ? tools : brushes }

  /** The item in the middle of a strip. */
  func highlighted(_ part: Part) -> Int { Int(position(part).rounded()) }

  /** The position as a strip shows it: held at each item until the roll is well on its way to
   * the next, then turning there quickly, so it clicks from one to the next. */
  func shownPosition(_ part: Part) -> Double {
    let position = position(part)
    if scrubbing == part { return position }
    let nearest = position.rounded()
    let off = position - nearest
    return nearest + 4 * off * off * off
  }

  /** On Blender's active item, unless it is turning here. */
  private func follow(_ part: Part) {
    guard settling[part] == nil, scrubbing != part else { return }
    let active = part == .tools ? activeTool : activeBrush
    if let index = items(part).firstIndex(where: { $0.id == active }), highlighted(part) != index {
      setPosition(part, Double(index))
    }
  }

  private func turn(_ part: Part, by steps: Double, at point: CGPoint) {
    let count = items(part).count
    guard count > 0 else { return }
    let before = position(part)
    let after = min(Double(count - 1), max(0, before + steps))
    setPosition(part, after)
    if Int(before.rounded()) != Int(after.rounded()) { tick(at: point) }
    /* Chosen once it stops turning, rather than every item it passes. */
    settle(part, after: 0.32) { [weak self] in self?.choose(part) }
  }

  /** The roll held still where the palette was just touched. */
  func lockRoll() { rollLock = lastPoint ?? .zero }

  /** Chooses a strip's item at \a index at once. */
  func pick(_ part: Part, _ index: Int) {
    lockRoll()
    guard items(part).indices.contains(index) else { return }
    cancelSettling(part)
    setPosition(part, Double(index))
    choose(part)
    Haptics.selection()
  }

  func beginScrub(_ part: Part) {
    cancelSettling(part)
    scrubbing = part
  }

  /** A finger or the Pencil dragging a strip to \a position. */
  func scrub(_ part: Part, to position: Double) {
    let count = items(part).count
    guard count > 0 else { return }
    let before = self.position(part)
    let after = min(Double(count - 1), max(0, position))
    setPosition(part, after)
    if Int(before.rounded()) != Int(after.rounded()) { Haptics.selection() }
  }

  func endScrub(_ part: Part, at position: Double) {
    lockRoll()
    scrubbing = nil
    let count = items(part).count
    guard count > 0 else { return }
    setPosition(part, min(Double(count - 1), max(0, position.rounded())))
    choose(part)
  }

  private func choose(_ part: Part) {
    let index = highlighted(part)
    setPosition(part, Double(index))
    let items = items(part)
    guard items.indices.contains(index) else { return }
    let item = items[index]
    if part == .tools, item.id != activeTool {
      activeTool = item.id
      chooseTool?(item)
    }
    else if part == .brushes, item.id != activeBrush {
      activeBrush = item.id
      chooseBrush?(item)
    }
  }

  private func settle(_ part: Part, after delay: Double, _ action: @escaping @MainActor () -> Void) {
    settling[part]?.task.cancel()
    let task = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let self else { return }
      self.settling[part] = nil
      action()
    }
    settling[part] = (task, action)
  }

  private func cancelSettling(_ part: Part) {
    settling[part]?.task.cancel()
    settling[part] = nil
  }

  /** Whatever was still turning as the palette closes is done now. */
  private func flushSettling() {
    let pending = settling
    settling = [:]
    for (_, entry) in pending {
      entry.task.cancel()
      entry.action()
    }
  }

  /* -------------------------------------------------------------------- */
  /* Size and strength */

  private func range(_ key: String) -> (low: Double, high: Double, logarithmic: Bool) {
    let json = brush?.dict(key)
    let low = json?.double("min") ?? 0
    let high = max(low + 1e-6, json?.double("max") ?? 1)
    /* Along a curve, so small sizes get as much of it as large ones. */
    return (low, high, key == "size" && low > 0)
  }

  func value(_ key: String) -> Double {
    values[key] ?? brush?.dict(key)?.double("value") ?? range(key).low
  }

  /** Where the value sits between its ends, from 0 to 1. */
  func fraction(_ key: String) -> Double {
    let (low, high, logarithmic) = range(key)
    let value = value(key)
    let t = logarithmic ? log(max(value, low) / low) / log(high / low) : (value - low) / (high - low)
    return min(1, max(0, t))
  }

  /** Blender follows at once; it keeps one undo step once the value is let go, or for a roll,
   * once it stops turning. */
  func setFraction(_ key: String, _ t: Double, settles: Bool = false) {
    let (low, high, logarithmic) = range(key)
    let value = logarithmic ? low * pow(high / low, t) : low + (high - low) * t
    values[key] = value
    sendBrushValue(key, value)
    preview(key)
    if settles {
      settle(Self.part(key), after: 0.4) { [weak self] in self?.commitValue(key, direct: false) }
    }
  }

  /** The brush shown where the arcs center while \a key changes, a moment longer after. */
  private func preview(_ key: String) {
    guard key == "size" || key == "strength" else { return }
    if previewing != key { previewing = key }
    previewGeneration += 1
    let current = previewGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
      if self.previewGeneration == current { self.previewing = nil }
    }
  }

  /** \a direct: let go of after a drag, rather than a roll that stopped. */
  func commitValue(_ key: String, direct: Bool = true) {
    if direct { lockRoll() }
    guard let value = values[key] else { return }
    sendBrushValue(key, value, commit: true)
    /* Shown until Blender's snapshot has it. */
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      if self.values[key] == value { self.values[key] = nil }
    }
  }

  func formatted(_ key: String) -> String {
    let value = value(key)
    if key == "strength" { return "\(Int((value * 100).rounded()))%" }
    if key == "weight" { return String(format: "%.2f", value) }
    return brush?.dict(key)?.bool("pixels") == true ? "\(Int(value.rounded())) px" : String(format: "%.3g m", value)
  }

  /* -------------------------------------------------------------------- */
  /* Direction */

  func chooseDirection(_ inverted: Bool) {
    lockRoll()
    guard var direction, direction.inverted != inverted else { return }
    direction.inverted = inverted
    self.direction = direction
    setDirection?(inverted)
  }

  /* -------------------------------------------------------------------- */
  /* Color */

  /** The brush's color, where it paints with one. */
  var color: [Double]? {
    localColor ?? (brush?["color"] as? [NSNumber]).map { $0.map(\.doubleValue) }
  }

  private static let recentKey = "BlenderPaletteRecentColors"
  private(set) var recentColors: [[Double]] =
    (UserDefaults.standard.array(forKey: "BlenderPaletteRecentColors") as? [[Double]]) ?? []

  /** Blender follows at once; one undo step once it settles, and it joins the recent colors. */
  func setColor(_ rgb: [Double], settleAfter delay: Double) {
    localColor = rgb
    if Date().timeIntervalSince(lastSent) > 1.0 / 30 {
      lastSent = Date()
      sendBrushValue("color", rgb)
    }
    settle(.color, after: delay) { [weak self] in self?.commitColor() }
  }

  /** A recent color, at once. */
  func applyColor(_ rgb: [Double]) {
    lockRoll()
    cancelSettling(.color)
    localColor = rgb
    commitColor()
    Haptics.selection()
  }

  private func commitColor() {
    guard let rgb = localColor else { return }
    sendBrushValue("color", rgb, commit: true)
    var recent = recentColors.filter { !Self.same($0, rgb) }
    recent.insert(rgb, at: 0)
    recentColors = Array(recent.prefix(8))
    UserDefaults.standard.set(recentColors, forKey: Self.recentKey)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      if self.localColor.map({ Self.same($0, rgb) }) == true { self.localColor = nil }
    }
  }

  static func same(_ a: [Double], _ b: [Double]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.004 }
  }

  /** Once around the hues for a full turn of the Pencil. */
  private func turnHue(by turns: Double, at point: CGPoint) {
    guard let rgb = color, rgb.count >= 3 else { return }
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    UIColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    /* A grey has no hue to turn: it takes some color as it turns. */
    if s < 0.05 { s = 0.8 }
    if b < 0.05 { b = 0.9 }
    let before = Double(h)
    var hue = (before + turns).truncatingRemainder(dividingBy: 1)
    if hue < 0 { hue += 1 }
    if Int(before * 12) != Int(hue * 12) { tick(at: point) }
    let next = UIColor(hue: hue, saturation: s, brightness: b, alpha: 1)
    var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0
    next.getRed(&r, green: &g, blue: &bl, alpha: &a)
    setColor([Double(r), Double(g), Double(bl)], settleAfter: 0.5)
  }

  /* -------------------------------------------------------------------- */
  /* Commands */

  var commands: [BlenderMenuItem]? { BlenderMenus.shared.items[commandRoute] }

  private var highlightedCommand: BlenderMenuItem? {
    guard let commandIndex, let commands else { return nil }
    let index = Int(commandIndex.rounded())
    return commands.indices.contains(index) ? commands[index] : nil
  }

  var highlightedCommandID: String? { highlightedCommand?.id }

  /** Where the commands' ring has turned to. */
  var commandPosition: Double { commandIndex ?? 0 }

  func scrubCommands(to position: Double) {
    guard let commands, !commands.isEmpty else { return }
    let before = commandPosition
    let after = min(Double(commands.count - 1), max(0, position))
    commandIndex = after
    if Int(before.rounded()) != Int(after.rounded()) { Haptics.selection() }
  }

  func endScrubCommands() {
    commandIndex = commandIndex.map { $0.rounded() }
  }

  /** The roll has turned to a command, which a squeeze then runs. */
  @ObservationIgnored private var commandRolled = false

  private func turnCommands(by steps: Double, at point: CGPoint) {
    guard let commands, !commands.isEmpty else { return }
    commandRolled = true
    let before = commandIndex ?? 0
    let after = min(Double(commands.count - 1), max(0, before + steps))
    commandIndex = after
    if Int(before.rounded()) != Int(after.rounded()) { tick(at: point) }
  }

  /** How many menus deep a command's route is: one for the context menu's own. */
  static func depth(of route: String) -> Int {
    guard let data = route.data(using: .utf8),
          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let path = json["path"] as? [Any]
    else { return 1 }
    return max(1, path.count)
  }

  /** The active object's or bone's name, for Rename Active to start from. */
  var activeName = ""

  /** Rename Active, asked for with the system's text field rather than Blender's popup. */
  private func rename(_ item: BlenderMenuItem) {
    close()
    guard let window, var top = window.rootViewController else { return }
    while let presented = top.presentedViewController { top = presented }
    let alert = UIAlertController(title: item.title.replacingOccurrences(of: "…", with: ""), message: nil,
                                  preferredStyle: .alert)
    alert.addTextField { [activeName] field in
      field.text = activeName
      field.clearButtonMode = .whileEditing
      field.autocapitalizationType = .none
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak alert] _ in
      guard let name = alert?.textFields?.first?.text, !name.isEmpty,
            let data = try? JSONSerialization.data(withJSONObject: name, options: .fragmentsAllowed),
            let json = String(data: data, encoding: .utf8)
      else { return }
      Engine.setting("rename_active", json)
    })
    top.present(alert, animated: true)
  }

  /** Runs a command, or opens its submenu. */
  func activate(_ item: BlenderMenuItem) {
    guard !item.disabled else { return }
    if item.title.hasPrefix("Rename Active") {
      rename(item)
      return
    }
    if item.submenu {
      /* Its own arc, further out than the one it is on, in place of any opened from there: tapped
       * again, it closes. */
      let depth = Self.depth(of: item.route)
      let open = isOpen(item)
      commandPath = Array(commandPath.prefix(max(0, depth - 1)))
      if open {
        Haptics.selection()
        return
      }
      commandPath.append((item.route, item.title))
      commandIndex = 0
      commandPage = 0
      Task { _ = await BlenderMenus.shared.fetch(item.route) }
      Haptics.selection()
      return
    }
    /* Where the Pencil is, so what follows the pointer, as Bevel does, starts from there. */
    if let tip {
      let pixels = wm_apple_ios_window_pixels(blenderWindow, tip)
      _ = item.route.withCString { WM_apple_ios_ui_menu_at_position_request($0, true, Int32(pixels.x), Int32(pixels.y)) }
    }
    else {
      BlenderMenus.shared.run(item)
    }
    Haptics.impact(.medium)
    close()
  }

  func commandsBack() {
    commandIndex = 0
    if commandPath.isEmpty { page = .main }
    else { commandPath.removeLast() }
  }

  /* -------------------------------------------------------------------- */
  /* History */

  func undo() {
    Engine.operatorCall("ED_OT_undo")
    Haptics.selection()
  }

  func redo() {
    Engine.operatorCall("ED_OT_redo")
    Haptics.selection()
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Input
 * \{ */

/** While the palette is open: the Pencil hovering anywhere in the window, with its roll, and
 * touches, which close it away from the palette. The touch still goes on to what is under it. */
@MainActor
private final class PaletteInput: NSObject, UIGestureRecognizerDelegate {
  private weak var window: UIWindow?
  private let hover = UIHoverGestureRecognizer()
  private let outside = TouchWatcher(target: nil, action: nil)
  private var observer: NSObjectProtocol?

  init(window: UIWindow) {
    self.window = window
    super.init()
    hover.addTarget(self, action: #selector(hovered(_:)))
    hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
    hover.delegate = self
    outside.delegate = self
    outside.began = { point in SqueezePalette.shared.touched(at: point) }
    window.addGestureRecognizer(hover)
    window.addGestureRecognizer(outside)
    /* The roll while the Pencil touches, see GHOST's window. */
    observer = NotificationCenter.default.addObserver(forName: Notification.Name("BlenderPencilRoll"), object: nil,
                                                      queue: .main) { note in
      let info = note.userInfo
      let down = (info?["down"] as? Bool) ?? false
      let angle = (info?["angle"] as? Double) ?? 0
      let point = CGPoint(x: (info?["x"] as? Double) ?? 0, y: (info?["y"] as? Double) ?? 0)
      MainActor.assumeIsolated { SqueezePalette.shared.pencilTouched(down: down, angle: angle, at: point) }
    }
  }

  func remove() {
    window?.removeGestureRecognizer(hover)
    window?.removeGestureRecognizer(outside)
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
  }

  @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
    switch recognizer.state {
      case .began, .changed:
        SqueezePalette.shared.pencilHovered(at: recognizer.location(in: nil), roll: Double(recognizer.rollAngle))
      default:
        SqueezePalette.shared.pencilHovered(at: nil, roll: nil)
    }
  }

  func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                         shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool
  {
    true
  }
}

/** Sees each touch begin, in the window, and never recognizes, so it takes nothing from anything
 * else. */
private final class TouchWatcher: UIGestureRecognizer {
  var began: ((CGPoint) -> Void)?

  override init(target: Any?, action: Selector?) {
    super.init(target: target, action: action)
    cancelsTouchesInView = false
    delaysTouchesBegan = false
    delaysTouchesEnded = false
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    if let touch = touches.first { began?(touch.location(in: nil)) }
    state = .failed
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Layer
 * \{ */

/** Over the whole window: the band around the Pencil while it is open, and what shows beside it.
 * Touches elsewhere, the tip inside the band too, go on to what is under it. */
struct SqueezePaletteLayer: View {
  private var palette: SqueezePalette { .shared }
  @State private var host = WindowHost()

  var body: some View {
    GeometryReader { proxy in
      let origin = proxy.frame(in: .global).origin
      if let arc = palette.arc, let tip = palette.tip, palette.window === host.window {
        let local = SqueezePalette.Arc(center: CGPoint(x: arc.center.x - origin.x, y: arc.center.y - origin.y),
                                       facing: arc.facing)
        /* Where the Pencil hovers, which the arcs grow out of. */
        let anchor = UnitPoint(x: (tip.x - origin.x) / max(1, proxy.size.width),
                               y: (tip.y - origin.y) / max(1, proxy.size.height))
        ZStack {
          ArcsView(arc: local, anchor: anchor)
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
        .allowsHitTesting(palette.shown)
        .animation(SqueezePalette.motion(.spring(response: 0.34, dampingFraction: 0.84)), value: palette.page)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tool Palette")
        .accessibilityIdentifier("blender.squeeze-palette")
        .accessibilityAction(.escape) { palette.close() }
      }
    }
    .ignoresSafeArea()
    .background(WindowReader(host: host))
  }
}

@MainActor
@Observable
private final class WindowHost {
  weak var window: UIWindow?
}

/** The window the layer is in, to show only the palette squeezed there. */
private struct WindowReader: UIViewRepresentable {
  let host: WindowHost

  func makeUIView(context: Context) -> Reader {
    let view = Reader()
    view.host = host
    view.isUserInteractionEnabled = false
    return view
  }

  func updateUIView(_ view: Reader, context: Context) { view.host = host }

  final class Reader: UIView {
    var host: WindowHost?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      host?.window = window
    }
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Arcs
 * \{ */

private typealias Arc = SqueezePalette.Arc
private typealias Ring = SqueezePalette.Ring
private typealias Piece = SqueezePalette.Piece

extension SqueezePalette.Arc {
  /** Turned to follow the arcs at \a angle, its top away from the tip, or towards it where they
   * face down, so it still reads upright. */
  fileprivate func upright(_ angle: Double, middle: Double? = nil) -> Angle {
    .radians(sin(middle ?? facing) < 0 ? angle + .pi / 2 : angle - .pi / 2)
  }

  /** The angle around the center of \a point, near the arcs' middle. */
  fileprivate func angle(of point: CGPoint) -> Double {
    facing + SqueezePalette.wrapped(atan2(Double(point.y - center.y), Double(point.x - center.x)) - facing)
  }
}

/** Placed on a ring at an angle, moving round it rather than straight across when the angle
 * changes. */
private struct OnArc: ViewModifier, Animatable {
  let center: CGPoint
  let radius: CGFloat
  var angle: Double

  var animatableData: Double {
    get { angle }
    set { angle = newValue }
  }

  func body(content: Content) -> some View {
    content.position(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
  }
}

/** A stretch of a ring, its ends rounded. */
private struct ArcBand: Shape {
  let center: CGPoint
  let radius: CGFloat
  let thickness: CGFloat
  let start: Double
  let end: Double

  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.addRelativeArc(center: center, radius: radius, startAngle: .radians(start), delta: .radians(max(0, end - start)))
    return path.strokedPath(StrokeStyle(lineWidth: thickness, lineCap: .round))
  }
}

/** Every arc, nearest the tip first, each its own glass, and the name of what is in use just
 * outside them. */
private struct ArcsView: View {
  let arc: Arc
  /** The Pencil's tip, in the layer, which they grow out of. */
  let anchor: UnitPoint
  private var palette: SqueezePalette { .shared }

  var body: some View {
    let rings = palette.rings
    ZStack {
      ForEach(Array(rings.enumerated()), id: \.element.id) { order, ring in
        /* Out of the tip, each a moment after the one inside it, and back in the other way. */
        RingView(arc: arc, ring: ring)
          .scaleEffect(palette.shown ? 1 : 0.15, anchor: anchor)
          .opacity(palette.shown ? 1 : 0)
          .animation(SqueezePalette.motion(.spring(response: 0.42, dampingFraction: 0.78)
                       .delay(palette.shown ? Double(order) * 0.05 : Double(rings.count - 1 - order) * 0.03)),
                     value: palette.shown)
          .transition(.scale(scale: 0.92, anchor: anchor).combined(with: .opacity))
      }
      if palette.colorWheel {
        ColorWheel()
          .position(arc.center)
          .transition(.scale(scale: 0.3).combined(with: .opacity))
      }
      else if palette.previewing != nil {
        BrushDab()
          .position(arc.center)
          .transition(.opacity.combined(with: .scale(scale: 0.85)))
          .allowsHitTesting(false)
      }
      /* What is in the lens, small and level, in the hollow of the arcs. */
      Text(title)
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
        .fixedSize()
        .position(arc.point(arc.facing, radius: Arc.inner * 0.3))
        .contentTransition(.opacity)
        .animation(.easeOut(duration: 0.12), value: title)
        .opacity(palette.shown && !title.isEmpty && palette.previewing == nil && !palette.colorWheel ? 1 : 0)
        .animation(.easeOut(duration: 0.2).delay(palette.shown ? 0.15 : 0), value: palette.shown)
        .allowsHitTesting(false)
    }
  }

  /** The tool or brush in the lens. */
  private var title: String {
    let part = palette.band
    let items = part == .tools ? palette.tools : palette.brushes
    return items.indices.contains(palette.highlighted(part)) ? items[palette.highlighted(part)].title : ""
  }
}

/** The brush's color as a disc where the arcs center: hue around it, saturation out from the
 * middle, and around it a ring for brightness, dark to full going round from the top. Dragged in,
 * a finger or the Pencil sets them; hovering it, the Pencil's roll turns the hue. */
private struct ColorWheel: View {
  private var palette: SqueezePalette { .shared }
  private static let radius = SqueezePalette.wheelRadius
  private static let ring = SqueezePalette.wheelRing
  /** Dragging the disc or the ring, as it began. */
  @State private var onRing: Bool?

  private var hsb: (h: Double, s: Double, b: Double) {
    let rgb = palette.color ?? [1, 1, 1]
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    UIColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    return (Double(h), Double(s), Double(b))
  }

  var body: some View {
    let (h, s, b) = hsb
    let side = 2 * (Self.radius + Self.ring + 2)
    let hues = (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) }
    let full = Color(hue: h, saturation: s, brightness: 1)
    let current = Color(hue: h, saturation: s, brightness: b)
    let knob = CGPoint(x: side / 2 + Self.radius * CGFloat(s) * CGFloat(cos(h * 2 * .pi)),
                       y: side / 2 + Self.radius * CGFloat(s) * CGFloat(sin(h * 2 * .pi)))
    let ringRadius = Self.radius + Self.ring / 2 + 1
    let bright = -Double.pi / 2 + b * 2 * .pi
    ZStack {
      /* Dark to full brightness, round from the top. */
      Circle()
        .strokeBorder(AngularGradient(colors: [.black, full], center: .center,
                                      startAngle: .degrees(-90), endAngle: .degrees(270)), lineWidth: Self.ring)
        .frame(width: 2 * (Self.radius + Self.ring + 2), height: 2 * (Self.radius + Self.ring + 2))
      Circle()
        .fill(AngularGradient(colors: hues, center: .center))
        .overlay(Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center,
                                              startRadius: 0, endRadius: Self.radius)))
        .overlay(Circle().fill(Color.black.opacity(1 - b)))
        .frame(width: 2 * Self.radius, height: 2 * Self.radius)
        .shadow(color: .black.opacity(0.25), radius: 10)
      Circle()
        .fill(current)
        .frame(width: 22, height: 22)
        .overlay(Circle().strokeBorder(.white, lineWidth: 3))
        .shadow(color: .black.opacity(0.35), radius: 2)
        .position(knob)
      Circle()
        .fill(.white)
        .frame(width: Self.ring + 4, height: Self.ring + 4)
        .shadow(color: .black.opacity(0.35), radius: 2)
        .position(x: side / 2 + ringRadius * CGFloat(cos(bright)), y: side / 2 + ringRadius * CGFloat(sin(bright)))
    }
    .frame(width: side, height: side)
    .contentShape(Circle())
    .gesture(DragGesture(minimumDistance: 0)
      .onChanged { value in
        let dx = Double(value.location.x - side / 2), dy = Double(value.location.y - side / 2)
        let distance = CGFloat(hypot(dx, dy))
        if onRing == nil { onRing = distance > Self.radius + 2 }
        var angle = atan2(dy, dx)
        if onRing == true {
          /* From the top, round. */
          angle += .pi / 2
          if angle < 0 { angle += 2 * .pi }
          set(h, s, min(1, max(0, angle / (2 * .pi))))
        }
        else {
          if angle < 0 { angle += 2 * .pi }
          set(angle / (2 * .pi), min(1, Double(distance / Self.radius)), b < 0.05 ? 1 : b)
        }
      }
      .onEnded { _ in
        onRing = nil
        palette.lockRoll()
      })
    .accessibilityElement()
    .accessibilityLabel("Color")
  }

  private func set(_ h: Double, _ s: Double, _ b: Double) {
    var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, a: CGFloat = 0
    UIColor(hue: h, saturation: s, brightness: b, alpha: 1).getRed(&r, green: &g, blue: &bl, alpha: &a)
    palette.setColor([Double(r), Double(g), Double(bl)], settleAfter: 0.5)
  }
}

/** The brush as it will paint: its size on screen, filled as strongly as it paints. */
private struct BrushDab: View {
  private var palette: SqueezePalette { .shared }
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    let size = palette.brush?.dict("size")
    let pixels = size?.bool("pixels") == true
    /* Blender's pixels are the screen's; a size in the scene shows by its place in its range. */
    let diameter = pixels ? CGFloat(palette.value("size")) / displayScale : 20 + 120 * CGFloat(palette.fraction("size"))
    let strength = palette.brush?.dict("strength") != nil ? palette.value("strength") : 1
    let rgb = palette.color ?? [1, 1, 1]
    ZStack {
      Circle().fill(Color(red: rgb[0], green: rgb[1], blue: rgb[2]).opacity(0.1 + 0.85 * min(1, strength)))
      Circle().stroke(Color.black.opacity(0.5), lineWidth: 3)
      Circle().stroke(Color.white, lineWidth: 1.5)
    }
    .frame(width: min(2 * (Arc.inner - Ring.wide / 2) - 16, max(6, diameter)),
           height: min(2 * (Arc.inner - Ring.wide / 2) - 16, max(6, diameter)))
    .animation(.easeOut(duration: 0.08), value: diameter)
  }
}

private struct RingView: View {
  let arc: Arc
  let ring: Ring
  private var palette: SqueezePalette { .shared }

  var body: some View {
    let band = ArcBand(center: arc.center, radius: ring.radius, thickness: ring.thickness, start: ring.start, end: ring.end)
    let floating = !ring.commands.isEmpty
    ZStack {
      if !floating {
        Color.clear
          .panelGlass(in: band)
          .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
          .contentShape(band)
      }
      ForEach(ring.sections, id: \.part) { section in
        ArcSection(arc: arc, ring: ring, section: section)
      }
      ForEach(ring.leading + ring.trailing, id: \.self) { accessory in
        self.accessory(accessory)
          .rotationEffect(arc.upright(ring.angle(accessory), middle: ring.middleAngle))
          .position(arc.point(ring.angle(accessory), radius: ring.radius))
      }
      if !ring.commands.isEmpty {
        ArcCommandRow(arc: arc, ring: ring)
      }
      ForEach(ring.pieces, id: \.self) { piece in
        content(piece)
      }
    }
  }

  @ViewBuilder
  private func accessory(_ accessory: SqueezePalette.Accessory) -> some View {
    switch accessory {
      case .undo:
        PaletteIconButton(symbol: "arrow.uturn.backward", label: "Undo", enabled: palette.canUndo) { palette.undo() }
      case .redo:
        PaletteIconButton(symbol: "arrow.uturn.forward", label: "Redo", enabled: palette.canRedo) { palette.redo() }
      case .more:
        PaletteIconButton(symbol: moreSymbol, label: palette.page == .commands ? "Back" : "Commands") { more() }
          .contentTransition(.symbolEffect(.replace))
          .accessibilityIdentifier("blender.squeeze-palette.commands")
    }
  }

  private var moreSymbol: String {
    palette.page != .commands ? "ellipsis" : palette.commandPath.isEmpty ? "xmark" : "chevron.backward"
  }

  /** The commands, back out of a submenu, or closed. */
  private func more() {
    if palette.page != .commands { palette.page = .commands }
    else if palette.commandPath.isEmpty { palette.page = .main }
    else { palette.commandsBack() }
  }

  @ViewBuilder
  private func content(_ piece: Piece) -> some View {
    switch piece.part {
      case .size:
        ArcSlider(arc: arc, ring: ring, piece: piece, key: "size", symbol: "circle.dashed")
      case .strength:
        ArcSlider(arc: arc, ring: ring, piece: piece, key: "strength", symbol: "drop.fill")
      case .weight:
        ArcSlider(arc: arc, ring: ring, piece: piece, key: "weight", symbol: "scalemass.fill")
      case .direction:
        ArcDirection(arc: arc, ring: ring, piece: piece)
      case .color:
        ArcRecentColors(arc: arc, ring: ring, piece: piece)
      default:
        EmptyView()
    }
  }
}

/** Lit while the Pencil's roll turns it. */
private struct Lit: ViewModifier {
  let shape: ArcBand
  let part: SqueezePalette.Part

  func body(content: Content) -> some View {
    let lit = SqueezePalette.shared.target == part
    content.overlay {
      shape.stroke(Color.accentColor.opacity(lit ? 0.7 : 0), lineWidth: 2)
        .animation(.easeOut(duration: 0.16), value: lit)
        .allowsHitTesting(false)
    }
  }
}

/** The tools' or brushes' stretch of their arc. Grown, they turn under a lens in its middle: a
 * slide moves them with the finger or Pencil, a tap picks the one under it, and hovering, the
 * Pencil's roll clicks them along. Shrunk, it holds the one in use, and a tap grows it, shrinking
 * the other. One gesture tells a tap from a slide, so neither takes the other's touches. */
private struct ArcSection: View {
  let arc: Arc
  let ring: Ring
  let section: SqueezePalette.Section
  private var palette: SqueezePalette { .shared }
  @State private var touch: (angle: Double, position: Double, moved: Bool)?

  private var part: SqueezePalette.Part { section.part }

  var body: some View {
    let items = part == .tools ? palette.tools : palette.brushes
    let active = part == .tools ? palette.activeTool : palette.activeBrush
    let position = section.collapsed ? Double(items.firstIndex { $0.id == active } ?? 0) : palette.shownPosition(part)
    let highlighted = section.collapsed ? Int(position) : palette.highlighted(part)
    let side = ring.thickness - 8
    let shape = ArcBand(center: arc.center, radius: ring.radius, thickness: ring.thickness, start: section.start,
                        end: section.end)
    ZStack {
      Color.clear.contentShape(shape)
      Circle()
        .fill(.clear)
        .panelGlass(.tinted(.blue), in: Circle())
        .frame(width: side + 2, height: side + 2)
        .position(arc.point(section.middle, radius: ring.radius))
        .allowsHitTesting(false)
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        let angle = section.middle + (Double(index) - position) * section.step
        let edge = min(angle - section.start, section.end - angle) / section.step
        /* Past its ends, they go on round and fade away. */
        if section.collapsed ? index == highlighted : edge > -1.5 {
          ArcItem(item: item, brush: part == .brushes, lensed: index == highlighted, active: item.id == active,
                  side: side)
            .rotationEffect(arc.upright(angle))
            .scaleEffect(index == highlighted ? 1 : 0.88)
            .opacity(section.collapsed ? 1 : max(0, min(1, edge * 1.6 + 0.4)))
            .modifier(OnArc(center: arc.center, radius: ring.radius, angle: angle))
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.6)))
        }
      }
    }
    .contentShape(shape)
    .gesture(gesture(items.count))
    .modifier(Lit(shape: shape, part: part))
    .animation(palette.scrubbing == part ? nil : SqueezePalette.motion(.spring(response: 0.26, dampingFraction: 0.84)),
               value: position)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(part == .tools ? "Tools" : "Brushes")
    .accessibilityValue(items.indices.contains(highlighted) ? items[highlighted].title : "")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { if section.collapsed { grow() } }
    .accessibilityAdjustableAction { direction in
      palette.pick(part, highlighted + (direction == .increment ? 1 : -1))
    }
  }

  private func grow() {
    Haptics.selection()
    withAnimation(SqueezePalette.motion(.spring(response: 0.36, dampingFraction: 0.84))) { palette.expanded = part }
  }

  private func gesture(_ count: Int) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .local)
      .onChanged { value in
        let angle = arc.angle(of: value.location)
        if touch == nil { touch = (arc.angle(of: value.startLocation), palette.position(part), false) }
        guard var current = touch, !section.collapsed else { return }
        /* A clear move along it is a slide; anything less stays a tap. */
        if !current.moved, hypot(value.translation.width, value.translation.height) > 8 {
          current.moved = true
          touch = current
          palette.beginScrub(part)
        }
        guard current.moved else { return }
        palette.scrub(part, to: current.position - (angle - current.angle) / section.step)
      }
      .onEnded { value in
        defer { touch = nil }
        guard let current = touch else { return }
        if section.collapsed {
          grow()
          return
        }
        if current.moved {
          palette.endScrub(part, at: current.position - (arc.angle(of: value.predictedEndLocation) - current.angle) / section.step)
          return
        }
        /* The one under the touch, by how far along from the lens it is. */
        let index = Int((current.position + (arc.angle(of: value.location) - section.middle) / section.step).rounded())
        palette.pick(part, min(max(0, index), count - 1))
      }
  }
}

/** A brush or tool on its arc. The one Blender has is marked while the arc is turned away. */
private struct ArcItem: View {
  let item: RailItem
  let brush: Bool
  let lensed: Bool
  let active: Bool
  var side: CGFloat = 48

  var body: some View {
    let image = lensed ? item.selectedImage ?? item.image : item.image
    Group {
      if let image {
        if brush {
          Image(uiImage: image).resizable().scaledToFit().padding(3)
        }
        else {
          Image(uiImage: image)
            .renderingMode(image.renderingMode == .alwaysOriginal ? .original : .template)
            .resizable()
            .scaledToFit()
            .padding(side * 0.2)
        }
      }
      else {
        Text(String(item.title.prefix(1))).font(.headline)
      }
    }
    .foregroundStyle(lensed ? Color.white : Color.primary)
    .frame(width: side, height: side)
    .overlay(alignment: .bottom) {
      if active && !lensed {
        Circle().fill(Color.accentColor).frame(width: 5, height: 5).offset(y: 5)
      }
    }
    .contentShape(Circle())
    .hoverHighlight(Circle())
  }
}

/** The brush's color at the end of the brushes' arc: the system's color well. */
private struct ColorWell: View {
  let rgb: [Double]
  private var palette: SqueezePalette { .shared }

  var body: some View {
    ColorPicker(selection: Binding(get: { Color(red: rgb[0], green: rgb[1], blue: rgb[2]) }, set: { color in
      var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
      UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
      palette.setColor([r, g, b].map { min(1, max(0, Double($0))) }, settleAfter: 0.6)
    }), supportsOpacity: false) {
      Text("Color")
    }
    .labelsHidden()
    .frame(width: 40, height: 40)
  }
}

/** A round icon button in the palette, its highlight under a hovering Pencil. */
private struct PaletteIconButton: View {
  let symbol: String
  let label: String
  var enabled = true
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 17, weight: .semibold))
        .frame(width: 44, height: 44)
        .contentShape(Circle())
    }
    .buttonStyle(.borderless)
    .tint(.primary)
    .disabled(!enabled)
    .hoverHighlight(Circle())
    .accessibilityLabel(label)
  }
}

/** A line along an arc growing from thin at its start to thick at its end: the size slider's,
 * up to \a upTo. */
private struct TaperedArc: Shape {
  let center: CGPoint
  let radius: CGFloat
  let thin: CGFloat
  let thick: CGFloat
  let start: Double
  let end: Double
  var upTo: Double

  func path(in rect: CGRect) -> Path {
    let last = min(end, max(start, upTo))
    let steps = 32
    func width(_ angle: Double) -> CGFloat {
      thin + (thick - thin) * CGFloat((angle - start) / max(1e-6, end - start))
    }
    func point(_ angle: Double, _ r: CGFloat) -> CGPoint {
      CGPoint(x: center.x + r * CGFloat(cos(angle)), y: center.y + r * CGFloat(sin(angle)))
    }
    var path = Path()
    var outer: [CGPoint] = [], inner: [CGPoint] = []
    for i in 0...steps {
      let a = start + (last - start) * Double(i) / Double(steps)
      outer.append(point(a, radius + width(a) / 2))
      inner.append(point(a, radius - width(a) / 2))
    }
    path.addLines(outer + inner.reversed())
    path.closeSubpath()
    /* Its ends rounded. */
    let first = point(start, radius), w0 = width(start)
    path.addEllipse(in: CGRect(x: first.x - w0 / 2, y: first.y - w0 / 2, width: w0, height: w0))
    let tip = point(last, radius), w1 = width(last)
    path.addEllipse(in: CGRect(x: tip.x - w1 / 2, y: tip.y - w1 / 2, width: w1, height: w1))
    return path
  }

  var animatableData: Double {
    get { upTo }
    set { upTo = newValue }
  }
}

/** One of the brush's values along a stretch of an arc, filled up to where it is from the start.
 * The size is a line growing thicker along the arc; the strength a gradient from faint to full.
 * Dragged along, it follows the finger or Pencil from where the value is; hovering, the Pencil's
 * roll turns it, half the way for half a turn. */
private struct ArcSlider: View {
  let arc: Arc
  let ring: Ring
  let piece: Piece
  let key: String
  let symbol: String
  private var palette: SqueezePalette { .shared }
  @State private var last: Double?

  var body: some View {
    let width = ring.thickness - 10
    let track = ArcBand(center: arc.center, radius: ring.radius, thickness: width, start: piece.start, end: piece.end)
    let t = palette.fraction(key)
    let value = piece.start + (piece.end - piece.start) * t
    GeometryReader { proxy in
      ZStack {
        if key == "size" {
          let line = { (upTo: Double) in
            TaperedArc(center: arc.center, radius: ring.radius, thin: 6, thick: width, start: piece.start,
                       end: piece.end, upTo: upTo)
          }
          line(piece.end).fill(Color.primary.opacity(0.1))
          line(value).fill(Color.accentColor)
        }
        else {
          /* Faint where it is weak, full where it is strong. */
          let center = UnitPoint(x: arc.center.x / max(1, proxy.size.width), y: arc.center.y / max(1, proxy.size.height))
          let gradient = AngularGradient(colors: [Color.accentColor.opacity(0.12), Color.accentColor], center: center,
                                         startAngle: .radians(piece.start), endAngle: .radians(piece.end))
          track.fill(Color.primary.opacity(0.08))
          track.fill(gradient).opacity(0.35)
          ArcBand(center: arc.center, radius: ring.radius, thickness: width, start: piece.start, end: value)
            .fill(gradient)
          /* Where it is, a knob on the line. */
          Circle()
            .fill(.white)
            .shadow(color: .black.opacity(0.25), radius: 2)
            .frame(width: width - 8, height: width - 8)
            .position(arc.point(value, radius: ring.radius))
        }
        Image(systemName: symbol)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(key == "size" ? Color.secondary : Color.white)
          .rotationEffect(arc.upright(piece.start))
          .position(arc.point(piece.start - Double(key == "size" ? 14 : 0) / Double(ring.radius), radius: ring.radius))
      }
    }
    .contentShape(track)
    .modifier(Lit(shape: track, part: SqueezePalette.part(key)))
    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
      .onChanged { gesture in
        let angle = arc.angle(of: gesture.location)
        defer { last = angle }
        guard let last else { return }
        let next = min(1, max(0, palette.fraction(key) + (angle - last) / (piece.end - piece.start)))
        palette.setFraction(key, next)
      }
      .onEnded { _ in
        last = nil
        palette.commitValue(key)
      })
    .accessibilityElement()
    .accessibilityLabel(key == "size" ? "Size" : key == "weight" ? "Weight" : "Strength")
    .accessibilityValue(palette.formatted(key))
    .accessibilityAdjustableAction { direction in
      palette.setFraction(key, min(1, max(0, t + (direction == .increment ? 0.05 : -0.05))))
      palette.commitValue(key)
    }
  }
}

/** Which way the brush strokes: one track along a stretch of an arc, its two halves, the chosen
 * one a thumb inside it that slides across, as the system's segmented controls have it. */
private struct ArcDirection: View {
  let arc: Arc
  let ring: Ring
  let piece: Piece
  private var palette: SqueezePalette { .shared }

  var body: some View {
    let width = ring.thickness - 10
    let middle = (piece.start + piece.end) / 2
    let track = ArcBand(center: arc.center, radius: ring.radius, thickness: width, start: piece.start, end: piece.end)
    let inverted = palette.direction?.inverted ?? false
    /* The thumb, its rounded ends inside the track's. */
    let inset = Double(3) / Double(ring.radius)
    let thumb = ArcBand(center: arc.center, radius: ring.radius, thickness: width - 6,
                        start: inverted ? middle + inset : piece.start + inset,
                        end: inverted ? piece.end - inset : middle - inset)
    ZStack {
      track.fill(Color.primary.opacity(0.1))
      Color.clear
        .panelGlass(.tinted(.blue), in: thumb)
        .animation(SqueezePalette.motion(.spring(response: 0.3, dampingFraction: 0.8)), value: inverted)
      if let direction = palette.direction {
        symbol(direction.addSymbol, at: (piece.start + middle) / 2, on: !inverted)
        symbol(direction.subtractSymbol, at: (middle + piece.end) / 2, on: inverted)
      }
    }
    .contentShape(track)
    .onTapGesture { location in
      /* The half tapped. */
      palette.chooseDirection(arc.angle(of: location) > middle)
      Haptics.selection()
    }
    .modifier(Lit(shape: track, part: .direction))
    .accessibilityElement()
    .accessibilityLabel(inverted ? palette.direction?.subtract ?? "" : palette.direction?.add ?? "")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { palette.chooseDirection(!inverted) }
  }

  private func symbol(_ name: String, at angle: Double, on: Bool) -> some View {
    DirectionSymbol.view(name)
      .font(.system(size: 15, weight: .semibold))
      .foregroundStyle(on ? Color.white : Color.primary)
      .rotationEffect(arc.upright(angle))
      .position(arc.point(angle, radius: ring.radius))
      .allowsHitTesting(false)
  }
}

/** The brush's color, the system's color well, beside the colors used last, around the middle of a
 * stretch of an arc; the one the brush has ringed. */
private struct ArcRecentColors: View {
  let arc: Arc
  let ring: Ring
  let piece: Piece
  private var palette: SqueezePalette { .shared }

  var body: some View {
    let step = Double(36) / Double(ring.radius)
    let fit = max(0, Int((piece.end - piece.start) / step))
    let current = palette.color.map { Array($0.prefix(3)) }
    /* The swatch shows the color in use: the recent ones are the others. */
    let colors = Array(palette.recentColors.filter { rgb in
      rgb.count >= 3 && !(current.map { SqueezePalette.same($0, rgb) } ?? false)
    }.prefix(fit))
    let whole = ArcBand(center: arc.center, radius: ring.radius, thickness: ring.thickness - 10, start: piece.start,
                        end: piece.end)
    let first = (piece.start + piece.end) / 2 - Double(colors.count) * step / 2
    ZStack {
      if let rgb = palette.color, rgb.count >= 3 {
        /* Opens the color wheel where the arcs center, or closes it. */
        Button {
          Haptics.selection()
          withAnimation(SqueezePalette.motion(.spring(response: 0.32, dampingFraction: 0.82))) {
            palette.colorWheel.toggle()
          }
        } label: {
          Circle()
            .fill(Color(red: rgb[0], green: rgb[1], blue: rgb[2]))
            .frame(width: 26, height: 26)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .padding(3)
            .overlay(Circle().strokeBorder(AngularGradient(colors: (0...6).map { Color(hue: Double($0) / 6, saturation: 1, brightness: 1) },
                                                            center: .center), lineWidth: 3))
            .frame(width: 38, height: 38)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(Circle())
        .position(arc.point(first, radius: ring.radius))
        .accessibilityLabel("Color")
      }
      ForEach(Array(colors.enumerated()), id: \.offset) { index, rgb in
        let on = current.map { SqueezePalette.same($0, rgb) } ?? false
        Button {
          palette.applyColor(rgb)
        } label: {
          Circle()
            .fill(Color(red: rgb[0], green: rgb[1], blue: rgb[2]))
            .frame(width: 28, height: 28)
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: on ? 3 : 1))
            .shadow(color: .black.opacity(0.2), radius: 1.5)
            .frame(width: 36, height: 36)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(Circle())
        .position(arc.point(first + Double(index + 1) * step, radius: ring.radius))
        .accessibilityLabel("Recent Color")
      }
    }
    .modifier(Lit(shape: whole, part: .color))
  }
}

/** Text set along an arc, each letter turned to follow it, reading the right way round whichever
 * way the arc faces, centered on \a middle and shrunk to fit \a length. */
private struct CurvedText: View {
  let text: String
  let arc: Arc
  let radius: CGFloat
  let middle: Double
  /** Along the arc, in points. */
  let length: CGFloat
  var size: CGFloat = 12
  var color: Color = .primary

  var body: some View {
    let (letters, font) = layout()
    /* Left to right across the top of a ring is clockwise; across its bottom, the other way. */
    let direction: Double = sin(middle) < 0 ? 1 : -1
    let total = letters.last.map { $0.offset + $0.width } ?? 0
    ZStack {
      ForEach(Array(letters.enumerated()), id: \.offset) { _, letter in
        let angle = middle + direction * Double(letter.offset + letter.width / 2 - total / 2) / Double(radius)
        Text(String(letter.character))
          .font(Font(font))
          .foregroundStyle(color)
          .fixedSize()
          .rotationEffect(arc.upright(angle, middle: middle))
          .position(arc.point(angle, radius: radius))
      }
    }
    .allowsHitTesting(false)
    .accessibilityElement()
    .accessibilityLabel(text)
  }

  /** Each letter and where it starts along the line, smaller, then cut short, until it fits. */
  private func layout() -> ([(character: Character, offset: CGFloat, width: CGFloat)], UIFont) {
    var text = text
    var size = self.size
    while true {
      let font = UIFont.systemFont(ofSize: size, weight: .semibold)
      var offset: CGFloat = 0
      var letters: [(Character, CGFloat, CGFloat)] = []
      for character in text {
        let width = (String(character) as NSString).size(withAttributes: [.font: font]).width
        letters.append((character, offset, width))
        offset += width
      }
      if offset <= length || text.count <= 2 { return (letters, font) }
      if size > 10 { size -= 0.5 }
      else { text = String(text.dropLast(text.hasSuffix("…") ? 2 : 1)) + "…" }
    }
  }
}

/** One arc of commands, together on one stretch of glass, each place as long as its title, the
 * titles curved along it, hairlines between them: undo and redo first, then the context menu's
 * commands for what is selected. A submenu opens its commands in their place, and Back goes up. */
private struct ArcCommandRow: View {
  let arc: Arc
  let ring: Ring
  private var palette: SqueezePalette { .shared }

  /** Each entry's start and length along the arc, in radians, centered where the arcs face. */
  private var places: [(entry: SqueezePalette.CommandEntry, start: Double, length: Double)] {
    let radius = Double(ring.radius)
    let gap = Double(SqueezePalette.commandGap) / radius
    var lengths = ring.commands.map { Double(SqueezePalette.commandWidth($0)) / radius }
    let gaps = gap * Double(max(0, lengths.count - 1))
    /* Stretched to fill the arc, each by its share. */
    let natural = lengths.reduce(0, +)
    let room = ring.end - ring.start - gaps
    if natural > 0, natural < room { lengths = lengths.map { $0 * room / natural } }
    let total = lengths.reduce(0, +) + gaps
    var angle = ring.middleAngle - total / 2
    return zip(ring.commands, lengths).map { entry, length in
      defer { angle += length + gap }
      return (entry, angle, length)
    }
  }

  var body: some View {
    let places = self.places
    let width = ring.thickness - 6
    let cap = Double(width / 2) / Double(ring.radius)
    ZStack {
      if let first = places.first, let last = places.last {
        let band = ArcBand(center: arc.center, radius: ring.radius, thickness: width,
                           start: first.start + cap, end: last.start + last.length - cap)
        Color.clear
          .panelGlass(in: band)
          .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
      }
      ForEach(Array(places.enumerated()), id: \.offset) { index, place in
        let middle = place.start + place.length / 2
        let shape = ArcBand(center: arc.center, radius: ring.radius, thickness: width,
                            start: place.start + cap, end: place.start + place.length - cap)
        if index > 0 {
          /* A hairline between places. */
          Capsule()
            .fill(Color.primary.opacity(0.18))
            .frame(width: 1, height: width - 14)
            .rotationEffect(.radians(place.start - Double(SqueezePalette.commandGap) / 2 / Double(ring.radius) + .pi / 2))
            .position(arc.point(place.start - Double(SqueezePalette.commandGap) / 2 / Double(ring.radius),
                                radius: ring.radius))
            .allowsHitTesting(false)
        }
        content(place.entry, middle: middle, length: CGFloat(place.length) * ring.radius, shape: shape)
      }
    }
    .animation(SqueezePalette.motion(.spring(response: 0.3, dampingFraction: 0.86)), value: palette.commandPath.count)
  }

  @ViewBuilder
  private func content(_ entry: SqueezePalette.CommandEntry, middle: Double, length: CGFloat, shape: ArcBand) -> some View {
    switch entry {
      case .undo, .redo:
        let undo = entry == .undo
        icon(undo ? "arrow.uturn.backward" : "arrow.uturn.forward", middle: middle)
          .opacity((undo ? palette.canUndo : palette.canRedo) ? 1 : 0.35)
          .contentShape(shape)
          .onTapGesture { if undo { palette.undo() } else { palette.redo() } }
          .hoverHighlight(shape)
          .accessibilityLabel(undo ? "Undo" : "Redo")
          .accessibilityAddTraits(.isButton)
      case .menu(let route):
        /* The full menu, for those that did not fit. */
        Menu {
          BlenderMenuItems(route: route)
        } label: {
          Image(systemName: "ellipsis")
            .font(.system(size: 15, weight: .semibold))
            .rotationEffect(arc.upright(middle, middle: ring.middleAngle))
            .frame(width: max(ring.thickness, length), height: ring.thickness)
            .contentShape(Rectangle())
        }
        .tint(.primary)
        .position(arc.point(middle, radius: ring.radius))
        .accessibilityLabel("All Commands")
      case .back:
        title("‹ Back", middle: middle, length: length)
          .contentShape(shape)
          .onTapGesture { palette.commandsBack() }
          .hoverHighlight(shape)
          .accessibilityAddTraits(.isButton)
      case .action(let action):
        title(action.title, middle: middle, length: length)
          .contentShape(shape)
          .onTapGesture {
            Haptics.selection()
            palette.runAction?(action)
            palette.close()
          }
          .hoverHighlight(shape)
          .accessibilityAddTraits(.isButton)
      case .group(let group):
        groupView(group, middle: middle, length: length)
      case .item(let item) where SqueezePalette.iconOnly(item) != nil:
        Image(uiImage: SqueezePalette.iconOnly(item)!.withRenderingMode(.alwaysTemplate))
          .resizable()
          .scaledToFit()
          .frame(width: 18, height: 18)
          .foregroundStyle(item.destructive ? Color.red : Color.primary)
          .rotationEffect(arc.upright(middle, middle: ring.middleAngle))
          .frame(width: ring.thickness, height: ring.thickness)
          .position(arc.point(middle, radius: ring.radius))
          .opacity(item.disabled ? 0.4 : 1)
          .contentShape(shape)
          .onTapGesture { palette.activate(item) }
          .allowsHitTesting(!item.disabled)
          .hoverHighlight(shape)
          .accessibilityLabel(item.title)
          .accessibilityAddTraits(.isButton)
      case .item(let item):
        /* A submenu open on the arc further out is lit. */
        let open = palette.isOpen(item)
        title(item.submenu ? item.title + " ›" : item.title, middle: middle, length: length,
              color: open ? .white : item.destructive ? .red : .primary)
          .background { if open { Color.clear.panelGlass(.tinted(.blue), in: shape) } }
          .opacity(item.disabled ? 0.4 : 1)
          .contentShape(shape)
          .onTapGesture { palette.activate(item) }
          .allowsHitTesting(!item.disabled)
          .hoverHighlight(shape)
          .accessibilityAddTraits(.isButton)
    }
  }

  /** A group's commands side by side in its place, each as long as its words, a fainter line
   * between them than between places. */
  private func groupView(_ group: SqueezePalette.CommandGroup, middle: Double, length: CGFloat) -> some View {
    let font = UIFont.systemFont(ofSize: 12, weight: .semibold)
    let widths = group.labels.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) + 12 }
    let total = widths.reduce(0, +)
    let radius = Double(ring.radius)
    let span = Double(length) / radius
    var starts: [Double] = []
    var angle = middle - span / 2
    for width in widths {
      starts.append(angle)
      angle += span * Double(width / total)
    }
    return ZStack {
      ForEach(Array(group.items.enumerated()), id: \.offset) { index, item in
        let start = starts[index], piece = span * Double(widths[index] / total)
        let shape = ArcBand(center: arc.center, radius: ring.radius, thickness: ring.thickness - 6,
                            start: start + 0.004, end: start + piece - 0.004)
        if index > 0 {
          Capsule()
            .fill(Color.primary.opacity(0.1))
            .frame(width: 1, height: ring.thickness - 22)
            .rotationEffect(.radians(start + .pi / 2))
            .position(arc.point(start, radius: ring.radius))
            .allowsHitTesting(false)
        }
        CurvedText(text: group.labels[index], arc: arc, radius: ring.radius, middle: start + piece / 2,
                   length: CGFloat(piece) * ring.radius - 6)
          .opacity(item.disabled ? 0.4 : 1)
          .contentShape(shape)
          .onTapGesture { palette.activate(item) }
          .allowsHitTesting(!item.disabled)
          .hoverHighlight(shape)
          .accessibilityElement()
          .accessibilityLabel(item.title)
          .accessibilityAddTraits(.isButton)
      }
    }
  }

  private func icon(_ symbol: String, middle: Double) -> some View {
    Image(systemName: symbol)
      .font(.system(size: 15, weight: .semibold))
      .rotationEffect(arc.upright(middle, middle: ring.middleAngle))
      .frame(width: ring.thickness, height: ring.thickness)
      .position(arc.point(middle, radius: ring.radius))
  }

  private func title(_ text: String, middle: Double, length: CGFloat, color: Color = .primary) -> some View {
    CurvedText(text: text, arc: arc, radius: ring.radius, middle: middle, length: length - 16, color: color)
  }
}

/** \} */

#endif






