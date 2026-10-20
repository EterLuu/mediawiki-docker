<?php
/**
 * 镜像的皮肤/扩展加载器。在 LocalSettings.php 的开头（紧跟 MEDIAWIKI 检查之后）加入：
 *
 *   require_once "$IP/extensions.php";
 *
 * 放在开头的原因：之后 LocalSettings.php 里写的任何设置都会覆盖这里的默认值。
 * 安装程序生成的 wfLoadExtension/wfLoadSkin 行可以保留，重复加载不会出错。
 *
 * 配置的生效顺序（后者覆盖前者）：
 *   1. 本文件中的全站默认值
 *   2. 镜像内各组件的默认配置 /etc/mediawiki-image/settings/<名称>.php（仓库 config/settings/）
 *   3. 外接配置目录中的 conf.d/*.php（默认 /var/www/config/conf.d/，按文件名排序）
 *   4. LocalSettings.php 中位于 require_once 之后的设置
 */
if ( !defined( 'MEDIAWIKI' ) ) {
	exit;
}

// 1. 全站默认值 ------------------------------------------------------------
$wgDefaultUserOptions['visualeditor-enable'] = 1;
// 允许管理员编辑跨维基前缀（1.44+ 为核心功能，1.43 由 Interwiki 扩展提供，权限名相同）
$wgGroupPermissions['sysop']['interwiki'] = true;

// 加载 components.json 中列出的组件 -----------------------------------------
$mwImageComponents = json_decode(
	file_get_contents( '/etc/mediawiki-image/components.json' ),
	true,
	512,
	JSON_THROW_ON_ERROR
);

foreach ( $mwImageComponents['skins'] as $mwImageItem ) {
	if ( $mwImageItem['load'] ) {
		wfLoadSkin( $mwImageItem['name'] );
	}
}
foreach ( $mwImageComponents['extensions'] as $mwImageItem ) {
	if ( $mwImageItem['load'] ) {
		wfLoadExtension( $mwImageItem['name'] );
	}
}
if ( !empty( $mwImageComponents['default_skin'] ) ) {
	$wgDefaultSkin = $mwImageComponents['default_skin'];
}

// 2. 各组件的默认配置（只为实际加载的组件引入）-------------------------------
foreach ( array_merge( $mwImageComponents['skins'], $mwImageComponents['extensions'] ) as $mwImageItem ) {
	$mwImageFile = '/etc/mediawiki-image/settings/' . $mwImageItem['name'] . '.php';
	if ( $mwImageItem['load'] && is_file( $mwImageFile ) ) {
		require $mwImageFile;
	}
}

// 3. 外接的站点配置片段 ------------------------------------------------------
$mwImageConfDir = ( getenv( 'MW_CONFIG_DIR' ) ?: '/var/www/config' ) . '/conf.d';
foreach ( glob( $mwImageConfDir . '/*.php' ) ?: [] as $mwImageFile ) {
	require $mwImageFile;
}

unset( $mwImageComponents, $mwImageItem, $mwImageFile, $mwImageConfDir );
