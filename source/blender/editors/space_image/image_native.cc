/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup spimage
 *
 * The Image Editor's picture for a native interface, which draws it: the images to choose from,
 * the one shown, its pixels as they change while painting and the UVs over it. The image shown
 * follows the texture being painted, as the Image Editor follows the active paint slot.
 */

#include <algorithm>
#include <array>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>

#include "MEM_guardedalloc.h"

#include "BLI_listbase.h"
#include "BLI_math_vector_types.hh"
#include "BLI_serialize.hh"
#include "BLI_string.h"

#include "DNA_image_types.h"
#include "DNA_material_types.h"
#include "DNA_mesh_types.h"
#include "DNA_object_types.h"
#include "DNA_brush_types.h"
#include "DNA_scene_types.h"
#include "DNA_screen_types.h"
#include "DNA_space_types.h"

#include "BKE_attribute.hh"
#include "BKE_brush.hh"
#include "BKE_context.hh"
#include "BKE_editmesh.hh"
#include "BKE_image.hh"
#include "BKE_image_partial_update.hh"
#include "BKE_lib_id.hh"
#include "BKE_main.hh"
#include "BKE_material.hh"
#include "BKE_mesh.hh"
#include "BKE_paint.hh"
#include "BKE_paint_types.hh"
#include "BKE_report.hh"
#include "BKE_screen.hh"

#include "IMB_colormanagement.hh"
#include "IMB_imbuf.hh"
#include "IMB_imbuf_types.hh"

#include "ED_image_native.hh"
#include "ED_paint.hh"
#include "ED_undo.hh"

#include "WM_api.hh"
#include "WM_types.hh"

#include "bmesh.hh"

namespace blender::ui {
/** PNG of an ID's preview, as Properties' pickers show it; empty until rendered. */
std::string native_id_preview_path(bContext *C, ID *id);
}  // namespace blender::ui

namespace blender::ed::image {

using namespace io::serialize;
using namespace bke::image::partial_update;

namespace {

/** The image chosen in the native editor, and the paint slot's, to follow it as it changes. */
struct NativeImageChoice {
  std::string chosen;
  int64_t pick = -1;
  std::string slot_seen;
  bool slot_known = false;
};
NativeImageChoice native_choice;

/** The pictures are sent no larger than this along either side. */
constexpr int native_image_max_side = 2048;

std::unique_ptr<Value> parse(const std::string &json)
{
  std::istringstream stream(json);
  return JsonFormatter().deserialize(stream);
}

/** The texture being painted on, as the Image Editor shows it in Texture Paint. */
Image *paint_image(bContext *C)
{
  Object *ob = CTX_data_active_object(C);
  Scene *scene = CTX_data_scene(C);
  if (!ob || !scene || !(ob->mode & OB_MODE_TEXTURE_PAINT)) {
    return nullptr;
  }
  const ImagePaintSettings &imapaint = scene->toolsettings->imapaint;
  if (imapaint.mode == IMAGEPAINT_MODE_IMAGE) {
    return imapaint.canvas;
  }
  Material *ma = BKE_object_material_get(ob, ob->actcol);
  if (ma && ma->texpaintslot && ma->paint_active_slot < ma->tot_slots) {
    return ma->texpaintslot[ma->paint_active_slot].ima;
  }
  return nullptr;
}

/** The image to show: the one chosen last, or the paint slot's once that changes. */
Image *shown_image(bContext *C, const DictionaryValue *state)
{
  Main *bmain = CTX_data_main(C);
  if (state) {
    const int64_t pick = state->lookup_int("pick").value_or(-1);
    if (pick != native_choice.pick) {
      native_choice.pick = pick;
      native_choice.chosen = state->lookup_str("image").value_or("");
    }
  }
  Image *slot = paint_image(C);
  const std::string slot_name = slot ? slot->id.name + 2 : "";
  if (!native_choice.slot_known || slot_name != native_choice.slot_seen) {
    native_choice.slot_known = true;
    native_choice.slot_seen = slot_name;
    if (slot) {
      native_choice.chosen = slot_name;
    }
  }
  if (!native_choice.chosen.empty()) {
    if (ID *id = BKE_libblock_find_name(bmain, ID_IM, native_choice.chosen.c_str())) {
      return reinterpret_cast<Image *>(id);
    }
  }
  return slot ? slot : static_cast<Image *>(bmain->images.first);
}

const char *source_name(const Image &ima)
{
  switch (ima.source) {
    case IMA_SRC_GENERATED:
      return "GENERATED";
    case IMA_SRC_VIEWER:
      return "VIEWER";
    case IMA_SRC_SEQUENCE:
    case IMA_SRC_MOVIE:
      return "MOVIE";
    case IMA_SRC_TILED:
      return "TILED";
    default:
      return "FILE";
  }
}

/** Kept for the session, as Blender's own would be: the Image Editor that strokes paint in. */
ScrArea *native_image_area(bContext *C)
{
  static ScrArea *area = nullptr;
  if (area == nullptr) {
    area = MEM_new<ScrArea>("native image editor");
    area->spacetype = SPACE_IMAGE;
    area->type = BKE_spacetype_from_id(SPACE_IMAGE);
    SpaceLink *link = area->type->create(area, CTX_data_scene(C));
    BLI_addtail(&area->spacedata, link);
    std::swap(area->regionbase, link->regionbase);
    for (ARegion &region : area->regionbase) {
      region.runtime->type = BKE_regiontype_from_id(area->type, region.regiontype);
    }
  }
  return area;
}

/**
 * The hidden Image Editor as the context's area while a stroke paints, in Paint mode on \a image.
 * Its region's pixels are the image's, so the points sent are where they paint.
 */
struct ImageSpaceContext {
  bContext *C;
  ScrArea *previous_area;
  ARegion *previous_region;

