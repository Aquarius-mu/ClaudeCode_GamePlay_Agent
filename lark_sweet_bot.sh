#!/bin/bash
# ══════════════════════════════════════════════════════════
#  飞书 Claude Bot — lark-cli 
# ══════════════════════════════════════════════════════════

LARK=/home/jiadongsun/nodejs/node22.15/bin/lark-cli
BOT_OPEN_ID=ou_7b2a74cf8aa3907ed7366f3f277662ff
ALLOWED_SENDER=ou_f8760ccaca19d1453f3128bef06e0b3c
BOT_DIR="$HOME/feishu_bot"
SESSION_FILE="$BOT_DIR/sessions"
SESSION_LOCK="$BOT_DIR/sessions.lock"
NAME_CACHE="$BOT_DIR/name_cache"
NAME_CACHE_LOCK="$BOT_DIR/name_cache.lock"
GROUP_CACHE="$BOT_DIR/group_cache"
GROUP_CACHE_LOCK="$BOT_DIR/group_cache.lock"
WARMUP_SESSION="$BOT_DIR/warmup_session"
WARMUP_LOCK="$BOT_DIR/warmup_session.lock"
CACHE_DIR="$BOT_DIR/cache"
SKILL_IMPROVE_LOG="$BOT_DIR/skill_improve.log"
SKILL_IMPROVE_LOCK="$BOT_DIR/skill_improve.lock"
PID_FILE="$BOT_DIR/bot.pid"
LOG_FILE="$BOT_DIR/bot.log"

CLAUDE_BIN=claude
MCP_CONFIG=/data/home/jiadongsun/.claude/mcp.json

SYSTEM_PROMPT="你是一个飞书群助手。每条用户消息开头会携带[系统上下文]，\
包含当前群组名称、chat_id、发送者姓名和 open_id，\
你可以直接使用这些 ID 调用 lark-cli 操作飞书。\
请直接回答用户问题。只有当用户明确要求查询、搜索或执行操作时，\
才考虑使用工具；普通对话、问候、知识问答等请直接回答，不要主动调用任何工具。\
如需输出格式丰富的飞书卡片（含表格、折叠面板、多列布局等组件），\
在回复开头输出 CARD_JSON:: 后紧跟合法的飞书卡片 JSON（schema 2.0），\
Bot 会直接将其作为最终卡片发送；普通文本回复无需任何前缀。"

mkdir -p "$BOT_DIR"
mkdir -p "$CACHE_DIR"

# ══════════════════════════════════════════════════════════
#  工具函数
# ══════════════════════════════════════════════════════════

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }

