#!/usr/bin/env python3
"""Convert a Roblox Studio XML place (.rbxlx) into chunked JSON for runtime.lua.

This is a best-effort client-side scene exporter, not a script decompiler. It deliberately
omits Script, LocalScript, ModuleScript, remotes, and other server/network behaviour.

Usage:
  python -m pip install lxml
  python convert_rbxlx.py "Cubev4.rbxlx" --output-dir "./cubev4-client-rebuild"

The output directory contains data/manifest.json and data/chunks/*.json.
"""
from __future__ import annotations
import argparse
import json
import os
import re
import sqlite3
import sys
import tempfile
from pathlib import Path
from typing import Any

try:
    from lxml import etree
except ImportError:
    print("Missing dependency: lxml. Install it with: python -m pip install lxml", file=sys.stderr)
    raise

ROOT_SERVICES = {
    "Workspace", "ServerStorage", "ReplicatedStorage", "StarterGui", "StarterPack",
    "StarterPlayer", "Lighting", "SoundService",
}
DEFAULT_ROOTS = ",".join(sorted(ROOT_SERVICES))
SKIP_CLASSES = {
    "Script", "LocalScript", "ModuleScript", "RemoteEvent", "RemoteFunction",
    "UnreliableRemoteEvent", "BindableEvent", "BindableFunction", "Actor",
}
# Classes representing engine services rather than ordinary Instances are handled as roots.


def tag_name(el) -> str:
    return etree.QName(el).localname


def child_text(el, name: str, default: str = "0") -> str:
    for child in el:
        if tag_name(child) == name:
            return (child.text or default).strip()
    return default


def as_float(text: str) -> float:
    try:
        return float(text)
    except (TypeError, ValueError):
        return 0.0


def as_int(text: str) -> int:
    try:
        return int(text)
    except (TypeError, ValueError):
        return 0


def decode_xml_value(el, prop_name: str) -> Any:
    tag = tag_name(el)
    text = (el.text or "").strip()
    if tag in ("string", "ProtectedString"):
        # Script Source is never included because script classes are excluded.
        return text
    if tag in ("bool",):
        return text.lower() == "true"
    if tag in ("int", "int64", "token"):
        if tag == "token":
            return {"__type": "Token", "value": as_int(text)}
        return as_int(text)
    if tag in ("float", "double"):
        return as_float(text)
    if tag == "Ref":
        return {"__type": "Ref", "value": text}
    if tag == "Content":
        url = ""
        for node in el.iter():
            if tag_name(node) == "url":
                url = (node.text or "").strip()
                break
        return {"__type": "Content", "value": url}
    if tag == "Vector3":
        return {"__type": "Vector3", "x": as_float(child_text(el, "X")), "y": as_float(child_text(el, "Y")), "z": as_float(child_text(el, "Z"))}
    if tag == "Vector2":
        return {"__type": "Vector2", "x": as_float(child_text(el, "X")), "y": as_float(child_text(el, "Y"))}
    if tag == "Color3":
        return {"__type": "Color3", "r": as_float(child_text(el, "R")), "g": as_float(child_text(el, "G")), "b": as_float(child_text(el, "B"))}
    if tag in ("CoordinateFrame", "CFrame"):
        names = ("X", "Y", "Z", "R00", "R01", "R02", "R10", "R11", "R12", "R20", "R21", "R22")
        return {"__type": "CFrame", "components": [as_float(child_text(el, name, "1" if name in ("R00", "R11", "R22") else "0")) for name in names]}
    if tag == "UDim":
        return {"__type": "UDim", "scale": as_float(child_text(el, "S")), "offset": as_int(child_text(el, "O"))}
    if tag == "UDim2":
        x = next((n for n in el if tag_name(n) == "X"), None)
        y = next((n for n in el if tag_name(n) == "Y"), None)
        return {"__type": "UDim2", "xScale": as_float(child_text(x, "S") if x is not None else "0"), "xOffset": as_int(child_text(x, "O") if x is not None else "0"), "yScale": as_float(child_text(y, "S") if y is not None else "0"), "yOffset": as_int(child_text(y, "O") if y is not None else "0")}
    if tag == "BrickColor":
        return {"__type": "BrickColor", "number": as_int(text)}
    if tag == "NumberRange":
        return {"__type": "NumberRange", "min": as_float(child_text(el, "min")), "max": as_float(child_text(el, "max"))}
    if tag == "NumberSequence":
        points = []
        for kp in el:
            if tag_name(kp) == "Keypoint":
                points.append({"time": as_float(child_text(kp, "Time")), "value": as_float(child_text(kp, "Value")), "envelope": as_float(child_text(kp, "Envelope"))})
        return {"__type": "NumberSequence", "keypoints": points}
    if tag == "ColorSequence":
        points = []
        for kp in el:
            if tag_name(kp) == "Keypoint":
                color = next((n for n in kp if tag_name(n) == "Color3"), None)
                points.append({"time": as_float(child_text(kp, "Time")), "r": as_float(child_text(color, "R") if color is not None else "0"), "g": as_float(child_text(color, "G") if color is not None else "0"), "b": as_float(child_text(color, "B") if color is not None else "0")})
        return {"__type": "ColorSequence", "keypoints": points}
    if tag == "PhysicalProperties":
        return {"__type": "PhysicalProperties", "density": as_float(child_text(el, "Density")), "friction": as_float(child_text(el, "Friction")), "elasticity": as_float(child_text(el, "Elasticity")), "frictionWeight": as_float(child_text(el, "FrictionWeight")), "elasticityWeight": as_float(child_text(el, "ElasticityWeight"))}
    if tag == "Rect2D":
        min_el = next((n for n in el if tag_name(n) == " min" or tag_name(n) == "Min"), None)
        max_el = next((n for n in el if tag_name(n) == " max" or tag_name(n) == "Max"), None)
        if min_el is not None and max_el is not None:
            return {"__type": "Rect", "minX": as_float(child_text(min_el, "X")), "minY": as_float(child_text(min_el, "Y")), "maxX": as_float(child_text(max_el, "X")), "maxY": as_float(child_text(max_el, "Y"))}
    # Keep only values that the runtime has a reasonable chance to assign.
    return None