  ImageSpaceContext(bContext *context, Image *image, const int width, const int height)
      : C(context)
  {
    previous_area = CTX_wm_area(C);
    previous_region = CTX_wm_region(C);
    ScrArea *area = native_image_area(C);
    SpaceImage *sima = static_cast<SpaceImage *>(area->spacedata.first);
    sima->image = image;
    sima->mode = SI_MODE_PAINT;
    /* Other editors update as it paints, as with Blender's Lock. */
    sima->lock = true;
    ARegion *region = BKE_area_find_region_type(area, RGN_TYPE_WINDOW);
    region->winx = std::max(1, width);
    region->winy = std::max(1, height);
    region->v2d.mask = {0, region->winx, 0, region->winy};
    region->v2d.cur = {0.0f, 1.0f, 0.0f, 1.0f};
    CTX_wm_area_set(C, area);
    CTX_wm_region_set(C, region);
  }

  ~ImageSpaceContext()
  {
    CTX_wm_area_set(C, previous_area);
    CTX_wm_region_set(C, previous_region);
  }
};

/** The 2D painting brush, which Texture Paint also paints with. */
Brush *paint_brush(bContext *C, Paint **r_paint)
{
  Scene *scene = CTX_data_scene(C);
  *r_paint = scene ? &scene->toolsettings->imapaint.paint : nullptr;
  return *r_paint ? BKE_paint_brush(*r_paint) : nullptr;
}

/** A number, which JSON may have written without a fraction. */
double number(const Value &value)
{
  if (const auto *real = value.as_double_value()) {
    return real->value();
  }
  if (const auto *integer = value.as_int_value()) {
    return double(integer->value());
  }
  return 0.0;
}

double lookup_number(const DictionaryValue &query, const StringRef key, const double fallback)
{
  for (const auto &item : query.elements()) {
    if (item.first == key) {
      return number(*item.second);
    }
  }
  return fallback;
}

std::vector<float> lookup_numbers(const DictionaryValue &query, const StringRef key)
{
  std::vector<float> numbers;
  if (const ArrayValue *values = query.lookup_array(key)) {
    for (const auto &value : values->elements()) {
      numbers.push_back(float(number(*value)));
    }
  }
  return numbers;
}

/** Each point's x, y and pressure. */
std::vector<std::array<float, 3>> stroke_points(const DictionaryValue &query)
{
  const std::vector<float> numbers = lookup_numbers(query, "points");
  std::vector<std::array<float, 3>> points;
  for (size_t i = 0; i + 2 < numbers.size(); i += 3) {
    points.push_back({numbers[i], numbers[i + 1], numbers[i + 2]});
  }
  return points;
}

std::string read_images(bContext *C, const DictionaryValue *state)
{
  Main *bmain = CTX_data_main(C);
  Image *shown = shown_image(C, state);
  Image *slot = paint_image(C);
  DictionaryValue result;
  auto images = result.append_array("images");
  for (Image &ima : bmain->images) {
    auto item = images->append_dict();
    item->append_str("name", ima.id.name + 2);
    item->append_str("source", source_name(ima));
    item->append_int("paint", &ima == slot);
    /* Rendered by a job the first time, and in a later snapshot once it is. */
    if (const std::string preview = ui::native_id_preview_path(C, &ima.id); !preview.empty()) {
      item->append_str("preview", preview);
    }
  }
  Object *ob = CTX_data_active_object(C);
  result.append_int("painting", ob && (ob->mode & OB_MODE_TEXTURE_PAINT));
  result.append_int("editing", ob && ob->type == OB_MESH && (ob->mode & OB_MODE_EDIT));
  if (shown) {
    auto image = result.append_dict("image");
    image->append_str("name", shown->id.name + 2);
    image->append_str("source", source_name(*shown));
    int width = 0, height = 0;
    ImageUser user = {};
    BKE_image_get_size(shown, &user, &width, &height);
    image->append_int("width", width);
    image->append_int("height", height);
    image->append_int("dirty", BKE_image_is_dirty(shown));
    image->append_int("packed", BKE_image_has_packedfile(shown));
    image->append_int("paint", shown == slot);
    image->append_int("float", (shown->flag & IMA_HIGH_BITDEPTH) != 0);
    image->append_str("colorspace", shown->colorspace_settings.name);
    /* Painted on as Blender's 2D painting can: not a render or a movie. */
    image->append_int("paintable", ELEM(shown->source, IMA_SRC_FILE, IMA_SRC_GENERATED, IMA_SRC_TILED));
  }
  /* Its brush, set up as Blender's Image Editor sets it up for Paint mode. */
  Paint *paint;
  if (!paint_brush(C, &paint) && paint) {
    BKE_paint_init(CTX_data_main(C), CTX_data_scene(C), PaintMode::Texture2D);
  }
  if (Brush *brush = paint_brush(C, &paint)) {
    auto item = result.append_dict("brush");
    item->append_str("name", brush->id.name + 2);
    item->append_int("size", BKE_brush_size_get(paint, brush));
    item->append_double("radius", BKE_brush_radius_get(paint, brush));
    item->append_double("strength", BKE_brush_alpha_get(paint, brush));
    auto color = item->append_array("color");
    const float *rgb = BKE_brush_color_get(paint, brush);
    for (int i = 0; i < 3; i++) {
      color->append_double(rgb[i]);
    }
  }
  std::ostringstream stream;
  JsonFormatter().serialize(stream, result);
  return stream.str();
}

std::optional<std::string> apply_edit(bContext *C, const DictionaryValue &query)
{
  Main *bmain = CTX_data_main(C);
  const std::string action = query.lookup_str("action").value_or("");
  if (action == "new") {
    const std::string name = query.lookup_str("name").value_or("Untitled");
    const int width = std::clamp(int(query.lookup_int("width").value_or(1024)), 1, 16384);
    const int height = std::clamp(int(query.lookup_int("height").value_or(1024)), 1, 16384);
    float color[4] = {0.0f, 0.0f, 0.0f, 1.0f};
    if (const ArrayValue *values = query.lookup_array("color")) {
      int i = 0;
      for (const auto &value : values->elements()) {
        if (i < 4) {
          if (const auto *number = value->as_double_value()) {
            color[i] = float(number->value());
          }
          else if (const auto *integer = value->as_int_value()) {
            color[i] = float(integer->value());
          }
        }
        i++;
      }
    }
    const bool alpha = query.lookup_int("alpha").value_or(1) != 0;
    if (!alpha) {
      color[3] = 1.0f;
    }
    const std::string type = query.lookup_str("type").value_or("BLANK");
    const short gen_type = type == "UV_GRID"    ? IMA_GENTYPE_GRID :
                           type == "COLOR_GRID" ? IMA_GENTYPE_GRID_COLOR :
                                                  IMA_GENTYPE_BLANK;
    const bool floatbuf = query.lookup_int("float").value_or(0) != 0;
    /* Its one user is the editor showing it, as the Image Editor would be. */
    Image *ima = BKE_image_add_generated(bmain,
                                         width,
                                         height,
                                         name.c_str(),
                                         alpha ? 32 : 24,
                                         floatbuf,
                                         gen_type,
                                         color,
                                         false,
                                         false,
                                         false);
    if (!ima) {
      return std::nullopt;
    }
    BKE_image_signal(bmain, ima, nullptr, IMA_SIGNAL_USER_NEW_IMAGE);
    native_choice.chosen = ima->id.name + 2;
    WM_event_add_notifier(C, NC_IMAGE | NA_ADDED, ima);
    return "New Image";
  }
  if (action == "open") {
    /* A copy the native interface made, so kept in the document. */
    const std::string path = query.lookup_str("path").value_or("");
    Image *ima = path.empty() ? nullptr : BKE_image_load(bmain, path.c_str());
    if (!ima) {
      return std::nullopt;
    }
    ReportList reports;
    BKE_reports_init(&reports, RPT_STORE);
    BKE_image_packfiles(&reports, ima, ID_BLEND_PATH(bmain, &ima->id));
    BKE_reports_free(&reports);
    native_choice.chosen = ima->id.name + 2;
    WM_event_add_notifier(C, NC_IMAGE | NA_ADDED, ima);
    return "Open Image";
  }
  if (action == "brush") {
    Paint *paint;
    Brush *brush = paint_brush(C, &paint);
    if (!brush) {
      return std::nullopt;
    }
    const std::string key = query.lookup_str("key").value_or("");
    if (key == "color") {
      const std::vector<float> rgb = lookup_numbers(query, "value");
      if (rgb.size() >= 3) {
        BKE_brush_color_set(paint, brush, rgb.data());
      }
    }
    else if (key == "size") {
      BKE_brush_size_set(paint, brush, std::max(1, int(lookup_number(query, "value", 1.0) + 0.5)));
    }
    else if (key == "strength") {
      BKE_brush_alpha_set(
          paint, brush, std::clamp(float(lookup_number(query, "value", 1.0)), 0.0f, 1.0f));
    }
    BKE_brush_tag_unsaved_changes(brush);
    WM_event_add_notifier(C, NC_BRUSH | NA_EDITED, brush);
    return "";
  }
  Image *ima = shown_image(C, nullptr);
  if (!ima) {
    return std::nullopt;
  }
  if (action == "stroke") {
    const std::string phase = query.lookup_str("phase").value_or("");
    int width = 0, height = 0;
    ImageUser user = {};
    BKE_image_get_size(ima, &user, &width, &height);
    ImageSpaceContext space(C, ima, width, height);
    const std::vector<std::array<float, 3>> points = stroke_points(query);
    if (phase == "begin") {
      if (points.empty()) {
        return std::nullopt;
      }
      const float zoom = float(lookup_number(query, "zoom", 1.0));
      if (!ED_image_paint_native_begin(C, zoom, points[0].data())) {
        return std::nullopt;
      }
      if (points.size() > 1) {
        ED_image_paint_native_points(
            C, reinterpret_cast<const float(*)[3]>(points[1].data()), int(points.size() - 1));
      }
    }
    else {
      if (!points.empty()) {
        ED_image_paint_native_points(
            C, reinterpret_cast<const float(*)[3]>(points.data()), int(points.size()));
      }
      if (phase == "end" || phase == "cancel") {
        ED_image_paint_native_end(C, phase == "cancel");
      }
    }
    return "";
  }
  if (action == "pack") {
    /* Painted or generated pixels are kept as they are; a file as it is on disk. */
    if (BKE_image_is_dirty(ima) || ima->source == IMA_SRC_GENERATED) {
      if (!BKE_image_memorypack(ima)) {
        return std::nullopt;
      }
    }
    else {
      ReportList reports;
      BKE_reports_init(&reports, RPT_STORE);
      BKE_image_packfiles(&reports, ima, ID_BLEND_PATH(bmain, &ima->id));
      BKE_reports_free(&reports);
    }
    WM_event_add_notifier(C, NC_IMAGE | NA_EDITED, ima);
    return "Pack Image";
  }
  if (action == "reload") {
    BKE_image_signal(bmain, ima, nullptr, IMA_SIGNAL_RELOAD);
    WM_event_add_notifier(C, NC_IMAGE | NA_EDITED, ima);
    return "";
  }
  if (action == "export") {
    const std::string path = query.lookup_str("path").value_or("");
    void *lock;
    ImageUser user = {};
    ImBuf *ibuf = BKE_image_acquire_ibuf(ima, &user, &lock);
    bool saved = false;
    if (ibuf && !path.empty()) {
      ImBuf *copy = IMB_dupImBuf(ibuf);
      if (copy->float_buffer.data && !copy->byte_buffer.data) {
        IMB_byte_from_float(copy);
      }
      copy->planes = 32;
      copy->ftype = IMB_FTYPE_PNG;
      saved = IMB_save_image(copy, path.c_str(), IB_byte_data);
      IMB_freeImBuf(copy);
    }
    BKE_image_release_ibuf(ima, ibuf, lock);
    return saved ? std::optional<std::string>("") : std::nullopt;
  }
  return std::nullopt;
}

}  // namespace

std::string native_image_query(bContext *C, const std::string &request, const bool execute)
{
  const std::unique_ptr<Value> value = parse(request);
  const DictionaryValue *query = value ? value->as_dictionary_value() : nullptr;
  if (!execute) {
    return read_images(C, query);
  }
  if (!query) {
    return "This image change could not be made.";
  }
  const std::optional<std::string> undo = apply_edit(C, *query);
  if (!undo) {
    return "This image change could not be made.";
  }
  if (!undo->empty()) {
    ED_undo_push(C, undo->c_str());
  }
  return "";
}

bool native_image_pixels(bContext *C, const std::string &state, NativeImagePixels &r_pixels)
{
  /* Changes since the last picture sent, as the Image Editor's drawing follows them. */
  static PartialUpdateUser *changes = nullptr;
  static uint32_t changes_image = 0;
  static bool sent_none = false;

  const std::unique_ptr<Value> value = parse(state);
  Image *ima = shown_image(C, value ? value->as_dictionary_value() : nullptr);
  Scene *scene = CTX_data_scene(C);
  if (!ima || !scene) {
    if (changes) {
      BKE_image_partial_update_free(changes);
      changes = nullptr;
      changes_image = 0;
    }
    const bool send = !sent_none;
    sent_none = true;
    r_pixels = {};
    return send;
  }
  bool changed = sent_none;
  sent_none = false;
  if (!changes || changes_image != ima->id.session_uid) {
    if (changes) {
      BKE_image_partial_update_free(changes);
    }
    changes = BKE_image_partial_update_create(ima);
    changes_image = ima->id.session_uid;
    changed = true;
  }
  if (BKE_image_partial_update_collect_changes(ima, changes) !=
      ePartialUpdateCollectResult::NoChangesDetected)
  {
    changed = true;
    PartialUpdateRegion region;
    while (BKE_image_partial_update_get_next_change(changes, &region) ==
           ePartialUpdateIterResult::ChangeAvailable)
    {
    }
  }
  if (!changed) {
    return false;
  }
  r_pixels = {};
  r_pixels.name = ima->id.name + 2;
  void *lock;
  ImageUser user = {};
  ImBuf *ibuf = BKE_image_acquire_ibuf(ima, &user, &lock);
  if (ibuf && ibuf->x > 0 && ibuf->y > 0) {
    /* In the scene's view transform, as the Image Editor shows it. */
    void *cache_handle = nullptr;
    const uchar *display = IMB_display_buffer_acquire(
        ibuf, &scene->view_settings, &scene->display_settings, &cache_handle);
    if (display) {
      const int scale_down = std::max(
          1, (std::max(ibuf->x, ibuf->y) + native_image_max_side - 1) / native_image_max_side);
      const int width = std::max(1, ibuf->x / scale_down);
      const int height = std::max(1, ibuf->y / scale_down);
      r_pixels.width = width;
      r_pixels.height = height;
      r_pixels.full_width = ibuf->x;
      r_pixels.full_height = ibuf->y;
      r_pixels.rgba.resize(size_t(width) * height * 4);
      /* Top row first, as the native interface's images are. */
      for (int y = 0; y < height; y++) {
        const uchar *row = display + size_t(ibuf->y - 1 - y * scale_down) * ibuf->x * 4;
        uchar *out = r_pixels.rgba.data() + size_t(y) * width * 4;
        if (scale_down == 1) {
          memcpy(out, row, size_t(width) * 4);
        }
        else {
          for (int x = 0; x < width; x++) {
            memcpy(out + x * 4, row + size_t(x) * scale_down * 4, 4);
          }
        }
      }
    }
    IMB_display_buffer_release(cache_handle);
  }
  BKE_image_release_ibuf(ima, ibuf, lock);
  return true;
}

std::vector<float> native_image_uvs(bContext *C)
{
  /* Each edge of each face as two points, of the active object's UV map. Hidden faces are left
   * out in Edit Mode. Big meshes are cut short: an overlay, not something to edit. */
  constexpr size_t max_edges = 200000;
  std::vector<float> segments;
  Object *ob = CTX_data_active_object(C);
  if (!ob || ob->type != OB_MESH) {
    return segments;
  }
  Mesh *mesh = reinterpret_cast<Mesh *>(ob->data);
  const StringRefNull uv_name = mesh->active_uv_map_name();
  if (uv_name.is_empty()) {
    return segments;
  }
  if (BMEditMesh *em = mesh->runtime->edit_mesh.get()) {
    BMesh *bm = em->bm;
    const int offset = CustomData_get_offset_named(&bm->ldata, CD_PROP_FLOAT2, uv_name);
    if (offset == -1) {
      return segments;
    }
    BMFace *face;
    BMIter iter;
    BM_ITER_MESH (face, &iter, bm, BM_FACES_OF_MESH) {
      if (BM_elem_flag_test(face, BM_ELEM_HIDDEN)) {
        continue;
      }
      BMLoop *first = BM_FACE_FIRST_LOOP(face);
      BMLoop *loop = first;
      do {
        const float *a = BM_ELEM_CD_GET_FLOAT_P(loop, offset);
        const float *b = BM_ELEM_CD_GET_FLOAT_P(loop->next, offset);
        segments.insert(segments.end(), {a[0], a[1], b[0], b[1]});
      } while ((loop = loop->next) != first);
      if (segments.size() / 4 >= max_edges) {
        break;
      }
    }
    return segments;
  }
  const bke::AttributeAccessor attributes = mesh->attributes();
  const VArraySpan<float2> uvs = *attributes.lookup<float2>(uv_name, bke::AttrDomain::Corner);
  if (uvs.is_empty()) {
    return segments;
  }
  const OffsetIndices faces = mesh->faces();
  for (const int face : faces.index_range()) {
    const IndexRange corners = faces[face];
    for (const int i : corners.index_range()) {
      const float2 a = uvs[corners[i]];
      const float2 b = uvs[corners[(i + 1) % corners.size()]];
      segments.insert(segments.end(), {a.x, a.y, b.x, b.y});
    }
    if (segments.size() / 4 >= max_edges) {
      break;
    }
  }
  return segments;
}

}  // namespace blender::ed::image
