"""Physical-iPad Release regression: render, move camera, and reopen the original scene.

Run via --python after copying to app Documents. Results and bounded memory samples are
written there. No scene files or preferences are saved. Override ALLEY_CYCLES (default 3).
"""
import bpy
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path
import threading
import time
import traceback
from mathutils import Vector

root = Path.home() / 'Documents'
lib = ctypes.CDLL(None)
lib.os_proc_available_memory.restype = ctypes.c_size_t

class TaskVMInfo(ctypes.Structure):
    """`task_vm_info_data_t` up to `phys_footprint` (revision 1). The footprint, not resident size,
    is what iPadOS compares with the app's memory limit."""
    _fields_ = [('virtual', ctypes.c_uint64), ('region_count', ctypes.c_int32), ('page_size', ctypes.c_int32),
                ('resident', ctypes.c_uint64), ('resident_peak', ctypes.c_uint64),
                ('device', ctypes.c_uint64), ('device_peak', ctypes.c_uint64),
                ('internal', ctypes.c_uint64), ('internal_peak', ctypes.c_uint64),
                ('external', ctypes.c_uint64), ('external_peak', ctypes.c_uint64),
                ('reusable', ctypes.c_uint64), ('reusable_peak', ctypes.c_uint64),
                ('purgeable_volatile_pmap', ctypes.c_uint64), ('purgeable_volatile_resident', ctypes.c_uint64),
                ('purgeable_volatile_virtual', ctypes.c_uint64),
                ('compressed', ctypes.c_uint64), ('compressed_peak', ctypes.c_uint64),
                ('compressed_lifetime', ctypes.c_uint64), ('phys_footprint', ctypes.c_uint64)]

TASK_VM_INFO = 22

task = ctypes.c_uint32.in_dll(lib, 'mach_task_self_').value
metal = ctypes.CDLL('/System/Library/Frameworks/Metal.framework/Metal')
metal.MTLCreateSystemDefaultDevice.restype = ctypes.c_void_p
device = metal.MTLCreateSystemDefaultDevice()
objc = ctypes.CDLL('/usr/lib/libobjc.A.dylib')
objc.sel_registerName.argtypes = [ctypes.c_char_p]
objc.sel_registerName.restype = ctypes.c_void_p
selector = objc.sel_registerName(b'currentAllocatedSize')
objc.objc_msgSend.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
objc.objc_msgSend.restype = ctypes.c_uint64

