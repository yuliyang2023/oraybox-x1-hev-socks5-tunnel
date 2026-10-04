# Leaf 与 HEV 统一管理

设备入口：`/root/hev-manager-with-leaf.sh`。

```sh
/root/hev-manager-with-leaf.sh start
/root/hev-manager-with-leaf.sh stop
/root/hev-manager-with-leaf.sh restart
/root/hev-manager-with-leaf.sh status
/root/hev-manager-with-leaf.sh check
/root/hev-manager-with-leaf.sh logs
```

`start` 后两个进程均在后台运行，关闭 SSH 不会停止。`start` 在已运行且配置未变时不会重复创建进程。修改正式配置后用 `restart`；每次重新启动可能短暂恢复直连。

## 配置与域名解析

继续编辑 `/root/leaf.json` 中的真实 VMess 服务器、UUID、WS path 和 Host。必须保留一个 `127.0.0.1:1080` SOCKS5 入站。Leaf 自带 SOCKS5，不需要 SSH 转发才能使用；SSH 转发只是远程测试方法。

启动时先停止 HEV，恢复设备正常 DNS，再解析所有 VMess 上游域名的真实 IPv4。脚本用 OpenWrt jshn 生成 `/tmp/hev-leaf-manager/leaf.json`，在 `dns.hosts` 中加入解析结果，原 VMess `address` 域名保持不变。Leaf 重启后使用该临时配置，不会通过 HEV 的合成 DNS 再解析上游域名。

运行中上游解析结果固定在此次取得的地址。服务商变更 IP 时，执行 `restart` 刷新；脚本不提供定时刷新。IPv6 上游地址不在当前支持范围。

HEV 临时配置为 `/tmp/hev-leaf-manager/hev.yml`：SOCKS5 指向 `127.0.0.1:1080`，去掉原账号密码，保留其余选项。正式 `/root/hev.yml` 保留原 SOCKS5 后端，因此原有独立 HEV 管理方式仍可使用。

配置及运行状态仅写入 `/tmp`，目录权限为 700，文件权限为 600。停止后清理临时凭据文件。启动失败时清理临时状态，并尝试恢复启动前正在运行的独立 Leaf/HEV 服务。

## 流量路径与停止行为

```text
Wi-Fi / 将此设备设为网关的 WAN 客户端
    → HEV 路由与 tun0
    → 127.0.0.1:1080 Leaf SOCKS5
    → WebSocket + VMess 上游服务器
    → 互联网
```

HEV 的映射 DNS 将目标网站域名转换为合成 IP，建立连接时恢复网站域名交给 Leaf/VMess。VMess 服务器自身的域名由启动前得到的 `dns.hosts` 解析结果处理，避免代理循环。

`stop` 顺序为先停止 HEV、恢复原路由/DNS/防火墙，再停止 Leaf，两个服务均停止。若从原有独立 HEV 模式切换到统一模式，统一 `stop` 不会自动重新启动原 HEV；它恢复的是正常 WAN 直连。

统一模式运行期间，请使用统一脚本操作。单独运行 `leaf-manager.sh restart` 会恢复 `/root/leaf.json`，丢失临时上游解析结果；单独停止 Leaf 会使 HEV 失去 SOCKS5 后端。

Leaf 由 procd 管理，异常退出时有限次重启；HEV 保留原脚本的后台运行和断流保护。没有新增远端代理健康检测。UDP 要求服务端支持，实际可用性需单独测试。

当前不配置开机启动。设备重启后 `/tmp` 状态消失，需要再次运行统一 `start`。

## 在另一台设备部署

从 [Leaf GitHub Actions](https://github.com/yuliyang2023/leaf/actions/workflows/oray-x1-vmess-ws.yml) 下载 `leaf-oray-x1-vmess-ws` 产物，取 `leaf-oray-vmess-ws-upx` 与配置示例。私有节点配置另行填写，不提交到本仓库。CPU 架构必须适配 MIPS 小端软浮点。

在本机仓库目录上传脚本：

```sh
scp -O hev-manager.sh hev-manager-with-leaf.sh leaf-manager.sh HEV-WITH-LEAF.md oray:/root/
scp -O leaf-with-runtime.init oray:/etc/init.d/leaf
```

另行上传 HEV 与 Leaf 二进制、`hev.yml` 和填写后的 `leaf.json` 到 `/root/`。设备需安装主 README 列出的依赖，并提供 `/usr/share/libubox/jshn.sh`、jsonfilter 和 procd。

在设备上设置权限并启动：

```sh
chmod 700 /root/hev-manager.sh /root/hev-manager-with-leaf.sh /root/leaf-manager.sh
chmod 700 /root/hev-socks5-tunnel /root/leaf-oray-vmess-ws-upx
chmod 600 /root/hev.yml /root/leaf.json
chmod 755 /etc/init.d/leaf
/root/hev-manager-with-leaf.sh check
/root/hev-manager-with-leaf.sh start
```

## 对现有脚本的修改

`hev-manager.sh` 支持 `HEV_CONFIG` 覆盖配置路径，默认仍为 `/root/hev.yml`；`/etc/init.d/leaf` 支持 `LEAF_CONFIG`，默认仍为 `/root/leaf.json`。统一脚本用这两个变量传递临时配置。安装前原脚本备份在 `/root/hev-leaf-script-backup-20261004-224009/`。

本机脚本与文档保存在 `~/Desktop/oray-hev/`。Leaf WS UPX 二进制和构建信息保存在 `~/Desktop/leaf-oray-x1-vmess-ws/`。
