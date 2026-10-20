#!/usr/bin/env python3
"""按 components.json 安装皮肤与扩展（镜像构建时运行）。

  python3 install-components.py /path/to/components.json

输出（默认在 /etc/mediawiki-image/）：
  components.txt   每个组件的来源、ref 与 commit（人读、也用于生成组件指纹）
  components.json  实际要加载的组件清单（config/extensions.php 读取它）
  update-key       组件指纹；变化时容器启动会重新执行 update.php

环境变量 MW_HOME（默认 /var/www/html）、MW_IMAGE_META（默认 /etc/mediawiki-image）可覆盖路径，便于本地测试。
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

MW_HOME = Path(os.environ.get("MW_HOME", "/var/www/html"))
META = Path(os.environ.get("MW_IMAGE_META", "/etc/mediawiki-image"))
KINDS = {"skins": "skin.json", "extensions": "extension.json"}
SHA = re.compile(r"^[0-9a-f]{40}$")
CONSTRAINT = re.compile(r"^\s*(>=|<=|==|!=|>|<)?\s*(\d+(?:\.\d+)*)\s*$")


class ManifestError(Exception):
    pass


def log(msg: str) -> None:
    print(f"[components] {msg}", flush=True)


def vtuple(v: str, width: int = 3) -> tuple[int, ...]:
    parts = [int(p) for p in v.split(".")]
    return tuple(parts + [0] * (width - len(parts)))


def satisfies(version: str, spec: str | None) -> bool:
    if not spec:
        return True
    have = vtuple(version)
    for cond in spec.split(","):
        m = CONSTRAINT.match(cond)
        if not m:
            raise ManifestError(f"invalid version constraint {cond!r}")
        op, want = m[1] or "==", vtuple(m[2])
        ok = {
            ">=": have >= want,
            "<=": have <= want,
            ">": have > want,
            "<": have < want,
            "==": have[: len(m[2].split("."))] == want[: len(m[2].split("."))],
            "!=": have[: len(m[2].split("."))] != want[: len(m[2].split("."))],
        }[op]
        if not ok:
            return False
    return True


def mw_version() -> str:
    text = (MW_HOME / "includes" / "Defines.php").read_text()
    m = re.search(r"define\( 'MW_VERSION', '([^']+)'", text)
    if not m:
        raise ManifestError("cannot determine MediaWiki version")
    return m[1]


def resolve_series(value, series: str):
    if isinstance(value, dict):
        return value.get(series, value.get("default"))
    return value


def resolve_ref(ref, series: str, branch: str) -> str | None:
    ref = resolve_series(ref, series)
    if ref in (None, "", "REL"):
        return None  # 表示“跟随 MediaWiki 发布分支”
    return str(ref)


def source_urls(kind: str, name: str, source: str) -> list[str]:
    if source == "gerrit":
        # Gerrit occasionally rejects anonymous clones from CI runners (HTTP
        # 403). Wikimedia maintains read-only GitHub mirrors for its MediaWiki
        # repositories, so keep Gerrit as the primary source and use the mirror
        # as a fallback when the runner cannot reach Gerrit.
        return [
            f"https://gerrit.wikimedia.org/r/mediawiki/{kind}/{name}",
            f"https://github.com/wikimedia/mediawiki-{kind}-{name}.git",
        ]
    if source.startswith("github:"):
        return [f"https://github.com/{source[len('github:'):]}.git"]
    if re.match(r"^(https?://|git@|ssh://)", source):
        return [source]
    raise ManifestError(f"{kind}/{name}: unknown source {source!r}")


def source_url(kind: str, name: str, source: str) -> str:
    """Return the primary URL for callers that only need one source."""
    return source_urls(kind, name, source)[0]


def git(*args: str, cwd: Path | None = None) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, capture_output=True, text=True
    ).stdout.strip()


def strip_git(dest: Path) -> None:
    for path in sorted(dest.rglob(".git"), key=lambda p: len(p.parts), reverse=True):
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()


def clone(url: str, ref: str, dest: Path) -> str:
    if dest.exists():
        shutil.rmtree(dest)
    if SHA.match(ref):
        dest.mkdir(parents=True)
        git("init", "-q", cwd=dest)
        git("remote", "add", "origin", url, cwd=dest)
        git("fetch", "-q", "--depth", "1", "origin", ref, cwd=dest)
        git("checkout", "-q", "FETCH_HEAD", cwd=dest)
        git("submodule", "update", "-q", "--init", "--recursive", "--depth", "1", cwd=dest)
    else:
        git("clone", "-q", "--depth", "1", "--recurse-submodules", "--shallow-submodules",
            "--branch", ref, url, str(dest))
    sha = git("rev-parse", "HEAD", cwd=dest)
    strip_git(dest)
    return sha


def run_composer(paths: list[str]) -> None:
    if not shutil.which("composer"):
        raise ManifestError("composer is required by some components but not installed")
    local = MW_HOME / "composer.local.json"
    data = json.loads(local.read_text()) if local.exists() else {}
    include = data.setdefault("extra", {}).setdefault("merge-plugin", {}).setdefault("include", [])
    for p in paths:
        if p not in include:
            include.append(p)
    local.write_text(json.dumps(data, indent=2) + "\n")
    log(f"composer: merging {', '.join(paths)}")
    subprocess.run(
        ["composer", "update", "--no-dev", "--no-interaction", "--no-progress", "--optimize-autoloader"],
        cwd=MW_HOME, check=True, env={**os.environ, "COMPOSER_ALLOW_SUPERUSER": "1"},
    )


def install(manifest: dict) -> None:
    version = mw_version()
    series = ".".join(version.split(".")[:2])
    branch = "REL" + series.replace(".", "_")
    log(f"MediaWiki {version} (branch {branch})")

    lines = [f"mediawiki {version} {branch}"]
    resolved: dict = {"default_skin": manifest.get("default_skin"), "skins": [], "extensions": []}
    composer_paths: list[str] = []
    seen: set[str] = set()

    for kind, json_name in KINDS.items():
        for item in manifest.get(kind, []):
            name = item["name"]
            key = f"{kind}/{name}"
            if key in seen:
                raise ManifestError(f"{key} is listed twice")
            seen.add(key)
            if not satisfies(version, item.get("mediawiki")):
                log(f"skip {key}: requires MediaWiki {item['mediawiki']}")
                lines.append(f"{key} skipped -")
                continue

            dest = MW_HOME / kind / name
            source = resolve_series(item.get("source", "bundled"), series)
            if not isinstance(source, str):
                raise ManifestError(f"{key}: source must be a string or a per-series mapping")
            ref = resolve_ref(item.get("ref"), series, branch)

            if source == "bundled":
                if not (dest / json_name).is_file():
                    raise ManifestError(
                        f"{key} is not bundled with MediaWiki {version}; give it a source "
                        f"(e.g. \"gerrit\") in components.json"
                    )
                lines.append(f"{key} bundled -")
            elif (dest / json_name).is_file() and ref is None:
                # 发布包里已经带了同分支的版本，直接用
                log(f"{key}: bundled with this release, using it")
                lines.append(f"{key} bundled -")
            else:
                use_ref = ref or branch
                if (dest / json_name).is_file():
                    log(f"{key}: replacing bundled copy with {use_ref}")
                urls = source_urls(kind, name, source)
                fetch_errors: list[str] = []
                for index, url in enumerate(urls):
                    try:
                        sha = clone(url, use_ref, dest)
                        if index:
                            log(f"{key}: using mirror {url}")
                        break
                    except subprocess.CalledProcessError as exc:
                        detail = (exc.stderr or "").strip()
                        fetch_errors.append(f"{url}: {detail}")
                        if index + 1 == len(urls):
                            raise ManifestError(
                                f"{key}: cannot fetch {use_ref!r}\n" + "\n".join(fetch_errors)
                            ) from None
                log(f"{key}: {use_ref} @ {sha[:12]}")
                lines.append(f"{key} {use_ref} {sha}")

            if not (dest / json_name).is_file():
                raise ManifestError(f"{key} has no {json_name}; only extension registration is supported")
            if item.get("composer") and (dest / "composer.json").is_file():
                composer_paths.append(f"{kind}/{name}/composer.json")
            # 扩展注册时用的是 JSON 中的 name（可能与目录名不同，如 SyntaxHighlight_GeSHi -> SyntaxHighlight）
            registered = json.loads((dest / json_name).read_text()).get("name", name)
            resolved[kind].append({"name": name, "registered_name": registered, "load": item.get("load", True)})

    if composer_paths:
        run_composer(composer_paths)

    META.mkdir(parents=True, exist_ok=True)
    text = "\n".join(lines) + "\n"
    (META / "components.txt").write_text(text)
    (META / "components.json").write_text(json.dumps(resolved, indent=2) + "\n")
    (META / "update-key").write_text(hashlib.sha256(text.encode()).hexdigest()[:16] + "\n")
    print(text, end="")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        install(json.loads(Path(sys.argv[1]).read_text()))
    except (ManifestError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, "stderr", None)
        print(f"[components] ERROR: {exc}" + (f"\n{detail}" if detail else ""), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
