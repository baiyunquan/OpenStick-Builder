# FOUND.md — 跨分支审计发现

> 时间：2026-07-26
> 起因：修完 pmOS CI（见 [SOLUTION.md](SOLUTION.md)）后，切到 UZ801 分支继续排查既有问题。
> 本文只记录**发现**（含已修和未修），修复过程见 SOLUTION.md，方法论见 [SKILLS.md](SKILLS.md)。

---

## F-1 ✅ UZ801 Debian 链路**没有**被上游漂移打断 —— 我的初始假设是错的

进这个分支之前，我的假设是："pmaports 把 `master` 改名 `main`，
所以 `debootstrap.sh` 里下载 pmOS 内核 apk 的 URL 也该坏了。"

**探测结果：全部存活，假设不成立。**

| URL | 状态 |
|---|---|
| `mirrors.aliyun.com/postmarketOS/v25.12/aarch64/linux-postmarketos-qcom-msm8916-6.12.1-r2.apk` | 200，28 912 813 B |
| `builds.96boards.org/.../rescue/20.07/dragonboard-410c-bootloader-emmc-linux-145.zip` | 200，8 290 887 B |
| `builds.96boards.org/.../rescue/17.09/dragonboard410c_bootloader_emmc_android-88.zip` | 200，12 774 138 B |
| `deb.debian.org/debian/dists/trixie/Release` | 200 |

**为什么没坏**：这条链路把内核**钉死在 v25.12 稳定版的具体版本号** `6.12.1-r2`，
而不是跟 edge 滚动。pmOS CI 之所以被打断，恰恰是因为它跟着 edge 走。

> 这条印证了 SKILLS.md §3 的纪律：**先探测，再下结论。**
> 我如果按假设直接去改 URL，会改坏一条本来好好的链路。

## F-2 ⚠️→✅ 同一个根因 bug 同时存在于 3 个分支

`device-zhihe-generic-nonfree-firmware` 这个已被上游删除的包，在**每一个**
带 pmOS workflow 的分支里都硬写在 `extra_packages` 中：

