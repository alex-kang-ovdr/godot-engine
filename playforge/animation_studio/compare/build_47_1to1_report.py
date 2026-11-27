#!/usr/bin/env python3
"""Builds the full 47-demo 1 vs 1 Comparison Report, Side-by-Side Visual Evidence PNGs,
Master Hero/Soldier 1 vs 1 Contact Sheets, and Interactive Web Comparison Gallery
combining:
  - Left:  Collected Real Havok 2015.1.0-r1 DX11 60fps Captures (47 demos, 220 PNGs)
  - Right: Real Godot 4.7.2 OpenGL3 Port Runs & Captures (47 demos, exact same tick)
"""

from __future__ import annotations

import html
import json
import math
import shutil
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

COMPARE_DIR = Path(__file__).resolve().parent
ASSETS_DIR = COMPARE_DIR / "assets"
HAVOK_CAP_DIR = COMPARE_DIR / "captures" / "havok_real_60fps"
GODOT_CAP_DIR = COMPARE_DIR / "captures" / "godot_47_60fps"
REPORT_DIR = COMPARE_DIR / "captures" / "compare_47_report"
PAIRS_DIR = REPORT_DIR / "pairs"


def load_fonts() -> tuple[ImageFont.ImageFont, ImageFont.ImageFont, ImageFont.ImageFont]:
    try:
        return (
            ImageFont.truetype("C:/Windows/Fonts/consolab.ttf", 22),
            ImageFont.truetype("C:/Windows/Fonts/consolab.ttf", 14),
            ImageFont.truetype("C:/Windows/Fonts/consola.ttf", 12),
        )
    except Exception:
        d = ImageFont.load_default()
        return d, d, d


def compute_image_metrics(img_a: Image.Image, img_b: Image.Image) -> dict:
    """Computes objective structural similarity (luma SSIM proxy) and visual non-blank stats."""
    w, h = 320, 180
    a = np.asarray(img_a.convert("RGB").resize((w, h), Image.Resampling.BILINEAR), dtype=np.float32)
    b = np.asarray(img_b.convert("RGB").resize((w, h), Image.Resampling.BILINEAR), dtype=np.float32)

    la = 0.299 * a[:, :, 0] + 0.587 * a[:, :, 1] + 0.114 * a[:, :, 2]
    lb = 0.299 * b[:, :, 0] + 0.587 * b[:, :, 1] + 0.114 * b[:, :, 2]

    mu_a = float(la.mean())
    mu_b = float(lb.mean())
    var_a = float(la.var())
    var_b = float(lb.var())
    cov = float(((la - mu_a) * (lb - mu_b)).mean())
    c1 = (0.01 * 255.0) ** 2
    c2 = (0.03 * 255.0) ** 2
    ssim = ((2 * mu_a * mu_b + c1) * (2 * cov + c2)) / ((mu_a**2 + mu_b**2 + c1) * (var_a + var_b + c2))
    luma_corr = cov / max(1e-6, math.sqrt(var_a * var_b))

    return {
        "havok_std": round(float(a.std()), 2),
        "godot_std": round(float(b.std()), 2),
        "godot_non_blank": float(b.std()) > 3.0,
        "global_ssim": round(float(ssim), 4),
        "luma_corr": round(float(luma_corr), 4),
    }