is_running() {
  [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

now_ms() { date +%s%3N; }

format_duration() {
  local ms="$1"
  if (( ms < 1000 )); then echo "${ms}ms"
  elif (( ms < 60000 )); then printf "%d.%03ds" "$(( ms/1000 ))" "$(( ms%1000 ))"
  else printf "%dm%ds" "$(( ms/60000 ))" "$(( (ms%60000)/1000 ))"
  fi
}

# ══════════════════════════════════════════════════════════
#  预建 Session 池
# ══════════════════════════════════════════════════════════

build_warmup_session() {
  (
    flock -n 200 || return
    log "预建session中..."
    local t0; t0=$(now_ms)
    local output sid
    output=$($CLAUDE_BIN -p \
      --dangerously-skip-permissions \
      --mcp-config "$MCP_CONFIG" \
      --output-format json \
      --system-prompt "$SYSTEM_PROMPT" \
      "." < /dev/null 2>>"$LOG_FILE")
    sid=$(printf '%s' "$output" | jq -r '.session_id // empty' 2>/dev/null)
    if [[ -n "$sid" ]]; then
      echo "$sid" > "$WARMUP_SESSION"
      log "预建session完成 ($(format_duration $(( $(now_ms)-t0 )))) sid=${sid:0:8}..."
    else
      log "预建session失败"
    fi
  ) 200>"$WARMUP_LOCK"
}

consume_warmup_session() {
  (
    flock -x 200
    if [[ -f "$WARMUP_SESSION" ]]; then
      cat "$WARMUP_SESSION"
      rm -f "$WARMUP_SESSION"
    fi
  ) 200>"$WARMUP_LOCK"
}

# ══════════════════════════════════════════════════════════
#  用户名缓存
# ══════════════════════════════════════════════════════════

get_sender_name() {
  local sender_id="$1"

  local cached
  cached=$(grep "^${sender_id}=" "$NAME_CACHE" 2>/dev/null | head -1 | cut -d= -f2)
  if [[ -n "$cached" ]]; then echo "$cached"; return; fi

  local name
  name=$($LARK contact +get-user \
    --user-id "$sender_id" \
    --user-id-type open_id \
    --as user \
    --jq '.data.user.name' \
    2>/dev/null) || name=""
  [[ -z "$name" || "$name" == "null" ]] && name="用户"

  (
    flock -x 200
    grep -q "^${sender_id}=" "$NAME_CACHE" 2>/dev/null \
      || echo "${sender_id}=${name}" >> "$NAME_CACHE"
  ) 200>"$NAME_CACHE_LOCK"

  _write_users_json "$sender_id" "$name" &

  echo "$name"
}

_write_users_json() {
  local open_id="$1" name="$2"
  local cache="$CACHE_DIR/users.json" lock="$CACHE_DIR/users.lock"
  local now; now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  (
    flock -x 200
    local cur; cur=$(cat "$cache" 2>/dev/null)
    echo "$cur" | jq empty 2>/dev/null || cur="{}"
    echo "$cur" | jq \
      --arg id "$open_id" --arg n "$name" --arg ts "$now" \
      'if .[$id] == null then .[$id] = {"name":$n,"updated_at":$ts} else . end' \
      > "${cache}.tmp" \
    && jq empty "${cache}.tmp" 2>/dev/null \
    && mv "${cache}.tmp" "$cache"
  ) 200>"$lock"
}

# ══════════════════════════════════════════════════════════
#  群名缓存
# ══════════════════════════════════════════════════════════

get_group_name() {
  local chat_id="$1"

  local cached
  cached=$(grep "^${chat_id}=" "$GROUP_CACHE" 2>/dev/null | head -1 | cut -d= -f2)
  if [[ -n "$cached" ]]; then echo "$cached"; return; fi

  local name
  name=$($LARK im +chats-get \
    --chat-id "$chat_id" \
    --as bot \
    --jq '.data.chat.name' \
    2>/dev/null) || name=""
  [[ -z "$name" || "$name" == "null" ]] && name="未知群组"

  (
    flock -x 200
    grep -q "^${chat_id}=" "$GROUP_CACHE" 2>/dev/null \
      || echo "${chat_id}=${name}" >> "$GROUP_CACHE"
  ) 200>"$GROUP_CACHE_LOCK"

  _write_groups_json "$chat_id" "$name" &

  echo "$name"
}

_write_groups_json() {
  local chat_id="$1" name="$2"
  local cache="$CACHE_DIR/groups.json" lock="$CACHE_DIR/groups.lock"
  local now; now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  (
    flock -x 200
    local cur; cur=$(cat "$cache" 2>/dev/null)
    echo "$cur" | jq empty 2>/dev/null || cur="{}"
    echo "$cur" | jq \
      --arg id "$chat_id" --arg n "$name" --arg ts "$now" \
      '.[$id] = ((.[$id] // {}) + {"name":$n,"updated_at":$ts})' \
      > "${cache}.tmp" \
    && jq empty "${cache}.tmp" 2>/dev/null \
    && mv "${cache}.tmp" "$cache"
  ) 200>"$lock"
}

# ══════════════════════════════════════════════════════════
#  构建注入给 Claude 的上下文头
# ══════════════════════════════════════════════════════════

build_context_header() {
  local chat_id="$1"
  local sender_id="$2"
  local sender_name="$3"
  local group_name="${4:-未知群组}"
  local now
  now=$(date '+%Y-%m-%d %H:%M:%S')

  cat <<EOF
[系统上下文 - 当前对话信息]
时间: ${now}
群组: ${group_name}（chat_id: ${chat_id}）
发送者: ${sender_name}（open_id: ${sender_id}）
---
EOF
}

# ══════════════════════════════════════════════════════════
#  会话管理
# ══════════════════════════════════════════════════════════

session_get() {
  grep "^${1}=" "$SESSION_FILE" 2>/dev/null | tail -1 | cut -d= -f2
}

session_set() {
  local chat_id="$1" sid="$2"
  (
    flock -x 200
    local tmp; tmp=$(mktemp "$BOT_DIR/.sessions.XXXXXX")
    grep -v "^${chat_id}=" "$SESSION_FILE" 2>/dev/null > "$tmp" || true
    echo "${chat_id}=${sid}" >> "$tmp"
    mv "$tmp" "$SESSION_FILE"
  ) 200>"$SESSION_LOCK"
}

session_clear() {
  local chat_id="$1"
  (
    flock -x 200
    local tmp; tmp=$(mktemp "$BOT_DIR/.sessions.XXXXXX")
    grep -v "^${chat_id}=" "$SESSION_FILE" 2>/dev/null > "$tmp" || true
    mv "$tmp" "$SESSION_FILE"
  ) 200>"$SESSION_LOCK"
  log "已清除 $chat_id 的会话历史"
}

# ══════════════════════════════════════════════════════════
#  卡片构建
# ══════════════════════════════════════════════════════════

_truncate() {
  local s="$1" max="${2:-80}"
  (( ${#s} > max )) && echo "${s:0:$max}…" || echo "$s"
}

make_thinking_card() {
  local q; q=$(_truncate "$2")
  jq -n --arg name "$1" --arg q "$q" '{
    schema:"2.0",
    header:{title:{tag:"plain_text",content:("💬 "+$name+" 问")},template:"grey"},
    config:{streaming_mode:true},
    body:{elements:[
      {tag:"markdown",content:("> "+$q)},
      {tag:"hr"},
      {tag:"markdown",content:"⏳ **思考中…**"}
    ]}
  }'
}

make_reply_card() {
  local name="$1"
  local q; q=$(_truncate "$2" 120)
  local ans="$3"
  local dur="$4"

  local ans_elem
  if (( ${#ans} > 1500 )); then
    ans_elem=$(jq -n --arg ans "$ans" '{
      tag:"collapsible_panel",
      expanded:true,
      background_color:"default",
      header:{
        title:{tag:"plain_text",content:"📄 查看完整回答"},
        background_color:"blue-100"
      },
      elements:[{tag:"div",text:{tag:"lark_md",content:$ans}}]
    }')
  else
    ans_elem=$(jq -n --arg ans "$ans" \
      '{tag:"div",text:{tag:"lark_md",content:$ans}}')
  fi

  jq -n \
    --arg name "$name" \
    --arg q "$q" \
    --arg dur "$dur" \
    --argjson ans_elem "$ans_elem" '{
    schema:"2.0",
    header:{title:{tag:"plain_text",content:("💬 "+$name+" 问")},template:"wathet"},
    config:{streaming_mode:false},
    body:{elements:[
      {tag:"div",text:{tag:"lark_md",content:("> "+$q)}},
      {tag:"hr"},
      $ans_elem,
      {tag:"hr"},
      {tag:"div",text:{tag:"lark_md",
        content:("<font color=grey>:DONE: 耗时 **"+$dur+"**</font>")}}
    ]}
  }'
}

make_error_card() {
  local msg="${1:-抱歉，我暂时无法回答，请稍后再试。}"
  local hint="${2:-}"
  local content="$msg"
  [[ -n "$hint" ]] && content+="\\n\\n💡 _${hint}_"
  jq -n --arg content "$content" '{
    schema:"2.0",
    header:{title:{tag:"plain_text",content:"❌ 出错了"},template:"red"},
    config:{streaming_mode:false},
    body:{elements:[{tag:"markdown",content:$content}]}
  }'
}

make_noperm_card() {
  jq -n '{
    schema:"2.0",
    header:{title:{tag:"plain_text",content:"⛔ 权限不足"},template:"red"},
    config:{streaming_mode:false},
    body:{elements:[{tag:"markdown",content:"抱歉，你没有使用该 Bot 的权限。"}]}
  }'
}

make_success_card() {
  jq -n --arg title "$1" --arg content "$2" '{
    schema:"2.0",
    header:{title:{tag:"plain_text",content:$title},template:"green"},
    config:{streaming_mode:false},
    body:{elements:[{tag:"markdown",content:$content}]}
  }'
}

make_help_card() {
  jq -n '{
    schema:"2.0",
    header:{title:{tag:"plain_text",content:"📖 使用帮助"},template:"blue"},
    config:{streaming_mode:false},
    body:{elements:[
      {tag:"markdown",content:"**可用指令**"},
      {tag:"markdown",content:"| 指令 | 说明 |\n|------|------|\n| `/clear` 或 `清除记忆` | 清除当前会话历史，开启新对话 |\n| `/help` 或 `帮助` | 显示本帮助 |"},
      {tag:"hr"},
      {tag:"markdown",content:"直接发送消息即可与 Claude 对话，**@Bot** 触发。"}
    ]}
  }'
}

# ══════════════════════════════════════════════════════════
#  卡片发送 / 更新
# ══════════════════════════════════════════════════════════

send_card() {
  local t0; t0=$(now_ms)
  local result
  result=$($LARK im +messages-reply \
    --message-id "$1" \
    --msg-type interactive \
    --content "$(printf '%s' "$2" | jq -c .)" \
    --as bot \
    --jq '.data.message_id' \
    2>/dev/null)
  log "send_card: $(format_duration $(( $(now_ms)-t0 )))"
  echo "$result"
}

update_card() {
  [[ -z "$1" ]] && return 1
  local t0; t0=$(now_ms)
  local payload result code
  payload=$(jq -n --argjson card "$2" \
    '{"msg_type":"interactive","content":($card|tojson)}')
  result=$($LARK api PATCH "/open-apis/im/v1/messages/${1}" \
    --data "$payload" \
    --as bot \
    2>/dev/null)
  code=$(printf '%s' "$result" | jq -r '.code // 0' 2>/dev/null)
  log "update_card: $(format_duration $(( $(now_ms)-t0 ))) code=${code}"
  [[ "$code" == "0" ]]
}

# ══════════════════════════════════════════════════════════
#  建立新 Session
# ══════════════════════════════════════════════════════════

_new_session() {
  local output sid
  output=$($CLAUDE_BIN -p \
    --dangerously-skip-permissions \
    --mcp-config "$MCP_CONFIG" \
    --output-format json \
    --system-prompt "$SYSTEM_PROMPT" \
    "." < /dev/null 2>>"$LOG_FILE")
  sid=$(printf '%s' "$output" | jq -r '.session_id // empty' 2>/dev/null)
  echo "$sid"
}

# ══════════════════════════════════════════════════════════
#  Claude 调用
# ══════════════════════════════════════════════════════════

call_claude() {
  local question="$1"
  local session_id="$2"
  local out_file="$3"

  if [[ -z "$session_id" ]]; then
    session_id=$(consume_warmup_session)
    if [[ -n "$session_id" ]]; then
      log "claude: 使用预建session sid=${session_id:0:8}..."
    else
      log "claude: 无预建session，临时建立..."
      local t0; t0=$(now_ms)
      session_id=$(_new_session)
      log "claude: 临时建立完成 ($(format_duration $(( $(now_ms)-t0 )))) sid=${session_id:0:8}..."
    fi
    build_warmup_session &
  fi

  if [[ -z "$session_id" ]]; then
    log "claude: ERROR 无法建立session"
    jq -n '{"text":"","session_id":""}' > "$out_file"
    return
  fi

  log "claude: resume sid=${session_id:0:8}..."
  local t0; t0=$(now_ms)

  local text
  text=$($CLAUDE_BIN -p \
    --dangerously-skip-permissions \
    --mcp-config "$MCP_CONFIG" \
    --resume "$session_id" \
    "${question}" \
    < /dev/null 2>>"$LOG_FILE")

  log "claude: $(format_duration $(( $(now_ms)-t0 ))) chars=${#text}"

  if [[ -z "$text" ]]; then
    log "claude: resume失败(sid=${session_id:0:8})，重建session..."
    local new_sid; new_sid=$(_new_session)
    if [[ -n "$new_sid" ]]; then
      session_id="$new_sid"
      text=$($CLAUDE_BIN -p \
        --dangerously-skip-permissions \
        --mcp-config "$MCP_CONFIG" \
        --resume "$session_id" \
        "${question}" \
        < /dev/null 2>>"$LOG_FILE")
      log "claude: 重建后 chars=${#text}"
      build_warmup_session &
    fi
  fi

  jq -n --arg text "$text" --arg sid "$session_id" \
    '{"text":$text,"session_id":$sid}' > "$out_file"
}

# ══════════════════════════════════════════════════════════
#  消息处理
# ══════════════════════════════════════════════════════════

handle_message() {
  local message_id="$1" sender_id="$2" question="$3" chat_id="$4"
  local start_ms; start_ms=$(now_ms)

  # 特殊指令
  case "$question" in
    /clear|清除记忆)
      session_clear "$chat_id"
      send_card "$message_id" \
        "$(make_success_card "🗑️ 已清除" "对话历史已清除，下一条消息将开启新会话。")" >/dev/null
      build_warmup_session &
      return ;;
    /help|帮助)
      send_card "$message_id" "$(make_help_card)" >/dev/null
      return ;;
  esac

  local session_id; session_id=$(session_get "$chat_id")

  # 读用户名缓存（有则 <1ms）
  local sender_name
  sender_name=$(grep "^${sender_id}=" "$NAME_CACHE" 2>/dev/null \
    | head -1 | cut -d= -f2)
  [[ -z "$sender_name" ]] && sender_name="用户"

  # 读群名缓存（有则 <1ms）
  local group_name
  group_name=$(grep "^${chat_id}=" "$GROUP_CACHE" 2>/dev/null \
    | head -1 | cut -d= -f2)
  [[ -z "$group_name" ]] && group_name="未知群组"

  log "收到 [${group_name}][${sender_name}]$(
    [ -n "$session_id" ] && echo "(续)" || echo "(首次)"
  ): ${question:0:80}"

  local tmp_mid;    tmp_mid=$(mktemp    "$BOT_DIR/.mid.XXXXXX")
  local tmp_claude; tmp_claude=$(mktemp "$BOT_DIR/.claude.XXXXXX")
  local tmp_name;   tmp_name=$(mktemp   "$BOT_DIR/.name.XXXXXX")
  echo "$sender_name" > "$tmp_name"

  trap "rm -f '$tmp_mid' '$tmp_claude' '$tmp_name'" EXIT

  # 并行1：发"思考中"卡片
  (
    local card mid
    card=$(make_thinking_card "$sender_name" "$question")
    mid=$(send_card "$message_id" "$card")
    echo "$mid" > "$tmp_mid"
  ) &
  local card_pid=$!

  # 并行2：异步补全用户名（有缓存则跳过）
  local name_pid=""
  if ! grep -q "^${sender_id}=" "$NAME_CACHE" 2>/dev/null; then
    (
      local name; name=$(get_sender_name "$sender_id")
      echo "$name" > "$tmp_name"
    ) &
    name_pid=$!
  fi

  # 并行3：异步拉取群名（有缓存则跳过）
  local group_pid=""
  if ! grep -q "^${chat_id}=" "$GROUP_CACHE" 2>/dev/null; then
    ( get_group_name "$chat_id" > /dev/null ) &
    group_pid=$!
  fi

  # 构建注入上下文的完整 prompt
  local context_header
  context_header=$(build_context_header \
    "$chat_id" "$sender_id" "$sender_name" "$group_name")
  local full_prompt="${context_header}${question}"

  # 主线程：调用 Claude（与上面并行）
  local call_start; call_start=$(now_ms)
  call_claude "$full_prompt" "$session_id" "$tmp_claude"
  log "Claude耗时: $(format_duration $(( $(now_ms)-call_start )))"

  wait "$card_pid"
  [[ -n "$name_pid"  ]] && wait "$name_pid"
  [[ -n "$group_pid" ]] && wait "$group_pid"

  local reply_msg_id; reply_msg_id=$(cat "$tmp_mid"   2>/dev/null)
  local real_name;    real_name=$(cat    "$tmp_name"  2>/dev/null)
  local result_text;  result_text=$(jq -r '.text // empty'       "$tmp_claude" 2>/dev/null)
  local result_sid;   result_sid=$(jq -r  '.session_id // empty' "$tmp_claude" 2>/dev/null)

  rm -f "$tmp_mid" "$tmp_claude" "$tmp_name"

  [[ -n "$real_name" && "$real_name" != "用户" ]] && sender_name="$real_name"
  [[ -n "$result_sid" ]] && session_set "$chat_id" "$result_sid"

  local total_ms=$(( $(now_ms)-start_ms ))
  local duration; duration=$(format_duration "$total_ms")
  log "完成 [${group_name}][${sender_name}] ${#result_text}字 总耗时${duration}"

  local final_card
  if [[ -z "$result_text" ]]; then
    final_card=$(make_error_card "" "可发送 /clear 重置会话后重试")
  elif [[ "$result_text" == CARD_JSON::* ]]; then
    local card_json="${result_text#CARD_JSON::}"
    if echo "$card_json" | jq empty 2>/dev/null; then
      final_card="$card_json"
      log "CARD_JSON: 使用 Claude 输出的富卡片"
    else
      log "CARD_JSON: JSON 解析失败，降级为文本卡片"
      final_card=$(make_reply_card "$sender_name" "$question" "$result_text" "$duration")
    fi
  else
    final_card=$(make_reply_card "$sender_name" "$question" "$result_text" "$duration")
  fi

  if [[ -n "$reply_msg_id" ]]; then
    update_card "$reply_msg_id" "$final_card" || send_card "$message_id" "$final_card" >/dev/null
  else
    send_card "$message_id" "$final_card" >/dev/null
  fi

  # 发送完成后异步改进 Skill（不阻塞主流程）
  trigger_skill_improve "$question" "$result_text"
}

