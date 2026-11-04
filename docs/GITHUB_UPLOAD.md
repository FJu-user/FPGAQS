# 上传 GitHub 并取得报名链接

## 上传文件

将 ZIP 解压，进入 `fpga-dual-board-vision` 文件夹。仓库根目录应直接看到 README.md、两份板卡工程、docs 和 scripts。ZIP 是交付载体；推荐将解压后的文件上传为可浏览的源码仓库。

本包超过100个文件。GitHub 网页单次最多添加100个文件，推荐使用 Git 或 GitHub Desktop 保留目录并一次提交；若使用网页，请分批且保留隐藏的 IP 参数文件。GitHub 当前文件大小说明见[官方上传文档](https://docs.github.com/en/repositories/working-with-files/managing-files/adding-a-file-to-a-repository)。

## 使用 Git

1. 在自己的 GitHub 账号创建空仓库，例如 `fpga-dual-board-vision`。选择所需可见性；供比赛审核时要确保评委可访问。先不要自动创建 README、许可证或 .gitignore。
2. 在解压后的仓库根目录打开 PowerShell，将下方远程地址中的 YOUR_NAME 与仓库名改成自己的真实值后执行：

```powershell
git init -b main
git add .
git commit -m "Add current dual-board FPGA vision source"
git remote add origin https://github.com/YOUR_NAME/fpga-dual-board-vision.git
git push -u origin main
```

如 Git 尚未配置提交姓名和邮箱，按本人实际身份配置后再提交。本文件不代填作者信息。认证通过 GitHub 自己的登录流程完成，无需把访问令牌写入工程。

3. 打开仓库主页，检查 README、两份 `.al`、user_source 与隐藏 IP 参数文件已出现，且不存在 AGENTS、历史版本或 Runs。
4. 把实际仓库主页链接填入比赛的“Github链接输入”框，例如 `https://github.com/你的账号/你的仓库名`。示例不是已创建的仓库，本次没有登录、上传或生成真实 GitHub 链接。

## 许可证

用户尚未选择开源许可，因此本包不附 MIT/Apache 等许可证。GitHub 可见性设置不替代权利人的授权；发布前根据 THIRD_PARTY_NOTICES.md 确认具体第三方文件的公开再分发范围。
