# MediaWiki Docker 镜像

基于官方 [`mediawiki`](https://hub.docker.com/_/mediawiki) 镜像，额外集成 Cargo、CodeMirror、TemplateSandbox、TemplateStylesExtender 扩展和 Citizen 皮肤。镜像由 GitHub Actions 自动构建，发布到 GHCR，支持 `linux/amd64` 和 `linux/arm64`。

包含哪些皮肤和扩展，全部由 [`components.json`](components.json) 一个文件决定。

## 镜像标签

每个镜像只对应一个 MediaWiki 版本：基础镜像是该精确版本，扩展默认用对应的 `REL1_xx` 分支。

| 标签 | 含义 | 是否会变 |
|---|---|---|
| `1.46.2-4aacf1e6` | MediaWiki 版本 + 配方哈希 | **不变**。同一组合只构建一次，适合需要绝对固定的场景 |
| `1.46.2` | 该 MediaWiki 版本的最新配方 | 修改配方（如增删扩展）后更新 |
| `1.46` | 该系列的最新补丁 | 有新补丁或新配方时更新 |
| `latest` | 官方 stable 系列 | 跨大版本更新 |
| `lts` | 官方 LTS 系列 | 跨 LTS 大版本更新 |

“配方”指决定镜像内容的文件：`Dockerfile`、`components.json`、`config/`、`docker/`。只改文档或工作流不会产生新配方。

镜像内的 `/etc/mediawiki-image/components.txt` 记录了每个组件的来源、分支和 commit：

```sh
docker run --rm --entrypoint cat ghcr.io/owner/repo:1.46 /etc/mediawiki-image/components.txt
```

## 增加或移除皮肤、扩展

只需要改 `components.json`，提交到 main，CI 会自动构建、测试并发布新镜像。

### 1. 在 `components.json` 中加一项

```jsonc
{
  "extensions": [
    // 随 MediaWiki 发布包自带的扩展：只写名字
    { "name": "Nuke", "source": "bundled" },

    // Wikimedia Gerrit 上的扩展：默认用与 MediaWiki 匹配的 REL1_xx 分支
    { "name": "Variables", "source": "gerrit" },

    // GitHub 等 git 仓库中的扩展：指定标签、分支或 40 位 commit
    { "name": "MyExtension", "source": "github:<owner>/<repo>", "ref": "v1.0.0" },

    // 只在部分 MediaWiki 版本中安装；有 composer 依赖时加 "composer": true
    { "name": "OtherExtension", "source": "https://git.example.org/OtherExtension.git",
      "ref": "main", "mediawiki": ">=1.43, <1.47", "composer": true }
  ]
}
```

| 字段 | 说明 |
|---|---|
| `name` | 目录名，也是 `wfLoadExtension`/`wfLoadSkin` 的参数 |
| `source` | `bundled`、`gerrit`（无法访问时回退 Wikimedia 官方 GitHub 镜像）、`github:<owner>/<repo>`，或完整的 git 地址；可按系列分别指定 |
| `ref` | 分支、标签或 commit。省略表示匹配的 `REL1_xx`。可按系列分别指定：`{"default": "master", "1.43": "REL1_43"}` |
| `mediawiki` | 版本约束，如 `">=1.43.9"`、`"<1.44"`，逗号表示同时满足。不满足时该版本的镜像里跳过此组件 |
| `load` | `false` 表示只安装、不自动加载（默认 `true`） |
| `composer` | `true` 表示通过 `composer.local.json` 安装该组件的 composer 依赖 |

列表顺序就是加载顺序（例如 TemplateStylesExtender 必须排在 TemplateStyles 之后）。皮肤放在 `skins` 数组里，写法相同；`default_skin` 设置默认皮肤。

### 2.（可选）给它加默认配置

新建 `config/settings/<name>.php`，例如 `config/settings/Variables.php`。只有该组件被加载时这个文件才会被引入，移除组件时配置也会一起失效。

### 3. 提交

- 开 PR：CI 只构建并跑冒烟测试。
- 合入 main：CI 自动构建并发布新镜像（`1.46.2-<新配方>`，并更新 `1.46.2`、`1.46` 等标签）。

冒烟测试会在镜像里用 SQLite 真实安装一个 wiki，确认 `components.json` 中每个组件都被 MediaWiki 实际加载，并渲染一段用到 ParserFunctions、Scribunto、SyntaxHighlight、Cite 的页面。扩展和当前 MediaWiki 版本不兼容时，CI 会在推送前失败。

本地验证可以直接构建：

```sh
docker build --build-arg MW_VERSION=1.46.2 -t mediawiki-custom .
docker run --rm --entrypoint mw-smoke-test mediawiki-custom
```

### 不想重新构建镜像？

纯 PHP、没有 composer 依赖的扩展，也可以在运行时外接：把扩展目录挂载到容器的 `/var/www/html/extensions/<名称>`，再在外接配置目录的 `conf.d/` 下加一个 `.php` 文件调用 `wfLoadExtension( '<名称>' );`。这种方式不经过 CI 测试；它也不会改变组件指纹，所以如果扩展需要建表，要手动执行一次 `docker compose exec mediawiki php maintenance/run.php update`。适合临时使用。

## 自动构建（GitHub Actions）

工作流 `.github/workflows/build.yml` 只构建 GHCR 上还不存在的“MediaWiki 版本 + 配方”组合：

| 触发 | 行为 |
|---|---|
| 每天定时 | 从 Docker Hub 读取官方 `stable`、`lts` 对应的版本；官方发布新版本后自动构建 |
| push 到 main | 配方有变化时自动构建并发布 |
| PR | 构建并测试所有跟踪的版本，不发布 |
| 手动运行 | 可勾选 `force` 无条件重建（例如想拉取 `ref` 为 `master` 的组件的新提交），可用 `series` 只构建某个系列 |

跟踪哪些 MediaWiki 系列在 `versions.json` 中配置：

```jsonc
{
  "track": ["stable", "lts"],   // 自动跟踪官方 stable 和 lts
  "extra_series": [],           // 额外保留的系列，如 ["1.45"]
  "min_series": "1.43"          // Citizen 与 TemplateStylesExtender 要求 >= 1.43
}
```

`ref` 写成分支（如 `master`）的组件，只在构建时取当时的最新提交，之后不会自动跟进；需要可重复构建时，建议写成标签或 commit。

### 首次推送到 GitHub 后

1. 推送到 main 后会自动运行一次；也可以到 **Actions → Build MediaWiki images → Run workflow** 手动运行。
2. 包发布后默认是私有的。如需公开，到仓库主页右侧 **Packages → 包设置 → Change visibility**。

## 部署

```sh
cp .env.example .env      # 修改 MW_IMAGE、数据库密码
docker compose up -d
```

1. 打开 http://localhost:8080 完成网页安装。数据库主机填 `database`；在“外观”一步可以把 Citizen 设为默认皮肤。
2. 把下载的 `LocalSettings.php` 放到 `./data/config/`，在文件**开头**的 `MEDIAWIKI` 检查之后加一行：
   ```php
   if ( !defined( 'MEDIAWIKI' ) ) {
   	exit;
   }
   require_once "$IP/extensions.php";   // ← 加在这里
   ```
   放在开头，后面 `LocalSettings.php` 里的设置就能覆盖镜像默认值。安装程序生成的 `wfLoadExtension`/`wfLoadSkin` 行可以保留，重复加载不会出错。
3. 执行 `docker compose restart mediawiki`。容器启动时会自动接入这份配置并运行 `update.php` 建表。
4. 可选：启用后台任务队列 `docker compose --profile jobs up -d`。

镜像同时提供 `/w/` 别名和 Apache 短 URL 规则。若希望使用 `/w` 作为脚本路径、`/wiki` 作为文章路径，并让生成的链接匹配这两个路径，在 `require_once "$IP/extensions.php";` 之后加入：

```php
$wgScriptPath = '/w';
$wgResourceBasePath = $wgScriptPath;
$wgArticlePath = '/wiki/$1';
$wgUsePathInfo = true;
```

### 配置的生效顺序

后者覆盖前者：

1. `config/extensions.php` 中的全站默认值
2. 各组件的默认配置 `config/settings/<名称>.php`
3. 外接配置目录中的 `conf.d/*.php`（按文件名排序），适合放站点专属设置而不改 LocalSettings
4. `LocalSettings.php` 中位于 `require_once` 之后的设置

## 存储与外接挂载

镜像**不声明任何 VOLUME**，不挂载任何东西也能运行（适合试用，删除容器即丢失数据）。需要持久化时按需外接：

| 容器内路径 | 用途 | 说明 |
|---|---|---|
| `/var/www/config/` | 放 `LocalSettings.php` 和 `conf.d/` 的目录 | 推荐。启动时自动链接到 `/var/www/html/LocalSettings.php`；没有该文件时视为未安装 |
| `/var/www/html/LocalSettings.php` | 直接挂载单个文件 | 也可以。注意宿主机上文件必须先存在，否则 Docker 会把它创建成目录 |
| `/var/www/html/images/` | 上传文件 | 如果 www-data 不可写，启动时自动修正属主（`MW_FIX_PERMISSIONS=false` 可关闭） |
| `/var/www/data/` | SQLite 数据库 | 仅使用 SQLite 时需要，这是官方镜像约定的目录 |

示例 `compose.yaml` 用的是宿主机目录 `./data/{config,images,mysql}`，而不是 Docker 命名卷，方便直接备份和迁移。

## 自动升级

容器入口脚本 `docker/mw-entrypoint.sh` 在启动 Web 服务前检查是否需要升级数据库：

- 当 **MediaWiki 版本** 或 **任一扩展/皮肤的 commit** 与上次不同时，自动执行 `maintenance/run.php update`。所以在 `components.json` 里新增扩展后，换上新镜像即可，需要的数据表会自动创建。
- 上次的状态记录在**数据库**里（MediaWiki 自带的 `updatelog` 表，键名 `docker-image-state`），所以容器不需要任何状态卷，删掉重建也能正确判断。
- 先等待数据库可用（读取状态本身就是可用性检查）。
- **防降级**：数据库已被高版本升级过时，用低版本镜像启动会直接报错退出。确认已恢复匹配的数据库备份后，可设 `MW_ALLOW_DOWNGRADE=true` 跳过。
- 多个容器连同一个数据库时，只让一个容器开启自动升级（compose 里 job runner 已设为 `false`）。

| 环境变量 | 默认值 | 说明 |
|---|---|---|
| `MW_AUTO_UPDATE` | `true` | 是否自动执行 update.php |
| `MW_CONFIG_DIR` | `/var/www/config` | 外接配置目录 |
| `MW_FIX_PERMISSIONS` | `true` | 自动修正外接 images 目录的属主 |
| `MW_DB_WAIT_TIMEOUT` | `120` | 等待数据库的秒数 |
| `MW_UPDATE_ARGS` | `--quick` | 传给 update 的参数 |
| `MW_ALLOW_DOWNGRADE` | `false` | 允许以较低版本启动 |

拉取新镜像并重启即可完成升级：

```sh
docker compose pull && docker compose up -d
```

想无人值守地跟随更新，可以在宿主机加一条定时任务，例如每天 4 点：

```cron
0 4 * * * cd /path/to/project && docker compose pull -q && docker compose up -d
```

建议：

- 生产环境用系列标签（如 `1.46`），只自动获取补丁版本和配方更新。大版本升级（如 1.46 → 1.47）手动修改 `MW_TAG`，并先备份数据库。
- `latest` 会跨大版本自动升级，不建议无人值守使用。

## 目录结构

```
components.json              镜像包含的皮肤与扩展（增删组件改这里）
config/extensions.php        加载器 + 全站默认值（镜像内 /var/www/html/extensions.php）
config/settings/<名称>.php   各组件的默认配置
versions.json                CI 跟踪的 MediaWiki 系列
Dockerfile                   镜像定义（构建参数只有 MW_VERSION）
docker/install-components.py 构建时按 components.json 安装组件
docker/mw-entrypoint.sh      入口脚本：接入外接配置、自动升级、防降级
docker/ImageState.php        在数据库中读写升级状态
docker/CheckComponents.php   冒烟测试：确认组件已加载
docker/mw-smoke-test.sh      冒烟测试：真实安装 + 渲染检查
scripts/resolve_versions.py  CI：决定构建哪些版本
compose.yaml                 部署示例
```
