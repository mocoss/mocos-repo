# 使用 GitHub Pages 搭建 Mocos 插件源

## 已准备的文件
`mocos-repo-template.zip` 中包含：
- rootless/debs/：1.0.0 rootless 安装包及独立索引。
- roothide/debs/：1.0.0 RootHide 安装包及独立索引。
- 两个目录各有 Packages、Packages.gz、Release。
- index.html：源介绍首页。
- tools/make_repo.py：读取 deb 元信息，检查架构并生成相对路径、SHA256和大小。
- .github/workflows/deploy.yml：自动生成索引并部署 Pages。
- .nojekyll：静态站点标记。

当前索引未配置仓库签名。部分越狱管理器可能允许添加未签名源，但不保证所有客户端接受；HTTPS不等于APT仓库签名。请勿通过关闭安全校验解决签名错误。正式公开分发建议配置GPG签名和客户端公钥信任，下面有说明。

## 方式A：网页上传，快速试用
1. 登录 GitHub，新建公开（Public）仓库，建议名称 `mocos-repo`，默认分支 `main`。GitHub Free 的 Pages 使用公开仓库。
2. 在电脑或iOS文件App解压模板。**解压后的文件放到仓库根目录，不是只上传ZIP，也不是再套一层repo文件夹。** 根目录应直接看到 index.html、rootless、roothide、tools。
3. GitHub 仓库 → Add file → Upload files，上传上述文件夹和文件并提交。手机网页对文件夹上传支持可能有限；如果不保留目录，用电脑上传、支持Git的客户端或后面的终端方式。
4. GitHub → 仓库 Settings → Pages → Source 选择 **GitHub Actions**（本模板用此模式，不选择分支部署）。
5. 确认 `.github/workflows/deploy.yml` 已上传。隐藏文件夹在文件App中可能不易选中。可在GitHub点 Add file → Create new file，名称输入 `.github/workflows/deploy.yml`，粘贴模板中的内容并提交。
6. 仓库 Actions 页面 → Deploy tweak repository → Run workflow，选择main执行。第一次也可能随提交自动运行。若要求启用Actions，先按GitHub提示启用。
7. 等待任务绿色完成，在 Settings → Pages 或部署任务输出中查看站点URL。
8. 浏览器检查首页、两个目录的 Packages.gz 与一个 deb 文件均能下载。首页可以打开不代表源索引一定正确。

假设GitHub用户名为 `YOURNAME`，仓库为 `mocos-repo`：
- 网页首页：https://YOURNAME.github.io/mocos-repo/
- rootless源：https://YOURNAME.github.io/mocos-repo/rootless/
- RootHide源：https://YOURNAME.github.io/mocos-repo/roothide/

这些只是占位示例，本次并未建立远程仓库或发布在线地址。

两个环境各添加一个对应源，地址以斜杠结尾。不要同时添加两种源；包ID相同但架构和布局不同。RootHide客户端是否接受索引、签名及架构还需实机确认。

## 方式B：用Git客户端/终端上传
本模板不需要上传源码、SDK或原微信助手。仅上传静态源目录。
在自己的仓库克隆目录中放入模板内容：

```sh
git add .
git commit -m "Publish Mocos tweak repository"
git push origin main
```

使用GitHub支持的登录方式，密码、令牌和私钥不要发到聊天或提交进仓库。若没有配置登录，可用GitHub客户端；也可以在Minis里让我检查文件并协助上传，但创建远程仓库和授权需你操作。

## 每次发布新版本
1. 必须提升 deb Version，不要在同版本号下替换内容。
2. 把新 rootless deb 放 rootless/debs，把新 RootHide deb 放 roothide/debs。
3. 提交到main，工作流自动在部署产物中重新生成索引并部署。仓库里的预生成索引可能不变，以线上部署产物为准。
4. 在两种设备各刷新源，检查版本、包下载与安装。
5. 不建议立即删除旧deb，避免用户持有旧索引时下载失败。

包名、版本、依赖来自deb，不是手写猜测。Filename相对于源目录，例如rootless源中的 `debs/wechat-float_1.0.0_dopamine-rootless.deb`；不要添加docs或重复rootless前缀。

## 正式分发的仓库签名
本模板**没有你的GPG私钥，也未完成签名或线上端到端测试**。自动工作流当前生成未签名索引，是部署起点，不是已完成的安全发布方案。

本地已有GPG密钥时，索引脚本支持：

```sh
python3 tools/make_repo.py . --label "Mocos Repo" --sign-key YOUR_GPG_FINGERPRINT
```

每个源目录会生成 InRelease 和 Release.gpg。将公钥通过安全方式提供给用户，公布完整指纹，并按客户端支持的专用keyring/Signed-By或公钥导入流程建立信任。不要上传私钥。

若使用Actions签名，应使用GitHub加密Secrets和临时GNUPGHOME，修改工作流的Build indexes步骤来安全导入并签名，签名后才上传站点。**不能把未签名的自动工作流和手动签名发布混用**：每次重建未签名索引都会删除旧签名，避免无效签名残留。配置自动签名时需单独核对密钥管理及客户端信任，不能只加一个公钥文件就当作完成。

如果暂不发布APT源，也可以先通过GitHub Releases分发deb及SHA256校验值。它方便下载安装包，但不等于已签名APT软件源。

## 简单检查
- 404：检查main是否部署成功、路径和文件名大小写、是否误套目录。
- Packages下载到HTML：地址指向网页或404，不是正确索引文件。
- 架构不兼容：检查是否加错源，不要强制安装。
- 签名错误：修复仓库签名、公钥信任或设备时间，不要关闭检查。
- 默认无需买域名。自定义域名可后续添加。
- GitHub Pages有约1GB站点大小、每月100GB带宽软上限等限制，不是无限流量服务；需遵守GitHub使用条款。

## 官方参考
- GitHub Pages Actions部署：https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages
- Pages配置：https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site
- Pages限制：https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits
- Debian仓库格式：https://wiki.debian.org/DebianRepository/Format
- APT安全与签名：https://manpages.debian.org/stable/apt/apt-secure.8.en.html
- RootHide适配文档：https://github.com/roothide/Developer