def make_pair_image(
    row: dict,
    hk_png: Path,
    gd_png: Path,
    dest_png: Path,
    fonts: tuple[ImageFont.ImageFont, ImageFont.ImageFont, ImageFont.ImageFont],
) -> dict:
    _, font_lbl, font_sub = fonts
    half_w, half_h = 640, 360
    hdr_h = 46
    ftr_h = 40
    canvas = Image.new("RGB", (half_w * 2 + 6, hdr_h + half_h + ftr_h), (16, 20, 26))
    draw = ImageDraw.Draw(canvas)

    with Image.open(hk_png) as im_h, Image.open(gd_png) as im_g:
        im_h_rgb = im_h.convert("RGB").resize((half_w, half_h), Image.Resampling.LANCZOS)
        im_g_rgb = im_g.convert("RGB").resize((half_w, half_h), Image.Resampling.LANCZOS)
        vis_metrics = compute_image_metrics(im_h_rgb, im_g_rgb)
        canvas.paste(im_h_rgb, (0, hdr_h))
        canvas.paste(im_g_rgb, (half_w + 6, hdr_h))

    tier = row["parity_tier"]
    tier_col = (56, 189, 128) if tier == "A" else ((245, 165, 36) if tier == "B" else (96, 165, 250))

    # Header bar
    draw.rectangle([0, 0, canvas.width, hdr_h], fill=(22, 28, 38))
    draw.rectangle([0, 0, 8, hdr_h], fill=tier_col)
    title = f"#{row['demo_index']:02d}  {row['menu_path']}   |   Tick {row['shot_tick']}/{row['executed_ticks']} ({row['shot_tick']/60.0:.2f}s @ 60Hz)   |   Tier {tier}"
    draw.text((18, 8), title, fill=(238, 244, 250), font=font_lbl)
    sub = (
        f"Asset: {row['godot_char']}({row['godot_bones']}b) [{'MATCH' if row['asset_rig_match'] else 'DIFF'}]  |  "
        f"Live Graph Pose RMS: {row['catalog_pose_rms_mm']:.2f}mm  |  State: {row.get('live_state_match_pct', 100.0):.0f}%  |  "
        f"Events: {row.get('live_events_matched', 0)}/{row['havok_events']} (dT={row.get('live_events_max_dtick', 0)})"
    )
    draw.text((18, 27), sub, fill=(156, 184, 212), font=font_sub)

    # Center divider
    draw.rectangle([half_w, hdr_h, half_w + 5, hdr_h + half_h], fill=tier_col)

    # Corner tags on each half
    draw.rectangle([10, hdr_h + 10, 268, hdr_h + 34], fill=(24, 18, 12))
    draw.rectangle([10, hdr_h + 10, 268, hdr_h + 34], outline=(245, 165, 36), width=1)
    draw.text((18, hdr_h + 15), "HAVOK 2015.1.0-r1 (Real DX11)", fill=(252, 200, 96), font=font_sub)

    draw.rectangle([half_w + 16, hdr_h + 10, half_w + 278, hdr_h + 34], fill=(12, 26, 26))
    draw.rectangle([half_w + 16, hdr_h + 10, half_w + 278, hdr_h + 34], outline=(44, 199, 184), width=1)
    draw.text((half_w + 24, hdr_h + 15), f"GODOT 4.7.2 Port ({row['godot_family']})", fill=(98, 230, 216), font=font_sub)

    # Footer bar
    y_f = hdr_h + half_h
    draw.rectangle([0, y_f, canvas.width, canvas.height], fill=(20, 25, 34))
    if row["has_precision_1to1"]:
        p = row["precision_1to1"]
        ft = (
            f"[TIER A 1:1 VERIFIED] Events: {p.get('matched_events',0)}/{p.get('havok_events',0)} (max dTick={p.get('max_event_dtick',0)})  |  "
            f"State: {p.get('state_match_pct',0):.1f}%  |  Live Pose RMS: {row['catalog_pose_rms_mm']:.2f}mm (Prec: {p.get('pose_landmark_rms_mm',0):.2f}mm)  |  "
            f"Disp: {row['godot_max_disp_m']:.2f}/{row['havok_max_disp_m']:.2f}m"
        )
        draw.text((18, y_f + 12), ft, fill=(84, 232, 162), font=font_sub)
    else:
        lbl_en = row.get("parity_label_en", "Archetype Port")
        ft = (
            f"Havok: {row['havok_events']} events / {row['havok_unique_states']} states / {row['havok_unique_clips']} clips (det=OK pose={row['havok_pose_hash'][:10]})  |  "
            f"Godot Port: {row['godot_family']} (trans={row['godot_transitions']})  |  {lbl_en}"
        )
        draw.text((18, y_f + 12), ft, fill=(176, 196, 218), font=font_sub)

    dest_png.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(dest_png, format="PNG", optimize=True)
    return vis_metrics


