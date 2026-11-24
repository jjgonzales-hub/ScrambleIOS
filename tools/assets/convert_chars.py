# Kenney Mini Characters (CC0) -> rigid-part hierarchy USDZ for SceneKit.
# Each bone becomes an Empty at the bone head; the vertices weighted to that
# bone become a mesh child, so SceneKit can pose parts by rotating the empties.
import bpy, sys, bmesh
from mathutils import Vector
args = sys.argv[sys.argv.index('--')+1:]
out = args[0]; srcs = args[1:]
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
for i, src in enumerate(srcs):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=src)
    new = [o for o in bpy.data.objects if o not in before]
    arm = next(o for o in new if o.type == 'ARMATURE')
    name = arm.name.replace('character-', '').replace('-', '_')
    # rest pose
    for a in bpy.data.actions: pass
    arm.animation_data_clear() if arm.animation_data else None
    arm.data.pose_position = 'REST'
    bpy.context.view_layer.update()
    root = bpy.data.objects.new(name, None); scene.collection.objects.link(root)
    empties = {}; wpos = {}
    for b in arm.data.bones:
        e = bpy.data.objects.new(f"{name}_{b.name.replace('-', '_')}", None)
        scene.collection.objects.link(e)
        empties[b.name] = e; wpos[b.name] = arm.matrix_world @ b.head_local
    for b in arm.data.bones:
        e = empties[b.name]
        e.parent = empties[b.parent.name] if b.parent else root
        e.matrix_parent_inverse.identity()
        e.location = wpos[b.name] - (wpos[b.parent.name] if b.parent else Vector((0,0,0)))
    for o in new:
        if o.type != 'MESH': continue
        if not o.vertex_groups:
            bpy.data.objects.remove(o); continue
        mw = o.matrix_world.copy()
        o.parent = None; o.matrix_world = mw
        bpy.context.view_layer.objects.active = o
        for m in list(o.modifiers): o.modifiers.remove(m)
        o.data.transform(mw); o.matrix_world.identity()
        gnames = {g.index: g.name for g in o.vertex_groups}
        for gi, gname in gnames.items():
            me = o.data.copy()
            bm = bmesh.new(); bm.from_mesh(me)
            dl = bm.verts.layers.deform.active
            kill = [v for v in bm.verts if gi not in v[dl] or v[dl][gi] < 0.5]
            bmesh.ops.delete(bm, geom=kill, context='VERTS')
            if len(bm.verts) == 0: bm.free(); continue
            bm.to_mesh(me); bm.free()
            part = bpy.data.objects.new(f"{name}_{gname.replace('-', '_')}_{o.name.split('-')[0]}_geo", me)
            scene.collection.objects.link(part)
            e = empties[gname]
            me.transform(__import__('mathutils').Matrix.Translation(-wpos[gname]))
            part.parent = e
            part.matrix_parent_inverse.identity()
            part.location = (0, 0, 0)
        bpy.data.objects.remove(o)
    bpy.data.objects.remove(arm)
    root.location = (i * 1.0, 0, 0)
for a in list(bpy.data.actions): bpy.data.actions.remove(a)
# Bake Y-up / +Z-forward into the data itself so every node (not just the
# file root) is upright in SceneKit: (x, y, z) -> (x, z, -y).
from mathutils import Matrix
import math
R = Matrix.Rotation(math.radians(-90), 4, 'X')
for o in bpy.data.objects:
    if o.type == 'MESH':
        o.data.transform(R)
    elif o.type == 'EMPTY' and o.parent is not None:
        o.location = (R @ o.location.to_4d()).to_3d()
bpy.context.view_layer.update()
bpy.ops.wm.usd_export(filepath=out, export_animation=False, export_materials=True,
                      selected_objects_only=False, export_armatures=False,
                      export_shapekeys=False, generate_materialx_network=False,
                      convert_orientation=False, triangulate_meshes=True,
                      export_lights=False, export_cameras=False, convert_world_material=False)
for o in bpy.data.objects: print("OUT", o.name, o.type, tuple(round(v,3) for v in o.matrix_world.translation))
