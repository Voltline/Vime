# 参与贡献

开发流程、测试与验证见 [开发与验证](Docs/Development.md)。

## 许可

提交到本仓库的贡献以 [GPL-3.0-or-later](LICENSE) 授权，并适用 [LICENSE-EXCEPTION](LICENSE-EXCEPTION) 中的额外许可，与项目其余部分一致。这项额外许可让 Vime 可以在 App Store 发布；不接受这项条款的改动无法合入。

提交 Pull Request 即表示你有权以上述条款授权所提交的内容。引入第三方代码或数据时，在同一改动中更新 `Shared/Resources/ThirdPartyNotices.txt`、`Vime/Resources/LicenseManifest.json` 与 `Vime/Resources/Licenses/`，并运行：

```sh
python3 Scripts/validate_app_resources.py
```

许可须与 GPLv3 兼容，且允许经应用商店分发；仅限非商业使用（如 CC BY-NC）或禁止演绎（ND）的素材不能随 App 发布。

## License (English)

Contributions are licensed under GPL-3.0-or-later with the additional permission in [LICENSE-EXCEPTION](LICENSE-EXCEPTION), which lets Vime ship on the App Store. By opening a pull request you confirm that you have the right to license your contribution on these terms. Third-party code or data must be GPLv3-compatible, allow app store distribution, and be recorded in the third-party notices and license manifest.
