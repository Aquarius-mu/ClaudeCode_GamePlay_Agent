---
name: feishu-cache
version: 1.0.0
description: "飞书Bot缓存管理：读写 ~/feishu_bot/cache/ 下的 tokens/groups/users JSON，含TTL校验、flock并发写入、name_cache同步、旧cache.json迁移。"
metadata:
  requires:
    bins: ["jq", "flock"]
---

# feishu-cache

## 缓存目录结构

```
~/feishu_bot/
├── cache/
│   ├── tokens.json     # spreadsheet/bitable/wiki token（Claude维护）
│   ├── groups.json     # chat_id + 群名（脚本写基础字段，Claude补完）
│   ├── users.json      # open_id + 用户详情（脚本写name，Claude补其余）
│   ├── tokens.lock
│   ├── groups.lock
│   └── users.lock
├── name_cache          # open_id=姓名，每行（脚本专属，只读）
├── group_cache         # chat_id=群名，每行（脚本专属，只读）
└── sessions            # chat_id=session_id（脚本专属，只读）
```

## 初始化

```bash
mkdir -p ~/feishu_bot/cache
```

---

## TTL 策略

| 数据类型 | TTL | 原因 |
|---------|-----|------|
| tokens.json 中的 token | 永久（人工清除） | token 不过期，除非表格被删除 |
| groups.json 群名 | 30天 | 群名偶尔改变 |
| users.json 姓名/部门 | 7天 | 人员信息变化不频繁 |

TTL 校验：
```bash
check_ttl() {
  local updated_at="$1" ttl_days="$2"
  [[ -z "$updated_at" ]] && return 1  # 无时间戳 → 过期
  local ts; ts=$(date -d "$updated_at" +%s 2>/dev/null) || return 1
  local now; now=$(date +%s)
  (( now - ts < ttl_days * 86400 ))
}
```

---

## 读取模式（先查缓存，过期再拉取）

### 查 users.json
```bash
read_user() {
  local open_id="$1"
  local cache=~/feishu_bot/cache/users.json
  [[ ! -f "$cache" ]] && return 1
  local entry; entry=$(jq -r --arg id "$open_id" '.[$id] // empty' "$cache" 2>/dev/null)
  [[ -z "$entry" ]] && return 1
  local updated_at; updated_at=$(echo "$entry" | jq -r '.updated_at // empty')
  check_ttl "$updated_at" 7 || return 1
  echo "$entry"
}
```

### 查 groups.json
```bash
read_group() {
  local chat_id="$1"
  local cache=~/feishu_bot/cache/groups.json
  [[ ! -f "$cache" ]] && return 1
  local entry; entry=$(jq -r --arg id "$chat_id" '.[$id] // empty' "$cache" 2>/dev/null)
  [[ -z "$entry" ]] && return 1
  local updated_at; updated_at=$(echo "$entry" | jq -r '.updated_at // empty')
  check_ttl "$updated_at" 30 || return 1
  echo "$entry"
}
```

### 查 tokens.json
```bash
read_token() {
  local token_type="$1" token="$2"  # token_type: spreadsheets|bitables|wikis
  local cache=~/feishu_bot/cache/tokens.json
  [[ ! -f "$cache" ]] && return 1
  jq -r --arg type "$token_type" --arg t "$token" '.[$type][$t] // empty' "$cache" 2>/dev/null
}
```

---

## 写入模式（flock + jq 合并 + 原子替换）

