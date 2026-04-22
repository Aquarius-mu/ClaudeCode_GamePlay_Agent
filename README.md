# Feishu_bot_CLI · Claude Code GamePlay Agent

> 部署在开发机上的 Claude Code 飞书对话助手，专为游戏项目策划 / QA / 运营设计。

---

## 能做什么

- **案子协作** — @ Bot 审阅需求、整理思路、@相关人员跟进
- **游戏后台运维** — 自然语言发 GM 指令、批量操作区服、拷贝角色，无需登录后台
- **飞书操作** — 发消息、读文档/多维表格、搜用户 open_id，全程 lark-cli 完成
- **富卡片回复** — schema 2.0 全组件（表格、折叠面板、多列布局、@提及），超长自动折叠

---

## 架构

```
飞书群消息（@ Bot）
→ lark-cli event +subscribe
→ Feishu_bot.sh（会话管理 / 并发优化 / 卡片构建）
→ Claude Code CLI --resume（带上下文调用）
→ lark-cli im +messages-send（卡片回复）
```

**Feishu_bot.sh 关键特性**

| 特性 | 说明 |
|------|------|
| 预建 Session 池 | 回复后异步预热下一个 session，消除冷启动延迟 |
| 群隔离 Session | 每个 chat_id 独立 Claude session |
| 思考态占位 | 先发「思考中…」卡片，完成后 PATCH 原地更新 |
| CARD_JSON:: 协议 | Claude 输出 `CARD_JSON::{json}` 前缀，Bot 直接用作最终卡片 |
| 超长回复折叠 | >1500 字符自动用 `collapsible_panel` 包裹 |
| Skill 自动改进 | 对话结束后异步触发，Claude 自主优化 Skill 文件 |

---

## Skills

| Skill | 职责 |
|-------|------|
| `feishu-lark-cli` | lark-cli 完整操作指南 + 避坑规则 |
| `feishu-card` | schema 2.0 卡片构建与发送 |
| `feishu-cache` | 缓存读写，并发安全 |
| `feishu-file-ops` | 文件操作白名单 |

---

## GM Server（游戏后台 MCP）

内置 MCP 服务，Claude 直接操作游戏后台：

| 工具 | 说明 |
|------|------|
| `list_zones` | 查询区服列表（5 分钟缓存，支持关键词过滤） |
| `search_gm_commands` | 搜索 GM 指令，支持中英文，最多 20 条 |
| `send_gm_command` | 向指定区服发送 GM 指令 |
| `batch_send_gm_command` | 并发批量发送，最多 100 个区，并发上限 20 |
| `copy_role` | 跨区拷贝角色（支持 dev/and/ali/cnf/cnt 环境） |

配置文件 `~/.claude/mcp-servers/gm_server/config.json`：

```json
{
  "base_url": "http://your-gm-backend/",
  "token": "your_token",
  "nick": "your_nick",
  "gm_cmd_js_path": "/path/to/gmweb/webback/js/gm_cmd.js"
}
```

> `token` 与 `username/password` 二选一；`gm_cmd_js_path` 配置后支持指令搜索。

---

## 飞书卡片速查（schema 2.0）

**组件**：`div` / `markdown` / `img` / `table` / `hr` / `column_set` / `collapsible_panel` / `button` / `input`

**@提及**：卡片 lark_md 内用 `<at id="ou_xxx">姓名</at>`；文本消息用 `<at user_id="ou_xxx">姓名</at>`

**颜色**：格式 `{色}-{层级}`，如 `blue-100`、`green-200`、`grey`；禁用无后缀色名（报错 11310）

**Emoji**：`:DONE:` `:OK:` `:WAITING:` `:ERROR:` `:FIRE:` `:ROCKET:` `:THUMBSUP:` 等；Unicode 🎉 ✅ ❌ 可直接用

> ⚠️ `note` tag 已在 schema 2.0 移除（报错 200861），替代：`{"tag":"div","text":{"tag":"lark_md","content":"<font color=grey>备注</font>"}}`

---

## lark-cli 常用命令

```bash
lark-cli im +chat-search --query "群名" --as user
lark-cli contact +search-user --query "姓名" --as user
lark-cli im chat.members get --params '{"chat_id":"oc_xxx"}' --as user --page-all
lark-cli wiki spaces get_node --params '{"token":"wiki_token"}' --as user
lark-cli sheets +export --spreadsheet-token xxx --file-extension xlsx --output-path ./out.xlsx
```

**构建卡片 JSON 必须用 heredoc**（含反引号时 `$(python3 -c "...")` 会崩）：

```bash
CARD=$(python3 - <<'PYEOF'
import json
card = {"schema":"2.0","header":{"title":{"tag":"plain_text","content":"标题"},"template":"blue"},"body":{"elements":[]}}
print(json.dumps(card))
PYEOF
)
lark-cli im +messages-send --chat-id oc_xxx --msg-type interactive --content "$CARD" --as bot
```

---

## 安装与配置

```bash
# 克隆仓库 & 安装依赖
git clone <repo_url> && cd <repo>
npm install -g @larksuiteoapi/lark-cli

# 登录（user 和 bot 都要）
lark-cli auth login --as user
lark-cli auth login --as bot

# 安装 Skills
cp -r skills/feishu-* ~/.claude/skills/
```

编辑 `Feishu_bot.sh` 顶部：

```bash
LARK=/path/to/lark-cli
BOT_OPEN_ID=ou_xxx          # 机器人 open_id
ALLOWED_SENDER=ou_xxx       # 允许使用的用户 open_id
MCP_CONFIG=/path/to/.claude/mcp.json
```

飞书应用需开启权限：`im:message` `im:chat` `contact:user.base:readonly`，订阅事件 `im.message.receive_v1`。

---

## 启动

```bash
./Feishu_bot.sh start    # 后台启动
./Feishu_bot.sh status   # 查看状态
./Feishu_bot.sh stop     # 停止
tail -f ~/feishu_bot/bot.log # 查看日志
```

群内指令：`@ Bot + 消息` 对话 | `/clear` 清除上下文 | `/help` 帮助

---

## 注意事项

- Bot 使用 `--dangerously-skip-permissions` 启动，请勿在公网直接暴露
- `ALLOWED_SENDER` 白名单外的用户会收到「权限不足」提示
- Skill 自动改进异步执行，不影响响应速度，日志写入 `~/feishu_bot/skill_improve.log`
