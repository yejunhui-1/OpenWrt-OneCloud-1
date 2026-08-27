#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-op2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#

# =============================================================================
# 加速优化：浅克隆 + GitHub 镜像回退
# 用法：clone_once <dest> <url> [branch]
# =============================================================================
clone_once() {
    local dest="$1" url="$2" branch="${3:-}"
    local -a args=(--depth 1 --single-branch --filter=blob:none --progress)
    [ -n "$branch" ] && args+=(-b "$branch")
    local mirrored rc
    # 按顺序尝试：GitHub 直连 → ghproxy 镜像 → gitclone 镜像（每步 5 分钟超时兜底）
    for prefix in "" "https://ghproxy.com/" "https://gitclone.com/"; do
        mirrored="${prefix}${url}"
        echo "[clone] ${mirrored}  →  ${dest}${branch:+ (branch=$branch)}"
        rm -rf "$dest"
        if timeout 300 git clone "${args[@]}" "$mirrored" "$dest"; then
            return 0
        fi
        rc=$?
        echo "[clone] 失败 rc=$rc，回退下一镜像: $mirrored"
    done
    echo "[clone] 所有镜像均失败: $url -> $dest" >&2
    return 1
}
# 并行 clone：子 shell 调用 clone_once，失败写入 .clone_fails
clone_async() {
    local dest="$1" url="$2" branch="${3:-}"
    {
        if ! clone_once "$dest" "$url" "$branch"; then
            echo "${dest}|${url}|${branch}" >>"$CLONE_FAIL_LOG"
        fi
    } &
}
export -f clone_once
export CLONE_FAIL_LOG="$(mktemp)"
: >"$CLONE_FAIL_LOG"

# =============================================================================
# 分组 1：仅依赖 feeds 目录（不依赖其他克隆产物）—— 并行
# =============================================================================
echo "=== [并行组 1/2] 克隆独立仓库（13 个并发）==="
# 删除自带的 golang
rm -rf feeds/packages/lang/golang
clone_async feeds/packages/lang/golang                       https://github.com/sbwml/packages_lang_golang.git                        26.x
# 删除 passwall 自带的核心库
rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,xray-plugin,geoview,shadow-tls}
rm -rf package/feeds/packages/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,xray-plugin,geoview,shadow-tls}
clone_async package/chajian/passwall-packages                https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git
# 删除 passwall 过时的 luci
rm -rf feeds/luci/applications/luci-app-passwall
rm -rf package/feeds/luci/luci-app-passwall
clone_async package/chajian/passwall-luci                    https://github.com/Openwrt-Passwall/openwrt-passwall.git
clone_async package/chajian/easytier                         https://github.com/EasyTier/luci-app-easytier.git
clone_async package/chajian/mentohust                        https://github.com/sbwml/luci-app-mentohust.git
clone_async package/chajian/msd_lite                          https://github.com/gtolog/openwrt-msd_lite.git
clone_async package/chajian/OpenAppFilter                     https://github.com/destan19/OpenAppFilter.git
## 删除自带的 luci-app-socat
rm -rf feeds/lienol/luci-app-socat
rm -rf package/feeds/lienol/luci-app-socat
clone_async package/chajian/socat                             https://github.com/chenmozhijin/luci-app-socat.git
# 替换 tailscale 的默认启动脚本和配置
sed -i '/\/etc\/init\.d\/tailscale/d;/\/etc\/config\/tailscale/d;' feeds/packages/net/tailscale/Makefile
clone_async package/chajian/tailscale/luci-app-tailscale      https://github.com/asvow/luci-app-tailscale.git
clone_async package/chajian/argon                             https://github.com/sbwml/luci-theme-argon.git                         openwrt-24.10
clone_async package/chajian/dockerman                         https://github.com/lisaac/luci-app-dockerman.git
clone_async package/chajian/openclash                         https://github.com/vernesong/OpenClash.git
clone_async package/chajian/homeproxy                         https://github.com/immortalwrt/homeproxy.git
clone_async package/chajian/istore                            https://github.com/linkease/istore.git
# 等待组 1 完成
wait
echo "=== [并行组 1/2] 完成，失败数：$(wc -l <"$CLONE_FAIL_LOG") ==="
if [ -s "$CLONE_FAIL_LOG" ]; then
    echo "以下仓库需重试（串行逐个回退三源）："
    cat "$CLONE_FAIL_LOG"
    while IFS='|' read -r dest url branch; do
        clone_once "$dest" "$url" "$branch"
    done <"$CLONE_FAIL_LOG"
