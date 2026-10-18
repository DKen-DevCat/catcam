# 改造したモデルを 4 方向から撮る。
#   blender -b models/out/doku_chihuahua.blend --python tools/blender/preview.py -- models/out/preview
import bpy, sys, mathutils
out = sys.argv[sys.argv.index("--") + 1]
sc = bpy.context.scene
target = bpy.data.objects["DokuChihuahua"]
bb = [target.matrix_world @ mathutils.Vector(c) for c in target.bound_box]
center = sum(bb, mathutils.Vector()) / 8
size = max((max(v[i] for v in bb) - min(v[i] for v in bb)) for i in range(3))
cam = bpy.data.objects["Camera"]
cam.data.type = "ORTHO"
cam.data.ortho_scale = size * 1.1
sc.camera = cam
sc.render.engine = "BLENDER_EEVEE"
world = sc.world or bpy.data.worlds.new("W")
sc.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.75, 0.68, 0.55, 1)
world.node_tree.nodes["Background"].inputs["Strength"].default_value = 1.0
sc.render.resolution_x = sc.render.resolution_y = 600
sc.render.resolution_percentage = 100
for name, d in {"front": (0, -1, 0.15), "side": (1, 0, 0.1), "back": (0, 1, 0.1), "q": (0.7, -0.7, 0.35)}.items():
    d = mathutils.Vector(d).normalized()
    cam.location = center + d * size * 3
    cam.rotation_euler = (center - cam.location).to_track_quat("-Z", "Y").to_euler()
    sc.render.filepath = f"{out}_{name}.png"
    bpy.ops.render.render(write_still=True)

# 左手の拡大
arm = bpy.data.objects["metarig"]
hc = arm.matrix_world @ arm.data.bones["hand.L"].head_local + mathutils.Vector((0.3, 0, 0))
cam.data.ortho_scale = 1.0
cam.location = hc + mathutils.Vector((0, -5, 0))
cam.rotation_euler = (hc - cam.location).to_track_quat("-Z", "Y").to_euler()
sc.render.filepath = f"{out}_hand.png"
bpy.ops.render.render(write_still=True)
