<?php
/**
 * 在数据库中读写“镜像状态”（上次执行 update.php 时的 MediaWiki 版本与组件指纹）。
 * 存在 MediaWiki 自带的 updatelog 表里，因此容器本身不需要任何持久化卷。
 *
 *   php maintenance/run.php /usr/local/lib/mediawiki-image/ImageState.php --get
 *   php maintenance/run.php /usr/local/lib/mediawiki-image/ImageState.php --set '1.46.2 abcd1234'
 *
 * --get 输出已保存的值（未保存过则输出空行）；数据库不可用时以非零状态退出。
 */

use MediaWiki\Maintenance\Maintenance;

// @codeCoverageIgnoreStart
if ( !class_exists( Maintenance::class ) ) {
	class_alias( 'Maintenance', Maintenance::class );
}
// @codeCoverageIgnoreEnd

class MediaWikiImageState extends Maintenance {
	private const KEY = 'docker-image-state';

	public function __construct() {
		parent::__construct();
		$this->addDescription( 'Read or write the Docker image upgrade state stored in updatelog' );
		$this->addOption( 'get', 'Print the stored state' );
		$this->addOption( 'set', 'Store a new state', false, true );
	}

	public function execute() {
		$dbw = $this->getPrimaryDB();
		if ( $this->hasOption( 'set' ) ) {
			$dbw->newReplaceQueryBuilder()
				->replaceInto( 'updatelog' )
				->uniqueIndexFields( [ 'ul_key' ] )
				->row( [ 'ul_key' => self::KEY, 'ul_value' => $this->getOption( 'set' ) ] )
				->caller( __METHOD__ )
				->execute();
			return true;
		}
		$value = $dbw->newSelectQueryBuilder()
			->select( 'ul_value' )
			->from( 'updatelog' )
			->where( [ 'ul_key' => self::KEY ] )
			->caller( __METHOD__ )
			->fetchField();
		$this->output( ( $value === false || $value === null ? '' : $value ) . "\n" );
		return true;
	}
}

// @codeCoverageIgnoreStart
$maintClass = MediaWikiImageState::class;
require_once RUN_MAINTENANCE_IF_MAIN;
// @codeCoverageIgnoreEnd
