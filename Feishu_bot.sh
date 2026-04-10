#!/bin/bash
# ══════════════════════════════════════════════════════════
#  飞书 Claude Bot
# ══════════════════════════════════════════════════════════

LARK=/home/jiadongsun/nodejs/node22.15/bin/lark-cli
BOT_OPEN_ID=ou_7b2a74cf8aa3907ed7366f3f277662ff
ALLOWED_SENDER=ou_f8760ccaca19d1453f3128bef06e0b3c
BOT_DIR="$HOME/feishu_bot"
SESSION_FILE="$BOT_DIR/sessions"
SESSION_LOCK="$BOT_DIR/sessions.lock"
NAME_CACHE="$BOT_DIR/name_cache"
NAME_CACHE_LOCK="$BOT_DIR/name_cache.lock"
WARMUP_SESSION="$BOT_DIR/warmup_session"
WARMUP_LOCK="$BOT_DIR/warmup_session.lock"
PID_FILE="$BOT_DIR/bot.pid"
LOG_FILE="$BOT_DIR/bot.log"

CLAUDE_BIN=claude
MCP_CONFIG=/data/home/jiadongsun/.claude/mcp.json

SYSTEM_PROMPT="你是一个对话助手。请直接回答用户的问题。只有当用户明确要求查询、搜索或执行某个操作时，才考虑使用工具；普通对话、问候、知识问答等请直接回答，不要主动调用任何工具。"

mkdir -p "$BOT_DIR"

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
#  用户名缓存（文件级，子进程共享）
# ══════════════════════════════════════════════════════════

get_sender_name() {
  local sender_id="$1"
  local cached
  cached=$(grep "^${sender_id}=" "$NAME_CACHE" 2>/dev/null | head -1 | cut -d= -f2)
  if [[ -n "$cached" ]]; then echo "$cached"; return; fi
  local name
  name=$($LARK contact +get-user \
    --user-id "$sender_id" --user-id-type open_id \
    --as user 2>/dev/null | jq -r '.data.user.name // ""') || name=""
  [[ -z "$name" ]] && name="用户"
  (
    flock -x 200
    grep -q "^${sender_id}=" "$NAME_CACHE" 2>/dev/null \
      || echo "${sender_id}=${name}" >> "$NAME_CACHE"
  ) 200>"$NAME_CACHE_LOCK"
  echo "$name"
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

make_thinking_card() {
  jq -n --arg name "$1" --arg q "$2" '{
    schema:"2.0",
    header:{title:{tag:"plain_text",content:("💬 "+$name+" 问")},template:"grey"},
    config:{streaming_mode:true},
    body:{elements:[{tag:"markdown",content:("> "+$q+"\n\n⏳ 思考中...")}]}
  }'
}

make_reply_card() {
  jq -n --arg name "$1" --arg answer "$2" --arg dur "$3" '{
    schema:"2.0",
    header:{title:{tag:"plain_text",content:("💬 "+$name+" 问")},template:"blue"},
    config:{streaming_mode:false},
    body:{elements:[{tag:"markdown",content:($answer+"\n\n---\n✅ 耗时 **"+$dur+"**")}]}
  }'
}

make_error_card() {
  jq -n --arg msg "${1:-抱歉，我暂时无法回答，请稍后再试。}" '{
    schema:"2.0",
    header:{title:{tag:"plain_text",content:"❌ 出错了"},template:"red"},
    config:{streaming_mode:false},
    body:{elements:[{tag:"markdown",content:$msg}]}
  }'
}

make_noperm_card() {
  jq -n '{
    schema:"2.0",
    header:{title:{tag:"plain_text",content:"⛔ 权限不足"},template:"red"},
    config:{streaming_mode:false},
    body:{elements:[{tag:"markdown",content:"抱歉，你没有对应权限。"}]}
  }'
}

# ══════════════════════════════════════════════════════════
#  卡片发送 / 更新
# ══════════════════════════════════════════════════════════

send_card() {
  local t0; t0=$(now_ms)
  local result
  result=$($LARK im +messages-reply \
    --message-id "$1" --msg-type interactive \
    --content "$(printf '%s' "$2" | jq -c .)" \
    --as bot 2>/dev/null | jq -r '.data.message_id // empty')
  log "send_card: $(format_duration $(( $(now_ms)-t0 )))"
  echo "$result"
}

update_card() {
  [[ -z "$1" ]] && return
  local t0; t0=$(now_ms)
  local payload
  payload=$(jq -n --argjson card "$2" \
    '{"msg_type":"interactive","content":($card|tojson)}')
  $LARK api PATCH "/open-apis/im/v1/messages/${1}" \
    --data "$payload" --as bot 2>/dev/null
  log "update_card: $(format_duration $(( $(now_ms)-t0 )))"
}

# ══════════════════════════════════════════════════════════
#  建立新 Session（带系统提示词）
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
#  · 系统提示词只在建立 session 时注入一次
#  · resume 时不传 --system-prompt
#  · 不传 --max-turns（会显著增加耗时）
# ══════════════════════════════════════════════════════════

