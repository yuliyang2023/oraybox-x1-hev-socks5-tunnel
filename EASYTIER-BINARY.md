# EasyTier Mini WS/WSS 二进制

`easytier-mini-oray-wss-upx` 面向 OrayBox X1 / MT7628AN，版本 2.7.0。
支持 TCP/UDP、WS/WSS、TUN、AES-GCM、UDP 打洞，以及原 Mini 的 Web 管理功能。
保留 Mini 的裁剪策略，不包含完整核心的全部功能。

- 架构：32 位小端 MIPS、MIPS32r2、软浮点，静态链接。
- 普通版：6,172,124 字节（5.886 MiB），未加入本仓库。
- 本仓库的 UPX 版：1,760,432 字节（1.679 MiB）。
- SHA-256：`8d39807ab0d10a4dc53ffa1523bfc50ab9cab05fcd9e5a6052abfd5c5b9598ac`。
- Rust 1.95、musl-cross 20250520、UPX 4.2.2，`mini` profile 体积优化。
- [构建结果与完整产物](https://github.com/yuliyang2023/EasyTier/actions/runs/37260606214)。
- [对应源码提交 8bdf682](https://github.com/yuliyang2023/EasyTier/tree/8bdf682b65b2fe758721f5ba5fc5fba912b95d89)。
- [编译工作流](https://github.com/yuliyang2023/EasyTier/blob/8bdf682b65b2fe758721f5ba5fc5fba912b95d89/.github/workflows/oray-mini-wss.yml)。
- 上游 LGPL-3.0 许可证保存在 `EASYTIER-LICENSE`；构建源码及修改见上述提交。

编译开关为 Mini 的 `websocket`，并修改 compact runtime，使 WS/WSS 节点及监听地址
不会被静默过滤。默认未开启该功能的 Mini 仍只支持 TCP/UDP。
WSS 沿用上游的 TLS 实现及证书验证策略。

默认 Mini、WebSocket Mini、节点/监听配置过滤及 WS/WSS 握手测试均通过。
普通版与 UPX 版通过 QEMU 的执行检查，UPX 自检通过。
本 UPX 版已在 X1-3111 实机运行：经 Leaf + HEV 成功连接 WSS 中继，
发现其他节点，并通过局域网 TCP 直连完成虚拟 IP 的 3 次 ping，0% 丢包。
这不代表公网中继数据吞吐或 UDP 打洞已完成测试。

二进制部署为 `/root/easytier-mini`，配置为 `/root/easytier.conf`。
程序放在持久 Flash 中，日志和 PID 文件放在 `/tmp`。
校验方法：

```sh
shasum -a 256 -c easytier-mini-oray-wss-upx.sha256
```

Mini 不支持本样例以外的全部上游功能；例如 WireGuard、QUIC、KCP、TCP 打洞，
以及 TXT DNS 查询均未启用。不支持的配置字段可能被保留但不执行，
因此本仓库样例不包含原配置中的 WireGuard 监听项或自定义 RPC 地址。
Mini 管理 RPC 固定监听 `127.0.0.1:15888`。
