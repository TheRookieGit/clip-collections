# 拾闻 / clip-collections

把感兴趣的新闻存成 PDF。来源是链接或截图，PDF 直接放在这台 Mac 的桌面。

- **Mac 应用 ClipCollections**（Swift，菜单栏小程序加新闻列表窗口）：抓取网页、生成 PDF。
- **网页版**（手机和电脑共用）：保存链接或截图，查看列表和状态。PDF 不上云。
- 接入[心愿中枢](https://therookiegit.github.io/my-collections/)的「新闻」分类。

这个仓库是公开的，用来发布 GitHub Pages。这里只放代码，不放任何个人数据、口令或密钥。

## 结构

- `Sources/ClipCapture`：抓取引擎和核心逻辑（PDF、导出、存储、Claude、云端客户端）。
- `Sources/ClipCollections`：Mac 应用。
- `Sources/ClipProbe`：命令行工具，用来诊断抓取和跑自测。
- `supabase/`：表和 Edge Function `api`。所有表开 RLS 且没有 policy，只能通过函数读写。
- `docs/index.html`：网页版，由 GitHub Pages 发布。

## 开发

```sh
scripts/check.sh            # 自测，不联网，不碰真实数据
scripts/build-app.sh        # 打包并安装到 /Applications/ahomemade
.build/debug/ClipProbe "<链接>"          # 抓取一个链接，结果写到 probe-output/
```

只需要 Command Line Tools。它不带 SwiftUI 的宏插件，所以界面状态放在 `@Observable` 类里，不用 `@State`。

## 部署云端

```sh
supabase login                                   # 用拥有这个项目的账号
supabase link --project-ref <project ref>        # 这里要输入数据库密码
supabase db push
supabase secrets set APP_PASSCODE=<自己定的口令>
supabase functions deploy api --no-verify-jwt
```

然后在 Mac 应用的设置（⌘,）里填同一个口令。

## 接入心愿中枢

在设置里用同步密码或配对码连接后，拾闻和中枢的「新闻」分类双向同步：

- 中枢新增的新闻进入拾闻的队列，拾闻新增的新闻写回中枢，两边用同一个 id。
- PDF 生成成功后通过 `mc_fulfill_put` 回报，中枢显示「已保存」。状态不写进条目 JSON。
- 两边同时改同一条时，中枢的改动优先。
- 需要 my-collections 的迁移 `006_clipcollections.sql`。

## 第三方代码

`Resources/vendor/Readability-0.6.0.js` 是 Mozilla Readability 0.6.0（Apache-2.0），来自 npm 包 `@mozilla/readability`，未经修改。
