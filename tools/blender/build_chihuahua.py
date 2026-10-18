# Bipedal Cat (DreamNoms, CC BY 4.0) を毒チワワ風に改造する。
#   blender -b models/bipedal-cat/source/BipedalNinjaCat.blend --python tools/blender/build_chihuahua.py -- models/out
# 出力: <out>/doku_chihuahua.blend と <out>/preview_*.png
import bpy, bmesh, math, random, sys, os
from mathutils import Vector, Matrix

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "models/out"
os.makedirs(OUT, exist_ok=True)

PURPLE = (0.36, 0.13, 0.52)
RIM = (0.62, 0.40, 0.78)
GREEN = (0.04, 0.38, 0.10)
WHITE = (0.92, 0.90, 0.95)
GRAY = (0.55, 0.55, 0.58)
BLACK = (0.01, 0.01, 0.012)

cat = bpy.data.objects["Cat"]
arm = bpy.data.objects["metarig"]

# ---- 不要なものを消す（ウィジェット・別メッシュ・首輪など） ----
for o in list(bpy.data.objects):
    if o.name not in ("Cat", "metarig", "Camera", "Point", "Point.001"):
        bpy.data.objects.remove(o, do_unlink=True)

# アニメーションを外して休止姿勢で作業する
if arm.animation_data:
    arm.animation_data.action = None
for pb in arm.pose.bones:
    pb.matrix_basis = Matrix.Identity(4)

bpy.context.view_layer.objects.active = cat
cat.select_set(True)
# ミラーを適用して左右を別々に塗れるようにする
bpy.ops.object.modifier_apply(modifier="Mirror")

head_group = cat.vertex_groups["Head"].index


def head_weight(v):
    for g in v.groups:
        if g.group == head_group:
            return g.weight
    return 0.0


# ---- 耳: 大きくして横に開く ----
me = cat.data
for side in (1, -1):
    base = Vector((0.8 * side, -0.05, 1.6))
    rot = Matrix.Rotation(math.radians(28) * side, 4, "Y")
    for v in me.vertices:
        if head_weight(v) > 0.5 and v.co.x * side > 0.72 and v.co.z > 1.5:
            d = v.co - base
            d = Vector((d.x * 1.9, d.y * 2.1, d.z * 1.7))
            v.co = base + (rot @ d.to_4d()).to_3d()

# ---- なめらかにする（頂点グループは補間されて残る） ----
sub = cat.modifiers.new("Sub", "SUBSURF")
sub.levels = 2
bpy.ops.object.modifier_move_to_index(modifier="Sub", index=0)
bpy.ops.object.modifier_apply(modifier="Sub")


# ---- 頭に付けるパーツ（目・鼻・鼻先・角）。Head ボーンにだけ追従させる ----
def add_part(name, mesh_op, loc, scale, mat, rot=(0, 0, 0)):
    mesh_op(location=loc)
    o = bpy.context.active_object
    o.name = name
    o.scale = scale
    o.rotation_euler = rot
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    o.data.materials.append(mat)
    vg = o.vertex_groups.new(name="Head")
    vg.add(list(range(len(o.data.vertices))), 1.0, "REPLACE")
    bpy.ops.object.shade_smooth()
    return o


def flat_mat(name, color, rough=0.5):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*color, 1)
    bsdf.inputs["Roughness"].default_value = rough
    m.diffuse_color = (*color, 1)
    return m


eye_mat = flat_mat("Eye", BLACK, 0.08)
hl_mat = flat_mat("Highlight", (1, 1, 1), 0.3)
white_mat = flat_mat("Muzzle", WHITE)
horn_mat = flat_mat("Horn", PURPLE)

uv_sphere = lambda location: bpy.ops.mesh.primitive_uv_sphere_add(segments=24, ring_count=12, radius=1, location=location)
parts = []
for s in (1, -1):
    parts.append(add_part(f"Eye.{s}", uv_sphere, (0.36 * s, -0.5, 1.42), (0.19, 0.17, 0.19), eye_mat))
    parts.append(add_part(f"Highlight.{s}", uv_sphere, (0.31 * s, -0.66, 1.49), (0.045, 0.03, 0.045), hl_mat))
parts.append(add_part("Muzzle", uv_sphere, (0, -0.58, 1.17), (0.27, 0.17, 0.17), white_mat))
parts.append(add_part("Nose", uv_sphere, (0, -0.74, 1.24), (0.09, 0.06, 0.065), eye_mat))
parts.append(add_part("Horn", lambda location: bpy.ops.mesh.primitive_cone_add(vertices=16, radius1=1, depth=2, location=location),
                      (0, 0.05, 2.05), (0.13, 0.13, 0.26), horn_mat, rot=(math.radians(-12), 0, 0)))

