# Kelivo 同步服务端

Kelivo 客户端的权威同步服务端。一台服务器、一个密码，多台设备（iPhone、Windows）连上之后数据实时互通。

## 它是怎么工作的

服务端是**唯一权威**：所有写入先到这里，由它排序、定版，再把变更实时推给其它在线设备。客户端只负责把本地数据表达成一条条记录发过来，收到记录后写回本地。

两个设计决定值得说明，因为它们直接对应"两端数据完全一样"：

- **通用记录模型。** 所有数据都被表示成 `(namespace, recordId, payload)`。服务端不理解聊天、助手、设置分别是什么，因此新增一种客户端数据不需要改服务端。
- **消息按 id 合并，而不是按设备覆盖。** 聊天消息一旦写入就不再变化（编辑是追加一个新版本），所以两端各自发消息时是两个不相交的集合求并集——**不会互相覆盖，也就不会丢消息**。只有在同一 id 被两端同时修改时，才按时间戳 + 设备号裁决，且这个裁决是确定性的，两端算出的结果必然相同。

## 快速开始

### 1. 拿到可执行文件

两种方式，任选：

**下载 CI 构建好的**（推荐）：在仓库的 Actions 里找 `Kelivo-Sync-Server` 这个 artifact，下载 `kelivo-sync-server-linux-x64`。

**自己编译**：任何装了 Dart SDK 的机器上

```bash
cd server
dart pub get
dart compile exe bin/kelivo_sync_server.dart -o kelivo-sync-server
```

产物是单个可执行文件，不依赖 Dart 运行时。

### 2. 在服务器上放好

```bash
mkdir -p /opt/kelivo-sync && cd /opt/kelivo-sync
# 把 kelivo-sync-server 传上来
chmod +x kelivo-sync-server

cp config.example.json config.json
vim config.json          # 改密码（务必）
```

### 3. 前台试跑一次

```bash
./kelivo-sync-server --config config.json
```

看到这行就成功了：

```
Kelivo sync server listening on http://0.0.0.0:8787
```

用 curl 验一下：

```bash
curl http://127.0.0.1:8787/api/health
# {"ok":true,"rev":0,"connections":0}
```

### 4. 让它常驻

用 systemd：

```ini
# /etc/systemd/system/kelivo-sync.service
[Unit]
Description=Kelivo sync server
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/kelivo-sync
ExecStart=/opt/kelivo-sync/kelivo-sync-server --config /opt/kelivo-sync/config.json
Restart=always
RestartSec=3
User=kelivo

[Install]
WantedBy=multi-user.target
```

```bash
sudo useradd -r -s /usr/sbin/nologin kelivo
sudo chown -R kelivo:kelivo /opt/kelivo-sync
sudo systemctl enable --now kelivo-sync
sudo systemctl status kelivo-sync
```

## 配置项

| 字段 | 说明 |
|---|---|
| `password` | **必填**。客户端登录密码。没填服务端会拒绝启动，不会退化成无密码 |
| `dataDir` | **必填**。数据目录，存放 `sync.sqlite` 和 `blobs/` |
| `host` | 监听地址，默认 `0.0.0.0`。只想本机访问就填 `127.0.0.1` |
| `port` | 端口，默认 `8787` |
| `tokenTtlDays` | 登录令牌有效期，默认 90 天 |
| `maxBlobBytes` | 单个文件上传上限，默认 512 MB |
| `tls` | 可选，直接由本进程提供 HTTPS：`{"cert": "…", "key": "…"}` |

也可以用环境变量覆盖：`KELIVO_SYNC_PASSWORD`、`KELIVO_SYNC_PORT`、`KELIVO_SYNC_CONFIG`。

## 上 HTTPS（强烈建议）

密码是明文 POST 的，**不加 TLS 就等于在网络上广播密码**。最省事的做法是让 nginx 终止 TLS，服务端只监听本机：

```nginx
server {
    listen 443 ssl http2;
    server_name sync.example.com;

    ssl_certificate     /etc/letsencrypt/live/sync.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/sync.example.com/privkey.pem;

    # 文件上传可能很大
    client_max_body_size 512m;

    location / {
        proxy_pass http://127.0.0.1:8787;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;

        # WebSocket —— 实时推送靠它，漏了这三行就退化成轮询
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
    }
}
```

证书用 Let's Encrypt：`sudo certbot --nginx -d sync.example.com`。

配好之后把 config.json 里的 `host` 改成 `127.0.0.1`，只让 nginx 能访问。

## 客户端怎么连

在 App 的同步设置里填两样：

- **服务器地址**：`https://sync.example.com`（或 `http://你的IP:8787`）
- **密码**：config.json 里那个

不需要填端口、不需要填用户名、不需要配密钥。登录一次后拿到令牌，之后自动续用。

## 数据与备份

所有状态都在 `dataDir` 下：

```
kelivo-sync-data/
├── sync.sqlite          # 全部记录和版本号
├── sync.sqlite-wal
├── blobs/               # 文件，按 sha256 分两层存放
└── token_secret         # 令牌签名密钥（自动生成，权限 600）
```

备份很简单——**停掉服务再打包整个目录**：

```bash
sudo systemctl stop kelivo-sync
sudo tar czf kelivo-sync-$(date +%F).tar.gz -C /opt kelivo-sync/kelivo-sync-data
sudo systemctl start kelivo-sync
```

`token_secret` 也要一起备份：丢了它，所有客户端都要重新登录（数据不受影响）。

## 注意

- 需要系统有 `libsqlite3`（Debian/Ubuntu：`apt install libsqlite3-0`）。**不需要装 `-dev` 包**——服务端会自己找运行时库名 `libsqlite3.so.0`，再回退到 `libsqlite3.so`。找不到时会打印出该装什么，而不是抛一段 Dart 堆栈。
- 服务端挂了不影响客户端使用，本地数据照常读写；恢复后自动追上。
- **一台服务器只服务一个人**。密码是单密码、没有多用户隔离，不要把它共享给别人的设备。
