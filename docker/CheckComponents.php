<?php
/**
 * 冒烟测试用：确认 /etc/mediawiki-image/components.json 中要加载的组件都已被 MediaWiki 实际加载。
 *
 *   php maintenance/run.php /usr/local/lib/mediawiki-image/CheckComponents.php
 */

use MediaWiki\Maintenance\Maintenance;
use MediaWiki\Registration\ExtensionRegistry;

// @codeCoverageIgnoreStart
if ( !class_exists( Maintenance::class ) ) {
	class_alias( 'Maintenance', Maintenance::class );
}
if ( !class_exists( ExtensionRegistry::class ) ) {
	class_alias( 'ExtensionRegistry', ExtensionRegistry::class );
}
// @codeCoverageIgnoreEnd

class MediaWikiImageCheckComponents extends Maintenance {
	public function __construct() {
		parent::__construct();
		$this->addDescription( 'Verify that every component listed for this image is loaded' );
		$this->addOption( 'manifest', 'Path to the resolved components.json', false, true );
	}

	public function execute() {
		$path = $this->getOption( 'manifest', '/etc/mediawiki-image/components.json' );
		$manifest = json_decode( file_get_contents( $path ), true, 512, JSON_THROW_ON_ERROR );
		$registry = ExtensionRegistry::getInstance();
		$missing = [];
		foreach ( [ 'skins', 'extensions' ] as $kind ) {
			foreach ( $manifest[$kind] as $item ) {
				if ( !$item['load'] ) {
					continue;
				}
				$name = $item['registered_name'] ?? $item['name'];
				$ok = $registry->isLoaded( $name );
				$this->output( ( $ok ? 'loaded   ' : 'MISSING  ' ) . "$kind/{$item['name']}" .
					( $name !== $item['name'] ? " ($name)" : '' ) . "\n" );
				if ( !$ok ) {
					$missing[] = $item['name'];
				}
			}
		}
		if ( $missing ) {
			$this->fatalError( 'Not loaded: ' . implode( ', ', $missing ) );
		}
		$this->output( 'Default skin: ' . $this->getConfig()->get( 'DefaultSkin' ) . "\n" );
	}
}

// @codeCoverageIgnoreStart
$maintClass = MediaWikiImageCheckComponents::class;
require_once RUN_MAINTENANCE_IF_MAIN;
// @codeCoverageIgnoreEnd
