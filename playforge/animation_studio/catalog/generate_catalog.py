#!/usr/bin/env python3
"""Build a path-only inventory of Havok Animation demo registrations.

Uses Python's standard library. Run with the SDK root as the first argument:
    python generate_catalog.py D:/SDK/hk2015_1_0/hk2015_1_0_r1
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Iterable

MACROS = {
    "HK_DECLARE_DEMO", "HK_DECLARE_DEMO_RENAME", "HK_DECLARE_DEMO_NO_REG",
    "HK_DECLARE_DEMO_SYMLINK", "HK_DECLARE_DEMO_VARIANT",
    "HK_DECLARE_DEMO_VARIANT_RENAME", "HK_DECLARE_DEMO_VARIANT_NO_REG",
    "HK_DECLARE_DEMO_VARIANT_SYMLINK", "HK_DECLARE_DEMO_VARIANT_USING_ENUM",
    "HK_DECLARE_DEMO_VARIANT_USING_ENUM_RENAME",
    "HK_DECLARE_DEMO_VARIANT_USING_STRUCT",
    "HK_DECLARE_DEMO_VARIANT_USING_STRUCT_RENAME",
    "HK_DECLARE_DEMO_VARIANT_USING_STRUCT_SYMLINK", "HK_DECLARE_DEMO_FACTORY",
    "HKA_DECLARE_PHYSICS_DEMO", "HKA_DECLARE_PHYSICS_DEMO_FACTORY",
    "HKA_DECLARE_PHYSICS_DEMO_VARIANT_USING_STRUCT",
    "HKA_DECLARE_PHYSICS_2012_DEMO", "HKA_DECLARE_PHYSICS_2012_DEMO_FACTORY",
    "HKA_DECLARE_PHYSICS_2012_DEMO_VARIANT_USING_STRUCT",
    "HKB_DECLARE_DEMO", "HKB_DECLARE_DEMO_RENAME", "HKB_DECLARE_DEMO_NO_REG",
    "HKB_DECLARE_DEMO_SYMLINK", "HKB_DECLARE_DEMO_VARIANT",
    "HKB_DECLARE_DEMO_VARIANT_RENAME", "HKB_DECLARE_DEMO_VARIANT_USING_STRUCT",
    "HKB_DECLARE_DEMO_FACTORY",
    "HKB_DECLARE_PHYSICS_DEMO", "HKB_DECLARE_PHYSICS_DEMO_FACTORY",
    "HKB_DECLARE_PHYSICS_DEMO_VARIANT", "HKB_DECLARE_PHYSICS_DEMO_VARIANT_USING_STRUCT",
    "HKB_DECLARE_PHYSICS_2012_DEMO", "HKB_DECLARE_PHYSICS_2012_DEMO_FACTORY",
    "HKB_DECLARE_PHYSICS_2012_DEMO_VARIANT", "HKB_DECLARE_PHYSICS_2012_DEMO_VARIANT_USING_STRUCT",
}
DOMAIN_FLAGS = {
    "HK_DEMO_TYPE_ANIMATION": "animation",
    "HK_DEMO_TYPE_BEHAVIOR": "behavior",
    "HK_DEMO_TYPE_OTHER": "other",
    "HK_DEMO_TYPE_TEST": "test",
    "HK_DEMO_TYPE_PHYSICS": "physics",
    "HK_DEMO_TYPE_PHYSICS_2012": "physics_2012",
    "HK_DEMO_TYPE_AI": "ai",
}


def mask_comments(text: str) -> str:
    """Replace C++ comments with spaces while retaining strings and newlines."""
    out = list(text)
    i = 0
    state = "code"
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if state == "code":
            if ch == '"':
                state = "string"
            elif ch == "'":
                state = "char"
            elif ch == "/" and nxt == "/":
                out[i] = out[i + 1] = " "
                i += 1
                state = "line_comment"
            elif ch == "/" and nxt == "*":
                out[i] = out[i + 1] = " "
                i += 1
                state = "block_comment"
        elif state in ("string", "char"):
            if ch == "\\":
                i += 1
            elif (state == "string" and ch == '"') or (state == "char" and ch == "'"):
                state = "code"
        elif state == "line_comment":
            if ch == "\n":
                state = "code"
            else:
                out[i] = " "
        elif state == "block_comment":
            if ch == "*" and nxt == "/":
                out[i] = out[i + 1] = " "
                i += 1
                state = "code"
            elif ch != "\n":
                out[i] = " "
        i += 1
    return "".join(out)


def split_args(text: str) -> list[str]:
    args: list[str] = []
    start = 0
    stack: list[str] = []
    quote = ""
    escaped = False
    pairs = {")": "(", "]": "[", "}": "{"}
    for i, ch in enumerate(text):
        if quote:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == quote:
                quote = ""
            continue
        if ch in ('"', "'"):
            quote = ch
        elif ch in "([{" :
            stack.append(ch)
        elif ch in ")]}" and stack and stack[-1] == pairs[ch]:
            stack.pop()
        elif ch == "," and not stack:
            args.append(text[start:i].strip())
            start = i + 1
    tail = text[start:].strip()
    if tail:
        args.append(tail)
    return args


def macro_calls(masked: str) -> Iterable[tuple[str, list[str], int]]:
    pattern = re.compile(r"\b((?:HK_DECLARE_DEMO[A-Z0-9_]*|HK[AB]_DECLARE_(?:PHYSICS(?:_2012)?_)?DEMO[A-Z0-9_]*))\s*\(")
    for match in pattern.finditer(masked):
        name = match.group(1)
        start = match.end()
        depth = 1
        quote = ""
        escaped = False
        i = start
        while i < len(masked) and depth:
            ch = masked[i]
            if quote:
                if escaped:
                    escaped = False
                elif ch == "\\":
                    escaped = True
                elif ch == quote:
                    quote = ""
            elif ch in ('"', "'"):
                quote = ch
            elif ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            i += 1
        if depth == 0:
            yield name, split_args(masked[start:i - 1]), masked.count("\n", 0, match.start()) + 1


def context_at_line(masked: str, target_line: int) -> tuple[list[str], bool]:
    stack: list[dict[str, object]] = []
    for line_no, line in enumerate(masked.splitlines(), 1):
        if line_no >= target_line:
            break
        directive = re.match(r"\s*#\s*(if|ifdef|ifndef|elif|else|endif)\b(.*)", line)
        if not directive:
            continue
        command, expression = directive.group(1), directive.group(2).strip()
        if command in ("if", "ifdef", "ifndef"):
            full = f"#{command} {expression}".strip()
            disabled = command == "if" and re.fullmatch(r"(?:0|false)\s*", expression, re.I) is not None
            stack.append({"condition": full, "disabled": disabled})
        elif command == "elif" and stack:
            parent = stack[-1]
            stack[-1] = {"condition": f"#elif {expression}", "disabled": command == "elif" and re.fullmatch(r"(?:0|false)\s*", expression, re.I) is not None}
        elif command == "else" and stack:
            parent = stack[-1]
            stack[-1] = {"condition": f"#else after {parent['condition']}", "disabled": False}
        elif command == "endif" and stack:
            stack.pop()
    conditions = [str(item["condition"]) for item in stack]
    disabled = any(bool(item["disabled"]) for item in stack)
    return conditions, disabled


def decode_string_expression(expr: str, defines: dict[str, str] | None = None) -> tuple[str | None, str]:
    """Resolve adjacent C strings and simple string macros without evaluating C++."""
    raw = " ".join(expr.strip().split())
    text = raw
    for _ in range(4):
        changed = False
        for name, value in (defines or {}).items():
            replaced = re.sub(rf"\b{re.escape(name)}\b", lambda _match: value, text)
            changed |= replaced != text
            text = replaced
        if not changed:
            break
    tokens = re.findall(r'"(?:\\.|[^"\\])*"', text)
    residue = re.sub(r'"(?:\\.|[^"\\])*"', "", text).strip()
    if not tokens or residue:
        return None, raw
    value = ""
    for token in tokens:
        try:
            value += bytes(token[1:-1], "utf-8").decode("unicode_escape")
        except UnicodeDecodeError:
            value += token[1:-1]
    return value, raw


def local_string_defines(masked: str) -> dict[str, str]:
    return {name: value.strip() for name, value in re.findall(
        r"^\s*#\s*define\s+([A-Za-z_]\w*)\s+([^\n]+)", masked, re.M
    )}


def balanced_block(text: str, open_at: int) -> int | None:
    depth = 0
    quote = ""
    escaped = False
    for i in range(open_at, len(text)):
        ch = text[i]
        if quote:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == quote:
                quote = ""
            continue
        if ch in ('"', "'"):
            quote = ch
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i
    return None


def table_variants(masked: str, table_expr: str, struct_expr: str, defines: dict[str, str]) -> list[dict[str, object]]:
    table_name = re.findall(r"[A-Za-z_]\w*", table_expr)
    struct_name = re.findall(r"[A-Za-z_]\w*", struct_expr)
    if not table_name or not struct_name:
        return []
    identifier = table_name[-1]
    struct_match = re.search(rf"\bstruct\s+{re.escape(struct_name[-1])}\s*\{{", masked)
    name_field_index = 0
    if struct_match:
        struct_open = masked.find("{", struct_match.start())
        struct_close = balanced_block(masked, struct_open)
        if struct_close is not None:
            field_declarations = [part.strip() for part in masked[struct_open + 1:struct_close].split(";") if part.strip()]
            field_names = []
            for declaration in field_declarations:
                names = re.findall(r"\b([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*$", declaration)
                if names:
                    field_names.append(names[-1])
            if "m_name" in field_names:
                name_field_index = field_names.index("m_name")
    decl = re.search(rf"\b{re.escape(identifier)}\s*(?:\[[^\]]*\])?\s*=", masked)
    if not decl:
        return []
    open_at = masked.find("{", decl.end())
    if open_at < 0:
        return []
    close_at = balanced_block(masked, open_at)
    if close_at is None:
        return []

    entries: list[dict[str, object]] = []
    i = open_at + 1
    array_index = 0
    while i < close_at:
        if masked[i] != "{":
            i += 1
            continue
        item_end = balanced_block(masked, i)
        if item_end is None or item_end > close_at:
            break
        fields = split_args(masked[i + 1:item_end])
        label = None
        raw_label = fields[name_field_index] if len(fields) > name_field_index else ""
        label, raw_expr = decode_string_expression(raw_label, defines)
        line = masked.count("\n", 0, i) + 1
        conditions, disabled = context_at_line(masked, line)
        entries.append({
            "index": array_index,
            "name": label,
            "raw_name_expression": raw_expr,
            "source_condition": conditions,
            "compile_disabled": disabled,
        })
        array_index += 1
        i = item_end + 1
    return entries


def domain_info(type_expr: str, masked: str = "") -> tuple[str, list[str], list[str]]:
    expressions = [type_expr]
    if masked and re.fullmatch(r"[A-Za-z_]\w*", type_expr.strip()):
        name = re.escape(type_expr.strip())
        expressions.extend(re.findall(
            rf"\b(?:static\s+)?(?:const\s+)?(?:int|DemoType)\s+{name}\s*=\s*([^;]+);",
            masked,
        ))
    flags = [flag for flag in DOMAIN_FLAGS if any(flag in expr for expr in expressions)]
    # Ignore flags such as CRITICAL, SERIALIZE, and DONT_BOOTSTRAP: they are not domains.
    distinct_flags = sorted(set(flags))
    distinct_domains = sorted({DOMAIN_FLAGS[flag] for flag in distinct_flags})
    domain = "+".join(distinct_domains) if distinct_domains else "unresolved"
    return domain, distinct_domains, distinct_flags


def macro_registration_kind(macro: str) -> str:
    if "NO_REG" in macro:
        return "manual_registration"
    if "SYMLINK" in macro:
        return "symlink"
    if "FACTORY" in macro:
        return "factory"
    return "auto_registration"


def relative_demo_path(source: Path, sdk_root: Path) -> str:
    """Return the SDK demo path convention, e.g. Animation/Api/..."""
    return source.relative_to(sdk_root / "Demo" / "Demos").as_posix()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sdk_root", type=Path, help="Havok SDK root containing Demo/Demos/Animation and Demo/Demos/Behavior")
    parser.add_argument("--products", default="Animation,Behavior", help="Comma-separated SDK demo product directories")
    parser.add_argument("--output", type=Path, default=Path(__file__).with_name("catalog.json"))
    args = parser.parse_args()
    sdk_root = args.sdk_root.resolve()
    products = [p.strip() for p in args.products.split(",") if p.strip()]
    sources: list[Path] = []
    for product in products:
        prod_root = sdk_root / "Demo" / "Demos" / product
        if not prod_root.is_dir():
            parser.error(f"{product} source tree not found: {prod_root}")
        sources.extend(sorted(path for path in prod_root.rglob("*") if path.suffix.lower() in {".cpp", ".h"}))

    masked_text: dict[Path, str] = {}
    declarations: list[dict[str, object]] = []
    macros_seen: dict[str, int] = {}
    unknown_macros: list[tuple[str, str, int]] = []

    for source in sources:
        rel_path = relative_demo_path(source, sdk_root)
        product_name = rel_path.split("/")[0].lower()
        raw = source.read_text(encoding="utf-8", errors="replace")
        masked = mask_comments(raw)
        masked_text[source] = masked
        defines = local_string_defines(masked)
        path_entries: list[dict[str, object]] = []
        for macro, argv, line in macro_calls(masked):
            entry_start = len(path_entries)
            macros_seen[macro] = macros_seen.get(macro, 0) + 1
            if macro not in MACROS:
                unknown_macros.append((macro, rel_path, line))
            if len(argv) < 2:
                continue
            class_name = argv[0].strip()
            type_expr = argv[1].strip()
            domain, domain_flags, type_flags = domain_info(type_expr, masked)
            if domain == "unresolved" and product_name in ("animation", "behavior"):
                domain = product_name
                domain_flags = [product_name]
            conditions, compile_disabled = context_at_line(masked, line)
            registration_kind = macro_registration_kind(macro)
            is_conditional_physics = macro.startswith("HKA_DECLARE_") or macro.startswith("HKB_DECLARE_PHYSICS")
            base = {
                "product": product_name,
                "case": class_name,
                "domain": domain,
                "domain_flags": domain_flags,
                "type_flags": type_flags,
                "domain_expression": type_expr,
                "path": rel_path,
                "source_exists": source.is_file(),
                "line": line,
                "macro": macro,
                "registration": "conditional_source_declaration" if is_conditional_physics else registration_kind,
                "compile_disabled": compile_disabled,
                "source_condition": conditions,
                "bootstrap_eligible": "HK_DEMO_TYPE_DONT_BOOTSTRAP" not in type_expr,
            }

            if "VARIANT_USING_STRUCT" in macro and "SYMLINK" in macro:
                variant_expr = argv[2].strip() if len(argv) > 2 else ""
                row = dict(base)
                row.update({"name": variant_expr or class_name, "display_name": variant_expr or class_name,
                            "variant_provenance": {"kind": "struct_variant_symlink", "id_expression": variant_expr,
                                                    "name_expression": variant_expr}})
                path_entries.append(row)
            elif "VARIANT_USING_STRUCT" in macro:
                table_expr = argv[3] if len(argv) > 3 else ""
                struct_expr = argv[2] if len(argv) > 2 else ""
                variants = table_variants(masked, table_expr, struct_expr, defines)
                provenance = {"kind": "struct_table", "table": table_expr, "variant_struct": struct_expr, "resolved": bool(variants)}
                if variants:
                    for variant in variants:
                        row = dict(base)
                        row.update({
                            "name": variant["name"] or class_name,
                            "display_name": variant["name"] or class_name,
                            "variant_provenance": {**provenance, **variant},
                        })
                        path_entries.append(row)
                else:
                    row = dict(base)
                    row.update({"name": class_name, "display_name": class_name,
                                "variant_provenance": {**provenance, "unresolved_reason": "variant table initializer not found"}})
                    path_entries.append(row)
            elif "USING_ENUM" in macro:
                enum_expr = argv[2] if len(argv) > 2 else ""
                row = dict(base)
                row.update({"name": class_name, "display_name": class_name,
                            "variant_provenance": {"kind": "enum_presets", "enum": enum_expr,
                                                    "count_expression": argv[3] if len(argv) > 3 else None,
                                                    "resolved": False}})
                path_entries.append(row)
            elif "VARIANT" in macro and "SYMLINK" in macro:
                variant_expr = argv[2].strip() if len(argv) > 2 else ""
                row = dict(base)
                row.update({"name": variant_expr or class_name, "display_name": variant_expr or class_name,
                            "variant_provenance": {"kind": "symlink", "id_expression": variant_expr,
                                                    "name_expression": variant_expr, "resolved_name": False}})
                path_entries.append(row)
            elif "VARIANT" in macro and len(argv) >= 4:
                name_arg = argv[2]
                label, raw_label = decode_string_expression(name_arg, defines)
                if label is None:
                    # Keep the expression visible if it depends on a build-time string macro.
                    label = raw_label
                variant_id = argv[3].strip()
                row = dict(base)
                row.update({"name": label or class_name, "display_name": label or class_name,
                            "variant_provenance": {"kind": "explicit", "id_expression": variant_id,
                                                    "name_expression": raw_label,
                                                    "resolved_name": decode_string_expression(name_arg, defines)[0] is not None}})
                path_entries.append(row)
            else:
                row = dict(base)
                row.update({"name": class_name, "display_name": class_name,
                            "variant_provenance": {"kind": "single", "id": -1}})
                path_entries.append(row)

            if "RENAME" in macro or "SYMLINK" in macro:
                path_arg = argv[-1].strip() if argv else ""
                for row in path_entries[entry_start:]:
                    row["registered_path_expression"] = path_arg
                    path_value, _ = decode_string_expression(path_arg, defines)
                    if "__FILE__" in path_arg:
                        row["registered_path"] = relative_demo_path(source, sdk_root)
                        row["registered_path_exists"] = source.is_file()
                    elif path_value is not None:
                        referenced = (sdk_root / path_value).resolve()
                        row["registered_path"] = Path(path_value).as_posix()
                        row["registered_path_exists"] = referenced.is_file()
                    else:
                        row["registered_path_exists"] = None
            if macro.startswith("HKA_DECLARE_") or macro.startswith("HKB_DECLARE_PHYSICS"):
                feature = "HK_FEATURE_PRODUCT_PHYSICS_2012" if "_2012_" in macro else "HK_FEATURE_PRODUCT_PHYSICS"
                for row in path_entries[entry_start:]:
                    row["required_feature"] = feature
                    row["uses_physics_2012"] = feature.endswith("_2012")
                    row["source_only_if_feature_unavailable"] = True
                    row["registration_condition"] = f"{macro} expands to a registration only when {feature} is defined"
            declarations.extend(path_entries[entry_start:])

    if unknown_macros:
        details = ", ".join(f"{name}@{path}:{line}" for name, path, line in unknown_macros)
        raise SystemExit(f"Unsupported demo registration macros found: {details}")

    # Keep concrete demo implementations that have stepDemo() or stepBehaviorDemo() but no registration macro
    # as explicitly source-only inventory rows. Helpers without a demo step are excluded.
    class_step = re.compile(r"\b(?:hkDemo::Result|Result)\s+([A-Za-z_]\w*)::(?:stepDemo|stepBehaviorDemo)\s*\(")
    registered_cases = {str(row["case"]) for row in declarations}
    for source, masked in masked_text.items():
        rel_path = relative_demo_path(source, sdk_root)
        product_name = rel_path.split("/")[0].lower()
        for class_name in sorted(set(class_step.findall(masked))):
            if class_name in registered_cases:
                continue
            step_pos = masked.find(f"{class_name}::stepDemo")
            if step_pos < 0:
                step_pos = masked.find(f"{class_name}::stepBehaviorDemo")
            row = {
                "product": product_name,
                "name": class_name,
                "display_name": class_name,
                "case": class_name,
                "domain": product_name,
                "domain_flags": [product_name],
                "path": rel_path,
                "source_exists": source.is_file(),
                "line": masked.count("\n", 0, max(0, step_pos)) + 1,
                "macro": None,
                "registration": "source_only_unregistered",
                "compile_disabled": False,
                "source_condition": [],
                "bootstrap_eligible": False,
                "variant_provenance": {"kind": "none", "reason": "stepDemo/stepBehaviorDemo implementation found without a registration macro"},
            }
            declarations.append(row)

    declarations.sort(key=lambda row: (str(row["path"]).casefold(), int(row["line"]), str(row["name"]).casefold(), str(row["domain"])))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(declarations, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    registration_count = sum(row["registration"] != "source_only_unregistered" for row in declarations)
    source_only_count = len(declarations) - registration_count
    conditional_source_count = sum(row["registration"] == "conditional_source_declaration" for row in declarations)
    disabled_count = sum(bool(row["compile_disabled"]) for row in declarations)
    unresolved_domains = sum(row["domain"] == "unresolved" for row in declarations)
    unresolved_variants = sum(row.get("variant_provenance", {}).get("resolved") is False for row in declarations)
    missing_sources = sum(not row["source_exists"] for row in declarations)
    print(f"sources={len(sources)} macro_invocations={sum(macros_seen.values())} rows={len(declarations)} registrations={registration_count}")
    print("macro_calls=" + json.dumps(macros_seen, sort_keys=True))
    print(f"source_only_unregistered={source_only_count} conditional_source_rows={conditional_source_count} preprocessor_disabled={disabled_count} unresolved_domains={unresolved_domains} unresolved_variants={unresolved_variants} missing_sources={missing_sources}")
    print(f"wrote={args.output.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
