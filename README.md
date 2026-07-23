# JuneMew

**MacBook 刘海上的 CME 期货 K 线收线倒计时。**

盯盘时最贵的注意力错误之一：回头看图才发现这根 5 分钟 K 线已经收了。JuneMew 把「这根 K 线还剩多久」常驻在刘海两侧 —— 视线不用离开图表，余光就能读到；收线前变色、可选响铃，离开屏幕也叫得回来。

- **K 线倒计时** — 1m / 3m / 5m / 15m / 30m / 1H，按 CME Globex 时段锚定（18:00 ET），与 TradingView 的 K 线边界一致
- **相位变色** — 常态白、警告琥珀、紧急橙红加辉光；亮度阶梯对所有色觉类型有效
- **收线响铃** — 提前 N 秒响，支持「响到手动关闭」模式；响铃时整个刘海就是停止按钮
- **刘海仪表盘** — 悬停放大提示，点击展开：全周期倒计时矩阵（点卡片切周期）、今日时段、距收盘、时钟状态、声音开关；休市时显示下次开盘
- **交易日历** — 内置 CME Equity Index 假期表（全天休市 / 提前收盘 / 延后开盘），表过期会告警而不是装作没事
- **时钟可信度** — 联网校准系统时钟 + 阶跃哨兵；时钟不可信时**拒绝显示数字**——一个不能相信的倒计时比没有更危险
- **自动更新** — Sparkle 2 + ed25519 签名，不依赖苹果签名体系

克制是刻意的：常态下一切静止（数字硬切、图标不动、鼠标划过无反应），运动只留给真正需要打断注意力的时刻。

## 安装

从 [Releases](https://github.com/1of1Adam/JuneMew/releases) 下载最新 DMG，拖入 Applications。

**首次启动会被 Gatekeeper 拦截**（本项目没有 Apple Developer 账号，未做公证）：

1. 打开 **系统设置 → 隐私与安全性**，在 Security 一节找到 "JuneMew was blocked…"，点 **Open Anyway**；或
2. 终端执行（macOS 26+ 的 `xattr` 已移除 `-r`，这是跨版本兼容写法）：

```bash
find /Applications/JuneMew.app -print0 | xargs -0 xattr -d com.apple.quarantine 2>/dev/null
```

只需放行这一次 —— 之后的版本由内置更新器分发，更新包不带 quarantine 标记，不会再弹「已损坏」。

## 自动更新的安全模型

没有 Apple Developer 账号，更新链路不经过苹果签名体系：

- 每个更新包发布前用**本机保管的 ed25519 私钥**签名（Sparkle `sign_update`）
- App 内嵌对应公钥（`SUPublicEDKey`），下载后验签通过才安装
- appcast 与更新包全程 HTTPS（GitHub）

菜单栏图标 → **Check for Updates…** 手动检查；设置 → General → Updates 可关闭每日自动检查。

## 构建

```bash
git clone https://github.com/1of1Adam/JuneMew.git
cd JuneMew
xcodebuild -project MewNotch.xcodeproj -scheme MewNotch -configuration Release build
```

要求 macOS 15.2+，Xcode 26+。领域层 `KLineCore`（交易时段 / 假期表 / K 线定位 / 时钟可信度）是独立 SPM 包，带 35+ 单元测试：

```bash
cd KLineCore && swift test
```

发版流程见 `scripts/release.sh`。

## 数据与隐私

全部计算在本地。仅有的网络请求：时钟校准（向两个 HTTPS 端点发 HEAD 读 `Date` 响应头，可在设置中关闭）和 Sparkle 更新检查（可关闭）。无统计、无追踪。

## 已知限制

- 假期表覆盖 2026–2027，状态为 `unverified_draft`（日期经算法交叉验证，但「全天休市 vs 提前收盘」及具体时刻尚未逐条对照 CME 官方日历）——刘海上的琥珀点即此告警
- 4H 周期未开放：TradingView 对 CME 4H K 线的锚点未实测确认前不上线错的东西
- 仅在有物理刘海的屏幕上显示（设置里可强制在所有屏幕模拟）

## 致谢与许可

Fork 自 [monuk7735/mew-notch](https://github.com/monuk7735/mew-notch)（通用刘海 HUD 工具），砍掉全部 HUD 功能后重建为专用交易工具，刘海窗口基建沿用原项目。

依赖：[Sparkle](https://github.com/sparkle-project/Sparkle) · [LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern) · [MacroVisionKit](https://github.com/TheBoredTeam/MacroVisionKit)

License: [GPLv3](LICENSE)（延续自原项目）

---

*本工具只做时间提醒，不构成任何交易建议。K 线边界以你的交易平台为准。*