fi
: >"$CLONE_FAIL_LOG"

# =============================================================================
# 特殊的替换配置（按仓库稀疏检出，保留原 merge_package 逻辑，并同样加镜像回退）
# =============================================================================
echo "=== [串行组] 稀疏检出 merge_package（5 个）==="
## 删除自带的 ddns-scripts
rm -rf feeds/packages/net/ddns-scripts
## 删除自带的 luci-base
rm -rf feeds/luci/modules/luci-base
## 删除自带的 luci-app-firewall
rm -rf feeds/luci/applications/luci-app-firewall
## 筛选程序
function merge_package(){
    # 参数1是分支名,参数2是库地址。所有文件下载到指定路径。
    # 同一个仓库下载多个文件夹直接在后面跟文件名或路径，空格分开。
    trap 'rm -rf "$tmpdir"' EXIT
    branch="$1" curl="$2" target_dir="$3" && shift 3
    rootdir="$PWD"
    localdir="$target_dir"
    [ -d "$localdir" ] || mkdir -p "$localdir"
    tmpdir="$(mktemp -d)" || exit 1
    # 浅克隆+三源镜像回退
    local mirrored rc
    for prefix in "" "https://ghproxy.com/" "https://gitclone.com/"; do
        mirrored="${prefix}${curl}"
        echo "[merge] clone ${mirrored} (branch=$branch) → $tmpdir"
        if timeout 300 git clone -b "$branch" --depth 1 --filter=blob:none --sparse "$mirrored" "$tmpdir"; then
            break
        fi
        rc=$?
        echo "[merge] clone 失败 rc=$rc，回退下一镜像"
        rm -rf "$tmpdir"
        tmpdir="$(mktemp -d)" || exit 1
    done
    if [ ! -d "$tmpdir/.git" ]; then
        echo "[merge] 所有镜像失败：$curl" >&2
        return 1
    fi
    cd "$tmpdir"
    git sparse-checkout init --cone
    git sparse-checkout set "$@"
    for folder in "$@"; do
        mv -f "$folder" "$rootdir/$localdir"
    done
    cd "$rootdir"
}
## 提取 ddns-scripts
merge_package openwrt-24.10 https://github.com/immortalwrt/packages.git feeds/packages/net net/ddns-scripts
## 提取 fullconenat-nft
merge_package openwrt-24.10 https://github.com/immortalwrt/immortalwrt.git package/network/utils package/network/utils/fullconenat-nft
## 提取 pdnsd-alt、upx
merge_package main https://github.com/kenzok8/jell.git package/chajian/kenzok8-package pdnsd-alt upx
## 提取 luci-base（如上 fullconenat-nft 需要）
merge_package openwrt-24.10 https://github.com/immortalwrt/luci.git feeds/luci/modules modules/luci-base
## 提取 luci-app-firewall（如上 fullconenat-nft 需要）
merge_package openwrt-24.10 https://github.com/immortalwrt/luci.git feeds/luci/applications applications/luci-app-firewall

# 删除 feeds.conf.default 中添加的第三方源
sed -i '/lienol/d' feeds.conf.default

# 修改默认 IP
sed -i 's/192.168.1.1/192.168.101.10/g' package/base-files/files/bin/config_generate
#sed -i 's/192.168.1.1/192.168.8.1/g' package/base-files/files/bin/config_generate

# 修改默认主题
sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci-light/Makefile

# 修改主机名
sed -i "s/hostname='.*'/hostname='OneCloud'/g" package/base-files/files/bin/config_generate

# 修改默认时区
## 创建 uci-defaults 脚本
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-timezone << 'EOF'
#!/bin/sh
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci commit system
EOF
chmod +x files/etc/uci-defaults/99-timezone

