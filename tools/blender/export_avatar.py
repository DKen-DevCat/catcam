# build_chihuahua.py で作ったモデルを catcam 用に書き出す。
#   blender -b models/out/doku_chihuahua.blend --python tools/blender/export_avatar.py -- models/out/avatar
# 出力: avatar.json（骨・頂点数など）, avatar.bin（頂点・インデックス）, テクスチャは doku_chihuahua.png をそのまま使う
#
# 頂点 1 つ = float32 × 22:
#   位置 3, 法線 3, UV 2, 色 4（w=1 ならテクスチャ、0 なら rgb の単色）, 艶 1, 口 1（口の頂点なら 1）,
#   骨番号 4, 骨の重み 4
# 座標は Blender のまま（Z 上、正面は -Y）
import bpy, json, struct, sys, os

out = sys.argv[sys.argv.index("--") + 1]
obj = bpy.data.objects["DokuChihuahua"]
arm = bpy.data.objects["metarig"]
me = obj.data
mw = obj.matrix_world
nmw = mw.to_3x3().inverted().transposed()

bones = list(arm.data.bones)
bone_index = {b.name: i for i, b in enumerate(bones)}
group_bone = {g.index: bone_index.get(g.name) for g in obj.vertex_groups}

# 材質ごとの色と艶。体（Body）だけテクスチャ
flat = {
    "Eye": ((0.01, 0.01, 0.012), 1.0),
    "Highlight": ((1.0, 1.0, 1.0), 0.0),
    "Muzzle": ((0.86, 0.85, 0.88), 0.0),
    "Horn": ((0.30, 0.04, 0.40), 0.2),
}

def to_srgb(c):
    return c * 12.92 if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


me.calc_loop_triangles()
uv = me.uv_layers.active.data
verts, index_of, indices = [], {}, []
for tri in me.loop_triangles:
    mat = me.materials[tri.material_index].name if me.materials else "Body"
    for li in tri.loops:
        loop = me.loops[li]
        vi = loop.vertex_index
        key = (vi, round(uv[li].uv.x, 5), round(uv[li].uv.y, 5), tri.material_index,
               tuple(round(c, 3) for c in loop.normal))
        if key not in index_of:
            v = me.vertices[vi]
            p = mw @ v.co
            n = (nmw @ loop.normal).normalized()
            ws = sorted(((g.weight, group_bone.get(g.group)) for g in v.groups if group_bone.get(g.group) is not None and g.weight > 0.001),
                        reverse=True)[:4]
            total = sum(w for w, _ in ws) or 1.0
            ws = [(w / total, b) for w, b in ws] + [(0.0, 0)] * (4 - len(ws))
            if mat.startswith("Body"):
                color, gloss = (1.0, 1.0, 1.0, 1.0), 0.0
            else:
                rgb, gloss = flat.get(mat.split(".")[0], ((1, 0, 1), 0.0))
                # テクスチャ（PNG）は sRGB で保存されているので、単色も sRGB に揃える
                color = (*[to_srgb(c) for c in rgb], 0.0)
            # 口は名前の付いた頂点グループで判定する（build 時に Mouth グループを付けている）
            is_mouth = 1.0 if mat.startswith("Eye") and any(obj.vertex_groups[g.group].name == "Mouth" for g in v.groups) else 0.0
            index_of[key] = len(verts)
            verts.append([p.x, p.y, p.z, n.x, n.y, n.z, uv[li].uv.x, 1 - uv[li].uv.y, *color, gloss, is_mouth,
                          *[float(b) for _, b in ws], *[w for w, _ in ws]])
        indices.append(index_of[key])

amw = arm.matrix_world
meta = {
    "vertexCount": len(verts),
    "indexCount": len(indices),
    "floatsPerVertex": 22,
    "texture": "doku_chihuahua.png",
    "bones": [{
        "name": b.name,
        "parent": bone_index[b.parent.name] if b.parent else -1,
        "head": list(amw @ b.head_local),
        "tail": list(amw @ b.tail_local),
    } for b in bones],
}
with open(out + ".json", "w") as f:
    json.dump(meta, f, indent=1)
with open(out + ".bin", "wb") as f:
    for v in verts:
        f.write(struct.pack("<22f", *v))
    f.write(struct.pack(f"<{len(indices)}I", *indices))
print("EXPORTED", len(verts), "verts", len(indices) // 3, "tris", len(bones), "bones")
