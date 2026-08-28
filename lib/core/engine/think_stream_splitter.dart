// lib/core/engine/think_stream_splitter.dart
// 流式 think 标签分流状态机（四期需求 §2.2）：
// - 消费引擎 token 流，把混合输出分流为 reasoning（思考）/ content（正文）
// - 核心难点：标签可能跨 chunk 边界（"<th" + "ink>"）→ 用 pending 缓冲区，
//   直到能判定不是标签前缀才把缓冲内容归属到当前字段
// - 标签用相邻字面量拼接定义，避免完整标签字面量被工具链转写
// - 首个 close 之后进入完成态：后续同款标签按正文处理（需求 §2.2 不二次切换）
// - 解析在 ChatService（Dart 侧）完成，引擎层不动（grill 决策）；
//   API 服务链路共用同一分流 → OpenAI/Anthropic 响应天然不含 think 标签
import 'dart:async';
import 'dart:math' as math;

/// 分流结果事件：一次回调产出的增量（两者可同时为空）
class ThinkSplitEvent {
  final String reasoningDelta;
  final String contentDelta;
  const ThinkSplitEvent(this.reasoningDelta, this.contentDelta);
}

/// 流式 think 标签状态机。
///
/// 用法：每个 token 到达时调用 [push]，把返回的事件增量追加到对应字段；
/// 流结束时调用 [close] 取回缓冲区残留。
class ThinkStreamSplitter {
  // 相邻字符串字面量在编译期拼接，等价于完整标签
  static const String openTag = '<th' 'ink>';
  static const String closeTag = '</th' 'ink>';

  bool _inThink = false;

  /// 首个 close 已出现：之后不再匹配任何标签（§2.2 不二次切换）
  bool _done = false;

  /// 缓冲区：可能是一个未判定完的标签前缀
  String _pending = '';

  /// 当前是否处于思考态（生成中 UI 判断用）
  bool get isInThink => _inThink;

  /// 流结束/取消时取回缓冲区残留（归属当前态）
  String close() {
    final rest = _pending;
    _pending = '';
    return rest;
  }

  /// 当前缓冲区是否有未判定的标签前缀
  bool get hasPending => _pending.isNotEmpty;

  /// 消费一个 token，返回该 token 产生的增量事件
  ThinkSplitEvent push(String token) {
    if (token.isEmpty) return const ThinkSplitEvent('', '');

    // 完成态：正文直通，不再做标签判定
    if (_done) {
      return ThinkSplitEvent('', token);
    }

    var buffer = _pending + token;
    _pending = '';

    final reasoningOut = StringBuffer();
    final contentOut = StringBuffer();

    while (buffer.isNotEmpty) {
      final tag = _inThink ? closeTag : openTag;
      final idx = buffer.indexOf(tag);

      if (idx == 0) {
        // 标签命中缓冲区头部：切换状态，继续处理剩余部分
        buffer = buffer.substring(tag.length);
        if (_inThink) {
          // 首个 close：进入完成态，剩余缓冲全部直通正文
          // （不能回到 while 循环再匹配，否则同 chunk 内的第二个 open 会二次进思考）
          _inThink = false;
          _done = true;
          if (buffer.isNotEmpty) contentOut.write(buffer);
          buffer = '';
        } else {
          _inThink = true;
        }
        continue;
      }
      if (idx > 0) {
        // 标签前有正文：先输出标签前的部分，再从标签处继续
        _emit(buffer.substring(0, idx), reasoningOut, contentOut);
        buffer = buffer.substring(idx);
        continue;
      }

      // idx < 0（含缓冲短于标签的情况）：完整标签未出现，
      // 但缓冲区尾部可能是标签前缀（跨 chunk 边界）——统一做尾部前缀检测
      var keep = 0;
      final maxKeep = math.min(tag.length - 1, buffer.length);
      for (var k = maxKeep; k > 0; k--) {
        if (tag.startsWith(buffer.substring(buffer.length - k))) {
          keep = k;
          break;
        }
      }
      if (keep == buffer.length) {
        // 整个缓冲都是标签前缀（如单独到达的 "<th"）→ 全部悬置
        _pending = buffer;
      } else if (keep > 0) {
        // 尾部是前缀（如 "abc<th"）：产出前面，尾部悬置
        _emit(
            buffer.substring(0, buffer.length - keep), reasoningOut, contentOut);
        _pending = buffer.substring(buffer.length - keep);
      } else {
        _emit(buffer, reasoningOut, contentOut);
      }
      buffer = '';
    }

    return ThinkSplitEvent(reasoningOut.toString(), contentOut.toString());
  }

  void _emit(String text, StringBuffer reasoning, StringBuffer content) {
    if (text.isEmpty) return;
    if (_inThink) {
      reasoning.write(text);
    } else {
      content.write(text);
    }
  }
}

/// 便捷封装：把原始 token 流转换为分流后的事件流。
/// [onRaw] 透传原始混合流（如需完整落库的调用方使用）。
Stream<ThinkSplitEvent> splitThinkStream(Stream<String> source,
    {void Function(String raw)? onRaw}) async* {
  final splitter = ThinkStreamSplitter();
  await for (final token in source) {
    onRaw?.call(token);
    final event = splitter.push(token);
    if (event.reasoningDelta.isNotEmpty || event.contentDelta.isNotEmpty) {
      yield event;
    }
  }
  // 流结束：缓冲残留归属当前态
  final rest = splitter.close();
  if (rest.isNotEmpty) {
    yield ThinkSplitEvent(
      splitter.isInThink ? rest : '',
      splitter.isInThink ? '' : rest,
    );
  }
}
