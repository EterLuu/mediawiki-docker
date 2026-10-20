#!/bin/bash
# 容器入口：准备外接配置与上传目录，按需自动升级数据库，然后启动 Web 服务。
#
# 镜像不声明任何 VOLUME，以下都是可选的外接挂载：
#   /var/www/html/images             上传文件目录
#   /var/www/html/LocalSettings.php  直接挂载单个文件
#   /var/www/config/                 或者挂载一个目录，入口脚本会把其中的 LocalSettings.php 链接过去
#                                    （推荐：宿主机上文件不存在时，单文件挂载会被 Docker 创建成目录）
#
# 升级状态（上次 update.php 时的 MediaWiki 版本 + 组件指纹）保存在数据库的 updatelog 表中，
# 所以即使不挂载任何卷，删除重建容器也能正确判断是否需要升级。
#
# 环境变量：
#   MW_AUTO_UPDATE        true/false，是否自动执行 update.php（默认 true；job runner 等辅助容器设为 false）
#   MW_CONFIG_DIR         外接配置目录（默认 /var/www/config）
#   MW_FIX_PERMISSIONS    true/false，外接的 images 目录 www-data 不可写时自动修正属主（默认 true）
#   MW_DB_WAIT_TIMEOUT    等待数据库可用的秒数（默认 120）
#   MW_ALLOW_DOWNGRADE    true 时允许以较低的 MediaWiki 版本启动（默认 false，拒绝启动）
#   MW_UPDATE_ARGS        传给 update 的额外参数（默认 --quick）
set -euo pipefail

MW_HOME=/var/www/html
CONFIG_DIR="${MW_CONFIG_DIR:-/var/www/config}"
STATE_SCRIPT=/usr/local/lib/mediawiki-image/ImageState.php
IMAGE_VERSION="${MW_IMAGE_VERSION:?MW_IMAGE_VERSION is not set}"
UPDATE_KEY="$(cat /etc/mediawiki-image/update-key 2> /dev/null || echo unknown)"

log() { echo "[mw-entrypoint] $*" >&2; }

is_root() { [ "$(id -u)" = 0 ]; }

# 以 www-data 身份运行，避免生成 root 拥有的缓存文件
as_www() {
	if is_root; then
		runuser -u www-data --preserve-environment -- "$@"
	else
		"$@"
	fi
}

fix_runtime_permissions() {
	# The official image normally ships these directories searchable by
	# www-data, but bind mounts and host-side chmod/chown can remove that bit.
	# Keep the application tree and the external config readable without making
	# LocalSettings.php world-readable (it contains the database password).
	is_root || return 0
	chmod a+rx /var/www /var/www/html 2> /dev/null || true
	[ -d "$CONFIG_DIR" ] || return 0
	chgrp -R www-data "$CONFIG_DIR" 2> /dev/null || true
	find "$CONFIG_DIR" -type d -exec chmod g+rx {} + 2> /dev/null || true
	find "$CONFIG_DIR" -type f -exec chmod g+r {} + 2> /dev/null || true
}

link_local_settings() {
	local target="$MW_HOME/LocalSettings.php" source="$CONFIG_DIR/LocalSettings.php"
	# 已经直接挂载了真实文件：不动它
	if [ -f "$target" ] && [ ! -L "$target" ]; then
		return 0
	fi
	if [ -f "$source" ]; then
		if ln -sfn "$source" "$target" 2> /dev/null; then
			log "using $source"
		else
			log "cannot link $source (not running as root?); mount it at $target instead"
		fi
	elif [ -L "$target" ]; then
		rm -f "$target" 2> /dev/null || true
	fi
}

fix_images_permissions() {
	local dir="$MW_HOME/images"
	[ "${MW_FIX_PERMISSIONS:-true}" = true ] || return 0
	is_root || return 0
	[ -d "$dir" ] || return 0
	if ! runuser -u www-data -- test -w "$dir"; then
		log "images directory is not writable by www-data, fixing ownership"
		chown -R www-data:www-data "$dir"
	fi
}

state_get() {
	as_www php "$MW_HOME/maintenance/run.php" "$STATE_SCRIPT" --get 2> /dev/null
}

state_set() {
	as_www php "$MW_HOME/maintenance/run.php" "$STATE_SCRIPT" --set "$1"
}

auto_update() {
	local timeout="${MW_DB_WAIT_TIMEOUT:-120}" waited=0 state
	# 读取状态的同时也检验数据库是否可用
	until state="$(state_get)"; do
		if [ "$waited" -ge "$timeout" ]; then
			log "database not reachable after ${timeout}s"
			exit 1
		fi
		sleep 3
		waited=$((waited + 3))
	done

	local last_version="" last_key=""
	read -r last_version last_key <<< "$state" || true

	# 防降级：数据库结构一旦升级就不能用旧版本代码运行
	if [ -n "$last_version" ] && [ "$last_version" != "$IMAGE_VERSION" ]; then
		local lowest
		lowest="$(printf '%s\n%s\n' "$last_version" "$IMAGE_VERSION" | sort -V | head -n1)"
		if [ "$lowest" = "$IMAGE_VERSION" ] && [ "${MW_ALLOW_DOWNGRADE:-false}" != true ]; then
			log "refusing to start: database was upgraded by MediaWiki $last_version, image is $IMAGE_VERSION"
			log "set MW_ALLOW_DOWNGRADE=true only if you have restored a matching database backup"
			exit 1
		fi
	fi

	if [ "$last_version" = "$IMAGE_VERSION" ] && [ "$last_key" = "$UPDATE_KEY" ]; then
		log "MediaWiki $IMAGE_VERSION already up to date"
		return 0
	fi

	log "upgrading: ${last_version:-<unknown>} -> $IMAGE_VERSION (components $UPDATE_KEY)"
	# shellcheck disable=SC2086 # MW_UPDATE_ARGS 允许传多个参数
	as_www php "$MW_HOME/maintenance/run.php" update ${MW_UPDATE_ARGS:---quick}
	state_set "$IMAGE_VERSION $UPDATE_KEY"
	log "upgrade finished"
}

fix_runtime_permissions
link_local_settings
fix_images_permissions

if [ "${MW_AUTO_UPDATE:-true}" = true ]; then
	if [ -e "$MW_HOME/LocalSettings.php" ]; then
		auto_update
	else
		log "LocalSettings.php not found, skipping auto update (run the web installer first)"
	fi
fi

exec docker-php-entrypoint "$@"
