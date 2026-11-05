/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup edinterface
 *
 * Views of Blender's panels, see `interface_native.hh`: the Properties editor, the tool settings,
 * the viewport's shading and overlays, the Preferences, the last operation, an operator's dialog
 * and the node editor. Their commands are edits of what their nodes show.
 *
 * Parameters of `properties` and `tool_settings`: `tab`, such as `OBJECT`, `TOOL`, `SHADING` or a
 * Preferences section, and `properties`, set for the Properties editor's own Tool tab rather than
 * the tool settings.
 */

#include "WM_api.hh"
#include "WM_types.hh"

#include "UI_interface.hh"

#include "interface_native.hh"

namespace blender::ui {

namespace {

using namespace wm::native_ui;
using namespace native;

std::string text_of(const protocol::Command &command)
{
  const protocol::TextValue *value = command.value_as_TextValue();
  return value && value->value() ? value->value()->str() : "";
}

CommandResult result(const std::string &error)
{
  return error.empty() ? CommandResult::Done : CommandResult::Failed;
}

/**
 * What \a command asks of a control editing a property or choosing a data-block, as \a request
 * gives it, or false for what it does not do. The updates of a drag are one step to undo, from
 * the first to the last.
 */
bool control_request(PanelsData &data,
                     const Edit &edit,
                     const protocol::Command &command,
                     EditRequest &request)
{
  request.edit = &edit;
  request.command = &command;
  const protocol::Op op = command.op();
  if (edit.kind == Edit::Kind::Picker) {
    switch (op) {
      case protocol::Op::Set:
        request.action = "select";
        request.text = text_of(command);
        return true;
      case protocol::Op::Add: {
        /* New, or a font from its files: its regular, bold, italic and bold italic faces. */
        const protocol::TextsValue *files = command.value_as_TextsValue();
        if (files == nullptr || files->value() == nullptr || files->value()->size() == 0) {
          request.action = "new";
          return true;
        }
        request.action = "load_font";
        request.text = files->value()->Get(0)->str();
        if (files->value()->size() == 4) {
          const char *slots[] = {"font", "font_bold", "font_italic", "font_bold_italic"};
          for (int i = 0; i < 4; i++) {
            request.family.append({slots[i], files->value()->Get(i)->str()});
          }
        }
        return true;
      }
      case protocol::Op::Remove:
        request.action = "unlink";
        return true;
      case protocol::Op::Rename:
        request.action = "rename";
        request.text = text_of(command);
        return true;
      case protocol::Op::Invoke:
        /* `fake_user` or `single_user`. */
        request.action = text_of(command);
        return true;
      default:
        return false;
    }
  }
  if (edit.kind == Edit::Kind::Ramp) {
    switch (op) {
      case protocol::Op::Activate:
        request.action = "activate";
        return true;
      case protocol::Op::Add:
        request.action = "add";
        return true;
      case protocol::Op::Remove:
        request.action = "remove";
        return true;
      case protocol::Op::Set:
        break;
      default:
        return false;
    }
  }
  else if (edit.kind != Edit::Kind::Property) {
    return false;
  }
  if (ELEM(op,
           protocol::Op::KeyframeInsert,
           protocol::Op::KeyframeDelete,
           protocol::Op::KeyframesClear))
  {
    /* Of all of an array's components when asked, or when it has no others. */
    const protocol::BoolValue *all = command.value_as_BoolValue();
    request.action = op == protocol::Op::KeyframeInsert ? "insert" :
                     op == protocol::Op::KeyframeDelete ? "delete" :
                                                          "clear";
    request.action += (all && all->value()) || !edit.component ? "_all" : "_single";
    return true;
  }
  if (op != protocol::Op::Set) {
    return false;
  }
  if (command.phase() == protocol::Phase::Once) {
    data.dragging = false;
    return true;
  }
  if (!data.dragging || command.phase() == protocol::Phase::Begin) {
    data.interaction++;
    data.dragging = true;
  }
  request.interaction = "native-" + std::to_string(data.interaction);
  request.phase = command.phase() == protocol::Phase::End    ? "end" :
                  command.phase() == protocol::Phase::Cancel ? "cancel" :
                                                               "update";
  data.dragging = !ELEM(command.phase(), protocol::Phase::End, protocol::Phase::Cancel);
  return true;
}

/* -------------------------------------------------------------------- */
/** \name Panels
 * \{ */

std::unique_ptr<ViewData> panels_create()
{
  return std::make_unique<PanelsData>();
}

void panels_build(bContext *C, const Params &params, ViewData *view_data, ViewBuilder &builder)
{
  PanelsData &data = static_cast<PanelsData &>(*view_data);
  if (data.tab.empty()) {
    data.tab = params.text("tab").value_or("OBJECT");
    data.tool_tab = params.flag("properties");
  }
  panels_write(C, data, builder);
}

CommandResult panels_command(bContext *C,
                             const Params & /*params*/,
                             ViewData *view_data,
                             const protocol::Command &command,
                             std::string &r_error)
{
  PanelsData &data = static_cast<PanelsData &>(*view_data);
  const std::string target = command.target()->str();
  const protocol::Op op = command.op();
  EditRequest request;
  request.command = &command;
  const auto run = [&](const Edit &edit) {
    request.edit = &edit;
    r_error = panels_edit(C, data, request);
    return result(r_error);
  };

  if (target == "tabs" && op == protocol::Op::Set) {
    data.tab = text_of(command);
    return CommandResult::Done;
  }

  if (const PanelState *panel = data.panels.lookup_ptr(target)) {
    if (ELEM(op, protocol::Op::Open, protocol::Op::Close)) {
      const bool open = op == protocol::Op::Open;
      if (panel->outer) {
        std::set<std::string> &expanded = data.expanded_panels();
        open ? (void)expanded.insert(panel->id) : (void)expanded.erase(panel->id);
      }
      else {
        PanelsData::subpanels().lookup_or_add_default(data.tab).add_overwrite(panel->id, open);
      }
      return CommandResult::Done;
    }
    if (op == protocol::Op::Move) {
      /* A stack's panel, such as a modifier, to its place in the stack. */
      request.action = "reorder";
      request.to = std::atoll(text_of(command).c_str());
      return run({Edit::Kind::Property, panel->id});
    }
    r_error = "Panels only open, close and move";
    return CommandResult::Failed;
  }

  if (const Row *row = data.rows.lookup_ptr(target)) {
    const Edit *list = data.edits.lookup_ptr(row->list);
    if (list == nullptr) {
      r_error = "The list is no longer there";
      return CommandResult::Failed;
    }
    request.index = row->index;
    switch (op) {
      case protocol::Op::Activate:
        request.action = "activate";
        return run(*list);
      case protocol::Op::Rename:
        if (!row->name.empty()) {
          /* By the name Blender draws on it. */
          return run({Edit::Kind::Property, list->panel, row->name, row->name_occurrence});
        }
        request.action = "rename";
        request.text = text_of(command);
        return run(*list);
      case protocol::Op::Move: {
        /* Before the row named, or to the end. */
        request.action = "move";
        if (const Row *before = data.rows.lookup_ptr(text_of(command))) {
          request.to = before->index;
        }
        else {
          request.to = 0;
          for (const Row &other : data.rows.values()) {
            request.to += other.list == row->list;
          }
        }
        return run(*list);
      }
      default:
        r_error = "Rows are activated, renamed and moved";
        return CommandResult::Failed;
    }
  }

  const Edit *edit = data.edits.lookup_ptr(target);
  if (edit == nullptr) {
    r_error = "Nothing to do for " + target;
    return CommandResult::Failed;
  }
  switch (edit->kind) {
    case Edit::Kind::List:
      if (ELEM(op, protocol::Op::Add, protocol::Op::Remove)) {
        const std::string &key = op == protocol::Op::Add ? edit->add : edit->remove;
        if (key.empty()) {
          r_error = "The list cannot do that";
          return CommandResult::Failed;
        }
        return run({Edit::Kind::Operator, edit->panel, key});
      }
      break;
    case Edit::Kind::Call:
      if (op == protocol::Op::Invoke) {
        /* Run as from the interface, on what is active. */
        return WM_operator_name_call(
                   C, edit->key.c_str(), wm::OpCallContext::InvokeDefault, nullptr, nullptr) &
                       OPERATOR_FINISHED ?
                   CommandResult::Done :
                   CommandResult::Failed;
      }
      break;
    case Edit::Kind::OperatorMenu:
      if (op == protocol::Op::Set) {
        return run(*edit);
      }
      break;
    case Edit::Kind::Operator:
      if (op == protocol::Op::Set && !edit->add.empty()) {
        /* A physics' switch: turned on, its settings open. */
        const protocol::BoolValue *on = command.value_as_BoolValue();
        if (on && on->value()) {
          data.expanded_panels().insert(edit->add);
        }
      }
      if (ELEM(op, protocol::Op::Set, protocol::Op::Invoke)) {
        return run(*edit);
      }
      break;
    default:
      if (control_request(data, *edit, command, request)) {
        return run(*edit);
      }
      break;
  }
  r_error = "Not something this control does";
  return CommandResult::Failed;
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Operators
 *
 * The last operation's properties, to adjust it, and an operator's asked for before it runs, in
 * place of Blender's dialog. The top node, keyed by the operation, takes `Invoke` with `dismiss`,
 * `confirm` or `cancel`; its controls are set as Properties' are.
 * \{ */

template<void (*write)(bContext *, PanelsData &, ViewBuilder &)>
void operator_build(bContext *C, const Params & /*params*/, ViewData *view_data, ViewBuilder &builder)
{
  write(C, static_cast<PanelsData &>(*view_data), builder);
}

template<std::string (*edit)(bContext *, PanelsData &, const EditRequest &)>
CommandResult operator_command(bContext *C,
                               const Params & /*params*/,
                               ViewData *view_data,
                               const protocol::Command &command,
                               std::string &r_error)
{
  PanelsData &data = static_cast<PanelsData &>(*view_data);
  EditRequest request;
  if (command.target()->string_view() == data.identity) {
    if (command.op() != protocol::Op::Invoke) {
      r_error = "An operation is dismissed, confirmed or cancelled";
      return CommandResult::Failed;
    }
    request.action = text_of(command);
  }
  else {
    const Edit *control = data.edits.lookup_ptr(command.target()->str());
    if (control == nullptr || command.op() != protocol::Op::Set ||
        !control_request(data, *control, command, request))
    {
      r_error = "Not something this control does";
      return CommandResult::Failed;
    }
  }
  r_error = edit(C, data, request);
  return result(r_error);
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name The Node Editor
 *
 * The `nodes` view, see #native::nodes_write. `Set` of `state` with parameters says which tree
 * to show; `Invoke` of `edit` with parameters makes an edit of the tree, such as moving nodes;
 * its controls take commands as Properties' do.
 * \{ */

CommandResult nodes_command(bContext *C,
                            const Params & /*params*/,
                            ViewData *view_data,
                            const protocol::Command &command,
                            std::string &r_error)
{
  NodesData &data = static_cast<NodesData &>(*view_data);
  const std::string_view target = command.target()->string_view();
  if (target == "state" && command.op() == protocol::Op::Set) {
    data.state = params_dictionary(command.params());
    data.composite = data.state->lookup_str("tree").value_or("") == "COMPOSITOR";
    return CommandResult::Done;
  }
  if (target == "edit" && command.op() == protocol::Op::Invoke) {
    std::unique_ptr<io::serialize::DictionaryValue> edit = params_dictionary(command.params());
    data.ack = edit->lookup_int("sequence").value_or(data.ack);
    for (const io::serialize::DictionaryValue::Item &item : data.state->elements()) {
      if (edit->lookup(item.first) == nullptr) {
        edit->append(item.first, item.second);
      }
    }
    data.error = nodes_edit(C, data, *edit);
    r_error = data.error;
    return result(r_error);
  }
  EditRequest request;
  const Edit *control = data.edits.lookup_ptr(std::string(target));
  if (control == nullptr || !control_request(data, *control, command, request)) {
    r_error = "Not something this control does";
    return CommandResult::Failed;
  }
  r_error = nodes_edit_control(C, data, request);
  return result(r_error);
}

/** \} */

}  // namespace

void native_views_register()
{
  ViewType properties;
  properties.name = "properties";
  /* At most four times a second while changes keep coming. */
  properties.min_interval = 0.25;
  properties.create = panels_create;
  properties.build = panels_build;
  properties.command = panels_command;
  view_type_add(properties);

  /* The tool's settings, which the top bar shows: at once when the tool, its brush or the mode
   * changes, and not as the scene does, as while sculpting. */
  ViewType tool_settings = properties;
  tool_settings.name = "tool_settings";
  tool_settings.min_interval = 0.0;
  tool_settings.notifiers = {
      NC_WM, NC_SCENE, NC_BRUSH, NC_TEXTURE, NC_MATERIAL, NC_SPACE, NC_WORKSPACE};
  view_type_add(std::move(tool_settings));

  ViewType redo;
  redo.name = "redo";
  redo.create = panels_create;
  redo.build = operator_build<redo_write>;
  redo.command = operator_command<redo_edit>;
  redo.min_interval = 0.1;
  view_type_add(std::move(redo));

  ViewType dialog;
  dialog.name = "dialog";
  dialog.create = panels_create;
  dialog.build = operator_build<dialog_write>;
  dialog.command = operator_command<dialog_edit>;
  view_type_add(std::move(dialog));

  ViewType nodes;
  nodes.name = "nodes";
  /* Four times a second at most, as while a node is dragged. */
  nodes.min_interval = 0.25;
  nodes.notifiers = {NC_NODE, NC_MATERIAL, NC_OBJECT, NC_SCENE, NC_WM, NC_SPACE, NC_WORLD, NC_TEXTURE};
  nodes.create = []() -> std::unique_ptr<ViewData> { return std::make_unique<NodesData>(); };
  nodes.build = [](bContext *C, const Params & /*params*/, ViewData *data, ViewBuilder &builder) {
    nodes_write(C, static_cast<NodesData &>(*data), builder);
  };
  nodes.command = nodes_command;
  view_type_add(std::move(nodes));
}

}  // namespace blender::ui