def memory():
    info = TaskVMInfo()
    count = ctypes.c_uint32(ctypes.sizeof(info)//4)
    status = lib.task_info(task, TASK_VM_INFO, ctypes.byref(info), ctypes.byref(count))
    available = lib.os_proc_available_memory()
    footprint = info.phys_footprint if status == 0 else None
    return dict(time=time.time(), available=available,
                resident=info.resident if status == 0 else None, footprint=footprint,
                # The limit as the governor will measure it: footprint plus what is still available.
                limit=footprint + available if footprint is not None else None,
                metal=objc.objc_msgSend(device, selector))

state = {'status': 'running', 'stage': 'startup', 'cycles': [],
         'binary_sha256': hashlib.file_digest(open(bpy.app.binary_path, 'rb'), 'sha256').hexdigest()}
stopped = threading.Event()
start = time.monotonic()
camera_matrix = None
moving_since = None
samples = 0
cycle = None

def save():
    state['memory'] = memory()
    (root/'alley-repeat-result.json').write_text(json.dumps(state, indent=2))

def monitor():
    with (root/'alley-repeat-memory.jsonl').open('w', buffering=1) as f:
        while not stopped.is_set() and time.monotonic()-start < 600:
            f.write(json.dumps(memory())+'\n')
            stopped.wait(.5)

def view():
    windows = list(bpy.context.window_manager.windows)
    assert len(windows) == 1, 'Native file open created an auxiliary desktop window'
    w = windows[0]
    assert len(w.screen.areas) == 1 and w.screen.areas[0].type == 'VIEW_3D'
    return w, w.screen.areas[0], w.screen.areas[0].spaces.active

@bpy.app.handlers.persistent
def solid_on_load(_):
    for screen in bpy.data.screens:
        for a in screen.areas:
            if a.type == 'VIEW_3D': a.spaces.active.shading.type = 'SOLID'

def fail():
    state.update(status='failed', error=traceback.format_exc())
    stopped.set()
    if solid_on_load in bpy.app.handlers.load_post:
        bpy.app.handlers.load_post.remove(solid_on_load)
    save()

def load():
    global cycle
    try:
        state['stage']='loading'
        for w in bpy.context.window_manager.windows:
            for a in w.screen.areas:
                if a.type == 'VIEW_3D': a.spaces.active.shading.type='SOLID'
        cycle={'number':len(state['cycles'])+1, 'before':memory(), 'settled':[]}
        state['cycles'].append(cycle)
        save()
        # Explicitly request UI to verify that native mode still keeps its layout.
        bpy.ops.wm.open_mainfile(filepath=str(root/'Promo Scenes/hidden_alley/ph_hidden_alley.blend'), load_ui=True)
        view()
        bpy.app.timers.register(rendered, first_interval=3)
    except Exception: fail()
    return None

def rendered():
    global camera_matrix, samples
    try:
        w, a, s = view()
        w.scene.render.engine='BLENDER_EEVEE'
        assert w.scene.camera
        camera_matrix=w.scene.camera.matrix_world.copy()
        s.camera=w.scene.camera
        s.region_3d.view_perspective='CAMERA'
        s.region_3d.view_camera_zoom=25
        s.region_3d.view_camera_offset=(0,0)
        s.overlay.show_overlays=False
        s.show_gizmo=False
        s.shading.type='RENDERED'
        a.tag_redraw()
        samples=0
        cycle['render_requested']=time.time()
        state['stage']='rendering'
        save()
        bpy.app.timers.register(settled, first_interval=7)
    except Exception: fail()
    return None

def settled():
    global samples, moving_since
    try:
        cycle['settled'].append(memory())
        samples+=1
        save()
        if samples<5: return 5
        state['stage']='moving_camera'
        moving_since=time.monotonic()
        bpy.app.timers.register(move, first_interval=.03)
    except Exception: fail()
    return None

def move():
    try:
        w,a,s=view()
        elapsed=time.monotonic()-moving_since
        matrix=camera_matrix.copy()
        matrix.translation += camera_matrix.to_quaternion() @ Vector((.08*math.sin(elapsed),0,0))
        w.scene.camera.matrix_world=matrix
        a.tag_redraw()
        if elapsed<6: return 1/30
        w.scene.camera.matrix_world=camera_matrix
        cycle['after_navigation']=memory()
        save()
        if len(state['cycles'])<int(os.environ.get('ALLEY_CYCLES','3')):
            s.shading.type='SOLID'
            bpy.app.timers.register(load, first_interval=2)
        else:
            first=state['cycles'][0]['settled'][-1]
            last=cycle['settled'][-1]
            state['settled_resident_growth']=last['resident']-first['resident']
            state['settled_footprint_growth']=last['footprint']-first['footprint']
            state['settled_metal_growth']=last['metal']-first['metal']
            assert state['settled_footprint_growth'] < 1024**3, 'Footprint grew by over 1 GiB across reloads'
            assert state['settled_metal_growth'] < 1024**3, 'Metal allocations grew by over 1 GiB across reloads'
            assert min(c['settled'][-1]['available'] for c in state['cycles']) > 1024**3, 'Less than 1 GiB settled headroom'
            state.update(status='passed', stage='complete')
            stopped.set()
            bpy.app.handlers.load_post.remove(solid_on_load)
            save()
    except Exception: fail()
    return None

bpy.context.preferences.system.memory_cache_limit=4096
bpy.context.preferences.system.gl_texture_limit='CLAMP_1024'
bpy.app.handlers.load_post.append(solid_on_load)
save()
threading.Thread(target=monitor, daemon=True).start()
bpy.app.timers.register(load, first_interval=4, persistent=True)
