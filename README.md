# 拾闻 / clip-collections

把感兴趣的新闻存成 PDF。来源是链接或截图，PDF 放在这台 Mac 的 `~/Desktop/新闻/`。

- **Mac 应用 ClipCollections**（Swift，菜单栏小程序加新闻列表窗口）：抓取网页、生成 PDF。
- **网页版**（手机和电脑共用）：保存链接或截图，查看列表和状态。PDF 不上云。
- 接入[心愿中枢](https://therookiegit.github.io/my-collections/)的「新闻」分类。

这个仓库是公开的，用来发布 GitHub Pages。这里只放代码，不放任何个人数据、口令或密钥。

## 当前进度

阶段 1：验证抓取。`Sources/ClipCapture` 是抓取引擎，`Sources/ClipProbe` 是命令行原型。

```sh
swift build
.build/debug/ClipProbe --selftest            # 不联网的检查
.build/debug/ClipProbe "<链接>"               # 抓取，结果写到 probe-output/
.build/debug/ClipProbe --login "<网址>"       # 打开窗口登录，登录后关闭窗口
```

## 第三方代码

`Resources/vendor/Readability-0.6.0.js` 是 Mozilla Readability 0.6.0（Apache-2.0），来自 npm 包 `@mozilla/readability`，未经修改。
