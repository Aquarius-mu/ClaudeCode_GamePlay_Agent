---
name: feishu-file-ops
version: 2.0.0
description: "飞书Bot文件操作安全规范：白名单写入 ~/feishu_bot/cache/，禁止操作敏感路径和脚本文件，所有写入必须 flock+jq 原子替换。"
metadata:
  requires:
    bins: ["jq", "flock"]
---

# feishu-file-ops

飞书 Bot 运行时的文件操作安全规范。**写操作仅限 `~/feishu_bot/cache/` 三个 JSON 文件**，其余路径一律只读。

---

## 路径权限速查

| 路径 | 读 | 写 | 说明 |
|------|----|----|------|
| `~/feishu_bot/cache/tokens.json` | ✅ | ✅ | Claude 维护 |
| `~/feishu_bot/cache/groups.json` | ✅ | ✅ | Claude 维护 |
| `~/feishu_bot/cache/users.json` | ✅ | ✅ | Claude 维护 |
| `~/feishu_bot/cache/*.lock` | ✅ | ✅ | flock 锁文件（自动创建） |
| `~/feishu_bot/bot.log` | ✅ | ❌ | 脚本写，Claude 只读 |
| `~/feishu_bot/skill_improve.log` | ✅ | ❌ | 脚本写，Claude 只读 |
| `~/feishu_bot/name_cache` | ✅ | ❌ | 脚本专属，只读 |
| `~/feishu_bot/group_cache` | ✅ | ❌ | 脚本专属，只读 |
| `~/feishu_bot/sessions` | ✅ | ❌ | 脚本专属，只读 |
| `~/feishu_bot/warmup_session` | ✅ | ❌ | 脚本专属，只读 |
| `~/.claude/skills/*/SKILL.md` | ✅ | ✅ | Skill 自我改进专用 |
| `~/.claude/lark_cli_rules.md` | ✅ | ✅ | 规则文件，可更新 |
| `~/.ssh/` `~/.gnupg/` | ❌ | ❌ | 绝对禁止 |
| `~/.claude/`（skills 外） | ✅ | ❌ | 只读 |
| `lark_sweet_bot.sh` 等脚本 | ✅ | ❌ | 只读，禁止执行 |

---

## 禁止的操作

```
rm / rmdir              ❌  不删除任何文件
chmod / chown           ❌  不修改权限
sudo / su               ❌  不提权
curl / wget             ❌  不自行下载
bash xxx.sh / ./xxx.sh  ❌  不执行任意脚本
> file（清空写）        ❌  不清空 sessions / name_cache / group_cache
整体覆盖 JSON           ❌  必须用 jq 合并，不能直接 echo '{...}' > file
```

---

## 写入规范（所有写 cache/ 的操作都必须遵守）

4 步缺一不可：

1. `flock -x` 持有对应 `.lock` 文件
2. `jq` **合并**（不整体覆盖），保留已有字段
3. 写入 `.tmp` 临时文件
4. `jq empty` 验证合法后 `mv` 原子替换

```bash
# 模板（以 groups.json 为例）
TARGET=~/feishu_bot/cache/groups.json
LOCK=~/feishu_bot/cache/groups.lock

(
  flock -x 200
  cur=$(cat "$TARGET" 2>/dev/null); [[ -z "$cur" ]] && cur="{}"
  echo "$cur" \
    | jq --arg id  "oc_xxx" \
         --arg name "群名" \
         --arg ts   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         '.[$id] = ((.[$id] // {}) + {"name":$name,"updated_at":$ts})' \
    > "${TARGET}.tmp" \
  && jq empty "${TARGET}.tmp" \
  && mv "${TARGET}.tmp" "$TARGET"
) 200>"$LOCK"
```

---

## 三个 JSON 的数据结构

### tokens.json

```json
{
  "spreadsheets": {
    "<spreadsheet_token>": {"name": "表格名", "updated_at": "2026-04-22T10:00:00Z"}
  },
  "bitables": {
    "<base_token>": {
      "name": "多维表格名",
      "updated_at": "2026-04-22T10:00:00Z",
      "tables": {"<table_id>": "版本/页签名"}
    }
  },
  "wikis": {
    "<wiki_node_token>": {"name": "知识库节点名", "updated_at": "2026-04-22T10:00:00Z"}
  }
}
```

### groups.json

```json
{
  "oc_xxx": {
    "name": "群名",
    "member_count": 42,
    "updated_at": "2026-04-22T10:00:00Z"
  }
}
```

### users.json

```json
{
  "ou_xxx": {
    "name": "张三",
    "en_name": "Zhang San",
    "email": "zhangsan@company.com",
    "department": "游戏策划部",
    "updated_at": "2026-04-22T10:00:00Z"
  }
}
```

---

## TTL 策略

| 文件 | TTL | 原因 |
|------|-----|------|
| `tokens.json` | 永久（人工清除） | token 不过期，除非文档被删 |
| `groups.json` | 30 天 | 群名偶尔改变 |
| `users.json` | 7 天 | 人员信息变化不频繁 |

TTL 校验：

```bash
is_fresh() {
  local updated_at="$1" ttl_days="$2"
  [[ -z "$updated_at" ]] && return 1
  local ts; ts=$(date -d "$updated_at" +%s 2>/dev/null) || return 1
  (( $(date +%s) - ts < ttl_days * 86400 ))
}

# 使用示例
entry=$(jq -r --arg id "$chat_id" '.[$id] // empty' ~/feishu_bot/cache/groups.json)
if [[ -n "$entry" ]] && is_fresh "$(echo "$entry" | jq -r '.updated_at')" 30; then
  echo "$entry" | jq -r '.name'   # 缓存命中
else
  # 缓存未命中，调 lark-cli 查询后写入
  :
fi
```

---

## 常用读取示例

```bash
# 读 users.json 中某个用户
jq -r --arg id "ou_xxx" '.[$id] // empty' ~/feishu_bot/cache/users.json

# 查所有已缓存的群
jq 'keys[]' ~/feishu_bot/cache/groups.json

# 查所有已解析的 bitable
jq '.bitables | to_entries[] | {token:.key, name:.value.name}' ~/feishu_bot/cache/tokens.json

# 查 name_cache（只读，脚本维护）
grep "^ou_xxx=" ~/feishu_bot/name_cache | cut -d= -f2
```

---

## Skill 自我改进

Claude 可以更新 `~/.claude/skills/*/SKILL.md` 和 `~/.claude/lark_cli_rules.md`，流程：

1. 用 Read 工具读取当前内容
2. 用 Edit/Write 工具更新
3. **禁止**修改 `lark_sweet_bot.sh` 或任何 `.sh` 脚本