# ══════════════════════════════════════════════════════════
#  异步 Skill 改进（发送后后台触发，不影响响应速度）
# ══════════════════════════════════════════════════════════

trigger_skill_improve() {
  local question="$1" answer="$2"
  # 只在涉及 lark-cli/缓存/飞书操作的对话后触发
  echo "${answer}${question}" | grep -qiE \
    "lark-cli|bitable|spreadsheet|飞书|cache|groups\.json|users\.json|tokens\.json|chat_id|open_id|feishu.card|schema.*2\.0|collapsible|column_set|CARD_JSON" \
    || return 0
  (
    flock -n 200 || exit 0  # 已有改进任务在跑则跳过
    local now; now=$(date +%s)
    local last; last=$(stat -c %Y "$SKILL_IMPROVE_LOG" 2>/dev/null || echo 0)
    (( now - last < 120 )) && exit 0  # 2 分钟内已改进过则跳过
    echo "[$(date '+%H:%M:%S')] skill_improve: start" >> "$SKILL_IMPROVE_LOG"
    local meta_prompt
    meta_prompt="你是飞书Bot技能文档的维护者。以下是刚完成的一次对话：

【用户问题】
${question}

【Bot回答（前600字）】
${answer:0:600}

请读取并检查这四个技能文件：
- ~/.claude/skills/feishu-lark-cli/SKILL.md
- ~/.claude/skills/feishu-cache/SKILL.md
- ~/.claude/skills/feishu-file-ops/SKILL.md
- ~/.claude/skills/feishu-card/SKILL.md

如果本次对话展示了未记录的 lark-cli 用法、新的错误处理方式、对缓存的改进、或新的卡片组件用法（颜色、组件结构、Emoji 等），请直接更新对应文件（只追加/修正，不删除已有内容，不改变格式）。否则输出 NO_UPDATE。"
    $CLAUDE_BIN -p \
      --dangerously-skip-permissions \
      --mcp-config "$MCP_CONFIG" \
      "$meta_prompt" < /dev/null >> "$SKILL_IMPROVE_LOG" 2>&1
    echo "[$(date '+%H:%M:%S')] skill_improve: done" >> "$SKILL_IMPROVE_LOG"
  ) 200>"$SKILL_IMPROVE_LOCK" &
}

