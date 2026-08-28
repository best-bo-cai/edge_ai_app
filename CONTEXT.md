# 词汇表（ ubiquitous language ）

本文件只放领域术语定义，不放实现细节。

## 会话（Conversation）

一次持续的多轮对话，拥有独立的消息时间线、创建时间与标题。用户可新建、切换、重命名、删除会话。App 内同一时刻只有一个「当前会话」。

## 消息（Message）

会话内的一条发言，角色为 user / assistant / system。流式生成中的 assistant 消息处于「生成中」状态，生成结束后固化。

## 模型（Model）

一个已下载或导入的 GGUF 模型文件，具有 id、名称、路径、量化等级等属性。同一时刻引擎最多加载一个模型。

## 会话绑定模型（Conversation-Model Binding）

每个会话在创建时绑定一个模型。在旧会话中继续发消息时，引擎自动热切换回该会话绑定的模型。

## 模型参数（Model Parameters）

每个模型独有的一套推理参数，分两类：
- 采样参数：temperature、top_k、top_p、repeat_penalty、max_tokens——每次生成即时生效
- 上下文参数：n_ctx、n_threads——改动后需重载模型生效

## API 服务（API Service）

内嵌于 App 的本地 HTTP 服务，向手机上其他 app 与局域网内其他设备提供 OpenAI / Anthropic 兼容接口。由用户手动开关，开启时监听所有网络接口、以 Android 前台服务保活。

## 接入地址（Access URL）

调用方配置 `base_url` 用的完整地址（`http://<IP>:<端口>/v1`）。手机可能同时持有多个 IP（WiFi、热点、蜂窝），接入地址按接口逐一列出，WiFi 优先。

## 消息（ChatMessage）

对话的基本单元，含角色（用户/助手/系统）与内容。助手消息由「思考内容」与「正文」两部分组成。

## 思考内容（Reasoning）

模型输出中 `..` 与 `..` 标签之间的推理过程文本。生成期间实时展示，生成完成后折叠；仅供查看，不参与复制。

## 正文（Content）

模型输出的最终回答部分（`..` 标签之后）。助手消息的正文可复制；用户消息不可复制（输入框历史可回查）。

## API 调用日志（API Call Log）

外部 API 请求的流水记录（时间、端点、token 数、请求与响应内容）。API 请求不产生会话，只记入调用日志，在独立的日志列表页查看。
