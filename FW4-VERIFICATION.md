# fw4 适配验证

2026-10-04，OrayBox X1，OpenWrt 25.12.2 / Linux 6.12.74 / nftables 1.1.6。

- 已安装 kmod-tun、ip-full、coreutils-nohup；flock 与 fw4/nftables 由官方镜像提供。
- 上游 SOCKS5 协商和实际 HTTP 请求通过；未修改代理凭据。
- HEV 映射 DNS 返回 198.19.0.0/16；映射地址经 TUN 的 HTTP 请求通过。
- 手机连接 Wi-Fi 后，用户确认可以正常上网。
- 连续两次 fw4 reload 后规则不重复、代理仍可用。
- LAN 客户端与 WAN 同网段客户端的策略路由均选择 tun0；WAN 客户端尚未独立完成实际客户端上网测试。
- 终止 HEV 后，TUN 消失，两类客户端外网路由均返回不可达，nftables guard 保留。
- 执行 stop 后，规则被清理、保存的 sysctl 全部还原、DNS 返回真实地址、普通直连 HTTP 请求通过。
- 持久 firewall、dhcp、network 文件 SHA-256 与适配前备份完全一致。
- 已重新 start，映射 HTTP 再次通过；最终保留代理运行。

原 iptables 版保留在设备 /root/hev-manager-iptables.sh 和本目录同名文件中。现在使用 /root/hev-manager.sh，未配置开机自启或定时健康检测。UDP 中继仍取决于 SOCKS5 服务端能力，未完成全部 UDP 应用测试。