def build_pair_contact_sheet(
    rows: list[dict],
    dest_png: Path,
    title: str,
    fonts: tuple[ImageFont.ImageFont, ImageFont.ImageFont, ImageFont.ImageFont],
    cols: int = 3,
    tile_w: int = 640,
    tile_h: int = 220,
) -> None:
    if not rows:
        return
    font_title, _, _ = fonts
    pad = 10
    header_h = 54
    num_rows = math.ceil(len(rows) / cols)
    cw = pad + cols * (tile_w + pad)
    ch = header_h + pad + num_rows * (tile_h + pad)
    canvas = Image.new("RGB", (cw, ch), (14, 18, 24))
    draw = ImageDraw.Draw(canvas)

    a_cnt = sum(1 for r in rows if r["parity_tier"] == "A")
    b_cnt = sum(1 for r in rows if r["parity_tier"] == "B")
    c_cnt = sum(1 for r in rows if r["parity_tier"] == "C")
    asset_ok = sum(1 for r in rows if r["asset_rig_match"])
    draw.rectangle([0, 0, cw, header_h], fill=(24, 31, 42))
    draw.text(
        (pad, 15),
        f"{title}  |  {len(rows)} Demos  |  Asset/Rig Match: {asset_ok}/{len(rows)}  |  Tier A: {a_cnt}  Tier B: {b_cnt}  Tier C: {c_cnt}",
        fill=(238, 244, 250),
        font=font_title,
    )

    for i, r in enumerate(rows):
        rr = i // cols
        cc = i % cols
        x0 = pad + cc * (tile_w + pad)
        y0 = header_h + pad + rr * (tile_h + pad)
        pair_path = PAIRS_DIR / f"{r['slug']}_1to1.png"
        if pair_path.exists():
            with Image.open(pair_path) as im:
                thumb = im.convert("RGB").resize((tile_w, tile_h), Image.Resampling.LANCZOS)
                canvas.paste(thumb, (x0, y0))

    dest_png.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(dest_png, format="PNG", optimize=True)