# ---- 体の色: 紫に緑の斑点、白い靴下・鼻先、灰色の耳の内側、白い眉 ----
random.seed(7)
spots = []
while len(spots) < 26:
    v = random.choice(me.vertices)
    p = v.co.copy()
    # 顔の正面と耳には置かない
    if p.z > 1.0 and p.y < -0.3:
        continue
    if abs(p.x) > 0.75 and p.z > 1.5:
        continue
    if all((p - q).length > 0.42 for q, _ in spots):
        spots.append((p, random.uniform(0.11, 0.17)))
# 頭の上の斑点（毒チワワは額にもある）
spots += [(Vector((0.42, -0.38, 1.72)), 0.1), (Vector((-0.5, -0.3, 1.66)), 0.1), (Vector((0.1, -0.2, 1.84)), 0.09)]
brows = [Vector((0.26 * s, -0.6, 1.63)) for s in (1, -1)]


def body_color(p, n):
    if p.z < -0.78:
        return WHITE
    if abs(p.x) > 0.78 and p.z > 1.45 and n.y < -0.2:
        return GRAY
    if p.z < 1.28 and p.z > 0.95 and p.y < -0.4 and abs(p.x) < 0.38:
        return WHITE
    for b in brows:
        if (p - b).length < 0.085:
            return WHITE
    for c, r in spots:
        d = (p - c).length
        if d < r:
            return GREEN
        if d < r * 1.3:
            return RIM
    return PURPLE


col = me.color_attributes.new("Col", "BYTE_COLOR", "CORNER")
for poly in me.polygons:
    for li in poly.loop_indices:
        vi = me.loops[li].vertex_index
        c = body_color(me.vertices[vi].co, poly.normal)
        col.data[li].color = (*c, 1)

# 体の色を画像に焼き込む（アプリ側はテクスチャ 1 枚で描くため）
# 元の UV は焼き込みに向かないので作り直す
while me.uv_layers:
    me.uv_layers.remove(me.uv_layers[0])
bake_uv = me.uv_layers.new(name="UVMap")
me.uv_layers.active = bake_uv
bake_uv.active_render = True
bpy.ops.object.select_all(action="DESELECT")
cat.select_set(True)
bpy.context.view_layer.objects.active = cat
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.select_all(action="SELECT")
bpy.ops.uv.smart_project(angle_limit=math.radians(60), island_margin=0.01)
bpy.ops.object.mode_set(mode="OBJECT")

img = bpy.data.images.new("DokuChihuahua", 1024, 1024)
body = bpy.data.materials.new("Body")
body.use_nodes = True
nt = body.node_tree
bsdf = nt.nodes.get("Principled BSDF")
bsdf.inputs["Roughness"].default_value = 0.7
attr = nt.nodes.new("ShaderNodeVertexColor")
attr.layer_name = "Col"
nt.links.new(attr.outputs["Color"], bsdf.inputs["Base Color"])
tex = nt.nodes.new("ShaderNodeTexImage")
tex.image = img
nt.nodes.active = tex
cat.data.materials.clear()
cat.data.materials.append(body)

sc = bpy.context.scene
sc.render.engine = "CYCLES"
sc.cycles.samples = 1
sc.render.bake.use_pass_direct = False
sc.render.bake.use_pass_indirect = False
sc.render.bake.margin = 8
bpy.ops.object.bake(type="DIFFUSE")
img.filepath_raw = os.path.join(os.path.abspath(OUT), "doku_chihuahua.png")
img.file_format = "PNG"
img.save()

# 焼いた画像で描く材質に差し替える
nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
nt.nodes.remove(attr)
tex.image = bpy.data.images.load(img.filepath_raw, check_existing=False)

# ---- パーツを体に合体して、アーマチュアに付け直す ----
bpy.ops.object.select_all(action="DESELECT")
for o in parts:
    o.select_set(True)
cat.select_set(True)
bpy.context.view_layer.objects.active = cat
bpy.ops.object.join()
cat.name = "DokuChihuahua"

bpy.ops.wm.save_as_mainfile(filepath=os.path.join(os.path.abspath(OUT), "doku_chihuahua.blend"))
print("BUILT", len(cat.data.vertices), "verts")