call_claude() {
  local question="$1"
  local session_id="$2"
  local out_file="$3"

  # 无 session 时取预建的（或临时建立）
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
    # 立刻补充下一个预建session
    build_warmup_session &
  fi

  if [[ -z "$session_id" ]]; then
    log "claude: ERROR 无法建立session"
    jq -n '{"text":"","session_id":""}' > "$out_file"
    return
  fi

  # Resume 极速调用
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

  # Resume 失败（空输出）时自动重建
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
      send_card "$message_id" "$(jq -n '{
        schema:"2.0",
        header:{title:{tag:"plain_text",content:"🗑️ 已清除"},template:"green"},
        config:{streaming_mode:false},
        body:{elements:[{tag:"markdown",
          content:"对话历史已清除，下一条消息将开启新会话。"}]}
      }')" >/dev/null
      build_warmup_session &
      return ;;
  esac

  # 读会话
  local session_id; session_id=$(session_get "$chat_id")

  # 查用户名缓存
  local sender_name
  sender_name=$(grep "^${sender_id}=" "$NAME_CACHE" 2>/dev/null \
    | head -1 | cut -d= -f2)
  [[ -z "$sender_name" ]] && sender_name="用户"

  log "收到 [$sender_name]$([ -n "$session_id" ] && echo "(续)" || echo "(首次)"): ${question:0:80}"

  # 临时文件（并行子进程间传递结果）
  local tmp_mid;    tmp_mid=$(mktemp    "$BOT_DIR/.mid.XXXXXX")
  local tmp_claude; tmp_claude=$(mktemp "$BOT_DIR/.claude.XXXXXX")
  local tmp_name;   tmp_name=$(mktemp   "$BOT_DIR/.name.XXXXXX")
  echo "$sender_name" > "$tmp_name"

  # 并行1：发"思考中"卡片
  (
    local card mid
    card=$(make_thinking_card "$sender_name" "$question")
    mid=$(send_card "$message_id" "$card")
    echo "$mid" > "$tmp_mid"
  ) &
  local card_pid=$!

  # 并行2：首次查用户名（有缓存则跳过）
  local name_pid=""
  if ! grep -q "^${sender_id}=" "$NAME_CACHE" 2>/dev/null; then
    (
      local name
      name=$($LARK contact +get-user \
        --user-id "$sender_id" --user-id-type open_id \
        --as user 2>/dev/null | jq -r '.data.user.name // ""') || name=""
      [[ -z "$name" ]] && name="用户"
      echo "$name" > "$tmp_name"
      (
        flock -x 200
        grep -q "^${sender_id}=" "$NAME_CACHE" 2>/dev/null \
          || echo "${sender_id}=${name}" >> "$NAME_CACHE"
      ) 200>"$NAME_CACHE_LOCK"
    ) &
    name_pid=$!
  fi

  # 主线程：调用 Claude（与上面并行）
  local call_start; call_start=$(now_ms)
  call_claude "$question" "$session_id" "$tmp_claude"
  log "Claude耗时: $(format_duration $(( $(now_ms)-call_start )))"

  # 等待并行任务
  wait "$card_pid"
  [[ -n "$name_pid" ]] && wait "$name_pid"

  local reply_msg_id; reply_msg_id=$(cat "$tmp_mid"  2>/dev/null)
  local real_name;    real_name=$(cat    "$tmp_name" 2>/dev/null)
  local result_text;  result_text=$(jq -r '.text // empty'       "$tmp_claude" 2>/dev/null)
  local result_sid;   result_sid=$(jq -r  '.session_id // empty' "$tmp_claude" 2>/dev/null)

  rm -f "$tmp_mid" "$tmp_claude" "$tmp_name"

  [[ -n "$real_name" ]] && sender_name="$real_name"
  [[ -n "$result_sid" ]] && session_set "$chat_id" "$result_sid"

  local total_ms=$(( $(now_ms)-start_ms ))
  local duration; duration=$(format_duration "$total_ms")
  log "完成 [$sender_name] ${#result_text}字 总耗时${duration}"

  local final_card
  if [[ -z "$result_text" ]]; then
    final_card=$(make_error_card)
  else
    final_card=$(make_reply_card "$sender_name" "$result_text" "$duration")
  fi

  if [[ -n "$reply_msg_id" ]]; then
    update_card "$reply_msg_id" "$final_card"
  else
    send_card "$message_id" "$final_card" >/dev/null
  fi
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

      chat_id=$(printf '%s' "$line" | jq -r '.event.message.chat_id // empty' 2>/dev/null)
      [[ -z "$chat_id" ]] && continue

      has_bot=$(printf '%s' "$line" | jq -r --arg oid "$BOT_OPEN_ID" \
        '[.event.message.mentions[]? | select(.id.open_id==$oid)] | length' 2>/dev/null)
      [[ "$has_bot" -lt 1 ]] && continue

      message_id=$(printf '%s' "$line" | jq -r '.event.message.message_id // empty' 2>/dev/null)
      sender_id=$(printf '%s'  "$line" | jq -r '.event.sender.sender_id.open_id // empty' 2>/dev/null)
      [[ -z "$message_id" ]] && continue

      [[ -n "${processed_ids[$message_id]+x}" ]] && continue
      processed_ids[$message_id]=1

      if [[ "$sender_id" != "$ALLOWED_SENDER" ]]; then
        send_card "$message_id" "$(make_noperm_card)" >/dev/null
        continue
      fi

      raw=$(printf '%s' "$line" | jq -r '.event.message.content // "{}"' 2>/dev/null)
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
