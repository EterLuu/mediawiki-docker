# syntax=docker/dockerfile:1
#
# MediaWiki + 额外扩展/皮肤
# 每个镜像只对应一个 MediaWiki 版本：基础镜像用精确的补丁版本标签（如 1.46.2）。
# 要包含哪些皮肤和扩展由 components.json 决定，构建时由 docker/install-components.py 安装，
# 实际版本记录在镜像内 /etc/mediawiki-image/components.txt。
#
# 本地构建示例：
#   docker build --build-arg MW_VERSION=1.46.2 -t mediawiki-custom:1.46.2 .

ARG MW_VERSION=1.46.2
FROM mediawiki:${MW_VERSION}-fpm

ARG MW_VERSION

# 镜像不声明 VOLUME：images、LocalSettings.php 等均为可选外接挂载（见 docker/mw-entrypoint.sh）。
# 注意 /var/www/data 是官方镜像的 SQLite 数据目录，使用 SQLite 时请自行挂载它。
ENV MW_IMAGE_VERSION=${MW_VERSION} \
    MW_AUTO_UPDATE=true \
    MW_CONFIG_DIR=/var/www/config

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ---- 运行时依赖 ----
# ghostscript / poppler-utils / imagemagick : PdfHandler 缩略图与文本提取
# python3                                    : SyntaxHighlight_GeSHi 调用 pygmentize
# git / unzip                                : 构建时拉取扩展、composer 下载依赖
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git nginx unzip ghostscript poppler-utils imagemagick python3; \
    rm -rf /var/lib/apt/lists/*; \
    chmod 755 /var/www /var/www/html

# ---- luasandbox（Scribunto 推荐引擎；基础镜像若已自带则跳过）----
# 编译依赖用完即删，只保留 .so 实际链接到的运行库（与官方 PHP 镜像同样的做法）
RUN set -eux; \
    if php -m | grep -qix luasandbox; then \
        echo "luasandbox already present"; \
    else \
        savedAptMark="$(apt-mark showmanual)"; \
        apt-get update; \
        apt-get install -y --no-install-recommends $PHPIZE_DEPS liblua5.1-0-dev pkg-config; \
        pecl install luasandbox; \
        docker-php-ext-enable luasandbox; \
        apt-mark auto '.*' > /dev/null; \
        apt-mark manual $savedAptMark; \
        extDir="$(php -r 'echo ini_get("extension_dir");')"; \
        ldd "$extDir"/*.so \
            | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) next; print so }' \
            | sort -u \
            | xargs -r dpkg-query --search \
            | cut -d: -f1 \
            | sort -u \
            | xargs -r apt-mark manual; \
        apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
        rm -rf /var/lib/apt/lists/* /tmp/pear; \
    fi; \
    php -m | grep -ix luasandbox

WORKDIR /var/www/html

# Public script/resource URLs use /w while the official image stores files at
# the document root.
RUN ln -s /var/www/html /var/www/html/w

# composer：只有 components.json 里标了 "composer": true 的组件才会用到
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

# 校验基础镜像确实是 MW_VERSION，防止上游标签漂移
RUN set -eux; \
    actual="$(grep -oP "define\( 'MW_VERSION', '\K[^']+" includes/Defines.php)"; \
    if [ "$actual" != "${MW_VERSION}" ]; then \
        echo "Base image is MediaWiki $actual, expected ${MW_VERSION}" >&2; exit 1; \
    fi

# ---- 皮肤与扩展（按 components.json 安装）----
# 生成 /etc/mediawiki-image/{components.txt,components.json,update-key}；
# update-key 是组件指纹，MW 版本或任一组件变化时容器启动会重新执行 update.php
COPY components.json /usr/local/lib/mediawiki-image/components.json
COPY --chmod=0755 docker/install-components.py /usr/local/lib/mediawiki-image/install-components.py
RUN set -eux; \
    python3 /usr/local/lib/mediawiki-image/install-components.py /usr/local/lib/mediawiki-image/components.json; \
    chown -R www-data:www-data extensions skins

# 加载器、各组件的默认配置片段
COPY config/extensions.php /var/www/html/extensions.php
COPY config/settings/ /etc/mediawiki-image/settings/
COPY --chmod=0755 docker/mw-entrypoint.sh /usr/local/bin/mw-entrypoint
COPY --chmod=0755 docker/mw-smoke-test.sh /usr/local/bin/mw-smoke-test
COPY docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY --chmod=0755 docker/mediawiki-web-start /usr/local/bin/mediawiki-web-start
RUN nginx -t
# 升级状态读写脚本：状态存在数据库 updatelog 表中，容器无需持久化卷
COPY --chmod=0644 docker/ImageState.php docker/CheckComponents.php /usr/local/lib/mediawiki-image/

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD curl -fsS -o /dev/null http://127.0.0.1/ || exit 1

EXPOSE 80

ENTRYPOINT ["mw-entrypoint"]
CMD ["mediawiki-web-start"]
