#!/bin/bash
# 镜像冒烟测试（CI 在推送前运行）：
#   1. 静态检查：MediaWiki 版本、PHP 扩展、系统命令
#   2. 用临时 SQLite 数据库真实安装一个 wiki，按镜像方式加载全部组件并执行 update.php
#   3. 确认 components.json 中每个组件都已加载，并渲染一段用到常用扩展的页面
#
# 会写入 LocalSettings.php，只能在一次性容器中运行：
#   docker run --rm --entrypoint mw-smoke-test <image>
set -euo pipefail

MW_HOME="${MW_HOME:-/var/www/html}"
META="${MW_IMAGE_META:-/etc/mediawiki-image}"
LIB="${MW_IMAGE_LIB:-/usr/local/lib/mediawiki-image}"
cd "$MW_HOME"

if [ -e LocalSettings.php ]; then
	echo "refusing to run: LocalSettings.php exists (use a throwaway container)" >&2
	exit 2
fi

fail=0
check() {
	if "$@" > /dev/null 2>&1; then
		echo "ok    $*"
	else
		echo "FAIL  $*"
		fail=1
	fi
}
section() { printf '\n=== %s ===\n' "$1"; }
# 组件是否在本镜像中加载（用于按需执行渲染测试）
has() {
	python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); sys.exit(0 if any(i["name"]==sys.argv[2] and i["load"] for k in ("skins","extensions") for i in m[k]) else 1)' \
		"$META/components.json" "$1"
}

section "static checks"
actual="$(grep -oP "define\( 'MW_VERSION', '\K[^']+" includes/Defines.php)"
echo "MediaWiki $actual (expected ${MW_IMAGE_VERSION:-?})"
[ "$actual" = "${MW_IMAGE_VERSION:-$actual}" ] || fail=1
check php -l extensions.php
check php -l "$LIB/ImageState.php"
check php -l "$LIB/CheckComponents.php"
for mod in luasandbox intl apcu; do
	check sh -c "php -m | grep -qix $mod"
done
for bin in gs pdfinfo pdftotext convert python3 git; do
	check command -v "$bin"
done
check test -s "$META/update-key"
check test -s "$META/components.json"
if [ "$fail" != 0 ]; then
	echo "static checks failed"
	exit 1
fi

section "install"
tmp="$(mktemp -d)"
# shellcheck disable=SC2329 # 由 trap 调用
cleanup() { rm -rf "$tmp" "$MW_HOME/LocalSettings.php"; }
trap cleanup EXIT
if ! php maintenance/run.php install \
	--dbtype=sqlite --dbpath="$tmp" --dbname=smoke \
	--server=http://localhost --scriptpath= --lang=en \
	--pass="Smoke-Test-Passw0rd-$RANDOM" \
	"Smoke Test" Admin > "$tmp/install.log" 2>&1; then
	cat "$tmp/install.log"
	exit 1
fi
tail -n 1 "$tmp/install.log"

# 按 README 推荐的方式接入：require_once 放在开头的 MEDIAWIKI 检查之后，
# 同时保留安装程序生成的 wfLoad* 行，顺带验证重复加载不会出错
awk '{ print } !done && /^}/ { print "require_once \"$IP/extensions.php\";"; done = 1 }' \
	LocalSettings.php > "$tmp/LocalSettings.php"
mv "$tmp/LocalSettings.php" LocalSettings.php
grep -q 'extensions.php' LocalSettings.php

section "update.php"
php maintenance/run.php update --quick | tail -n 3

section "components"
php maintenance/run.php "$LIB/CheckComponents.php"

section "render"
expect=()
wikitext=""
if has ParserFunctions; then
	wikitext+=$'{{#if:x|pf-ok}}\n'
	expect+=(pf-ok)
fi
if has Scribunto; then
	printf 'local p = {}\nfunction p.hello() return "lua-ok" end\nreturn p\n' |
		php maintenance/run.php edit --user Admin --summary smoke Module:Smoke > /dev/null
	wikitext+=$'{{#invoke:Smoke|hello}}\n'
	expect+=(lua-ok)
fi
if has SyntaxHighlight_GeSHi; then
	wikitext+=$'<syntaxhighlight lang="python">print(1)</syntaxhighlight>\n'
	expect+=(mw-highlight)
fi
if has Cite; then
	wikitext+=$'text<ref>cite-ok</ref>\n<references />\n'
	expect+=(cite-ok)
fi
html="$(printf '%s' "$wikitext" | php maintenance/run.php parse 2>&1)"
for needle in "${expect[@]}"; do
	if grep -q -- "$needle" <<< "$html"; then
		echo "ok    rendered $needle"
	else
		echo "FAIL  rendered $needle"
		fail=1
	fi
done
if [ "$fail" != 0 ]; then
	echo "--- rendered output ---"
	echo "$html"
fi

section "components.txt"
cat "$META/components.txt"

exit "$fail"
