# SOLUTION.md — postmarketOS CI 构建失败排查记录

> 事故日期：2026-07-20 ～ 2026-07-26
> 影响范围：`build-pmos-zhihe.yml`、`build-pmos-zhihe-modem.yml`（两个 workflow 全部失败）
> 修复提交：`632e99f`
> 验证：run [30208799701](https://github.com/baiyunquan/OpenStick-Builder/actions/runs/30208799701)（modem，4m47s）、
> [30208804625](https://github.com/baiyunquan/OpenStick-Builder/actions/runs/30208804625)（plain，2m21s），均 ✅

---

## 1. 症状

两个 pmOS workflow 每次 `workflow_dispatch` 都在 **Build split postmarketOS image**
这一步失败，耗时只有 1–2 分钟。CI 日志里只有一行：

```
ERROR: Command failed (exit code 1): /home/runner/pmbootstrap-work/apk.static \
  --no-progress --root .../chroot_rootfs_zhihe-generic --arch aarch64 ... \
  add --no-interactive lang font-twemoji ... device-zhihe-generic-nonfree-firmware ...
NOTE: The failed command's output is above the ^^^ line in the log file: .../log.txt
```

**关键问题：真正的错误在 `log.txt` 里，而 `log.txt` 从来没进过 CI 输出。**
所以 CI 只告诉你"某个包装不上"，不告诉你是哪个包。

## 2. 根因

pmaports 提交 [`e5536561`](https://gitlab.postmarketos.org/postmarketOS/pmaports/-/commit/e5536561)
*"treewide: device/testing: remove nonfree-firmware subpackages"*（2026-07-19，MR 8961）
删掉了 `device-zhihe-generic` 的 `-nonfree-firmware` 子包，
把它原来的两个依赖提升成了主包的硬依赖：

```diff
-subpackages="$pkgname-nonfree-firmware:nonfree_firmware ..."
 depends="
+	firmware-qcom-msm8916-venus
 	mkbootimg
+	msm-firmware-loader
 	postmarketos-base
 	soc-qcom-msm8916
 	soc-qcom-msm8916-rproc
 	"
-nonfree_firmware() {
-	depends="msm-firmware-loader firmware-qcom-msm8916-venus"
-}
```

而两个 workflow 都把 `device-zhihe-generic-nonfree-firmware` **硬写在
`extra_packages` 里**，所以 apk 一上来就报 "no such package" 退出。

pmbootstrap 自身的 `get_nonfree_packages()`（`pmb/install/_install.py:61`）
是读 APKBUILD 的 `subpackages` 动态判断的，已经正确地不再自动添加它了——
**问题 100% 出在 workflow 手写死的配置上，不是 pmbootstrap 的 bug。**

时间线完全吻合：

| 日期 | 事件 |
|---|---|
| 2026-07-06 | 最后一次成功（run 28791435678，pmbootstrap 3.10.1） |
| 2026-07-19 | pmaports 合并 e5536561 |
| 2026-07-20 01:23 | 首次失败 |

## 3. 定位方法（可复用）

CI 日志没给出缺失的包名，所以不能靠读日志。用的办法是**离线依赖闭包解析**：
直接把真实的 APKINDEX 拉下来，在本地把整个包集合解一遍，看哪个解不出来。

### 3.1 确定要拉哪几个 APKINDEX

这一步容易踩坑，因为 postmarketOS 的仓库路径不是"channel 名"，而是
**channels.cfg 里的 `branch_pmaports`**（见 `pmb/helpers/repo.py`
`get_repos_from_config()`：`mirrordir_pmos = channel_cfg["branch_pmaports"]`）。

pmaports 默认分支已从 `master` 改名 `main`，所以 edge 的 mirrordir 现在是 **`main` 而不是 `edge`**：

```bash
curl -s https://gitlab.postmarketos.org/postmarketOS/pmaports/-/raw/main/channels.cfg
# [edge]
# branch_pmaports=main       <- mirrordir_pmos
# branch_aports=master
# mirrordir_alpine=edge      <- mirrordir_alpine
```

对应五个索引：

```bash
mkdir -p /tmp/apkidx && cd /tmp/apkidx
curl -sO https://dl-cdn.alpinelinux.org/alpine/edge/main/aarch64/APKINDEX.tar.gz      # -> alpine_main.tar.gz
curl -sO https://dl-cdn.alpinelinux.org/alpine/edge/community/aarch64/APKINDEX.tar.gz # -> alpine_community.tar.gz
curl -sO https://dl-cdn.alpinelinux.org/alpine/edge/testing/aarch64/APKINDEX.tar.gz   # -> alpine_testing.tar.gz
curl -sO https://mirror.postmarketos.org/postmarketos/main/aarch64/APKINDEX.tar.gz    # -> pmos_main.tar.gz
curl -sO https://mirror.postmarketos.org/postmarketos/extra-repos/systemd/main/aarch64/APKINDEX.tar.gz  # -> pmos_systemd.tar.gz
```

> `ui = console` 会启用 systemd（`postmarketos-ui-console defaults to systemd`），
> 此时 channel 显示为 `systemd-edge`，需要额外算上 `extra-repos/systemd`。
> `ui = none` 不启用，只用 `pmos_main`。

### 3.2 解析脚本

```python
import tarfile, re
from collections import defaultdict

providers = defaultdict(list)
for path in ["alpine_main.tar.gz", "alpine_community.tar.gz", "alpine_testing.tar.gz",
             "pmos_main.tar.gz", "pmos_systemd.tar.gz"]:
    data = tarfile.open(path).extractfile("APKINDEX").read().decode("utf-8", "replace")
    for block in data.split("\n\n"):
        f = {}
        for line in block.splitlines():
            if len(line) > 1 and line[1] == ":":
                f.setdefault(line[0], []).append(line[2:])
        name = f.get("P", [None])[0]
        if not name:
            continue
        deps = f.get("D", [""])[0].split()
        providers[name].append(deps)
        for pr in f.get("p", [""])[0].split():      # provides 也要算
            providers[re.split(r"[=<>~]", pr)[0]].append(deps)

def resolve(roots, label):
    seen, missing, q = set(), [], list(roots)
    while q:
        raw = q.pop()
        if raw.startswith("!"):                      # conflict，跳过
            continue
        dep = re.split(r"[=<>~]", raw)[0]            # 剥掉版本约束
        if dep in seen:
            continue
        seen.add(dep)
        if dep not in providers:
            missing.append(dep)
            continue
        q.extend(providers[dep][0])
    print(f"{label}: walked={len(seen)} MISSING={sorted(set(missing)) or 'none'}")
```

**包列表直接从 CI 日志里那行 `apk.static ... add --no-interactive <...>` 抄下来即可。**

### 3.3 结果

| 包集合 | 走过的包数 | 缺失 |
|---|---|---|
| modem workflow 修复前 | 333 | `device-zhihe-generic-nonfree-firmware` |
| modem workflow 修复后 | 332 | **无** |
| plain workflow 修复前 | 173 | `device-zhihe-generic-nonfree-firmware` |
| plain workflow 修复后 | 172 | **无** |

一次就锁定了唯一的元凶，并且证明了**后面不会再撞第二个坑**——这一点很重要，
否则改一次推一次等 5 分钟，来回试错要花几小时。

顺带验证 firmware 没有丢：

```
msm-firmware-loader          in closure: True
firmware-qcom-msm8916-venus  in closure: True
```

它们现在由 `device-zhihe-generic` v8 直接带入，所以**只需删掉那一行，不用补包**。

## 4. 修复内容

### 4.1 根因修复

两个 workflow 的 `extra_packages` 去掉 `device-zhihe-generic-nonfree-firmware,`：

```diff
-extra_packages = device-zhihe-generic-nonfree-firmware,soc-qcom-msm8916-rproc,qmi-utils,qrtr,modemmanager,iw,wpa_supplicant,wireless-regdb
+extra_packages = soc-qcom-msm8916-rproc,qmi-utils,qrtr,modemmanager,iw,wpa_supplicant,wireless-regdb
```

### 4.2 撤销一次误判

之前的提交 `fda1da2` *"Remove locale setting to fix unresolvable lang package"* 是**误判**：

- `lang` 一直存在于 Alpine edge main（APKINDEX 已确认）；
- `lang` 来自 `_pmb_recommends` 链（`get_recommends()`，`pmb/install/_install.py:1206`），
  跟 `locale` 配置项毫无关系——跑在 fda1da2 上的 run 29852350103 包列表里 `lang` 依然在；
- 删掉 `locale` 唯一的效果，是让镜像 locale 从 `C.UTF-8` **静默变成**
  pmbootstrap 的默认值 `en_US.UTF-8`（`pmb/core/config.py:68`）。

所以把 `locale = C.UTF-8` 加了回来。

> 教训：**改配置前先证明因果关系**。"某个包名出现在报错命令里" ≠ "它就是失败原因"，
> 那一行 apk 命令里有十几个包，报错信息压根没说是哪个。

### 4.3 CI 加固

| 改动 | 原因 |
|---|---|
| `printf '8\n' > $PMB_WORK/version` → 从 `pmb.config.work_version` 读 | 硬编码的 work version 一旦被上游 bump，`migrate_work_folder()`（`pmb/helpers/other.py:99`）会走进 `pmb.helpers.cli.confirm()` 交互分支，CI 里直接挂死 |
| pmbootstrap clone 钉到 `--branch 3.11.1` | 原来跟 `main` 浮动，07-06 是 3.10.1、07-21 变 3.11.1，构建不可复现 |
| `build-pmos-zhihe.yml` 补上失败时 `tail -n 300 log.txt` | 这次排查被迫靠反推包列表，就是因为它没有 |
| `actions/checkout@v4` → `@v5` | Node 20 弃用告警 |
| `pmbootstrap status > ... \|\| true` | 别让 status 的非零退出把已经成功的构建判失败 |

## 5. 本地 pmbootstrap 核对结论

- 本地 `pmbootstrap/` 与上游 `main` HEAD **逐字节一致**（`diff -rq` 无输出），版本 `3.11.1`；
- CI 失败那两次用的也是 3.11.1，2026-07-06 成功那次是 3.10.1；
- **pmbootstrap 完全没有问题**，不需要升级或降级。破坏来自 pmaports 数据侧。

核对方法：

```bash
curl -sSL https://gitlab.postmarketos.org/postmarketOS/pmbootstrap/-/archive/main/pmbootstrap-main.tar.gz \
  | tar -xz -C /tmp
diff -rq --exclude=.git --exclude=__pycache__ /tmp/pmbootstrap-main ./pmbootstrap
```

> 注意 pmbootstrap 的默认分支也叫 `main`（不是 `master`），
> 用 `.../archive/master/...` 会拿到一个 HTML 错误页，`tar` 报 "not in gzip format"。

## 6. 需要留意（非阻塞）

上游 `postmarketos-ui-console` 的依赖已改成 `postmarketos-base-ui-networkmanager`。
2026-07-06 那次构建里还是 `postmarketos-base-ui-wifi-wpa_supplicant` +
`postmarketos-base-ui-audio-backend-pulseaudio`，现在都没有了。

对 modem 镜像来说是好事（NetworkManager + ModemManager 是标准组合），
但**刷机后请实测 wifi / modem 行为**——网络栈换过了。

## 7. main 分支

`build-pmos-zhihe.yml` 在 `main` 分支上仍是坏的（run 29693650791 已证实）。
本分支验证通过后需要把 `632e99f` 合并 / cherry-pick 到 `main`。

## 8. 经验提炼

1. **跟 rolling release 上游（pmaports edge）的 CI 必然会被上游改动打断。**
   一旦某天"代码没动但 CI 挂了"，先去查上游最近的提交，别怀疑自己的代码。
   `git log --since` 上游仓库 + 对照最后一次成功的时间点，通常几分钟就能定位。

2. **不要把上游的子包名硬写进配置。** pmbootstrap 已经有
   `get_nonfree_packages()` 动态探测 `subpackages`；手写死等于放弃了这层保护。
   `extra_packages` 里只放**真正额外**的、上游 device 包不会带的东西。

3. **CI 失败时一定要把工具自己的日志 dump 出来。** pmbootstrap 把真实错误写在
   `$PMB_WORK/log.txt`，不打出来就等于盲调。这一个 `tail -n 300` 能省掉几小时。

4. **离线 APKINDEX 解析是验证包集合的最快手段。** 几秒钟出结果，不用等 CI，
   而且能一次性证明"没有第二个坑"。

5. **凡是钉不住的外部依赖都要显式钉。** pmbootstrap 钉 tag；pmaports 因为要跟
   edge 所以不钉，但正因如此更需要 3 和 4 这两条来快速定位。
