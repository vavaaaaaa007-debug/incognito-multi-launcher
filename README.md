# 一键多开无痕浏览器

一键打开多个**互相隔离**的无痕浏览器窗口，自动按九宫格排好。

- 每个窗口用一份独立的临时配置，再加上无痕模式，Cookie 和登录状态互不相通，适合多账号同时登录
- 关闭窗口或退出软件时，临时数据会全部删除
- 支持 Chrome、Edge、Brave、Firefox（会自动找出电脑上装了哪些）
- 可以设置默认打开的网址（每行一个，每个窗口各开一个标签页）和默认页面缩放（默认 50%）
- 网址框只接受 http/https 网址，以 `-` 开头的行会被跳过，防止被当成浏览器启动参数

支持的系统：**macOS 13 及以上**（Apple 芯片和 Intel 都支持）、**Windows 10/11（64 位）**。

## 下载

到本仓库的 **Releases** 页面下载：

| 文件 | 用途 |
|---|---|
| `一键多开无痕浏览器-v<版本>.dmg` | Mac：打开后把 app 拖进「应用程序」 |
| `一键多开无痕浏览器-v<版本>-安装包.exe` | Windows：安装版（不需要管理员权限） |
| `一键多开无痕浏览器-v<版本>-Windows免安装版.zip` | Windows：解压即用 |

软件没有购买苹果和微软的正式签名，第一次打开时：
- **Mac**：如果提示「无法验证开发者」，在 app 上**右键 → 打开**，再点「打开」
- **Windows**：如果弹出「Windows 已保护你的电脑」，点「更多信息」，再点「仍要运行」

## 用 GitHub 自动打包

仓库里已经带了 `.github/workflows/build.yml`，不需要自己的电脑参与：

1. **每次推送代码**：GitHub 会自动打包 Mac 版和 Windows 版。打开仓库的 **Actions** 页面，点进最近一次运行，在页面底部的 **Artifacts** 里下载。
2. **发布新版本**：
   1. 把 `VERSION` 文件里的版本号改掉，例如 `1.0.1`，然后提交
   2. 推送同名标签：
      ```bash
      git tag v1.0.1
      git push origin v1.0.1
      ```
   3. 打包完成后，会自动创建一个 Release，并把 dmg、exe、zip 都附在上面

> 标签必须和 `VERSION` 文件一致（`v` + 版本号），否则发布那一步会停下来提示。

## 在自己电脑上打包

**Mac 版**（需要 macOS 和 Xcode 或 Command Line Tools）：

```bash
bash mac/build.sh
```

**Windows 版**（在 Mac 或 Linux 上交叉编译，不需要 Windows 电脑）：

```bash
brew install go makensis
```
```bash
bash win/build.sh
```

打包好的文件都在 `dist/` 文件夹里。

## 目录结构

```
VERSION                    版本号（打包脚本和发布流程都读这里）
mac/main.swift             Mac 版源码（SwiftUI，单文件）
mac/build.sh               Mac 打包脚本 → .app + .dmg
win/main.go                Windows 版源码（Go + lxn/walk）
win/go.mod, win/go.sum     Go 依赖（已锁定版本和校验和）
win/app.manifest           Windows 界面清单（高分屏、新版控件样式）
win/installer.nsi          Windows 安装包脚本（NSIS）
win/build.sh               Windows 打包脚本 → 安装包.exe + 免安装版.zip
.github/workflows/build.yml  GitHub 自动打包流程
```

## 实现说明

- **隔离方式**：Chromium 系浏览器（Chrome / Edge / Brave）用 `--user-data-dir=<临时目录> --incognito`；Firefox 用独立的临时 profile，并开启永久隐私模式。
- **默认缩放**：Chromium 在临时配置的 `Preferences` 里写入 `partition.default_zoom_level`（缩放级别 = log(比例)/log(1.2)）；Firefox 使用 `layout.css.devPixelsPerPx`，所以工具栏也会一起缩小。
- **九宫格**：按主屏幕可用区域分成 3×3；超过 9 个窗口时，下一页错开一点继续排。Mac 版用「辅助功能」权限精确摆放窗口（Firefox 必须开这个权限），Windows 版用系统窗口接口摆放。