### 写 users.json（补充或更新单个用户）
```bash
write_user() {
  local open_id="$1"
  local name="$2" en_name="${3:-}" email="${4:-}" department="${5:-}"
  local cache=~/feishu_bot/cache/users.json
  local lock=~/feishu_bot/cache/users.lock
  local now; now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  mkdir -p ~/feishu_bot/cache
  (
    flock -x 200
    local current; current=$(cat "$cache" 2>/dev/null)
    [[ -z "$current" ]] || ! jq empty <<< "$current" 2>/dev/null && current="{}"
    echo "$current" | jq \
      --arg id "$open_id" --arg name "$name" \
      --arg en "$en_name" --arg email "$email" \
      --arg dept "$department" --arg ts "$now" \
      '.[$id] = (.[$id] // {}) +
        ({"name":$name,"en_name":$en,"email":$email,"department":$dept,"updated_at":$ts}
         | with_entries(select(.value != "")))' \
      > "${cache}.tmp" \
    && jq empty "${cache}.tmp" \
    && mv "${cache}.tmp" "$cache"
  ) 200>"$lock"
}
```

### 写 groups.json
```bash
write_group() {
  local chat_id="$1" name="$2" member_count="${3:-0}"
  local cache=~/feishu_bot/cache/groups.json
  local lock=~/feishu_bot/cache/groups.lock
  local now; now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  mkdir -p ~/feishu_bot/cache
  (
    flock -x 200
    local current; current=$(cat "$cache" 2>/dev/null)
    [[ -z "$current" ]] || ! jq empty <<< "$current" 2>/dev/null && current="{}"
    echo "$current" | jq \
      --arg id "$chat_id" --arg name "$name" \
      --argjson mc "$member_count" --arg ts "$now" \
      '.[$id] = (.[$id] // {}) + {"name":$name,"member_count":$mc,"updated_at":$ts}' \
      > "${cache}.tmp" \
    && jq empty "${cache}.tmp" \
    && mv "${cache}.tmp" "$cache"
  ) 200>"$lock"
}
```

### 写 tokens.json
```bash
write_token() {
  local token_type="$1" token="$2" name="${3:-}" tables_json="${4:-null}"
  local cache=~/feishu_bot/cache/tokens.json
  local lock=~/feishu_bot/cache/tokens.lock
  local now; now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  mkdir -p ~/feishu_bot/cache
  (
    flock -x 200
    local current; current=$(cat "$cache" 2>/dev/null)
    [[ -z "$current" ]] || ! jq empty <<< "$current" 2>/dev/null && current='{"spreadsheets":{},"bitables":{},"wikis":{}}'
    echo "$current" | jq \
      --arg type "$token_type" --arg t "$token" \
      --arg name "$name" --argjson tables "$tables_json" --arg ts "$now" \
      '.[$type][$t] = ((.[$type][$t] // {}) + {"name":$name,"updated_at":$ts} +
        (if $tables != null then {"tables":$tables} else {} end))' \
      > "${cache}.tmp" \
    && jq empty "${cache}.tmp" \
    && mv "${cache}.tmp" "$cache"
  ) 200>"$lock"
}
```

---

## 同步 name_cache → users.json

每次操作 users.json 前，先做增量同步（只补 name，不覆盖已有 email/department）：

```bash
sync_name_cache_to_users() {
  local name_cache=~/feishu_bot/name_cache
  local cache=~/feishu_bot/cache/users.json
  local lock=~/feishu_bot/cache/users.lock
  [[ ! -f "$name_cache" ]] && return
  mkdir -p ~/feishu_bot/cache
  (
    flock -x 200
    local current; current=$(cat "$cache" 2>/dev/null)
    [[ -z "$current" ]] || ! jq empty <<< "$current" 2>/dev/null && current="{}"
    local now; now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    while IFS='=' read -r oid name; do
      [[ -z "$oid" || -z "$name" ]] && continue
      # 只在 users.json 中没有该 open_id 时写入 name（不覆盖 Claude 已补充的字段）
      current=$(echo "$current" | jq \
        --arg id "$oid" --arg name "$name" --arg ts "$now" \
        'if .[$id] == null then .[$id] = {"name":$name,"updated_at":$ts} else . end')
    done < "$name_cache"
    echo "$current" > "${cache}.tmp" \
    && jq empty "${cache}.tmp" \
    && mv "${cache}.tmp" "$cache"
  ) 200>"$lock"
}
```