# ══════════════════════════════════════════════════════════
#  事件主循环
# ══════════════════════════════════════════════════════════

event_loop() {
  pkill -f "lark-cli event .subscribe" 2>/dev/null
  sleep 1

  echo $$ > "$PID_FILE"
  trap "rm -f '$PID_FILE'; pkill -f 'lark-cli event .subscribe' 2>/dev/null" EXIT

  log "启动监听 (PID $$)"
  build_warmup_session &

  declare -A processed_ids

  while true; do
    log "连接飞书事件流..."

    while IFS= read -r line; do

      chat_id=$(printf '%s' "$line" | \
        jq -r '.event.message.chat_id // empty' 2>/dev/null)
      [[ -z "$chat_id" ]] && continue

      has_bot=$(printf '%s' "$line" | jq -r --arg oid "$BOT_OPEN_ID" \
        '[.event.message.mentions[]? | select(.id.open_id==$oid)] | length' 2>/dev/null)
      [[ "$has_bot" -lt 1 ]] && continue

      message_id=$(printf '%s' "$line" | \
        jq -r '.event.message.message_id // empty' 2>/dev/null)
      sender_id=$(printf '%s' "$line" | \
        jq -r '.event.sender.sender_id.open_id // empty' 2>/dev/null)
      [[ -z "$message_id" ]] && continue

      [[ -n "${processed_ids[$message_id]+x}" ]] && continue
      processed_ids[$message_id]=1

      if [[ "$sender_id" != "$ALLOWED_SENDER" ]]; then
        send_card "$message_id" "$(make_noperm_card)" >/dev/null
        continue
      fi

      raw=$(printf '%s' "$line" | \
        jq -r '.event.message.content // "{}"' 2>/dev/null)
      question=$(printf '%s' "$raw" | jq -r '.text // ""' 2>/dev/null \
        | sed 's/@[^ ]*//g; s/^[[:space:]]*//; s/[[:space:]]*$//')
      [[ -z "$question" ]] && continue

      handle_message "$message_id" "$sender_id" "$question" "$chat_id" &

    done < <($LARK event +subscribe \
               --event-types im.message.receive_v1 --quiet --as bot 2>/dev/null)

    log "断开，5秒后重连..."
    sleep 5
  done
}