def parse_properties(properties_el) -> tuple[str | None, dict[str, Any]]:
    name = None
    props: dict[str, Any] = {}
    for prop in properties_el:
        prop_name = prop.get("name")
        if not prop_name:
            continue
        if prop_name in {"Source", "LinkedSource", "Capabilities", "Sandboxed"}:
            continue
        try:
            value = decode_xml_value(prop, prop_name)
        except Exception:
            value = None
        if value is not None:
            if prop_name == "Name" and isinstance(value, str):
                name = value
            elif prop_name not in ("Parent", "Name"):
                props[prop_name] = value
    return name, props


def safe_file_part(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]+", "_", text).strip("_") or "root"


def convert(input_file: Path, output_dir: Path, roots: set[str], chunk_bytes: int) -> dict:
    if not input_file.exists():
        raise FileNotFoundError(input_file)
    data_dir = output_dir / "data"
    chunks_dir = data_dir / "chunks"
    chunks_dir.mkdir(parents=True, exist_ok=True)
    # Remove old chunk outputs to prevent stale chunks remaining in a rebuilt repo.
    for old in chunks_dir.glob("*.json"):
        old.unlink()
    manifest_path = data_dir / "manifest.json"
    if manifest_path.exists():
        manifest_path.unlink()

    db_fd, db_name = tempfile.mkstemp(prefix="cubev4_", suffix=".sqlite")
    os.close(db_fd)
    db = sqlite3.connect(db_name)
    db.execute("CREATE TABLE records (id TEXT PRIMARY KEY, parent TEXT, root TEXT, depth INTEGER, seq INTEGER, payload TEXT)")

    stack: list[dict[str, Any]] = []
    seq = 0
    parsed_items = 0
    exported_items = 0
    try:
        context = etree.iterparse(str(input_file), events=("start", "end"), huge_tree=True, recover=False)
        for event, elem in context:
            tag = tag_name(elem)
            if event == "start" and tag == "Item":
                class_name = elem.get("class", "Instance")
                referent = elem.get("referent") or f"GEN_{seq + 1}"
                parent = stack[-1] if stack else None

                if class_name in ROOT_SERVICES:
                    root = class_name
                    include = False  # Services are routing roots, not reconstructed Instances.
                    allow_children = class_name in roots
                    parent_id = None
                    is_root_service = True
                elif parent is None:
                    root = None
                    include = False
                    allow_children = False
                    parent_id = None
                    is_root_service = False
                else:
                    root = parent.get("root")
                    parent_allows = parent.get("allow_children") if parent.get("is_root_service") else parent.get("include")
                    include = bool(parent_allows) and class_name not in SKIP_CLASSES
                    allow_children = include
                    parent_id = None if parent.get("is_root_service") else parent.get("referent")
                    is_root_service = False

                if class_name in SKIP_CLASSES:
                    include = False
                    allow_children = False
                record = {
                    "class": class_name,
                    "referent": referent,
                    "parent": parent_id,
                    "root": root,
                    "depth": 0 if parent is None or (parent and parent.get("is_root_service")) else int(parent.get("depth", 0)) + 1,
                    "include": include,
                    "allow_children": allow_children,
                    "is_root_service": is_root_service,
                    "name": class_name,
                    "properties": {},
                }
                stack.append(record)

            elif event == "end" and tag == "Properties":
                if stack:
                    name, props = parse_properties(elem)
                    if name:
                        stack[-1]["name"] = name
                    stack[-1]["properties"].update(props)
                elem.clear()

            elif event == "end" and tag == "Item":
                if not stack:
                    elem.clear()
                    continue
                record = stack.pop()
                parsed_items += 1
                if record["include"] and record["root"]:
                    seq += 1
                    payload = {
                        "id": record["referent"],
                        "class": record["class"],
                        "name": record["name"],
                        "parent": record["parent"],
                        "root": record["root"],
                        "properties": record["properties"],
                    }
                    db.execute(
                        "INSERT OR REPLACE INTO records(id,parent,root,depth,seq,payload) VALUES(?,?,?,?,?,?)",
                        (record["referent"], record["parent"], record["root"], record["depth"], seq, json.dumps(payload, separators=(",", ":"), ensure_ascii=False)),
                    )
                    exported_items += 1
                # Free processed XML nodes; lxml supports removing from the parent.
                elem.clear()
                parent_element = elem.getparent()
                if parent_element is not None:
                    while elem.getprevious() is not None:
                        del parent_element[0]
        db.commit()

        chunks = []
        total_bytes = 0
        cur = db.execute("SELECT root,payload FROM records ORDER BY root,depth,seq")
        active_root = None
        buffer: list[str] = []
        buffer_size = 2
        chunk_no = 0

        def flush(root_name: str | None):
            nonlocal buffer, buffer_size, chunk_no, total_bytes
            if not buffer or not root_name:
                buffer = []
                buffer_size = 2
                return
            chunk_no += 1
            filename = f"chunks/{safe_file_part(root_name)}_{chunk_no:04d}.json"
            file_path = data_dir / filename
            with file_path.open("w", encoding="utf-8", newline="\n") as handle:
                handle.write('{"instances":[')
                handle.write(",".join(buffer))
                handle.write("]}")
            size = file_path.stat().st_size
            total_bytes += size
            chunks.append({"file": filename, "root": root_name, "count": len(buffer), "bytes": size})
            buffer = []
            buffer_size = 2

        for root_name, payload in cur:
            if active_root is None:
                active_root = root_name
            if root_name != active_root:
                flush(active_root)
                active_root = root_name
                chunk_no = 0
            encoded = payload
            extra = len(encoded.encode("utf-8")) + (1 if buffer else 0)
            if buffer and buffer_size + extra > chunk_bytes:
                flush(active_root)
                chunk_no = len([c for c in chunks if c["root"] == active_root])
            buffer.append(encoded)
            buffer_size += extra
        flush(active_root)

        manifest = {
            "format": "cubev4-client-data-v1",
            "source": input_file.name,
            "totalInstances": exported_items,
            "parsedXmlItems": parsed_items,
            "omittedClasses": sorted(SKIP_CLASSES),
            "roots": sorted(roots),
            "chunkCount": len(chunks),
            "chunks": chunks,
            "notes": [
                "Best-effort XML export. Unsupported property value types are omitted.",
                "Scripts, remotes, server logic, and persistence are intentionally excluded.",
                "Mesh/texture/audio content IDs remain references; the binary asset data is not embedded.",
                "The runtime only attempts local Instance construction and property assignment.",
            ],
        }
        data_dir.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    finally:
        db.close()
        try:
            os.remove(db_name)
        except OSError:
            pass

    return {"parsed": parsed_items, "exported": exported_items, "chunks": len(chunks), "bytes": total_bytes, "manifest": str(manifest_path)}


def main() -> int:
    parser = argparse.ArgumentParser(description="Export RBXLX scene data into JSON chunks for the Cubev4 client runtime.")
    parser.add_argument("input", type=Path, help="Input .rbxlx exported from Roblox Studio")
    parser.add_argument("--output-dir", type=Path, default=Path("."), help="Repository/output directory")
    parser.add_argument("--roots", default=DEFAULT_ROOTS, help="Comma-separated services to export")
    parser.add_argument("--chunk-bytes", type=int, default=1_500_000, help="Approximate maximum chunk size (default 1.5 MB)")
    args = parser.parse_args()
    roots = {item.strip() for item in args.roots.split(",") if item.strip()}
    result = convert(args.input, args.output_dir, roots, max(100_000, args.chunk_bytes))
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
