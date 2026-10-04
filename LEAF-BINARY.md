# Leaf 二进制与配置样例

`leaf-oray-vmess-ws-upx` 为 OrayBox X1 / MT7628 的可执行文件，版本 0.14.2，支持 SOCKS5 入站、VMess TCP 和 VMess over WebSocket。此精简版本不支持 WSS/TLS。

- 架构：MIPS 小端、MIPS32r2、O32、软浮点。
- musl/OpenSSL 静态链接，不需要在设备安装对应共享库。
- 文件大小：1,470,644 字节（1.403 MiB）。
- SHA-256：`25d0d95eb5377e21cad7bf0082ddf3d6bdc6708d1d4496fd00d42fca36ccac2f`。
- 构建来源：[GitHub Actions run 37207953673](https://github.com/yuliyang2023/leaf/actions/runs/37207953673)。
- 源码提交：[82ce6cf9b6b70a33a669c7697c95ec7c9969e631](https://github.com/yuliyang2023/leaf/commit/82ce6cf9b6b70a33a669c7697c95ec7c9969e631)。
- UPX 5.2.1；Rust nightly-2026-10-04。
- Leaf 许可证保存在 `LEAF-LICENSE`；修改及编译脚本见上述源码仓库。

原始版与 UPX 版均通过 QEMU 24KEc 的版本、配置、SOCKS5 握手、WebSocket 路径/Host 升级和二进制帧测试。UPX 版已在 OrayBox X1 实机验证；真实节点的 Leaf SOCKS5 和 HEV → Leaf → VMess HTTP/HTTPS 链路测试通过。UDP 应用尚未完成实际测试。

校验：

```sh
sha256sum -c leaf-oray-vmess-ws-upx.sha256
```

`leaf.example.json` 使用保留示例域名与占位 UUID，不含真实节点信息。复制成 `leaf.json` 并填写真实配置。默认监听 `127.0.0.1:1080`，DNS 指向本地 `127.0.0.1`；联合模式由统一管理脚本生成临时上游 DNS hosts，解决 HEV 映射 DNS 循环。
