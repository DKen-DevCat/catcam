# Bipedal Cat (DreamNoms, CC BY 4.0) を毒チワワ風に改造する。
#   blender -b models/bipedal-cat/source/BipedalNinjaCat.blend --python tools/blender/build_chihuahua.py -- models/out
# 出力: <out>/doku_chihuahua.blend と <out>/preview_*.png
import bpy, bmesh, math, random, sys, os
from mathutils import Vector, Matrix

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "models/out"
os.makedirs(OUT, exist_ok=True)

# 色はリニア値（参考画像の sRGB を換算）
PURPLE = (0.30, 0.04, 0.40)
GREEN = (0.05, 0.36, 0.08)
GREEN_RIM = (0.01, 0.10, 0.02)
WHITE = (0.86, 0.85, 0.88)
EAR_INNER = (0.86, 0.70, 0.78)
LILAC = (0.55, 0.36, 0.72)
DARK_PURPLE = (0.12, 0.02, 0.18)
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

# ---- 尻尾: 背中から立ち上げて、正面から見ると頭の上に角のように突き出る形にする ----
# 尻尾の骨を曲げて伸ばした姿勢を作り、それを新しい休止姿勢として焼き込む
TAIL = [f"TailBase{'' if i == 0 else f'.{i:03d}'}" for i in range(6)]
TAIL_DIRS = [(0, 1, -0.3), (0, 0.7, 0.7), (0, 0.2, 1), (0, 0, 1), (0, -0.1, 1), (0, -0.25, 1)]
TAIL_STRETCH = 2.3
for name in TAIL:
    arm.data.bones[name].inherit_scale = "NONE"
bpy.context.view_layer.update()
tip = None
for name, d in zip(TAIL, TAIL_DIRS):
    pb = arm.pose.bones[name]
    y = Vector(d).normalized()
    x = Vector((1, 0, 0))
    z = x.cross(y)
    head = tip if tip is not None else pb.head.copy()
    m = Matrix((x, y * TAIL_STRETCH, z)).transposed().to_4x4()
    m.translation = head
    pb.matrix = m
    bpy.context.view_layer.update()
    tip = pb.tail.copy()
bpy.ops.object.modifier_apply(modifier="Armature")
bpy.ops.object.select_all(action="DESELECT")
arm.select_set(True)
bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode="POSE")
bpy.ops.pose.armature_apply(selected=False)
bpy.ops.object.mode_set(mode="OBJECT")
for name in TAIL:
    arm.data.bones[name].inherit_scale = "FULL"
bpy.ops.object.select_all(action="DESELECT")
cat.select_set(True)
bpy.context.view_layer.objects.active = cat
mod = cat.modifiers.new("Armature", "ARMATURE")
mod.object = arm

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

uv_sphere = lambda location: bpy.ops.mesh.primitive_uv_sphere_add(segments=24, ring_count=12, radius=1, location=location)
parts = []
for s in (1, -1):
    # 横長の楕円にして、丸い目の可愛さを抑える
    parts.append(add_part(f"Eye.{s}", uv_sphere, (0.37 * s, -0.52, 1.42), (0.22, 0.15, 0.125), eye_mat))
    parts.append(add_part(f"Highlight.{s}", uv_sphere, (0.31 * s, -0.66, 1.46), (0.035, 0.025, 0.028), hl_mat))
MUZ_C, MUZ_R = Vector((0, -0.57, 1.14)), Vector((0.33, 0.2, 0.21))
parts.append(add_part("Muzzle", uv_sphere, tuple(MUZ_C), tuple(MUZ_R), white_mat))
parts.append(add_part("Nose", uv_sphere, (0, -0.77, 1.25), (0.13, 0.07, 0.075), eye_mat))
# 口はいつも少し開けておく。鼻の下の小さい笑い口


def on_muzzle(x, z, lift):
    """鼻先の楕円体の正面の表面上の点（少し浮かせる）"""
    k = 1 - (x / MUZ_R.x) ** 2 - ((z - MUZ_C.z) / MUZ_R.z) ** 2
    y = MUZ_C.y - MUZ_R.y * math.sqrt(max(k, 0.0))
    return Vector((x, y - lift, z))


def add_mouth():
    w, n = 0.15, 20
    top, bottom = [], []
    for i in range(n + 1):
        u = -w + 2 * w * i / n
        t = (u / w) ** 2
        # 上の縁は中央だけ白い上唇が垂れ下がる。両端で上下の縁が近づいて細くなる
        up = 1.1 + 0.04 * t - 0.015 * math.exp(-(u / 0.04) ** 2)
        lo = 1.06 + 0.07 * t
        top.append(on_muzzle(u, up, 0.012))
        bottom.append(on_muzzle(u, min(lo, up - 0.012), 0.012))
    verts = top + bottom
    faces = [(i, i + 1, n + 2 + i, n + 1 + i) for i in range(n)]
    me = bpy.data.meshes.new("Mouth")
    me.from_pydata([tuple(v) for v in verts], [], faces)
    o = bpy.data.objects.new("Mouth", me)
    bpy.context.collection.objects.link(o)
    bpy.ops.object.select_all(action="DESELECT")
    o.select_set(True)
    bpy.context.view_layer.objects.active = o
    sol = o.modifiers.new("Solid", "SOLIDIFY")
    sol.thickness = 0.02
    bpy.ops.object.modifier_apply(modifier="Solid")
    o.data.materials.append(eye_mat)
    vg = o.vertex_groups.new(name="Head")
    vg.add(list(range(len(o.data.vertices))), 1.0, "REPLACE")
    # アプリ側で口の開閉に合わせて伸縮させるための目印（対応する骨はないので変形には影響しない）
    o.vertex_groups.new(name="Mouth").add(list(range(len(o.data.vertices))), 1.0, "REPLACE")
    return o


