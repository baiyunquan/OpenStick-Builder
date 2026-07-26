# SKILLS.md — "代码没动，CI 却挂了" 的排查流程

> 这是 [SOLUTION.md](SOLUTION.md) 的方法论版本。
> SOLUTION.md 记录**这一次**发生了什么，本文记录**下次**该怎么做。
> 适用范围：任何跟随 rolling upstream（pmaports edge、Alpine edge、AUR、nixpkgs-unstable、
> npm `latest`、Docker `:latest`）的 CI。

---

## 0. 先判断问题属于哪一类

看到 CI 失败，第一件事不是读日志，是回答一个问题：

> **上次成功和这次失败之间，我改了什么？**

```bash
gh run list --limit 30
```

看 workflow 名 + 分支 + 结论，找到**最后一次成功**和**第一次失败**的时间戳，
再对照 `git log`。

| 情况 | 性质 | 怎么查 |
|---|---|---|
| 中间有你的提交 | 普通回归 | 正常 bisect 你自己的代码 |
| **中间没有你的提交** | **上游漂移** | **本文的流程** |
| 只有某些分支挂 | 配置分叉 | 对比分支间的 workflow 差异 |

这次的判断依据：最后成功 2026-07-06，首次失败 2026-07-20，中间仓库零提交
→ 立刻确定是上游问题，**不要浪费时间怀疑自己的代码**。

> ⚠️ 顺手看一眼失败耗时。健康构建 ~5 分钟，失败全在 1–2 分钟
> → 说明死在依赖解析阶段，还没开始真正干活。耗时本身就是信息。

---

## 1. 拿到真正的错误，而不是错误的摘要

### 1.1 定位失败的 step

```bash
gh run view <run-id>          # 哪个 step 挂了
```

### 1.2 拿完整日志

```bash
gh run view <run-id> --log-failed        # 首选，但可能返回空
gh run view <run-id> --log               # 次选
# 上面两个都不行时，走 API：
gh api repos/OWNER/REPO/actions/runs/<run-id>/jobs --jq '.jobs[].id'
gh api repos/OWNER/REPO/actions/jobs/<job-id>/logs
```

**踩过的坑：**
- 这次 `--log-failed` **返回空**，`gh api .../jobs/<id>/logs` 才拿到东西。别在第一个命令上卡住。
- `gh` 靠 cwd 推断仓库。在 `/tmp` 里跑会报
  `failed to determine base repo`。要么在仓库里跑，要么加 `-R OWNER/REPO`。

### 1.3 找工具自己的日志

很多构建工具**只把摘要打到 stdout，真正的错误写在自己的日志文件里**：

```
NOTE: The failed command's output is above the ^^^ line in the log file: .../log.txt
```

这行就是在告诉你"你看到的不是全部"。如果 CI 没 dump 这个文件——
**先加 dump，再继续排查**，别硬猜：

```yaml
- name: Build
  run: |
    if ! some-tool build; then
      echo "==== log.txt (last 300 lines) ===="
      tail -n 300 "$WORK/log.txt" || true
      exit 1
    fi
```

这次因为缺这一步，被迫用第 3 节的办法反推。加上它本可以省几小时。

---

## 2. 从失败命令里提取"事实集合"

失败日志里那条完整命令是**最有价值的单个 artifact**，抄下来：

```
apk.static --root ... --arch aarch64 --repository ... \
  add --no-interactive lang font-twemoji ... device-zhihe-generic-nonfree-firmware ...
```

它给了你：参数、仓库源、**以及完整的输入集合**。后面所有验证都基于它。

### 关键纪律：区分"出现在报错里"和"导致了报错"

那条命令里有 18 个包，报错信息**一个都没点名**。
上一次修复（`fda1da2`）就是栽在这——看到列表里有 `lang`，就断定
"`lang` 不可用"，删掉了 `locale` 配置。结果：

- `lang` 一直存在于 Alpine edge main；
- `lang` 来自 `_pmb_recommends` 链，跟 `locale` 毫无关系；
- 改完之后 `lang` **依然在包列表里**，构建照挂；
- 唯一效果是镜像 locale 被静默改成了 `en_US.UTF-8`。

> **一次"看起来合理"的猜测，浪费了一周，还引入了一个静默的行为变更。**

### 找第二个数据点来收窄

这次有两个 workflow 同时挂，包列表不同：

```
modem: lang fonts sudo-rs ... qmi-utils qrtr modemmanager iw ... nonfree-firmware ...
plain:              sudo-rs ...                        iw ... nonfree-firmware ...
```

取交集 → 嫌疑范围从 18 个缩到 10 个，并且立刻排除了 `lang`（plain 里没有 `lang`，
一样挂）。**有多个失败样本时，先做交集，这一步免费。**

---

## 3. 离线复现依赖解析 —— 不要拿 CI 当 REPL

改一行、推一次、等 5 分钟，是最贵的调试循环。
包管理器的解析过程可以**完全离线复现**，几秒出结果。

### 3.1 先搞清楚仓库 URL 到底是什么