# 旁路由模式配置：网关 192.168.101.1，关闭 DHCP（主路由负责分配）
## 在 config_generate 之后运行，此时 /etc/config/network 已生成
cat > files/etc/uci-defaults/98-bypass-router << 'EOF'
#!/bin/sh
uci set network.lan.ipaddr='192.168.101.10'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='192.168.101.1'
uci set network.lan.dns='192.168.101.1'
uci set network.lan.broadcast='192.168.101.255'
uci set dhcp.lan.ignore='1'
uci commit network
uci commit dhcp
exit 0
EOF
chmod +x files/etc/uci-defaults/98-bypass-router

# 修复软件源
## /etc/opkg/opkg.conf
mkdir -p files/etc/opkg
cat > files/etc/opkg/opkg.conf << 'EOF'
dest root /
dest ram /tmp
lists_dir ext /var/opkg-lists
option overlay_root /overlay
EOF

## /etc/opkg/customfeeds.conf
cat > files/etc/opkg/customfeeds.conf << 'EOF'
# add your custom package feeds here
#
# src/gz example_feed_name `http://www.example.com/path/to/files`
EOF

## /etc/opkg/distfeeds.conf（使用 dl.openwrt.ai 软件源，24.10 / 6.6.102 内核分支）
# 注：kwrt_core（内核模块源）对应 6.6.102，随 OpenWrt 24.10 主线编译内核一致，
#     本构建现已切换到 REPO_BRANCH=openwrt-24.10，vermagic 匹配，kmod-* 可正常安装。
cat > files/etc/opkg/distfeeds.conf << 'EOF'
src/gz kwrt_core `https://dl.openwrt.ai/releases/24.10/targets/amlogic/meson8b/6.6.102`
src/gz kwrt_base `https://dl.openwrt.ai/releases/24.10/packages/arm_cortex-a5_vfpv4/base`
src/gz kwrt_packages `https://dl.openwrt.ai/releases/24.10/packages/arm_cortex-a5_vfpv4/packages`
src/gz kwrt_luci `https://dl.openwrt.ai/releases/24.10/packages/arm_cortex-a5_vfpv4/luci`
src/gz kwrt_routing `https://dl.openwrt.ai/releases/24.10/packages/arm_cortex-a5_vfpv4/routing`
src/gz kwrt_kiddin9 `https://dl.openwrt.ai/releases/24.10/packages/arm_cortex-a5_vfpv4/kiddin9`
EOF

# iStoreOS / 首页向导：兜底软链（防止 feeds install -a 漏装 nas/nas_luci 中的包，
# 因为它们的包名依赖 luci-lib-ipkg 等可能被自动跳过）。若已在 package/feeds/ 下则不会重复。
[ -d package/chajian/istore/luci-app-store       ] && ln -sfn ../../chajian/istore/luci-app-store       package/luci-app-store
[ -d package/chajian/istore/luci-lib-ipkg        ] && ln -sfn ../../chajian/istore/luci-lib-ipkg        package/luci-lib-ipkg
[ -d feeds/nas_luci/luci/applications/luci-app-quickstart ] && {
    [ -d package/feeds/nas_luci ] || mkdir -p package/feeds/nas_luci
    ln -sfn ../../../feeds/nas_luci/luci/applications/luci-app-quickstart package/feeds/nas_luci/luci-app-quickstart 2>/dev/null || true
}
[ -d feeds/nas/packages/quickstart               ] && {
    [ -d package/feeds/nas ] || mkdir -p package/feeds/nas
    ln -sfn ../../../feeds/nas/packages/quickstart package/feeds/nas/quickstart 2>/dev/null || true
}
# argon-config 同样兜底（sbwml 仓库是顶层+子目录结构，防止仅主题被 install 时漏掉）
[ -d package/chajian/argon/luci-app-argon-config ] && ln -sfn ../../chajian/argon/luci-app-argon-config package/luci-app-argon-config 2>/dev/null || true
[ -d package/chajian/argon/luci-theme-argon      ] && ln -sfn ../../chajian/argon/luci-theme-argon      package/luci-theme-argon      2>/dev/null || true

# 清理临时文件
rm -f "$CLONE_FAIL_LOG"