# ══════════════════════════════════════════════════════════
#  管理命令
# ══════════════════════════════════════════════════════════

cmd_start() {
  is_running && { log "已运行 (PID $(cat "$PID_FILE"))"; return; }
  if [[ -z "$LARK_BOT_DAEMON" ]]; then
    export LARK_BOT_DAEMON=1
    nohup "$0" start >> "$LOG_FILE" 2>&1 &
    log "后台启动 (PID $!)，日志: $LOG_FILE"
    return
  fi
  event_loop
}

cmd_stop() {
  if is_running; then
    local pid; pid=$(cat "$PID_FILE")
    kill "$pid" 2>/dev/null
    local i=0
    while kill -0 "$pid" 2>/dev/null && (( i++ < 10 )); do sleep 0.5; done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  fi
  rm -f "$PID_FILE"
  pkill -f "lark-cli event .subscribe" 2>/dev/null
  log "已停止"
}

cmd_status() {
  is_running \
    && log "运行中 (PID $(cat "$PID_FILE"))" \
    || log "未运行"
}

main() {
  case "${1:-start}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_stop; sleep 1; cmd_start ;;
    status)  cmd_status ;;
    *) echo "用法: $0 [start|stop|restart|status]"; exit 1 ;;
  esac
}

main "$@"
