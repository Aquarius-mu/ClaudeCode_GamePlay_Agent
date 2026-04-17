---
name: feishu-file-ops
version: 1.0.0
description: "飞书Bot文件操作：在 ~/feishu_bot/ 下安全读写缓存文件。白名单写入 cache/ 目录，禁止操作敏感路径和执行脚本。"
metadata:
  requires:
    bins: ["jq", "flock"]
---

# feishu-file-ops

安全地在飞书Bot工作目录下读写文件。**写操作仅限 `~/feishu_bot/cache/`**。

## 允许的操作

### 读取（无限制路径）
```bash
cat ~/feishu_bot/cache/tokens.json
cat ~/feishu_bot/cache/groups.json
cat ~/feishu_bot/cache/users.json
cat ~/feishu_bot/name_cache          # 只读：脚本维护
cat ~/feishu_bot/group_cache         # 只读：脚本维护
cat ~/feishu_bot/sessions            # 只读：脚本维护
cat ~/feishu_bot/bot.log
cat ~/feishu_bot/skill_improve.log
ls ~/feishu_bot/cache/
grep "ou_xxx" ~/feishu_bot/name_cache
find ~/feishu_bot/cache/ -name "*.json"
```

### 写入（仅 `~/feishu_bot/cache/`）
```bash
# 正确：只写 cache/ 目录下的文件
~/feishu_bot/cache/tokens.json
~/feishu_bot/cache/groups.json
~/feishu_bot/cache/users.json

# 禁止写入的路径
~/feishu_bot/sessions          # ❌ 脚本专属
~/feishu_bot/name_cache        # ❌ 脚本专属
~/feishu_bot/group_cache       # ❌ 脚本专属
~/.ssh/                        # ❌ 绝对禁止
~/.gnupg/                      # ❌ 绝对禁止
~/.claude/                     # ❌ 绝对禁止（除 skills/ 下的 SKILL.md）
```

## 禁止的操作

```
rm / rmdir          ❌ 不删除任何文件
chmod / chown       ❌ 不修改权限
sudo / su           ❌ 不提权
curl / wget         ❌ 不自行下载
bash xxx / ./xxx    ❌ 不执行任意脚本
> file（清空）      ❌ 不清空 sessions/name_cache/group_cache
```

## 写入规范（必须 flock + jq）

所有写 JSON 文件必须：
1. 用 `flock -x` 持有锁文件（`同名.lock`）
2. 用 `jq` 合并而不是整体覆盖
3. 写入临时文件再 `mv`（原子替换）
4. 写后用 `jq empty` 验证 JSON 合法性

```bash
CACHE_DIR=~/feishu_bot/cache
TARGET=$CACHE_DIR/groups.json
LOCK=$CACHE_DIR/groups.lock

(
  flock -x 200
  current=$(cat "$TARGET" 2>/dev/null)
  [[ -z "$current" || ! $(echo "$current" | jq empty 2>/dev/null; echo $?) -eq 0 ]] && current="{}"
  echo "$current" \
    | jq --arg id "oc_xxx" --arg name "群名" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '.[$id] = {"name":$name,"updated_at":$ts}' \
    > "${TARGET}.tmp" \
  && jq empty "${TARGET}.tmp" \
  && mv "${TARGET}.tmp" "$TARGET"
) 200>"$LOCK"
```

## 初始化 cache 目录

```bash
mkdir -p ~/feishu_bot/cache
```
