## 架构                                                                                                                                                                      
                                                                                                                                                                            
飞书群消息                                                                                                                                                                   
    → lark-cli event +subscribe（事件监听）                 
    → lark_sweet_bot.sh（消息过滤 / 会话管理）                                                                                                                                 
    → claude CLI --resume（带上下文调用 Claude）                                                                                                                               
    → lark-cli im +messages-send（发卡片回复）                                                                                                                                 
                                                                                                                                                                            
Claude 具备三个 Skill，对话结束后异步自我改进：                                                                                                                              
- **feishu-lark-cli**：lark-cli 完整操作指南                                                                                                                                 
- **feishu-cache**：缓存读写规范                                                                                                                                             
- **feishu-file-ops**：文件操作安全规范                                                                                                                                      
                                                                                                                                                                            
## 前置依赖                                                                                                                                                                  
                                                                                                                                                                            
| 依赖 | 版本 | 说明 |                                                                                                                                                       
|------|------|------|                                    
| [Claude Code CLI](https://github.com/anthropics/claude-code) | 最新 | `claude` 命令 |                                                                                      
| [lark-cli](https://github.com/larksuite/cli) | ≥ 1.0.7 | 飞书 API 命令行工具 |                                                                                             
| `jq` | ≥ 1.6 | JSON 处理 |                                                                                                                                                 
| `flock` | 系统自带 | 并发锁（Linux util-linux） |                                                                                                                          
| `python3` | ≥ 3.6 | 构建卡片 JSON |                                                                                                                                        
                                                                                                                                                                            
## 飞书应用配置                                                                                                                                                              
                                                                                                                                                                            
1. 在[飞书开放平台](https://open.feishu.cn)创建自建应用                                                                                                                      
2. 开启以下权限：                                         
    - `im:message`（收发消息）                                                                                                                                                
    - `im:chat`（读取群信息）                                                                                                                                                 
    - `contact:user.base:readonly`（查询用户信息）                                                                                                                            
    - `wiki:wiki:readonly`（读知识库，可选）                                                                                                                                  
    - `sheets:spreadsheet:readonly`（读表格，可选）                                                                                                                           
    - `bitable:app:readonly`（读多维表格，可选）                                                                                                                              
3. 订阅事件：`im.message.receive_v1`                                                                                                                                         
4. 记录应用的 **App ID** 和 **App Secret**                                                                                                                                   
                                                                                                                                                                            
## 安装                                                                                                                                                                      
                                                                                                                                                                            
```bash                                                                                                                                                                      
# 1. 克隆仓库                                             
git clone <repo_url>                                                                                                                                                         
cd <repo>                                                                                                                                                                    
                                                                                                                                                                            
# 2. 安装 lark-cli                                                                                                                                                           
npm install -g @larksuiteoapi/lark-cli   # 或参考官方文档                                                                                                                    
                                                                                                                                                                            
# 3. 配置 lark-cli（user 和 bot 两个身份都要登录）                                                                                                                           
lark-cli auth login --as user                                                                                                                                                
lark-cli auth login --as bot                                                                                                                                                 
                                                            
# 4. 安装 Claude Code CLI                                                                                                                                                    
# 参考 https://github.com/anthropics/claude-code          
                                                                                                                                                                            
# 5. 安装 Skills（复制到 Claude 配置目录）                                                                                                                                   
cp -r skills/feishu-lark-cli  ~/.claude/skills/
cp -r skills/feishu-cache     ~/.claude/skills/                                                                                                                              
cp -r skills/feishu-file-ops  ~/.claude/skills/           
                                                                                                                                                                            
配置脚本
                                                                                                                                                                            
编辑 lark_sweet_bot.sh 顶部的以下变量：                   

# lark-cli 可执行路径（which lark-cli 查看）
LARK=/path/to/lark-cli                                                                                                                                                       

# Bot 的 open_id（在飞书开放平台「应用信息」页查看机器人的 open_id）                                                                                                         
BOT_OPEN_ID=ou_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx           
                                                                                                                                                                            
# 允许使用 Bot 的用户 open_id（目前只支持单个用户）       
# 用 lark-cli contact +search-user --query "姓名" --as user 查询                                                                                                             
ALLOWED_SENDER=ou_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx                                                                                                                           

# Claude Code CLI 的 MCP 配置文件路径                                                                                                                                        
MCP_CONFIG=/path/to/.claude/mcp.json                      
                                                                                                                                                                            
启动                                                                                                                                                                         
                                                                                                                                                                            
chmod +x lark_sweet_bot.sh                                                                                                                                                   
                                                                                                                                                                            
# 启动（后台 daemon）                                                                                                                                                        
./lark_sweet_bot.sh start                                                                                                                                                    
                                                                                                                                                                            
# 查看状态                                                                                                                                                                   
./lark_sweet_bot.sh status                                                                                                                                                   
                                                                                                                                                                            
# 查看日志                                                                                                                                                                   
tail -f ~/feishu_bot/bot.log
                                                                                                                                                                            
# 停止 / 重启                                                                                                                                                                
./lark_sweet_bot.sh stop                                                                                                                                                     
./lark_sweet_bot.sh restart                                                                                                                                                  
                                                                                                                                                                            
在群里使用                                                                                                                                                                   
                                                                                                                                                                            
- @ Bot + 消息：与 Claude 对话，支持多轮上下文                                                                                                                               
- /clear 或发送清除记忆：清除当前群的对话历史             
- /help 或发送帮助：显示使用说明                                                                                                                                             
                                                                                                                                                                            
缓存目录结构                                                                                                                                                                 
                                                                                                                                                                            
~/feishu_bot/                                                                                                                                                                
├── cache/                                                                                                                                                                   
│   ├── tokens.json   # spreadsheet / bitable / wiki token
│   ├── groups.json   # 群组信息（chat_id + 群名）                                                                                                                           
│   └── users.json    # 用户信息（open_id + 姓名/邮箱/部门）                                                                                                                 
├── name_cache        # open_id=姓名，脚本自动维护                                                                                                                           
├── group_cache       # chat_id=群名，脚本自动维护                                                                                                                           
├── sessions          # 各群的 Claude session_id                                                                                                                             
├── bot.log           # 运行日志                                                                                                                                             
└── skill_improve.log # Skill 自动改进日志                                                                                                                                   
                                                                                                                                                                            
权限控制                                                                                                                                                                     
                                                            
当前版本通过 ALLOWED_SENDER 白名单控制访问，只有指定用户 @ Bot 才会响应，其他人收到「权限不足」提示。                                                                        

注意事项                                                                                                                                                                     
                                                            
- MCP_CONFIG 需包含 lark-cli 相关 MCP server 配置，Claude 才能调用飞书工具                                                                                                   
- Bot 使用 --dangerously-skip-permissions 启动 Claude，请确保运行环境安全，不要在公网服务器上直接暴露
- Skill 自动改进功能会在对话结束后异步调用 Claude，不影响响应速度，日志写入 skill_improve.log    