**这一步最容易错**，因为"channel 名"往往 ≠ "仓库路径"。
读工具源码，别猜：

```python
# pmb/helpers/repo.py get_repos_from_config()
mirrordir_pmos  = channel_cfg["branch_pmaports"]   # 不是 channel 名！
mirrordir_alpine = channel_cfg["mirrordir_alpine"]
```

```bash
curl -s https://gitlab.postmarketos.org/postmarketOS/pmaports/-/raw/main/channels.cfg
# [edge]
# branch_pmaports=main     <- 所以 edge 的仓库在 /postmarketos/main/，不是 /postmarketos/edge/
```

> pmaports 把默认分支从 `master` 改名成了 `main`，仓库路径跟着变了。
> 直接拼 `/postmarketos/edge/APKINDEX.tar.gz` 会得到 404 —— **404 不代表包没了，
> 可能只是你的 URL 猜错了。先用目录列表确认：**
> `curl -s https://mirror.postmarketos.org/postmarketos/ | grep -o 'href="[^"]*"'`

同理，条件性的 repo 要判断是否生效：`extra-repos/systemd` 只在启用 systemd 时加入
（`ui = console` 会，`ui = none` 不会）—— 看 pmbootstrap 打印的 `Channel:` 那行。

### 3.2 把索引拉下来解一遍

完整脚本见 [SOLUTION.md](SOLUTION.md) §3.2。核心就三件事：

1. 解析索引，建 `name -> depends` 映射，**`provides`（`p:` 字段）也要算进去**；
2. 从输入集合 BFS，剥掉版本约束（`re.split(r"[=<>~]", dep)[0]`），跳过 `!conflict`；
3. 报告走不到的名字。

### 3.3 必须回答三个问题，缺一不可

| 问题 | 为什么重要 |
|---|---|
| **① 少了什么？** | 定位元凶 |
| **② 去掉之后还缺不缺？** | 证明**没有第二个坑**，避免改一次推一次 |
| **③ 删掉的东西，功能有没有丢？** | 证明修复是安全的，不是把问题藏起来 |

这次的答案：

```
修复前 → MISSING = ['device-zhihe-generic-nonfree-firmware']   ①唯一元凶
修复后 → MISSING = none          （332 / 172 个包全解开）      ②没有第二个坑
msm-firmware-loader          in closure: True                  ③firmware 没丢
firmware-qcom-msm8916-venus  in closure: True
```

正因为②，第一次推送就通过了。**没有②就只是"试试看"，不是"解决了"。**

---

## 4. 到上游取证，锁定那一次改动

有了嫌疑包名，去上游查它**什么时候、为什么**消失的。
用 API 精确查文件历史，比 clone 整个仓库快得多：

```bash
# 文件级 commit 历史 —— 直接把改动时间打出来，跟失败窗口对
curl -s "https://gitlab.postmarketos.org/api/v4/projects/postmarketOS%2Fpmaports/\
repository/commits?path=device/testing/device-zhihe-generic/APKBUILD&ref_name=main" \
  | python3 -c "import sys,json;[print(c['created_at'][:10], c['short_id'], c['title']) for c in json.load(sys.stdin)]"
# 2026-07-19 e5536561 treewide: device/testing: remove nonfree-firmware subpackages   <- 落在窗口内
```

```bash
# 看具体 diff，确认替代方案是什么
curl -s "https://gitlab.postmarketos.org/postmarketOS/pmaports/-/commit/e5536561.diff"
```

**读 diff 是为了知道该怎么改。** 这次 diff 显示两个依赖被提升成了主包的 `depends`
→ 结论是**只删不补**，不需要手动加 `msm-firmware-loader`。
如果只看到"包没了"就自己补一堆包，就会写出多余且以后还会再坏的配置。

### GitLab/GitHub API 小抄

```bash
# 默认分支（能抓到 master -> main 这类改名）
curl -s "https://gitlab.postmarketos.org/api/v4/projects/<url-encoded-path>" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['default_branch'])"

# 目录树（注意 per_page 上限 100，要翻页）
.../repository/tree?path=device/testing&per_page=100&page=N&ref=main

# 原始文件
https://gitlab.postmarketos.org/<group>/<proj>/-/raw/<ref>/<path>
```

> 坑：GitLab 的 `search?scope=blobs` 需要认证，匿名访问返回 `401`。
> 用 tree API 翻页 + raw 文件代替。

---

## 5. 排除工具本身

在把锅扣给上游数据之前，先证明**工具没变**：

```bash
curl -sSL https://gitlab.postmarketos.org/postmarketOS/pmbootstrap/-/archive/main/pmbootstrap-main.tar.gz \
  | tar -xz -C /tmp
diff -rq --exclude=.git --exclude=__pycache__ /tmp/pmbootstrap-main ./pmbootstrap
```

无输出 = 本地与上游一致 → 工具可以排除，锅在数据侧。

