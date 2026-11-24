import bpy, sys
args = sys.argv[sys.argv.index('--')+1:]
out = args[0]; srcs = args[1:]
bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
for i, src in enumerate(srcs):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=src)
    new = [o for o in bpy.data.objects if o not in before]
    name = src.split('/')[-1].replace('.glb', '')
    root = bpy.data.objects.new('prop_' + name, None); sc.collection.objects.link(root)
    bpy.context.view_layer.update()
    from mathutils import Matrix
    import math
    R = Matrix.Rotation(math.radians(-90), 4, 'X')
    for o in new:
        if o.type != 'MESH':
            continue
        mw = o.matrix_world.copy()
        o.data = o.data.copy()
        o.parent = None
        o.data.transform(R @ mw)
        o.matrix_world = Matrix.Identity(4)
        o.parent = root
    for o in new:
        if o.type != 'MESH':
            bpy.data.objects.remove(o)
    root.location = (i * 2.0, 0, 0)
bpy.context.view_layer.update()
for m in bpy.data.materials: print("MAT", m.name)
bpy.ops.wm.usd_export(filepath=out, selected_objects_only=False, export_armatures=False,
    generate_materialx_network=False, convert_orientation=False,
    triangulate_meshes=True, export_lights=False, export_cameras=False, convert_world_material=False)
for o in bpy.data.objects:
    if o.parent is None: print("PROP", o.name, tuple(round(v,2) for v in o.dimensions))
