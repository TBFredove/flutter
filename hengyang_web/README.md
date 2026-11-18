# 恒洋物联

Flutter Web 前端及 Go 后端源码。网页通过同域 `/api/v1` 访问后端，不直接连接 MQTT。

## 功能

- 管理设备型号（展示字段和命令）及 15 位字符串 IMEI 设备。
- 展示已登记设备最近一次 telemetry，时间为后端接收时间；不能据此判定设备当前在线。
  后端保存新遥测后通过 SSE 通知网页刷新设备数据；连接中断会提示并自动重连，
  重连后重新获取最新状态。手动刷新仍可使用。
- 型号允许配置命令，但当前只允许向固件发布 `PLAY`、`PAUSE`、`NEXT`、`PREV`、
  `SET_VOLUME` 及四个 `ULTRASONIC_*` 命令；
  其他命令仅保存配置。发布成功不代表设备收到或执行成功。设备必须运行兼容的固件，
  并使用 `aisms/{imei}/status` 和 `aisms/{imei}/cmd` 主题。
- 型号命令列表添加 `SET_VOLUME` 后，在「音乐播放」区域显示音量滑条；设备需支持该命令。
  滑条发送 0–100 整数，不会假定设备已应用，实际音量以设备遥测为准。
- 含 `PLAY` 命令的设备可在播放器中获取 SD 卡歌单（每页 20 首），点击曲目右侧播放按钮点播。
  歌单由设备实时返回，需支持 `GET_SONGS` 的固件；更换 SD 卡或修改曲目后请重新获取。
  页面播放状态和当前曲目以遥测为准，不会在命令发布时预先切换。
- 在型号编辑中勾选“启用超声控制”，即可在音乐区域外显示独立的超声控制，
  使用一个播放／暂停按钮和一个扫频／定频切换控件。
  设备需刷入支持该功能的固件；状态以设备上报为准，旧固件显示未知。
  停止时选模式不启动播放，运行时切换模式立即生效；扫频单程 60 秒。
- 地图中心为手动输入的 WGS-84 经纬度，默认经度 117.58、纬度 37.76，
  并持久化到后端。暂不使用设备 GPS 自动更新位置。
- 初始管理员为 `admin` / `admin`，首次登录必须修改密码；账户已有密码时重启
  不会重置。初始密码已公开，部署后应立即修改。当前只有一个管理员，尚无多用户、
  角色管理、找回密码、设备归属或细粒度授权。
- 登录界面的“忘记密码？”进入修改密码流程，需要验证当前密码；不能找回遗忘的密码。
- 设备命令直接发送，不再弹确认框；每个命令按钮点击后至少禁用 0.2 秒，
  请求未完成时继续禁用，避免重复发送。

IMEI 目前只是设备标识，尚未实现设备认证。部署方必须另行配置 EMQX 身份认证及
主题 ACL；否则其他 MQTT 客户端可能伪造设备状态。历史协议、状态 ACK、设备在线
判定和命令执行结果尚未完整实现，需与实际设备联调。

地图使用 OpenStreetMap 公共瓦片，须显示署名、遵守
[瓦片使用政策](https://operations.osmfoundation.org/policies/tiles/)；服务不保证
可用性，生产流量需评估替代供应商。可构建时通过 `--dart-define=MAP_TILE_URL=...`
替换瓦片地址；中国境内地图供应商如使用 GCJ-02 等坐标系，需要另行处理坐标转换。

## 本机开发

Flutter SDK 位于 `/home/dafei/flutter`。在项目目录运行：

```sh
/home/dafei/flutter/bin/flutter pub get
/home/dafei/flutter/bin/flutter analyze
/home/dafei/flutter/bin/flutter test
/home/dafei/flutter/bin/flutter build web --release --pwa-strategy=none
cp deploy/flutter_service_worker.js build/web/flutter_service_worker.js
```

构建产物在 `build/web`。本机开发需另行提供 HTTPS 同域反向代理和后端；
登录 Cookie 要求 HTTPS，不能直接用文件路径打开页面。

## Android

Android 应用使用 `https://iot.hengyanghk.com` 的同一后端，遥测自动更新并在断线后
重连。登录会话仅保存在应用内存中，完全退出应用后需要重新登录。
安装 Android SDK 和兼容 Gradle 8.3 的 Java 17 后，在项目目录运行
`flutter build apk --release`，生成的安装包位于 `build/app/outputs/flutter-apk/`。
当前构建配置使用 Android 调试密钥签名，仅适合内部测试；正式分发前需配置并安全
保管独立的发布签名密钥，调试签名与正式签名的安装包不能直接覆盖升级。

后端源码位于 `backend/`。部署需要现有 MySQL、PostgreSQL 和 EMQX；MySQL 中
的 `hengyang_backend` 数据库存储账号、设备、型号、会话和地图中心。数据库模式
在服务启动时以 `CREATE TABLE IF NOT EXISTS` 初始化。数据库用户名和密码由
Compose 环境变量提供，不写入项目源码。账号密码以 bcrypt 哈希保存。

## 服务器部署及续期

本次部署使用 `iot.hengyanghk.com`、Nginx 与 Let's Encrypt。前端静态文件放在
服务器 `/opt/hengyang_platform/nginx/html`，Nginx 配置在
`/opt/hengyang_platform/nginx/conf.d/default.conf`。Compose 将 HTTPS 443、
HTTP 80 和已有 8080/8443 映射到 Nginx；后端 8000 只绑定服务器回环地址。
证书通过 certbot webroot 自动续期，续期成功后 deploy hook 重载 Nginx。
HTTP 80 必须保持可从公网访问，以便证书续期。

项目 `deploy/nginx.conf` 和 `deploy/certbot-reload` 是部署配置的源文件。
Web 不再安装离线缓存。发布时保留构建步骤复制的 `flutter_service_worker.js`，
用于注销已安装的旧 Flutter worker 并清理其缓存。Nginx 要求浏览器重新验证网页入口和应用脚本。
修改前请核对服务器现有配置并备份，不要删除数据库卷。部署后验证证书、登录、
接口以及 `certbot renew --dry-run`。服务器已有备份应妥善保护，因为 Compose
文件包含数据库密码。