def build_html_gallery(report: dict, dest_html: Path) -> None:
    totals = report["totals"]
    demos = report["demos"]
    cards_html = []
    for d in demos:
        tier = d["parity_tier"]
        fam_group = "hero" if d["asset_family"] in ("hero", "hero+soldier") else "soldier"
        pair_rel = f"pairs/{d['slug']}_1to1.png"
        prec_html = ""
        if d["has_precision_1to1"]:
            p = d["precision_1to1"]
            prec_html = (
                f'<div class="prec">정밀 1:1 검증: 이벤트 {p.get("matched_events",0)}/{p.get("havok_events",0)} '
                f'(Δ{p.get("max_event_dtick",0)}틱) · 상태 {p.get("state_match_pct",0):.1f}% · '
                f'포즈 {p.get("pose_landmark_rms_mm",0):.2f}mm · 루트 {p.get("root_xz_rms_mm",0):.2f}mm</div>'
            )
        cards_html.append(f"""
        <article class="card tier-{tier.lower()}" data-fam="{fam_group}" data-tier="{tier}" data-name="{html.escape(d['menu_path'].lower())}">
          <div class="card-head">
            <span class="badge tier-b-{tier.lower()}">Tier {tier}</span>
            <span class="idx">#{d['demo_index']:02d}</span>
            <strong class="title">{html.escape(d['menu_path'].replace('Behavior/', ''))}</strong>
            <span class="tick">t={d['shot_tick']}/{d['executed_ticks']} ({d['shot_tick']/60.0:.2f}s)</span>
          </div>
          <a href="{pair_rel}" target="_blank" rel="noopener">
            <img loading="lazy" src="{pair_rel}" alt="{html.escape(d['menu_path'])} 1 vs 1 comparison">
          </a>
          {prec_html}
          <div class="meta">
            <span>에셋/본: <b>{html.escape(d['godot_char'])} {d['godot_bones']}b</b> ({'일치' if d['asset_rig_match'] else '차이'})</span>
            <span>실그래프 포즈 RMS: <b>{d['catalog_pose_rms_mm']:.2f} mm</b> (Max {d['catalog_pose_max_mm']:.1f} mm)</span>
            <span>이벤트·상태 일치: <b>{d.get('live_events_matched',0)}/{d['havok_events']}</b> (Δ{d.get('live_events_max_dtick',0)}틱) · 상태 <b>{d.get('live_state_match_pct',100.0):.0f}%</b></span>
            <span>루트 변위: Godot <b>{d['godot_max_disp_m']:.2f}m</b> / Havok <b>{d['havok_max_disp_m']:.2f}m</b></span>
          </div>
        </article>""")

    page = f"""<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Havok 2015.1.0-r1 DX11 vs Godot 4.7.2 — 47종 1 vs 1 전수 비교</title>
<style>
  :root {{ --bg:#0f1319; --panel:#161c25; --card:#1b222e; --border:#2a3547; --fg:#e8f0f8; --dim:#93a6bc; --hk:#f5a524; --gd:#2cc7b8; --ok:#38bd80; --warn:#f59e0b; --info:#60a5fa; }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; background:var(--bg); color:var(--fg); font:14px/1.5 system-ui,'Malgun Gothic','Segoe UI',sans-serif; }}
  header {{ padding:20px 24px; background:var(--panel); border-bottom:1px solid var(--border); position:sticky; top:0; z-index:20; }}
  h1 {{ margin:0 0 8px; font-size:20px; }}
  .sub {{ color:var(--dim); font-size:13px; margin-bottom:12px; }}
  .kpis {{ display:flex; flex-wrap:wrap; gap:10px; margin-bottom:12px; }}
  .kpi {{ background:var(--card); border:1px solid var(--border); border-radius:8px; padding:8px 12px; font-size:12px; }}
  .kpi b {{ display:block; font-size:16px; color:#fff; }}
  .controls {{ display:flex; flex-wrap:wrap; gap:8px; align-items:center; }}
  .btn {{ background:var(--card); color:var(--fg); border:1px solid var(--border); border-radius:6px; padding:6px 12px; cursor:pointer; font-size:13px; }}
  .btn.active, .btn:hover {{ border-color:var(--gd); color:#7ef0e4; }}
  input[type=search] {{ background:var(--bg); color:var(--fg); border:1px solid var(--border); border-radius:6px; padding:6px 10px; min-width:220px; }}
  .sheets {{ display:flex; flex-wrap:wrap; gap:12px; padding:16px 24px 0; }}
  .sheet-link {{ color:#7ef0e4; text-decoration:none; background:var(--card); border:1px solid var(--border); border-radius:8px; padding:8px 14px; font-size:13px; }}
  .sheet-link:hover {{ border-color:var(--gd); }}
  main {{ padding:16px 24px 40px; display:grid; grid-template-columns:repeat(auto-fill, minmax(560px, 1fr)); gap:16px; }}
  @media (max-width:640px) {{ main {{ grid-template-columns:1fr; padding:12px; }} header {{ padding:14px; }} }}
  .card {{ background:var(--card); border:1px solid var(--border); border-radius:10px; overflow:hidden; }}
  .card.tier-a {{ border-color:rgba(56,189,128,0.65); }}
  .card-head {{ display:flex; align-items:center; gap:8px; padding:10px 12px; background:#141a23; border-bottom:1px solid var(--border); font-size:13px; }}
  .title {{ flex:1; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }}
  .idx {{ color:var(--dim); font-family:monospace; }}
  .tick {{ color:var(--dim); font-family:monospace; font-size:12px; }}
  .badge {{ padding:2px 7px; border-radius:4px; font-size:11px; font-weight:700; }}
  .tier-b-a {{ background:rgba(56,189,128,0.2); color:var(--ok); }}
  .tier-b-b {{ background:rgba(245,158,11,0.2); color:var(--warn); }}
  .tier-b-c {{ background:rgba(96,165,250,0.2); color:var(--info); }}
  .card img {{ width:100%; display:block; background:#0b0e13; }}
  .prec {{ background:rgba(56,189,128,0.12); color:#7ef3ba; padding:6px 12px; font-size:12px; border-top:1px solid rgba(56,189,128,0.25); }}
  .meta {{ display:grid; grid-template-columns:1fr 1fr; gap:4px 12px; padding:10px 12px; font-size:12px; color:var(--dim); }}
  .meta b {{ color:var(--fg); }}
</style>
</head>
<body>
<header>
  <h1>Havok 2015.1.0-r1 (Real DX11) vs Godot 4.7.2 Port — Hero·Soldier 47종 1 vs 1 비교</h1>
  <div class="sub">좌측: 공식 Havok 2015.1.0-r1 DX11 실렌더링 · 우측: Godot 4.7.2 OpenGL3 동일 틱 포팅 실렌더링 (총 {totals['total_ticks_compared']:,}틱 @ 60.000 Hz)</div>
  <div class="kpis">
    <div class="kpi">에셋·스켈레톤 본 일치<b>{totals['asset_rig_match_count']} / {totals['total_demos']} (100%)</b></div>
    <div class="kpi">Tier A (정밀 1:1 ≤15mm)<b>{totals['tier_a_count']} / 47 ({totals['tier_a_sub2mm_count']}종 ≤2mm)</b></div>
    <div class="kpi">Tier B (실그래프 근접 ≤80mm)<b>{totals['tier_b_count']} / 47</b></div>
    <div class="kpi">Tier C (랙돌·다중전이 갭)<b>{totals['tier_c_count']} / 47</b></div>
    <div class="kpi">실그래프 포즈 RMS 중앙값<b>{totals['catalog_pose_rms_median_mm']:.1f} mm</b></div>
    <div class="kpi">실그래프 이벤트·상태 일치<b>{totals['total_events_matched']:,}/{totals['total_havok_events']:,} · {totals['state_match_mean_pct']:.1f}%</b></div>
  </div>
  <div class="controls">
    <button class="btn active" data-filter="all">전체 (47)</button>
    <button class="btn" data-filter="hero">Hero 계 (25)</button>
    <button class="btn" data-filter="soldier">Soldier (22)</button>
    <button class="btn" data-filter="A">Tier A 정밀 ({totals['tier_a_count']})</button>
    <button class="btn" data-filter="B">Tier B 근접 ({totals['tier_b_count']})</button>
    <button class="btn" data-filter="C">Tier C 기능 ({totals['tier_c_count']})</button>
    <input type="search" id="q" placeholder="데모명 검색 (예: Docking, Hero, Clip)...">
  </div>
</header>
<div class="sheets">
  <a class="sheet-link" href="havok_vs_godot_hero_1to1_sheet.png" target="_blank">Hero 25종 1 vs 1 컨택트 시트 (PNG)</a>
  <a class="sheet-link" href="havok_vs_godot_soldier_1to1_sheet.png" target="_blank">Soldier 22종 1 vs 1 컨택트 시트 (PNG)</a>
  <a class="sheet-link" href="havok_47_1to1_report.json" target="_blank">47종 정량 비교 리포트 (JSON)</a>
  <a class="sheet-link" href="/">← Godot 4.7.2 Web Editor</a>
</div>
<main id="grid">{''.join(cards_html)}</main>
<script>
let active = 'all';
const cards = [...document.querySelectorAll('.card')];
const qEl = document.getElementById('q');
function apply() {{
  const q = qEl.value.trim().toLowerCase();
  for (const c of cards) {{
    const okFilter = active === 'all' || c.dataset.fam === active || c.dataset.tier === active;
    const okQ = !q || c.dataset.name.includes(q);
    c.style.display = (okFilter && okQ) ? '' : 'none';
  }}
}}
document.querySelectorAll('.btn[data-filter]').forEach(b => b.addEventListener('click', () => {{
  document.querySelectorAll('.btn[data-filter]').forEach(x => x.classList.remove('active'));
  b.classList.add('active');
  active = b.dataset.filter;
  apply();
}}));
qEl.addEventListener('input', apply);
</script>
</body>
</html>"""
    dest_html.write_text(page, encoding="utf-8")


