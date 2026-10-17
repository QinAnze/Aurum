"""导出原始 Blender 网格和 glTF PBR 参数，不改变资源内容。"""

import json
import struct
import pathlib
import hashlib

root = pathlib.Path(__file__).resolve().parents[1]
output_directory = root / "output/resources"
output_directory.mkdir(parents=True, exist_ok=True)
# 原始模型与材质一同导出，不改变几何、变换或光学参数。
for asset in ["archive-cassette", "archive-assembly"]:
    source_bytes = (root / f"Assets/models/{asset}.glb").read_bytes()
    length = struct.unpack_from("<I", source_bytes, 12)[0]
    gltf = json.loads(source_bytes[20 : 20 + length])
    binary = source_bytes[28 + length :]

    def read_accessor(accessor_index):
        """按 glTF accessor 的偏移、步长和分量类型读取原始二进制数据。"""
        accessor = gltf["accessors"][accessor_index]
        buffer_view = gltf["bufferViews"][accessor["bufferView"]]
        component_format = {5126: "f", 5125: "I", 5123: "H", 5121: "B"}[accessor["componentType"]]
        component_count = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[accessor["type"]]
        byte_stride = buffer_view.get("byteStride", struct.calcsize(component_format) * component_count)
        byte_offset = buffer_view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
        return [
            struct.unpack_from(
                "<" + component_format * component_count, binary, byte_offset + item_index * byte_stride
            )
            for item_index in range(accessor["count"])
        ]

    # 顶点统一为十二个分量，索引偏移与原生渲染层保持一致。
    vertices = []
    index_values = []
    parts = []
    for node in gltf["nodes"]:
        if "mesh" not in node:
            continue
        assert not any(
            (k in node for k in ("matrix", "rotation", "translation", "scale"))
        ), "Do not silently discard transforms"
        for primitive in gltf["meshes"][node["mesh"]]["primitives"]:
            material = gltf["materials"][primitive["material"]]
            name = material["name"].split(".")[0]
            if name == "Carbon_Ink":
                continue
            positions = read_accessor(primitive["attributes"]["POSITION"])
            normals = read_accessor(primitive["attributes"]["NORMAL"])
            texture_coordinates = (
                read_accessor(primitive["attributes"]["TEXCOORD_0"])
                if "TEXCOORD_0" in primitive["attributes"]
                else [(0, 0)] * len(positions)
            )
            indices = read_accessor(primitive["indices"])
            index_offset = len(index_values)
            vertex_offset = len(vertices) // 12
            for i in range(len(positions)):
                vertices.extend([*positions[i], 1, *normals[i], 0, *texture_coordinates[i], 0, 0])
            index_values.extend((vertex_offset + i[0] for i in indices))
            parts.append(
                dict(
                    name=name,
                    start=index_offset,
                    count=len(indices),
                    vertexStart=vertex_offset,
                    vertexCount=len(positions),
                    material=material,
                    minimum=gltf["accessors"][primitive["attributes"]["POSITION"]]["min"],
                    maximum=gltf["accessors"][primitive["attributes"]["POSITION"]]["max"],
                    assemblyPart=node.get("extras", {}).get("assemblyPart", "shell"),
                )
            )
    # 原生绘制与拾取共用二进制坐标，不再生成脚本侧坐标副本。
    (output_directory / f"{asset}.bin").write_bytes(struct.pack("<" + "f" * len(vertices), *vertices))
    (output_directory / f"{asset}-indices.bin").write_bytes(
        struct.pack("<" + "I" * len(index_values), *index_values)
    )
    (output_directory / f"{asset}.json").write_text(
        json.dumps(
            dict(sourceSHA256=hashlib.sha256(source_bytes).hexdigest(), meshes=parts), ensure_ascii=False
        ),
        encoding="utf-8",
    )

for path in ["Resources/slots.json", "Resources/boot-lettering-art.json", "Resources/scene-fixture.json"]:
    (
        output_directory / ("slots.json" if path.endswith("slots.json") else pathlib.Path(path).name)
    ).write_bytes((root / path).read_bytes())
print(output_directory)
