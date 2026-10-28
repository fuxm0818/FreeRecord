<!--
目标分支请选 develop（日常开发主干），不要直接提 main。
-->

## 这个 PR 解决什么

<!-- 一句话说明动机；关联 issue 用 `closes #123` -->

## 改动要点

-

## 验证

跑了哪些、看到什么结果。内核改动（`Sources/FreeRecordCore`）至少覆盖：整屏/窗口/区域各录 10 秒、双音轨、暂停后成片时长、成片可播放。

- [ ] `swift build` 无错误无警告
- [ ] `bash scripts/build.sh` 通过，`lipo -info` 显示 `x86_64 arm64`
- [ ] 手动回归了受影响的功能
- [ ] 用户可见变化已同步 README / CHANGELOG
- [ ] `git status --ignored` 里没有误提交的 `dist/`、`.build*` 或本地私有文件
- [ ] 新增的悬浮窗带 `hiddenWindowTitle` 标记且 `sharingType = .none`（不会被录进成片）

## 备注

已知限制、没覆盖到的场景、后续想做的。