> 坑：这个仓库默认分支也叫 `main`。用 `.../archive/master/...` 会返回一个 HTML 错误页，
> `tar` 报 `not in gzip format` —— **看着像网络问题，其实是 URL 错了。**
> 解压报格式错误时，先 `file` 一下下载到的东西。

顺便记录版本漂移：这次成功那版是 pmbootstrap 3.10.1，失败那版是 3.11.1。
虽然不是本次元凶，但它暴露了"依赖没钉住"这个问题，进入第 6 节。

---

## 6. 修完之后，顺手做同类隐患审计

找到一个"硬编码了上游假设"的 bug，就去找**同一类的其他实例**。
这次从 1 个根因扩展出 4 个潜在故障：

| 隐患 | 什么时候炸 | 处理 |
|---|---|---|
| `extra_packages` 硬写上游子包名 | 上游重构包结构（**已炸**） | 删掉，交给工具自动探测 |
| `printf '8\n' > $WORK/version` 硬编码 work version | 上游 bump 到 9 | 改成从 `pmb.config.work_version` 读 |
| `git clone --depth=1`（跟随默认分支） | 上游任意一次提交 | 钉到 `--branch 3.11.1` |
| 失败时不 dump 工具日志 | 每次排查 | 两个 workflow 都补上 |

判定标准很简单：**这个值是我拍的，还是能从权威来源读出来的？**
能读就读，别拍。

同时**复查历史上的"修复"**——`fda1da2` 号称修好了但从没验证过，
它引入的静默行为变更一直躺在树里。
> 一个从没被验证过的修复，是一个伪装成解决方案的 bug。

---

## 7. 推送前的本地校验

CI 是最慢的验证环节，能在本地做的都在本地做完：

```bash
# YAML 语法
python3 -c "import yaml;[yaml.safe_load(open(f)) for f in ['.github/workflows/a.yml']]"

# 由 heredoc + sed 生成的配置文件，模拟一遍再解析
bash -c 'cat > /tmp/sim.cfg <<EOF
          ...
EOF'
sed -i 's/^          //' /tmp/sim.cfg
python3 -c "import configparser;c=configparser.ConfigParser();c.read('/tmp/sim.cfg');print(c.sections())"

# 依赖解析（第 3 节）用改完之后的包列表再跑一遍
# 引用的外部 ref 真的存在吗
git ls-remote --tags <repo> | grep 3.11.1
```

然后推送、触发、盯完：

```bash
gh workflow run <wf>.yml --ref <branch>
gh run watch <run-id> --exit-status --interval 30
```

**`--exit-status` 很关键**——它让退出码反映构建结果，
否则容易看到 "watch 结束了" 就以为成功了。

---

## 8. 一页纸速查

```
CI 挂了
 │
 ├─ gh run list ─── 找到 最后成功 / 首次失败 的时间边界
 │                  中间有我的提交？ ── 有 ─→ 普通 bisect，本文到此为止
 │                                      └ 无 ─→ 上游漂移，继续
 │
 ├─ 拿完整日志（--log-failed 空就走 gh api .../jobs/<id>/logs）
 │   └─ 日志提到"另有 log 文件"？ ── 先给 CI 加 dump
 │
 ├─ 抄下失败的那条完整命令 = 事实集合
 │   ├─ 多个失败样本 ─→ 取交集收窄
 │   └─ ⚠ 别把"出现在命令里"当成"导致了失败"
 │
 ├─ 离线复现解析（几秒）
 │   ├─ 先用工具源码确认仓库 URL（channel 名 ≠ 路径；404 先怀疑 URL）
 │   └─ 必须回答：①少什么 ②去掉后还缺不缺 ③功能丢没丢
 │
 ├─ 上游取证：文件级 commit 历史 → 落在窗口内的那次改动 → 读 diff 定修复方案
 │
 ├─ 排除工具本身：本地副本 diff 上游
 │
 ├─ 同类隐患审计：所有"我拍的值"都换成"读出来的值"
 │   └─ 顺便复查历史上未经验证的"修复"
 │
 └─ 本地校验（语法 / 配置生成 / 重跑解析 / ref 存在性）→ 推送 → gh run watch --exit-status
```

---

## 9. 五条能带走的原则

1. **先划边界，再读日志。** "上次成功 → 这次失败"之间没有你的提交，
   就别在自己的代码里找原因。

2. **错误摘要不是错误。** 工具往往把真相写在自己的日志文件里。
   看到"详见 xxx.log"就说明你看到的信息不完整——先把它 dump 出来。

3. **"出现在报错里" ≠ "导致了报错"。** 一条命令有 18 个参数时，
   凭直觉挑一个来改，成功率是 1/18，但**看起来**总是很合理。

4. **验证要证明唯一性和充分性，不只是可能性。**
   "去掉它就好了"不够，还要"去掉之后没有别的问题了"+"功能没丢"。
   做到这三条，第一次推送就该通过。

5. **能读出来的值就别硬编码。** 版本号、子包名、路径、分支名——
   每一个手写的上游假设，都是一颗定时炸弹。今天你只是拆掉了先爆的那颗。