| 分支 | 修复前状态 | 现在 |
|---|---|---|
| `pmos-zhihe-ufi103s-v05` | ❌ | ✅ `632e99f` |
| `main` | ❌ | 🔄 PR [#4](https://github.com/baiyunquan/OpenStick-Builder/pull/4) 待合并 |
| `uz801-v21-trixie-fullimg-gpt-fix` | ❌ | ✅ `9562da0`（cherry-pick） |
| `uz801-v21-trixie-fullimg` | ❌ | **未修** |

**根本原因不是那个包，是 workflow 文件被复制而不是共享。**
四份 `build-pmos-zhihe*.yml` 各自独立演化，一处上游改动就要修四遍，
而且每个分支的副本还停在不同的历史版本上。

> 这也是为什么 `uz801-*-gpt-fix` 上的 pmOS workflow 比 `pmos-*` 分支的更旧
> —— 它是更早期的拷贝，连后来加的 sha256 校验、SIM DTB 变体步骤都没有。

## F-3 🔴 PR #4 合并后会埋一个定时炸弹（**未修**）

`pmos-zhihe-ufi103s-v05` 分支的 tz 固件下载指向**分支名固定**的 raw URL：

```yaml
wget -q -O /tmp/db410c_fw.zip \
  'https://raw.githubusercontent.com/baiyunquan/OpenStick-Builder/refs/heads/pmos-zhihe-ufi103s-v05/firmware/dragonboard410c/dragonboard410c_bootloader_emmc_android-88.zip'
```

**PR #4 合并进 `main` 之后，`main` 上的 workflow 仍然会去拉那个特性分支。**
一旦该分支被删除（合并后删分支是常规操作），`main` 的构建立刻挂掉。

已核实**这个依赖是多余的**——`origin/main` 自己就跟踪着同一个文件，且字节相同：

```
origin/main:firmware/dragonboard410c/dragonboard410c_bootloader_emmc_android-88.zip
  → 72494b6882f60cc1704f2970543adb91370d1ec75497c4f6510fc13a4e1378ee
96boards 17.09 下载的同名文件
  → 72494b6882f60cc1704f2970543adb91370d1ec75497c4f6510fc13a4e1378ee   ← 完全一致
workflow 里写死的期望值
  → 72494b6882f60cc1704f2970543adb91370d1ec75497c4f6510fc13a4e1378ee   ← 一致
```

**建议修复（一行）**：把 URL 里的 `refs/heads/pmos-zhihe-ufi103s-v05`
换成 `refs/heads/main`，或者更稳妥地钉到 commit SHA。
sha256 校验行不用动。

> 我没有直接改，因为它会动到已经开着的 PR #4 的内容，属于你的决策范围。

## F-4 ⚠️ 两个 UZ801 分支各有一半工作，谁也没合并（**未修**）

两个分支在 `ab6e722` 之后分叉，**各自往前走了不同的一步**：

```
                        ┌── ae117bd  Split UZ801 image assembly into merge script
ab6e722 (共同祖先) ─────┤            → uz801-v21-trixie-fullimg          (07-11 绿)
                        └── 330b2a8  Fix GPT backup area bounds
                                     → uz801-v21-trixie-fullimg-gpt-fix (07-11 绿)
```

差异：`merge_uz801_v21_fullimg.sh`（161 行，只在前者）
vs `build_fullimg_uz801_v21.sh` 里的 GPT 边界修复（只在后者）。

**两边都绿过，但没有任何一个分支同时包含两项工作**，也没有合并到 `main`。
需要你决定哪条是主线；我选了 `gpt-fix` 作为修复基线，因为它是最后一次成功构建的 SHA。

## F-5 ⚠️ main 的 Debian 链路落后 8 个文件 / 312 行（**未修**）

`main` 上的 `build.yml` 最后一次运行是 2026-07-07，**失败**。
修好它的工作全在 `uz801-*-gpt-fix` 上，从未合并：

```
 .github/workflows/build-uz801-v21-trixie-fullimg.yml |  11 +-
 scripts/build_fullimg_uz801_v21.sh                   |  21 +-
 scripts/build_kernel_mainline.sh                     | 129 +++++++ (新增)
 scripts/debootstrap.sh                               |  66 +-
 scripts/extract_fw.sh                                |  18 +-
 scripts/install_deps.sh                              |  12 +-
 scripts/install_kernel_artifact.sh                   |  91 ++++ (新增)
 scripts/setup.sh                                     |   2 +
```

这是一次**功能性合并**，不是 bug 修复。我没有把它塞进 PR #4——
那会让一个已验证为绿的 CI 修复变得无法评审。**建议单独开 PR。**

## F-6 ℹ️ 三个分支的 `.gitignore` 三个样

| 分支 | 差异内容 |
|---|---|
| `pmos-zhihe-ufi103s-v05` | 有 `!firmware/dragonboard410c/*.zip`（为了能提交 tz 固件 zip） |
| `main` | 既无 `!firmware/...` 例外，却**跟踪着** 4 个 zip（历史遗留，靠已入库生效） |
| `uz801-*-gpt-fix` | 有 `artifacts`，无 `!firmware/...`，也**不跟踪**任何 zip |

不影响构建，但 `main` 属于"规则说忽略、实际却在跟踪"的状态——
将来谁更新那几个 zip 会踩坑。

## F-7 ℹ️ tz 固件有两个来源，只有一个做校验

| 分支 | 来源 | 校验 |
|---|---|---|
| `pmos-*` | 自己仓库的 raw URL（见 F-3） | ✅ sha256 |
| `uz801-*`、`main` 的旧 workflow | `builds.96boards.org` 第三方 | ❌ 无 |

三处内容字节相同（F-3 已验证）。96boards 目前存活，但它是外部主机，
且下载后不校验——建议统一到自托管 + sha256。

## F-8 ✅ 已修：四个 workflow 的 `checkout@v4`

`build.yml`、`build-uz801-v21-trixie-fullimg.yml`、两个 pmOS workflow
全部升到 `@v5`（`e18a88d` / `9562da0`）。

**遗留**：`actions/upload-artifact@v4` 仍在报 Node 20 弃用告警，四个 workflow 都有。
只是告警，不影响构建。

## F-9 ✅ 已修：lk2nd 子模块工作区误删

`src/lk2nd/lib/openssl/crypto/bn/asm/armv4-mont.S` 被删（仅工作区，从未提交）。
CI 每次全新 `submodule update --init` 所以不受影响，但本地编译 lk2nd 会失败。
已 `git -C src/lk2nd checkout -- .` 还原。

---

## 验证状态

| 项目 | 结果 |
|---|---|
| pmOS modem @ `pmos-*` | ✅ [30208799701](https://github.com/baiyunquan/OpenStick-Builder/actions/runs/30208799701) 4m47s |
| pmOS plain @ `pmos-*` | ✅ [30208804625](https://github.com/baiyunquan/OpenStick-Builder/actions/runs/30208804625) 2m21s |
| pmOS modem @ `uz801-*-gpt-fix` | ✅ [30209901918](https://github.com/baiyunquan/OpenStick-Builder/actions/runs/30209901918) 4m49s |
| 依赖闭包离线解析（两条包列表） | ✅ `MISSING=none`（332 / 172 个包） |
| 四个 workflow YAML 语法 | ✅ |
| UZ801 Debian 全镜像 @ `gpt-fix` | ⏳ [30209906401](https://github.com/baiyunquan/OpenStick-Builder/actions/runs/30209906401) —— 按要求停止监控，**结果未确认** |

> UZ801 全镜像构建约需 70 分钟。停止监控时它已通过
> checkout / 依赖安装 / bootloader 构建 / 固件提取，正处于 `Create trixie rootfs`。
> **最终结论请自行查看上面那个 run。**

---

## 待办清单

| 编号 | 事项 | 归属 |
|---|---|---|
| F-3 | tz raw URL 从特性分支改指 `main` 或 commit SHA | 合并 PR #4 前 |
| F-4 | 决定 UZ801 主线分支，合并两边各自的工作 | 需你决策 |
| F-5 | Debian 链路 8 文件单独开 PR 合入 main | 需你决策 |
| F-2 | `uz801-v21-trixie-fullimg` 分支的同款 bug 仍未修 | 若该分支还要用 |
| F-6 | 统一三个分支的 `.gitignore` | 低优先级 |
| F-7 | tz 固件来源统一 + 加校验 | 低优先级 |
| F-8 | `upload-artifact@v4` → `@v5` | 低优先级 |
| — | 刷机后实测 wifi/modem（上游网络栈换成 NetworkManager） | 需硬件 |
