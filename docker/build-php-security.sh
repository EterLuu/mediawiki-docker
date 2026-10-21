#!/bin/bash
set -euxo pipefail

version="${1:?PHP version is required}"
sha256="${2:?PHP source SHA-256 is required}"
current="$(php -r 'echo PHP_VERSION;')"

if PHP_SECURITY_VERSION="$version" php -r 'exit(version_compare(PHP_VERSION, getenv("PHP_SECURITY_VERSION"), ">=") ? 0 : 1);'; then
	printf 'Base PHP %s is already patched; no rebuild needed.\n' "$current"
	exit 0
fi

savedAptMark="$(apt-mark showmanual)"
apt-get update
apt-get install -y --no-install-recommends \
	$PHPIZE_DEPS \
	ca-certificates \
	curl \
	libargon2-dev \
	libcurl4-openssl-dev \
	libonig-dev \
	libreadline-dev \
	libsodium-dev \
	libsqlite3-dev \
	libssl-dev \
	libxml2-dev \
	xz-utils \
	zlib1g-dev

src="/tmp/php-${version}"
mkdir -p "$src"
curl -fsSL "https://www.php.net/distributions/php-${version}.tar.xz" -o /tmp/php.tar.xz
echo "${sha256}  /tmp/php.tar.xz" | sha256sum -c -
tar -xJf /tmp/php.tar.xz --strip-components=1 -C "$src"
rm -f /tmp/php.tar.xz

cd "$src"
export CFLAGS="${PHP_CFLAGS:--fstack-protector-strong -fpic -fpie -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64}"
export CPPFLAGS="${PHP_CPPFLAGS:-$CFLAGS}"
export LDFLAGS="${PHP_LDFLAGS:--Wl,-O1 -pie}"
export PHP_BUILD_PROVIDER='https://github.com/docker-library/php'
export PHP_UNAME='Linux - Docker'

gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"
debMultiarch="$(dpkg-architecture --query DEB_BUILD_MULTIARCH)"
if [ ! -d /usr/include/curl ]; then
	ln -sT "/usr/include/${debMultiarch}/curl" /usr/local/include/curl
fi

./configure \
	--build="$gnuArch" \
	--sysconfdir=/usr/local/etc \
	--with-config-file-path=/usr/local/etc/php \
	--with-config-file-scan-dir=/usr/local/etc/php/conf.d \
	--enable-option-checking=fatal \
	--with-mhash \
	--with-pic \
	--enable-mbstring \
	--enable-mysqlnd \
	--with-password-argon2 \
	--with-sodium=shared \
	--with-pdo-sqlite=/usr \
	--with-sqlite3=/usr \
	--with-curl \
	--with-iconv \
	--with-openssl \
	--with-readline \
	--with-zlib \
	--disable-phpdbg \
	--with-pear \
	--with-libdir="lib/${debMultiarch}" \
	--disable-cgi \
	--enable-fpm \
	--with-fpm-user=www-data \
	--with-fpm-group=www-data

make -j"$(nproc)"
make install
php -v | grep -F "PHP ${version}"

cd /
rm -rf "$src"
apt-mark auto '.*' >/dev/null
apt-mark manual $savedAptMark >/dev/null
apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false
rm -rf /var/lib/apt/lists/*
