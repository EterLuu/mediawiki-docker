#!/usr/bin/env python3
"""决定本次 CI 需要构建哪些 MediaWiki 版本，输出 GitHub Actions 矩阵。

版本来源：Docker Hub 上官方 mediawiki 镜像的标签。
  - 通过 stable / lts 标签的 digest 找到它们对应的精确版本（如 1.46.2、1.43.9）
  - 每个系列（1.46、1.43 …）只取最新补丁版本

配方（recipe）：决定镜像内容的仓库文件（Dockerfile、components.json、config/、docker/）以及
官方 MediaWiki 基础镜像 digest 的哈希。基础镜像重建（例如 PHP 安全更新）也会产生新配方。
每个镜像有一个唯一标签 <MW 版本>-<配方哈希>，例如 1.46.2-3f9c2a1b。

发布规则：
  - 发布模式（定时任务、push 到 main、手动触发）：<MW 版本>-<配方哈希> 还不存在才构建。
    因此官方发布新版本、或你修改了配方（如增删扩展），都会自动构建；其他情况什么也不做。
    FORCE=true 时无条件重建。
  - 测试模式（PR）：全部构建并跑冒烟测试，但不推送。

环境变量：
  MODE          publish | test
  IMAGE         ghcr.io/<owner>/<repo>（必须小写）
  FORCE         true 时忽略“已存在”检查
  ONLY_SERIES   逗号分隔，仅构建这些系列，如 "1.46"
  HUB_TAGS_FILE 调试用：从本地 JSON 文件读取标签而不是请求 Docker Hub
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

HUB_URL = "https://hub.docker.com/v2/repositories/library/mediawiki/tags?page_size=100"
EXACT = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
ROOT = Path(__file__).resolve().parent.parent
# 影响镜像内容的文件；修改它们会产生新的配方哈希
RECIPE_PATHS = ["Dockerfile", "components.json", "config", "docker"]
MISSING_MARKERS = ("not found", "manifest unknown", "name unknown", "denied")


def vkey(v: str) -> tuple[int, ...]:
    return tuple(int(p) for p in v.split("."))


def recipe_hash(base_images: dict[str, str | None] | None = None) -> str:
    digest = hashlib.sha256()
    files: list[Path] = []
    for rel in RECIPE_PATHS:
        path = ROOT / rel
        files.extend(sorted(p for p in path.rglob("*") if p.is_file()) if path.is_dir() else [path])
    for path in files:
        if path.suffix == ".md":  # 说明文档不影响镜像内容（也不在构建上下文中）
            continue
        digest.update(path.relative_to(ROOT).as_posix().encode() + b"\0")
        digest.update(path.read_bytes() + b"\0")
    if base_images:
        digest.update(b"mediawiki-base-images\0")
        for version, image_digest in sorted(base_images.items()):
            digest.update(version.encode() + b"\0")
            digest.update((image_digest or "unknown").encode() + b"\0")
    return digest.hexdigest()[:8]


def fetch_hub_tags() -> dict[str, str | None]:
    """返回 {标签名: digest}。"""
    if path := os.environ.get("HUB_TAGS_FILE"):
        data = json.loads(Path(path).read_text())
        return {t["name"]: t.get("digest") for t in data}
    tags: dict[str, str | None] = {}
    url: str | None = HUB_URL
    while url:
        req = urllib.request.Request(url, headers={"User-Agent": "mediawiki-image-ci"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            page = json.load(resp)
        for t in page["results"]:
            tags[t["name"]] = t.get("digest")
        url = page.get("next")
    return tags


def image_exists(image: str, tag: str) -> bool:
    """标签存在返回 True，确实不存在返回 False；其他错误（网络、超时等）直接失败，
    避免把“查询失败”误判为“未发布”而重复发布。
    首次发布时 GHCR 上还没有这个包，会返回 denied/name unknown，按“不存在”处理。"""
    result = subprocess.run(
        ["docker", "buildx", "imagetools", "inspect", f"{image}:{tag}"],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        return True
    err = result.stderr.lower()
    if any(m in err for m in MISSING_MARKERS):
        return False
    raise RuntimeError(f"cannot check {image}:{tag}: {result.stderr.strip()}")


def main() -> int:
    config = json.loads((ROOT / "versions.json").read_text())
    mode = os.environ.get("MODE", "test")
    image = os.environ.get("IMAGE", "")
    force = os.environ.get("FORCE", "false") == "true"
    only = {s.strip() for s in os.environ.get("ONLY_SERIES", "").split(",") if s.strip()}

    if mode == "publish" and (not image or image != image.lower()):
        print(f"IMAGE must be set and lowercase in publish mode, got {image!r}", file=sys.stderr)
        return 1

    hub = fetch_hub_tags()

    # 每个系列的最新补丁版本
    latest: dict[str, str] = {}
    for name in hub:
        if m := EXACT.match(name):
            series = f"{m[1]}.{m[2]}"
            if series not in latest or vkey(name) > vkey(latest[series]):
                latest[series] = name

    # stable / lts 指向哪个系列（按 digest 匹配精确版本）
    channels: dict[str, str] = {}
    for channel in ("stable", "lts"):
        digest = hub.get(channel)
        if not digest:
            continue
        matches = [n for n, d in hub.items() if EXACT.match(n) and d == digest]
        if matches:
            channels[channel] = max(matches, key=vkey).rsplit(".", 1)[0]
    if "stable" not in channels and latest:
        channels["stable"] = max(latest, key=vkey)

    wanted = {channels[c] for c in config.get("track", []) if c in channels}
    wanted |= set(config.get("extra_series", []))
    min_series = config.get("min_series", "0.0")
    wanted = {s for s in wanted if vkey(s) >= vkey(min_series) and s in latest}
    if only:
        wanted &= only

    # Dockerfile uses the official FPM variant, whose tag has the -fpm suffix.
    base_images = {latest[series]: hub.get(f"{latest[series]}-fpm") for series in wanted}
    recipe = recipe_hash(base_images)
    print(f"recipe {recipe}", file=sys.stderr)
    for version, digest in sorted(base_images.items(), key=lambda item: vkey(item[0]), reverse=True):
        if digest:
            print(f"base {version} {digest}", file=sys.stderr)
        else:
            print(f"base {version} digest unavailable", file=sys.stderr)

    include = []
    for series in sorted(wanted, key=vkey, reverse=True):
        version = latest[series]
        unique = f"{version}-{recipe}"
        if mode == "publish" and not force and image_exists(image, unique):
            print(f"skip {version}: {image}:{unique} already published", file=sys.stderr)
            continue

        tags = [unique, version, series]
        if channels.get("stable") == series:
            tags.append("latest")
        if channels.get("lts") == series:
            tags.append("lts")

        include.append(
            {
                "mw_version": version,
                "series": series,
                "recipe": recipe,
                "tags": ",".join(f"{image}:{t}" for t in tags) if image else "",
                "tag_list": " ".join(tags),
            }
        )
        print(f"build {version} -> {' '.join(tags)}", file=sys.stderr)

    out = {
        "matrix": json.dumps({"include": include}),
        "has_jobs": "true" if include else "false",
        "publish": "true" if mode == "publish" else "false",
    }
    if gh_out := os.environ.get("GITHUB_OUTPUT"):
        with open(gh_out, "a") as fh:
            for k, v in out.items():
                fh.write(f"{k}={v}\n")
    else:
        print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
