# Native UI

Blender's interface drawn by a platform's own toolkit, such as SwiftUI on the iPad or Jetpack
Compose on Android, with Blender running as usual underneath. This folder holds what such an
interface, a *shell*, and Blender share: the protocol between them.

## How it works

Blender describes what a shell shows as **views**: the Properties editor, the tool settings, the
viewport's shading. A view is a tree of **nodes** with stable keys. Most nodes are controls
(panels, numbers, switches, choices, lists, buttons, menus), which a shell draws with its own
controls, the same way for every view.

1. The shell **subscribes** to a view it shows, with parameters such as the Properties tab.
2. Blender builds the view when notifiers say what it shows changed, at most as often as the
   view asks, and sends it whole once, then only the nodes that changed: each node is hashed as
   it is written, and only nodes whose bytes changed are sent.
3. The shell sends **commands** aimed at a node: set a value, run a button, open a panel,
   activate a row of a list. Each one is answered, with an error if it failed. A drag is sent as
   `Update` phases and an `End` (or `Cancel`), which Blender makes one undo step of.
4. The shell unsubscribes while the view is hidden, and Blender stops building it.

Nothing happens while nothing changes: an idle Blender checks one empty queue.

Everything the interface shows of Blender comes this way, and everything it asks of Blender goes
this way, but for two kinds of things that are not views: input, such as a stylus hovering or an
asset dragged over the viewport, and pixels, such as the Image Editor's picture, which `WM_native_ui.h`
passes on directly.

## Views

| View | What it is |
|---|---|
| `properties` | The Properties editor, a tab at a time, and the Preferences' sections. |
| `tool_settings` | The active tool's settings. |
| `toolbar` | Around the viewport: the mode, tools, undo, transform settings, the brush's direction and values, quick actions, the text being typed, and where Blender draws what the interface keeps clear of. |
| `brushes` | The brushes the mode offers. |
| `redo`, `dialog` | The last operation's settings, and an operator's asked for before it runs. |
| `operators` | Shows nothing: `Invoke` runs the operator its target names. |
| `menu`, `popup` | One of Blender's menus, by its route; and what Blender asks to show in place of its popups. |
| `timeline`, `timeline_keys` | The frame and its range, and the keys. |
| `assets` | The assets the asset pane offers. |
| `outliner` | The scene's collections and objects. |
| `preferences_list` | The add-ons and keymaps. |
| `settings`, `render`, `volume` | The interface's settings Blender keeps, a render's state, and the scene shown as 3D geometry. |
| `graph`, `storyboard`, `image`, `nodes` | Canvases: the curve editor, storyboard, Image Editor and node editor. |

A canvas is sent as `Record`s, one node for each of its items, with its values as typed parameters
and lists of items as children, so a change resends only the items it changed. Its state and its
edits are commands with parameters.

## Files

- `protocol.fbs`: the protocol, in FlatBuffers' schema language. Read its comments first.
- `generate.py`: makes a language's code from it with `flatc`. Blender's build does this for C++
  and Swift with FlatBuffers from its libraries, so nothing generated is checked in.
- `view_tree.hh`: how Blender's code writes a view, a node at a time.
- `../WM_native_ui_views.hh`: how an editor adds a view type.
- `../WM_native_ui.h`: the C API a shell calls, from Swift directly or from Kotlin through JNI.
- `tests/`: the view tree's tests, and `kotlin_check.py`, which compiles and runs the generated
  Kotlin code as a shell would use it.
- `timings.py`: compares the timings of two recordings, to check a change made nothing slower.

## Writing a shell

A shell needs FlatBuffers' runtime for its language and the generated code for it.

```
subscription = WM_native_ui_subscribe(Subscribe{view: "properties", params: [tab: "OBJECT"]})

on Blender's "updates published" wake-up, on the interface's thread:
  while buffer = WM_native_ui_take_updates():
    for update in Updates(buffer).updates:
      view = views[update.subscription]
      if update.reset: view.clear()
      else if update.version != view.version + 1: resubscribe(view)   # one went missing
      for each node buffer: copy it, and keep it by its node's key  # it outlives the buffer
      for each children list: set the parent's children
      for each removed key: forget the node
    for ack in Updates(buffer).acks: settle the command's pending value, show its error
    WM_native_ui_buffer_free(buffer)

on a control's change:
  show the new value at once, then
  WM_native_ui_send(Commands{[Command{subscription, target: node.key, op: Set, value, phase}]})
```

Draw each node by its content type: `Panel` as a collapsible section with its children of the
roles `Name`, `Visibility` and `Header` beside its title, `Group` by its layout (`Row` for a vector's components, `Joined`
for toggles drawn together), `Number` as a field to drag or type (or a slider), `Choice` by its
style, `List` with its `Row` children, and so on. A node's `role` says what it is to its parent,
such as a component's lock or a row's mode, so a shell can show it with what it belongs to.

The iPad's shell is `apple_ios/swift/NativeViews.swift` (the protocol, operators and canvases) and
`NativePanels.swift`, `NativeControls.swift`, `NativeLists.swift` and `NativeToolSettings.swift`
(the controls). `ShellModel.swift` reads the toolbar.

## Checking views without a screen

With `BLENDER_NATIVE_UI_VIEWS=properties:OBJECT` in its environment, the iPad's shell writes
that view as text to `native_ui_record/views/` in its temporary folder whenever it changes: a view
with its tab, `menu:VIEW3D_MT_add` for a menu, or a parameter as `preferences_list:list=addons`.
With `BLENDER_NATIVE_UI_COMMANDS` too, such as `panel:OBJECT_PT_relations open;tabs set MODIFIER`,
it sends those commands one at a time and writes the view after each: to another view as
`operators>MESH_OT_primitive_cube_add invoke`, with parameters as `state set tree=SHADER`.

With `BLENDER_NATIVE_UI_RECORD`, Blender and the shell record how long each part took, in
`native_ui_record/timings.jsonl` and `interface_timings.jsonl`; `timings.py` summarizes and
compares recordings.
