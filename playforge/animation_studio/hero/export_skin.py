#!/usr/bin/env python3
"""Convert the SDK Hero skinned meshes and diffuse maps to a local glTF.

The Havok SDK's FileConvert sample is built here with the Animation reflection
classes enabled, then used to decode Rig.hkt to XML. The XML parser below reads
the original hkxSkinBinding, hkxVertexBuffer, hkxIndexBuffer and hkxMaterial
objects and writes a standard glTF 2.0 scene. Generated data is ignored by git.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import xml.etree.ElementTree as ET
from typing import Any

try:
    from PIL import Image
except ImportError:  # pragma: no cover - exercised only for the SDK's TGA maps.
    Image = None


DEFAULT_SDK = Path(r"D:\SDK\hk2015_1_0\hk2015_1_0_r1")
ET.register_namespace("", "http://schemas.microsoft.com/developer/msbuild/2003")
HERO_ASSETS = Path("Demo/Demos/Resources/Behavior/GameAssets/Hero/CharacterAssets")
RIG_FILE = HERO_ASSETS / "Rig.hkt"
OUTPUT_DIR = Path(__file__).resolve().parent / "generated"
ANIMATION_LIBS = [
    "hkBase.lib", "hkCompat.lib", "hkSceneData.lib", "hkInternal.lib",
    "hkVisualize.lib", "hkGeometryUtilities.lib", "hkImageUtilities.lib",
    "hkcdInternal.lib", "hkcdCollide.lib", "hkaAnimation.lib", "hkaInternal.lib",
]
VECTOR_USAGE = {1: "POSITION", 4: "NORMAL", 8: "TANGENT", 16: "BINORMAL"}


def find_msbuild() -> Path | None:
    for candidate in (
        Path(os.environ.get("MSBUILD", "")),
        Path(r"C:\Program Files\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe"),
        Path(r"C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe"),
        Path(r"C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\MSBuild\Current\Bin\MSBuild.exe"),
    ):
        if candidate.is_file():
            return candidate
    return None


def build_converter(sdk_root: Path, build_dir: Path) -> Path:
    """Build the SDK converter with its animation reflection class list."""
    sdk_project_dir = sdk_root / "Tools/FileConvert"
    template_path = sdk_project_dir / "FileConvert_x64_vs2015.vcxproj.template"
    project_dir = build_dir / "converter"
    project_dir.mkdir(parents=True, exist_ok=True)
    project_path = project_dir / "FileConvert_animation.vcxproj"
    executable = build_dir / "bin/FileConvert.exe"
    if not template_path.is_file():
        raise FileNotFoundError(f"SDK FileConvert project template not found: {template_path}")
    msbuild = find_msbuild()
    if msbuild is None:
        raise RuntimeError("MSBuild was not found. Set MSBUILD to a Visual Studio MSBuild.exe path.")

    tree = ET.parse(template_path)
    project = tree.getroot()
    ns = {"msb": "http://schemas.microsoft.com/developer/msbuild/2003"}
    dependencies = ";".join(ANIMATION_LIBS) + ";%(AdditionalDependencies)"
    for node in project.findall(".//msb:PreprocessorDefinitions", ns):
        node.text = "HK_FEATURE_PRODUCT_ANIMATION;" + (node.text or "")
    for node in project.findall(".//msb:AdditionalDependencies", ns):
        node.text = dependencies
    for node in project.findall(".//msb:AdditionalIncludeDirectories", ns):
        node.text = f"{sdk_root / 'Source'};{sdk_project_dir};%(AdditionalIncludeDirectories)"
    for node in project.findall(".//msb:AdditionalLibraryDirectories", ns):
        node.text = f"{sdk_root / 'Lib/x64_vs2015/dev'};%(AdditionalLibraryDirectories)"
    for node in project.findall(".//msb:IntDir", ns):
        node.text = str(build_dir / "obj") + os.sep
    for node in project.findall(".//msb:OutDir", ns):
        node.text = str(build_dir / "bin") + os.sep
    compile_item = project.find(".//msb:ClCompile[@Include='FileConvert.cpp']", ns)
    if compile_item is None:
        raise RuntimeError("SDK FileConvert template no longer includes FileConvert.cpp as expected")
    compile_item.attrib["Include"] = str(sdk_project_dir / "FileConvert.cpp")
    for node in project.findall(".//msb:PostBuildEvent", ns):
        parent = next(parent for parent in project.iter() if node in list(parent))
        parent.remove(node)
    tree.write(project_path, encoding="utf-8", xml_declaration=True)

    subprocess.run(
        [str(msbuild), str(project_path), "/t:Rebuild", "/p:Configuration=Dev", "/p:Platform=x64", "/p:PlatformToolset=v140", "/m", "/verbosity:minimal"],
        check=True,
    )
    # The project output directory is local to the ignored generated folder.
    if not executable.is_file():
        raise RuntimeError(f"MSBuild did not produce the converter: {executable}")
    return executable


def field(record: ET.Element, name: str) -> ET.Element:
    for item in record.findall("field"):
        if item.attrib.get("name") == name:
            return next(child for child in item if child.tag is not ET.Comment)
    raise KeyError(f"missing Havok XML field {name!r}")


def values(element: ET.Element, tag: str) -> list[ET.Element]:
    return [item for item in element.iter(tag)]


def xml_value(element: ET.Element) -> str:
    return element.attrib.get("value", "")


def xml_float(element: ET.Element) -> float:
    # Havok writes hkArray<hkFloat32> streams as integer bit patterns.
    if element.tag == "integer" and "value" in element.attrib:
        bits = int(element.attrib["value"]) & 0xFFFFFFFF
        return struct.unpack("<f", struct.pack("<I", bits))[0]
    return float(element.attrib.get("dec", element.attrib.get("value", "0")))


def matrix_from_xml(element: ET.Element) -> list[float]:
    out = [xml_float(item) for item in element.iter("real")]
    if len(out) != 16:
        raise ValueError(f"expected 16 values in hkMatrix4, got {len(out)}")
    return out


def convert_vector(vector: list[float]) -> list[float]:
    x, y, z = vector[:3]
    return [x, z, -y]


def convert_quaternion(q: list[float]) -> list[float]:
    x, y, z, w = q[:4]
    return [x, z, -y, w]


def mat4_rows(column_major: list[float]) -> list[list[float]]:
    return [[column_major[c * 4 + r] for c in range(4)] for r in range(4)]


def mat4_columns(rows: list[list[float]]) -> list[float]:
    return [rows[r][c] for c in range(4) for r in range(4)]


def multiply(a: list[list[float]], b: list[list[float]]) -> list[list[float]]:
    return [[sum(a[r][k] * b[k][c] for k in range(4)) for c in range(4)] for r in range(4)]


def inverse(matrix: list[list[float]]) -> list[list[float]]:
    work = [row[:] + [1.0 if r == c else 0.0 for c in range(4)] for r, row in enumerate(matrix)]
    for col in range(4):
        pivot = max(range(col, 4), key=lambda row: abs(work[row][col]))
        if abs(work[pivot][col]) < 1e-12:
            raise ValueError("singular skin bind transform")
        work[col], work[pivot] = work[pivot], work[col]
        scale = work[col][col]
        work[col] = [value / scale for value in work[col]]
        for row in range(4):
            if row == col:
                continue
            scale = work[row][col]
            work[row] = [work[row][i] - scale * work[col][i] for i in range(8)]
    return [row[4:] for row in work]


def matrix_to_godot(matrix: list[float]) -> list[float]:
    rows = mat4_rows(matrix)
    basis = [[1.0, 0.0, 0.0, 0.0], [0.0, 0.0, 1.0, 0.0], [0.0, -1.0, 0.0, 0.0], [0.0, 0.0, 0.0, 1.0]]
    basis_inv = [[basis[c][r] for c in range(4)] for r in range(4)]
    return mat4_columns(multiply(multiply(basis, rows), basis_inv))


def trs_matrix(translation: list[float], rotation: list[float], scale: list[float]) -> list[list[float]]:
    x, y, z, w = rotation
    sx, sy, sz = scale
    return [
        [(1 - 2 * (y * y + z * z)) * sx, (2 * (x * y - z * w)) * sy, (2 * (x * z + y * w)) * sz, translation[0]],
        [(2 * (x * y + z * w)) * sx, (1 - 2 * (x * x + z * z)) * sy, (2 * (y * z - x * w)) * sz, translation[1]],
        [(2 * (x * z - y * w)) * sx, (2 * (y * z + x * w)) * sy, (1 - 2 * (x * x + y * y)) * sz, translation[2]],
        [0.0, 0.0, 0.0, 1.0],
    ]


class GltfBuilder:
    def __init__(self, out_dir: Path):
        self.out_dir = out_dir
        self.buffer = bytearray()
        self.views: list[dict[str, Any]] = []
        self.accessors: list[dict[str, Any]] = []

    def accessor(self, data: bytes, component_type: int, count: int, kind: str, values_for_bounds: list[list[float]] | None = None, normalized: bool = False) -> int:
        while len(self.buffer) % 4:
            self.buffer.append(0)
        offset = len(self.buffer)
        self.buffer.extend(data)
        view = len(self.views)
        self.views.append({"buffer": 0, "byteOffset": offset, "byteLength": len(data)})
        item: dict[str, Any] = {"bufferView": view, "componentType": component_type, "count": count, "type": kind}
        if normalized:
            item["normalized"] = True
        if values_for_bounds:
            cols = zip(*values_for_bounds)
            item["min"] = [min(col) for col in cols]
            item["max"] = [max(col) for col in zip(*values_for_bounds)]
        self.accessors.append(item)
        return len(self.accessors) - 1

    def write(self, document: dict[str, Any], filename: str) -> Path:
        (self.out_dir / "hero_skin.bin").write_bytes(self.buffer)
        document["buffers"] = [{"uri": "hero_skin.bin", "byteLength": len(self.buffer)}]
        document["bufferViews"] = self.views
        document["accessors"] = self.accessors
        target = self.out_dir / filename
        target.write_text(json.dumps(document, separators=(",", ":")), encoding="utf-8")
        return target


def parse_xml(xml_path: Path, sdk_root: Path, out_dir: Path) -> tuple[dict[str, Any], dict[str, Any], GltfBuilder]:
    root = ET.parse(xml_path, parser=ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))).getroot()
    types = {item.attrib["id"]: item.find("name").attrib["value"] for item in root.findall("type") if item.find("name") is not None}
    objects = {item.attrib["id"]: item for item in root.findall("object")}

    def obj_fields(object_id: str) -> ET.Element:
        return objects[object_id].find("record")

    def field_for(object_id: str, name: str) -> ET.Element:
        return field(obj_fields(object_id), name)

    def list_items(array: ET.Element) -> list[ET.Element]:
        if array.tag != "array":
            array = array.find("array")
        if array is None:
            return []
        return [item for item in array if item.tag is not ET.Comment]

    def pointers(array: ET.Element) -> list[str]:
        return [item.attrib["id"] for item in list_items(array) if item.tag == "pointer"]

    def pointer_id(element: ET.Element) -> str:
        pointer = element if element.tag == "pointer" else element.find("pointer")
        if pointer is None:
            raise ValueError(f"expected Havok pointer, found {element.tag}")
        return pointer.attrib["id"]

    def array_element(element: ET.Element) -> ET.Element:
        array = element if element.tag == "array" else element.find("array")
        if array is None:
            raise ValueError(f"expected Havok array, found {element.tag}")
        return array

    def parse_ref_transform(element: ET.Element) -> dict[str, list[float]]:
        fields = {item.attrib["name"]: next(child for child in item if child.tag is not ET.Comment) for item in element.findall("field")}
        translation = [xml_float(v) for v in fields["translation"].findall("real")]
        rotation = [xml_float(v) for v in fields["rotation"].findall("real")]
        scale = [xml_float(v) for v in fields["scale"].findall("real")]
        return {"translation": convert_vector(translation), "rotation": convert_quaternion(rotation), "scale": [scale[0], scale[2], scale[1]]}

    skeleton_id = next(oid for oid in objects if types[objects[oid].attrib["typeid"]] == "hkaSkeleton")
    skeleton_record = obj_fields(skeleton_id)
    bone_names = [xml_value(field(item, "name")) for item in list_items(field_for(skeleton_id, "bones")) if item.tag == "record"]
    parents = [int(xml_value(item)) for item in list_items(field_for(skeleton_id, "parentIndices")) if item.tag == "integer"]
    refs = list_items(field_for(skeleton_id, "referencePose"))
    bones = [parse_ref_transform(item) for item in refs]
    if len(bone_names) != 85 or len(parents) != len(bones) or len(bones) != len(bone_names):
        raise ValueError(f"Hero rig expected 85 corresponding bones, got {len(bone_names)} names, {len(parents)} parents, {len(bones)} transforms")
    name_to_index = {name: index for index, name in enumerate(bone_names)}

    nodes: list[dict[str, Any]] = []
    bone_children: dict[int, list[int]] = {index: [] for index in range(len(bones))}
    root_bones = []
    for index, (name, parent, transform) in enumerate(zip(bone_names, parents, bones)):
        node: dict[str, Any] = {"name": name, **transform}
        nodes.append(node)
        if parent < 0:
            root_bones.append(index)
        else:
            bone_children[parent].append(index)
    if len(root_bones) != 1:
        raise ValueError(f"expected one Hero skeleton root, found {root_bones}")
    for index, children in bone_children.items():
        if children:
            nodes[index]["children"] = children

    builder = GltfBuilder(out_dir)
    gltf_materials: list[dict[str, Any]] = []
    material_by_id: dict[str, int] = {}
    images: list[dict[str, Any]] = []
    textures: list[dict[str, Any]] = []
    image_by_name: dict[str, int] = {}
    texture_dir = sdk_root / HERO_ASSETS / "textures"

    def material_index(material_id: str) -> int:
        if material_id in material_by_id:
            return material_by_id[material_id]
        mat_fields = {item.attrib["name"]: next(child for child in item if child.tag is not ET.Comment) for item in obj_fields(material_id).findall("field")}
        mat_name = xml_value(mat_fields["name"])
        material: dict[str, Any] = {"name": mat_name, "pbrMetallicRoughness": {"baseColorFactor": [1.0, 1.0, 1.0, 1.0], "metallicFactor": 0.0, "roughnessFactor": 0.72}}
        stages = list_items(mat_fields["stages"])
        diffuse = None
        for stage in stages:
            if stage.tag != "record":
                continue
            stage_values = {item.attrib["name"]: next(child for child in item if child.tag is not ET.Comment) for item in stage.findall("field")}
            if int(xml_value(stage_values["usageHint"])) == 1:
                diffuse = pointer_id(stage_values["texture"])
                break
        if diffuse:
            texture_name = Path(xml_value(field_for(diffuse, "filename"))).name
            source_texture = texture_dir / texture_name
            if not source_texture.is_file():
                raise FileNotFoundError(f"Hero texture referenced by Rig.hkt was not found: {source_texture}")
            output_texture = texture_name
            if source_texture.suffix.lower() == ".tga":
                if Image is None:
                    raise RuntimeError("Pillow is required to convert SDK TGA maps to glTF-compatible PNGs")
                output_texture = source_texture.stem + ".png"
                with Image.open(source_texture) as bitmap:
                    bitmap.save(out_dir / output_texture, format="PNG")
            elif not (out_dir / output_texture).is_file() or (out_dir / output_texture).stat().st_mtime < source_texture.stat().st_mtime:
                shutil.copy2(source_texture, out_dir / output_texture)
            if output_texture not in image_by_name:
                image_by_name[output_texture] = len(images)
                images.append({"uri": output_texture, "name": output_texture})
                textures.append({"source": image_by_name[output_texture]})
            material["pbrMetallicRoughness"]["baseColorTexture"] = {"index": image_by_name[output_texture]}
        if mat_name.lower() in ("lashes", "eyeblend"):
            material["alphaMode"] = "BLEND"
            material["doubleSided"] = True
        material_by_id[material_id] = len(gltf_materials)
        gltf_materials.append(material)
        return material_by_id[material_id]

    skin_bindings: dict[str, str] = {}
    for oid, element in objects.items():
        if types[element.attrib["typeid"]] == "hkxSkinBinding":
            mesh_id = pointer_id(field_for(oid, "mesh"))
            skin_bindings[mesh_id] = oid
    if len(skin_bindings) != 6:
        raise ValueError(f"expected six Hero skinned meshes, found {len(skin_bindings)}")
    native_mesh_bindings: dict[str, str] = {}
    for oid, element in objects.items():
        if types[element.attrib["typeid"]] == "hkaMeshBinding":
            native_mesh_bindings[pointer_id(field_for(oid, "mesh"))] = oid
    if set(native_mesh_bindings) != set(skin_bindings):
        raise ValueError("hkxSkinBinding and hkaMeshBinding do not reference the same six meshes")

    skins: list[dict[str, Any]] = []
    mesh_nodes = []
    gltf_meshes = []
    max_bind_conversion_error = 0.0
    root_node = nodes[root_bones[0]]
    root_node.setdefault("children", [])

    def decode_stream(field_el: ET.Element, expected_count: int, *, uint8: bool = False) -> list[int] | list[float]:
        arr = array_element(field_el)
        stream = list_items(arr)
        if len(stream) != expected_count:
            raise ValueError(f"stream expected {expected_count} items, got {len(stream)}")
        if uint8:
            return [int(item.attrib["value"]) & 0xFF for item in stream]
        return [xml_float(item) for item in stream]

    for mesh_id, binding_id in skin_bindings.items():
        binding_fields = {item.attrib["name"]: next(child for child in item if child.tag is not ET.Comment) for item in obj_fields(binding_id).findall("field")}
        binding_names = [xml_value(item) for item in list_items(binding_fields["nodeNames"]) if item.tag == "string"]
        if len(binding_names) != len(bone_names) or set(binding_names) != set(bone_names):
            raise ValueError(f"skin binding {binding_id} does not match original skeleton bone names")
        binding_to_source = [name_to_index[name] for name in binding_names]
        bind_matrices = [matrix_from_xml(item) for item in list_items(binding_fields["bindPose"])]
        if len(bind_matrices) != len(binding_names):
            raise ValueError(f"skin binding {binding_id} bind-pose count does not match its bone names")
        init_skin = matrix_from_xml(binding_fields["initSkinTransform"])
        # Prefer Havok's animation binding palette (bone-from-skin-mesh), which
        # is the exact glTF inverse-bind matrix. Cross-check it with hkxSkinBinding
        # world bind poses to catch matrix order or basis conversion mistakes.
        native_binding = native_mesh_bindings[mesh_id]
        native_transforms = list_items(field_for(native_binding, "boneFromSkinMeshTransforms"))
        if len(native_transforms) != len(bone_names):
            raise ValueError(f"hkaMeshBinding {native_binding} has {len(native_transforms)} transforms for {len(bone_names)} bones")
        inverse_binds = []
        for source_index in range(len(bone_names)):
            binding_index = binding_to_source.index(source_index)
            reconstructed = mat4_columns(multiply(
                inverse(mat4_rows(matrix_to_godot(bind_matrices[binding_index]))),
                mat4_rows(matrix_to_godot(init_skin)),
            ))
            authoritative = matrix_to_godot(matrix_from_xml(native_transforms[source_index]))
            discrepancy = max(abs(a - b) for a, b in zip(reconstructed, authoritative))
            max_bind_conversion_error = max(max_bind_conversion_error, discrepancy)
            if discrepancy > 1e-4:
                raise ValueError(f"skin inverse bind disagrees with hkaMeshBinding by {discrepancy:g} for {bone_names[source_index]}")
            inverse_binds.append(authoritative)
        ibm_bytes = b"".join(struct.pack("<16f", *matrix) for matrix in inverse_binds)
        ibm_accessor = builder.accessor(ibm_bytes, 5126, len(inverse_binds), "MAT4")
        skin_index = len(skins)
        skin: dict[str, Any] = {"name": f"HeroSkin{skin_index}", "joints": list(range(len(bone_names))), "inverseBindMatrices": ibm_accessor, "skeleton": root_bones[0]}
        skins.append(skin)

        section_refs = pointers(field_for(mesh_id, "sections"))
        primitives = []
        for section_id in section_refs:
            section_fields = {item.attrib["name"]: next(child for child in item if child.tag is not ET.Comment) for item in obj_fields(section_id).findall("field")}
            vertex_id = pointer_id(section_fields["vertexBuffer"])
            vertex_fields = {item.attrib["name"]: next(child for child in item if child.tag is not ET.Comment) for item in obj_fields(vertex_id).findall("field")}
            data_fields = {item.attrib["name"]: next(child for child in item if child.tag is not ET.Comment) for item in vertex_fields["data"].findall("field")}
            vertex_count = int(xml_value(data_fields["numVerts"]))
            vectors = decode_stream(data_fields["vectorData"], vertex_count * 16)
            floats = decode_stream(data_fields["floatData"], vertex_count * 2)
            byte_data = decode_stream(data_fields["uint8Data"], vertex_count * 8, uint8=True)
            positions, normals, tangents, uvs, joints, weights = [], [], [], [], [], []
            for vertex in range(vertex_count):
                base = vertex * 16
                positions.append(convert_vector(vectors[base:base + 3]))
                normals.append(convert_vector(vectors[base + 4:base + 7]))
                tangent = convert_vector(vectors[base + 8:base + 11])
                binormal = convert_vector(vectors[base + 12:base + 15])
                normal = normals[-1]
                sign = 1.0 if sum((normal[1] * tangent[2] - normal[2] * tangent[1]) * binormal[0] + (normal[2] * tangent[0] - normal[0] * tangent[2]) * binormal[1] + (normal[0] * tangent[1] - normal[1] * tangent[0]) * binormal[2] for _ in [0]) >= 0.0 else -1.0
                tangents.append(tangent + [sign])
                uvs.append([floats[vertex * 2], 1.0 - floats[vertex * 2 + 1]])
                weight_bytes = byte_data[vertex * 8:vertex * 8 + 4]
                joint_bytes = byte_data[vertex * 8 + 4:vertex * 8 + 8]
                joints.append([binding_to_source[index] for index in joint_bytes])
                total_weight = sum(weight_bytes)
                weights.append([value / total_weight if total_weight else 0.0 for value in weight_bytes])

            position_accessor = builder.accessor(b"".join(struct.pack("<3f", *v) for v in positions), 5126, vertex_count, "VEC3", positions)
            normal_accessor = builder.accessor(b"".join(struct.pack("<3f", *v) for v in normals), 5126, vertex_count, "VEC3")
            tangent_accessor = builder.accessor(b"".join(struct.pack("<4f", *v) for v in tangents), 5126, vertex_count, "VEC4")
            uv_accessor = builder.accessor(b"".join(struct.pack("<2f", *v) for v in uvs), 5126, vertex_count, "VEC2")
            joint_accessor = builder.accessor(b"".join(struct.pack("<4B", *v) for v in joints), 5121, vertex_count, "VEC4")
            weight_accessor = builder.accessor(b"".join(struct.pack("<4f", *v) for v in weights), 5126, vertex_count, "VEC4")
            index_buffer_refs = pointers(section_fields["indexBuffers"])
            if len(index_buffer_refs) != 1:
                raise ValueError(f"section {section_id} must have one index buffer")
            index_fields = {item.attrib["name"]: next(child for child in item if child.tag is not ET.Comment) for item in obj_fields(index_buffer_refs[0]).findall("field")}
            index_values = [int(xml_value(item)) for item in list_items(index_fields["indices16"]) if item.tag == "integer"]
            if max(index_values, default=0) > 65535:
                index_accessor = builder.accessor(b"".join(struct.pack("<I", value) for value in index_values), 5125, len(index_values), "SCALAR")
            else:
                index_accessor = builder.accessor(b"".join(struct.pack("<H", value) for value in index_values), 5123, len(index_values), "SCALAR")
            material_id = pointer_id(section_fields["material"])
            primitives.append({
                "attributes": {"POSITION": position_accessor, "NORMAL": normal_accessor, "TANGENT": tangent_accessor, "TEXCOORD_0": uv_accessor, "JOINTS_0": joint_accessor, "WEIGHTS_0": weight_accessor},
                "indices": index_accessor,
                "material": material_index(material_id),
                "mode": 4,
            })

        mesh_index = len(gltf_meshes)
        gltf_meshes.append({"name": f"HeroMesh_{mesh_id}", "primitives": primitives})
        mesh_node_index = len(nodes)
        mesh_transform = matrix_to_godot(init_skin)
        node: dict[str, Any] = {"name": f"HeroMesh_{mesh_id}", "mesh": mesh_index, "skin": skin_index, "matrix": mesh_transform}
        nodes.append(node)
        mesh_nodes.append(mesh_node_index)

    document: dict[str, Any] = {
        "asset": {"version": "2.0", "generator": "Animation Studio Hero skin exporter"},
        "scene": 0,
        "scenes": [{"name": "Hero", "nodes": root_bones + mesh_nodes}],
        "nodes": nodes,
        "meshes": gltf_meshes,
        "skins": skins,
        "materials": gltf_materials,
        "images": images,
        "textures": textures,
        "samplers": [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}],
        "extensionsUsed": [],
    }
    # Textures use the default sampler unless the importer has its own project setting.
    for texture in document["textures"]:
        texture["sampler"] = 0
    metadata = {
        "source": "Havok SDK hk2015_1_0_r1 Hero/CharacterAssets/Rig.hkt",
        "skeletonBoneCount": len(bone_names),
        "skinBindingCount": len(skins),
        "skinnedMeshCount": len(gltf_meshes),
        "sectionCount": sum(len(mesh["primitives"]) for mesh in gltf_meshes),
        "maxInverseBindMatrixDiscrepancy": max_bind_conversion_error,
        "jointOrder": "hkaSkeleton bones/source order; JOINTS_0 indices remap hkxSkinBinding.nodeNames into that same order",
        "textures": [image["uri"] for image in images],
    }
    return document, metadata, builder


def export(sdk_root: Path, output_dir: Path, xml_path: Path | None, converter: Path | None) -> dict[str, Any]:
    sdk_root = sdk_root.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    # The sample loads its glTF at runtime, bypassing the editor import cache.
    (output_dir / ".gdignore").touch()
    rig_hash = None
    if xml_path is None:
        xml_path = output_dir / "Rig.xml"
        source_rig = sdk_root / RIG_FILE
        if not source_rig.is_file():
            raise FileNotFoundError(f"SDK Hero rig not found: {source_rig}")
        rig_hash = hashlib.sha256(source_rig.read_bytes()).hexdigest()
        converter = converter or build_converter(sdk_root, output_dir / "build")
        subprocess.run([str(converter), "-x", str(source_rig), str(xml_path)], check=True)
    if not xml_path.is_file():
        raise FileNotFoundError(f"Havok XML input not found: {xml_path}")
    document, metadata, builder = parse_xml(xml_path, sdk_root, output_dir)
    path = builder.write(document, "hero_skin.gltf")
    metadata["rig_sha256"] = rig_hash
    metadata["gltf"] = path.name
    (output_dir / "hero_skin.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    return metadata


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk-root", type=Path, default=DEFAULT_SDK)
    parser.add_argument("--output-dir", type=Path, default=OUTPUT_DIR)
    parser.add_argument("--xml", type=Path, help="reuse a converted Havok XML file")
    parser.add_argument("--converter", type=Path, help="path to the animation-enabled Havok FileConvert executable")
    args = parser.parse_args()
    metadata = export(args.sdk_root, args.output_dir, args.xml, args.converter)
    print(json.dumps(metadata, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