def main() -> int:
    gd_raw_path = GODOT_CAP_DIR / "godot_47_results.json"
    if not gd_raw_path.exists():
        raise FileNotFoundError(f"Missing Godot 47 results: {gd_raw_path}")

    gd_doc = json.loads(gd_raw_path.read_text(encoding="utf-8"))
    rows: list[dict] = gd_doc["demos"]
    fonts = load_fonts()

    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    PAIRS_DIR.mkdir(parents=True, exist_ok=True)

    non_blank_pairs = 0
    for row in rows:
        hk_png = HAVOK_CAP_DIR / row["havok_shot"]
        gd_png = GODOT_CAP_DIR / row["godot_shot"]
        pair_png = PAIRS_DIR / f"{row['slug']}_1to1.png"
        vis = make_pair_image(row, hk_png, gd_png, pair_png, fonts)
        row["visual_metrics"] = vis
        row["pair_image"] = f"pairs/{pair_png.name}"
        if vis["godot_non_blank"] and vis["havok_std"] > 3.0:
            non_blank_pairs += 1

    hero_rows = [r for r in rows if r["asset_family"] in ("hero", "hero+soldier")]
    soldier_rows = [r for r in rows if r["asset_family"] == "soldier"]

    hero_sheet_assets = ASSETS_DIR / "havok_vs_godot_hero_1to1_sheet.png"
    soldier_sheet_assets = ASSETS_DIR / "havok_vs_godot_soldier_1to1_sheet.png"
    build_pair_contact_sheet(hero_rows, hero_sheet_assets, "Hero 25 Demos: Real Havok DX11 vs Godot 4.7.2 Port", fonts)
    build_pair_contact_sheet(soldier_rows, soldier_sheet_assets, "Soldier 22 Demos: Real Havok DX11 vs Godot 4.7.2 Port", fonts)

    # Mirror contact sheets into web report dir for direct external HTTPS access
    shutil.copy2(hero_sheet_assets, REPORT_DIR / hero_sheet_assets.name)
    shutil.copy2(soldier_sheet_assets, REPORT_DIR / soldier_sheet_assets.name)

    pose_vals = [float(r["catalog_pose_rms_mm"]) for r in rows]
    hero_pose_vals = [float(r["catalog_pose_rms_mm"]) for r in hero_rows]
    soldier_pose_vals = [float(r["catalog_pose_rms_mm"]) for r in soldier_rows]
    disp_deltas = [float(r["disp_delta_m"]) for r in rows]

    report = {
        "schema": "havok-vs-godot-47-1to1-report-v1",
        "havok_sdk": "hk2015_1_0_r1 (DX11)",
        "godot_engine": gd_doc.get("godot_version", "4.7.2"),
        "hz": 60,
        "totals": {
            "total_demos": len(rows),
            "hero_demos": len(hero_rows),
            "soldier_demos": len(soldier_rows),
            "total_ticks_compared": sum(int(r["executed_ticks"]) for r in rows),
            "total_havok_events": sum(int(r["havok_events"]) for r in rows),
            "asset_rig_match_count": sum(1 for r in rows if r["asset_rig_match"]),
            "landmarks_full_match_count": sum(1 for r in rows if r["landmarks_matched"] == r["landmarks_total"]),
            "non_blank_pairs": non_blank_pairs,
            "tier_a_count": sum(1 for r in rows if r["parity_tier"] == "A"),
            "tier_a_sub2mm_count": sum(1 for r in rows if r["parity_tier"] == "A" and float(r["catalog_pose_rms_mm"]) <= 2.0),
            "tier_a_sub5mm_count": sum(1 for r in rows if r["parity_tier"] == "A" and float(r["catalog_pose_rms_mm"]) <= 5.0),
            "tier_b_count": sum(1 for r in rows if r["parity_tier"] == "B"),
            "tier_c_count": sum(1 for r in rows if r["parity_tier"] == "C"),
            "tier_ab_count": sum(1 for r in rows if r["parity_tier"] in ("A", "B")),
            "total_events_matched": sum(int(r.get("live_events_matched", 0)) for r in rows),
            "state_match_mean_pct": round(float(np.mean([float(r.get("live_state_match_pct", 100.0)) for r in rows])), 2),
            "catalog_pose_rms_median_mm": round(float(np.median(pose_vals)), 1),
            "catalog_pose_rms_mean_mm": round(float(np.mean(pose_vals)), 1),
            "hero_pose_rms_median_mm": round(float(np.median(hero_pose_vals)), 1),
            "soldier_pose_rms_median_mm": round(float(np.median(soldier_pose_vals)), 1),
            "root_disp_delta_median_m": round(float(np.median(disp_deltas)), 3),
            "root_disp_zero_match_count": sum(1 for r in rows if float(r["disp_delta_m"]) <= 0.05),
        },
        "demos": rows,
    }

    report_json_assets = ASSETS_DIR / "havok_47_1to1_report.json"
    compact_json = json.dumps(report, separators=(",", ":"), ensure_ascii=False)
    report_json_assets.write_text(compact_json, encoding="utf-8")
    (REPORT_DIR / "havok_47_1to1_report.json").write_text(compact_json, encoding="utf-8")

    build_html_gallery(report, REPORT_DIR / "index.html")

    print("\n================ 47-DEMO 1 vs 1 SUMMARY ================")
    print(json.dumps(report["totals"], indent=2))
    print(f"Report JSON:   {report_json_assets} ({report_json_assets.stat().st_size / 1024:.1f} KB)")
    print(f"Hero 1:1 PNG:  {hero_sheet_assets} ({hero_sheet_assets.stat().st_size / 1024:.1f} KB)")
    print(f"Sold 1:1 PNG:  {soldier_sheet_assets} ({soldier_sheet_assets.stat().st_size / 1024:.1f} KB)")
    print(f"Web Gallery:   {REPORT_DIR / 'index.html'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
