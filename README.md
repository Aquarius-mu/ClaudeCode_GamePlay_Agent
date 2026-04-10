# Feishu_bot_CLI
Claude Code + Feishu_bot_CLI  GamePlayAgent
- 部署在远程linux终端/开发机器上面的Claude Code 对话助手  
- 接入飞书，借助飞书机器人，使用流式卡片，可以帮你审阅提取案子关键信息，艾特人员询问，帮你整理案子思路。  
- 使用缓存，保留对话session上下文记录，执行更加迅速准确。  
- 借助Harness Engineering执行平时gm指令发送，查看日志，发送服务器，查看服务器状态操作。解放双手，辅助策划、qa、运营更加了解项目。

# 1. 首先在本地Claude Code 安装FeiShu CLI

# 2. 在Claude Code 本地运行脚本
bash Feishu_bot.sh start

# 3. Harness Engineering
主要由.claude 下面 CLAUDE.md, skills, mcp-servers 驱动
这里由于涉及了项目隐秘信息就不保存了

# 4. 运行效果
## 1. 读取飞书案子，自动询问策划补充需求
<img width="1352" height="220" alt="image" src="https://github.com/user-attachments/assets/8b9ed0c6-935a-4d91-aae9-89f3e16cebd8" />

## 2. 读取飞书表格，自动化发版本艾特相关人员，缓存sessionid,保留上下文记忆
<img width="935" height="536" alt="image" src="https://github.com/user-attachments/assets/8038182b-2d58-4314-b1f9-2adab9366ac2" />
<img width="751" height="297" alt="image" src="https://github.com/user-attachments/assets/94c2ffcc-f92b-4921-88c0-137f90458790" />

## 3. 辅助策划，测试执行gm指令，发放最新服务器
<img width="682" height="186" alt="image" src="https://github.com/user-attachments/assets/52585757-d2d6-4f97-bca6-1abce36c496c" />
<img width="868" height="238" alt="image" src="https://github.com/user-attachments/assets/6bf96d60-b69c-482d-b476-13f79b6558bf" />
<img width="690" height="187" alt="image" src="https://github.com/user-attachments/assets/e28d7495-95f3-44de-bd72-bcc85f596f1b" />

## 4. 远程书写代码，帮你执行操作
<img width="811" height="505" alt="image" src="https://github.com/user-attachments/assets/fc7bd974-8c36-47b4-9087-59dec7d5b0d5" />