---

## 迁移旧 cache.json → cache/ 目录

首次运行时执行（幂等，迁移后重命名旧文件）：

```bash
migrate_old_cache() {
  local old=~/feishu_bot/cache.json
  [[ ! -f "$old" ]] && return
  echo "迁移 cache.json → cache/ ..."
  mkdir -p ~/feishu_bot/cache
  local now; now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  # 提取并迁移 tokens（spreadsheet/bitable/wiki）
  local tokens_cache=~/feishu_bot/cache/tokens.json
  [[ ! -f "$tokens_cache" ]] && echo '{"spreadsheets":{},"bitables":{},"wikis":{}}' > "$tokens_cache"

  # 从旧 cache.json 提取 spreadsheet_token
  local sp_token; sp_token=$(jq -r '.spreadsheet_token // empty' "$old" 2>/dev/null)
  if [[ -n "$sp_token" ]]; then
    local sp_name; sp_name=$(jq -r '.spreadsheet_name // "MLA配置确认表"' "$old" 2>/dev/null)
    write_token "spreadsheets" "$sp_token" "$sp_name"
  fi

  # 从旧 cache.json 提取 bitable tokens（支持多版本格式：{"654":{"base_token":"...","table_id":"..."}}）
  jq -r 'to_entries[] | select(.value.base_token?) | "\(.key)=\(.value.base_token)_\(.value.table_id)"' \
    "$old" 2>/dev/null | while IFS='=' read -r ver block_token; do
    local base_t="${block_token%_*}" table_t="${block_token#*_}"
    write_token "bitables" "$base_t" "版本${ver}" "{\"$table_t\":\"${ver}\"}"
  done

  # 从旧 cache.json 提取 wiki_token
  local wiki_token; wiki_token=$(jq -r '.wiki_token // empty' "$old" 2>/dev/null)
  if [[ -n "$wiki_token" ]]; then
    write_token "wikis" "$wiki_token" "MLA知识库节点"
  fi

  # 提取用户 open_id → users.json
  local users_cache=~/feishu_bot/cache/users.json
  [[ ! -f "$users_cache" ]] && echo '{}' > "$users_cache"
  jq -r 'to_entries[] | select(.key | startswith("ou_")) | "\(.key)=\(.value)"' \
    "$old" 2>/dev/null | while IFS='=' read -r oid name; do
    write_user "$oid" "$name"
  done

  # 提取群 chat_id → groups.json
  local groups_cache=~/feishu_bot/cache/groups.json
  [[ ! -f "$groups_cache" ]] && echo '{}' > "$groups_cache"
  jq -r 'to_entries[] | select(.key | startswith("oc_")) | "\(.key)=\(.value)"' \
    "$old" 2>/dev/null | while IFS='=' read -r cid name; do
    write_group "$cid" "$name"
  done

  # 保留旧文件（改名）
  mv "$old" "${old}.migrated"
  echo "迁移完成，旧文件已重命名为 cache.json.migrated"
}
```

---

## 完整查询流程（带缓存）

```bash
# 查用户，缓存未命中时拉取并写入
get_user_cached() {
  local open_id="$1"
  sync_name_cache_to_users
  local entry; entry=$(read_user "$open_id")
  if [[ -n "$entry" ]]; then echo "$entry"; return; fi
  # 缓存未命中：调 lark-cli
  local result; result=$(lark-cli contact +get-user \
    --user-id "$open_id" --user-id-type open_id --as user 2>/dev/null)
  local name;  name=$(echo "$result"  | jq -r '.data.user.name // empty')
  local email; email=$(echo "$result" | jq -r '.data.user.email // empty')
  local dept;  dept=$(echo "$result"  | jq -r '.data.user.department_ids[0] // empty')
  local en;    en=$(echo "$result"    | jq -r '.data.user.en_name // empty')
  write_user "$open_id" "$name" "$en" "$email" "$dept"
  read_user "$open_id"
}
```