parts.append(add_mouth())

# ---- 体の色（参考: ゲーム画面の毒チワワ） ----
# 額の左右に、明るい紫のふちが付いた大きい緑の斑点。角の付け根のまわりに、ふちなしの小さい斑点
# 細かい模様は輪郭をなめらかにしたいので、頂点色ではなく焼き込み時のシェーダで描く（下の paint_details）
spots = [(Vector((0.5 * s, -0.3, 1.74)), 0.12, LILAC) for s in (1, -1)]
spots += [(Vector((0, -0.3, 1.81)), 0.07, None)]
spots += [(Vector((0.2 * s, -0.12, 1.86)), 0.06, None) for s in (1, -1)]
# 目の上（少し内側）のぼんやりした白い丸
brows = [(Vector((0.24 * s, -0.5, 1.6)), 0.075) for s in (1, -1)]
eyes = [Vector((0.37 * s, -0.52, 1.42)) for s in (1, -1)]


def mix(a, b, t):
    return tuple(x + (y - x) * t for x, y in zip(a, b))


def smooth(e0, e1, x):
    t = min(max((x - e0) / (e1 - e0), 0.0), 1.0)
    return t * t * (3 - 2 * t)


def body_color(p, n):
    # 足・手先は白
    if (p.z < -0.45 and p.y < 0.6) or (abs(p.x) > 1.12 and p.z < 1.0):
        return WHITE
    # 耳の内側は白っぽいピンク
    if abs(p.x) > 0.78 and p.z > 1.45 and n.y < -0.2:
        return EAR_INNER
    # 鼻先のまわりから喉までは白（頬は紫のまま）
    if p.y < -0.3 and 0.9 < p.z < 1.32 and abs(p.x) < 0.4:
        return WHITE
    # 胸からお腹の前側は白
    if -0.45 <= p.z < 0.98 and n.y < -0.35 and abs(p.x) < 0.62 and p.y < 0.3:
        return WHITE
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

img = bpy.data.images.new("DokuChihuahua", 2048, 2048)
body = bpy.data.materials.new("Body")
body.use_nodes = True
nt = body.node_tree
bsdf = nt.nodes.get("Principled BSDF")
bsdf.inputs["Roughness"].default_value = 0.7
attr = nt.nodes.new("ShaderNodeVertexColor")
attr.layer_name = "Col"
coord = nt.nodes.new("ShaderNodeTexCoord")


def snap(p):
    """模様の中心を一番近い表面の点に寄せる（中心が体の中に埋まって小さくならないように）"""
    return min((v.co for v in me.vertices), key=lambda q: (q - p).length).copy()


def layer(base, dist, edge, soft, color):
    """dist < edge の所を color で塗る（境目を soft 幅でぼかす）"""
    ramp = nt.nodes.new("ShaderNodeMapRange")
    ramp.interpolation_type = "SMOOTHSTEP"
    nt.links.new(dist, ramp.inputs["Value"])
    ramp.inputs["From Min"].default_value = edge - soft
    ramp.inputs["From Max"].default_value = edge + soft
    ramp.inputs["To Min"].default_value = 1
    ramp.inputs["To Max"].default_value = 0
    m = nt.nodes.new("ShaderNodeMix")
    m.data_type = "RGBA"
    nt.links.new(ramp.outputs["Result"], m.inputs["Factor"])
    nt.links.new(base, m.inputs[6])
    m.inputs[7].default_value = (*color, 1)
    return m.outputs[2]


def distance(center, scale=(1, 1, 1)):
    sub = nt.nodes.new("ShaderNodeVectorMath")
    sub.operation = "SUBTRACT"
    nt.links.new(coord.outputs["Object"], sub.inputs[0])
    sub.inputs[1].default_value = center
    mul = nt.nodes.new("ShaderNodeVectorMath")
    mul.operation = "MULTIPLY"
    nt.links.new(sub.outputs[0], mul.inputs[0])
    mul.inputs[1].default_value = scale
    ln = nt.nodes.new("ShaderNodeVectorMath")
    ln.operation = "LENGTH"
    nt.links.new(mul.outputs[0], ln.inputs[0])
    return ln.outputs["Value"]


def paint_details(base):
    # 目のまわりの濃い紫（顔の正面だけに効くよう奥行きも楕円に含める）
    for e in eyes:
        base = layer(base, distance(e, (1 / 0.3, 1 / 0.3, 1 / 0.21)), 1.0, 0.12, DARK_PURPLE)
    for c, r in brows:
        base = layer(base, distance(snap(c)), r, 0.035, WHITE)
    for c, r, rim in spots:
        c = snap(c)
        if rim:
            base = layer(base, distance(c), r * 1.35, 0.01, rim)
        base = layer(base, distance(c), r, 0.01, GREEN)
    return base


nt.links.new(paint_details(attr.outputs["Color"]), bsdf.inputs["Base Color"])
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
