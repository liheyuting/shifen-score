# 拾分 · 一起记分

## 运行

在本目录启动静态网页：

```bash
python3 -m http.server 8000
```

浏览器打开 <http://localhost:8000/>。

网站源码会通过 GitHub Pages 发布。部署完成后，直接访问仓库对应的 Pages 地址即可。

## 功能

- 新建云端房间，或通过房间码/邀请二维码加入同一个共享房间；扫描邀请二维码后直接输入昵称即可加入
- 房间成员、积分变更和明细实时同步
- 查看伙伴积分排行与积分明细
- 给伙伴记分、相互转分，或手动调整积分（允许负分）
- 导出 JSON 数据备份

## 配置跨设备共享

首次部署前，需要创建 Supabase 项目：

1. 在 Supabase 项目 **SQL Editor** 执行 [`supabase-schema.sql`](./supabase-schema.sql)。
2. 在 **Authentication → Providers** 启用 Anonymous Sign-Ins。
3. 将 Project URL 和 anon/publishable key 填入 [`supabase-config.js`](./supabase-config.js) 的 `url` 与 `anonKey`。
4. 发布这三个网页文件（`index.html`、`supabase-config.js`、`supabase-schema.sql`）到 GitHub Pages。

页面只使用公开 anon/publishable key；房间读写由 RLS 和数据库函数校验，切勿把 `service_role` key 放进网页。未配置 Supabase 时，首页会提示共享功能尚未启用，创建/加入操作不会伪装成成功。

房间和积分存于 Supabase 云端，同一房间成员可跨设备同步。新建房间的成员初始积分为 0；二维码带有房间码，新设备扫描后会直接显示昵称输入框，不必再选择新建或加入，也不必手动输入房间码。二维码生成依赖联网加载 QRCode.js。
