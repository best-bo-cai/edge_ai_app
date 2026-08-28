// test/think_splitter_test.dart
// 四期 §2.2/§2.3：think 标签流式分流状态机 + 懒拆分
import 'package:flutter_test/flutter_test.dart';

import 'package:edge_ai_app/core/engine/think_stream_splitter.dart';
import 'package:edge_ai_app/core/models/message.dart';

const open = '<think>';
const close = '</think>';

void main() {
  group('ThinkStreamSplitter 跨 chunk 标签边界', () {
    test('整段一次到达：思考 + 正文', () {
      final s = ThinkStreamSplitter();
      final e = s.push('$open 思考内容 $close 正文内容');
      expect(e.reasoningDelta, ' 思考内容 ');
      expect(e.contentDelta, ' 正文内容');
      expect(s.close(), '');
    });

    test('标签被拆成两个 chunk（"<th" + "ink>"）', () {
      final s = ThinkStreamSplitter();
      // "<think>" 拆三段："<th" | "ink>" ；前缀悬置期间不产出
      final e1 = s.push('<th');
      expect(e1.reasoningDelta, '');
      expect(e1.contentDelta, '');
      final e2 = s.push('ink>思考');
      expect(e2.reasoningDelta, '思考');
      expect(e2.contentDelta, '');
      // "</think>" 拆两段："</th" | "ink>正文"
      final e3 = s.push('</th');
      expect(e3.reasoningDelta, '');
      final e4 = s.push('ink>正文');
      expect(e4.reasoningDelta, '');
      expect(e4.contentDelta, '正文');
    });

    test('正文态尾部像标签前缀但不完整 → 保留待判，非前缀部分先产出', () {
      final s = ThinkStreamSplitter();
      // "abc<th"：abc 立即产出，"<th" 悬置
      final e = s.push('abc<th');
      expect(e.contentDelta, 'abc');
      // 下一 chunk 证明不是标签：悬置部分作为正文产出
      final e2 = s.push('oughtful');
      expect(e2.contentDelta, '<thoughtful');
      expect(e2.reasoningDelta, '');
    });

    test('思考态中标签跨 chunk 切换回正文态', () {
      final s = ThinkStreamSplitter();
      s.push('$open 我在思考');
      final e = s.push('</');
      expect(e.reasoningDelta, '');
      final e2 = s.push('think>好了');
      expect(e2.contentDelta, '好了');
      expect(e2.reasoningDelta, '');
    });

    test('无标签输出：全部进正文，行为与旧版一致', () {
      final s = ThinkStreamSplitter();
      final e = s.push('普通回复，没有任何标签');
      expect(e.reasoningDelta, '');
      expect(e.contentDelta, '普通回复，没有任何标签');
    });

    test('流中断（未闭合 think）：残留归属思考态', () {
      final s = ThinkStreamSplitter();
      s.push('$open 只思考了一半');
      final e = s.push('还没想完');
      expect(e.reasoningDelta, '还没想完');
      final rest = s.close();
      expect(rest, '');
      expect(s.isInThink, isTrue);
    });

    test('关闭后悬置缓冲归属当前态（正文）', () {
      final s = ThinkStreamSplitter();
      s.push('正文结尾出现 <th');
      final rest = s.close();
      expect(rest, '<th');
      expect(s.isInThink, isFalse);
    });

    test('close 之后第二个 open：不二次进入思考（含同 chunk 场景）', () {
      final s = ThinkStreamSplitter();
      // 同一 chunk 内：思考 + close + 正文 + 假 open
      final e = s.push('$open 思考 $close 正文$open 假标签');
      expect(e.reasoningDelta, ' 思考 ');
      expect(e.contentDelta, ' 正文$open 假标签');
      // 后续 chunk 中的假 open 也直通
      final e2 = s.push('尾巴$open');
      expect(e2.contentDelta, '尾巴$open');
      expect(e2.reasoningDelta, '');
    });

    test('空 token：无产出且不破坏状态', () {
      final s = ThinkStreamSplitter();
      final e = s.push('');
      expect(e.reasoningDelta, '');
      expect(e.contentDelta, '');
    });
  });

  group('ThinkSplitter 一次性解析（懒拆分）', () {
    test('标准混合内容', () {
      final r = ThinkSplitter.parse('$open 推理过程 $close 最终答案');
      expect(r.reasoning, ' 推理过程 ');
      expect(r.content, ' 最终答案');
    });

    test('无标签：原样返回 content', () {
      final r = ThinkSplitter.parse('普通内容');
      expect(r.reasoning, '');
      expect(r.content, '普通内容');
    });

    test('未闭合（中断）：全部进 reasoning', () {
      final r = ThinkSplitter.parse('$open 想到一半');
      expect(r.reasoning, ' 想到一半');
      expect(r.content, '');
    });

    test('close 之后出现的第二个 open 标签：按正文处理不再切换', () {
      // 需求 §2.2：正常模型只输出一个思考块；close 之后的 open 按字面正文
      final r = ThinkSplitter.parse('$open 思考 $close 正文$open 假标签');
      expect(r.reasoning, ' 思考 ');
      expect(r.content, ' 正文$open 假标签');
    });

    test('未闭合且 open 前有正文：正文保留不丢弃', () {
      final r = ThinkSplitter.parse('前置正文$open 思考到一半');
      expect(r.reasoning, ' 思考到一半');
      expect(r.content, '前置正文');
    });
  });

  group('ChatMessage.splitLegacy 懒拆分', () {
    test('assistant 旧混合消息被拆分', () {
      final msg = ChatMessage.assistant('$open 思考 $close 回答');
      final split = ChatMessage.splitLegacy(msg);
      expect(split.reasoning, ' 思考 ');
      expect(split.content, ' 回答');
    });

    test('无标签消息原样返回（同一实例语义）', () {
      final msg = ChatMessage.assistant('普通回答');
      final split = ChatMessage.splitLegacy(msg);
      expect(split.reasoning, '');
      expect(split.content, '普通回答');
    });

    test('user 消息不拆分', () {
      final msg = ChatMessage.user('$open 不会出现 $close 但按用户消息处理');
      final split = ChatMessage.splitLegacy(msg);
      expect(split.reasoning, '');
      expect(split.content, contains(open));
    });

    test('fromJson 懒拆分兜底（旧版 JSON 无 reasoning 字段）', () {
      final json = {
        'id': 'm1',
        'role': 'assistant',
        'content': '$open 老思考 $close 老回答',
        'timestamp': DateTime(2026, 1, 1).toIso8601String(),
        'isStreaming': false,
      };
      final msg = ChatMessage.fromJson(json);
      expect(msg.reasoning, ' 老思考 ');
      expect(msg.content, ' 老回答');
    });

    test('toJson/fromJson reasoning 序列化往返', () {
      final msg = ChatMessage.assistant('回答', reasoning: '思考');
      final restored = ChatMessage.fromJson(msg.toJson());
      expect(restored.reasoning, '思考');
      expect(restored.content, '回答');
    });
  });

  group('splitThinkStream 流封装', () {
    test('事件流正确聚合 + 结尾残留', () async {
      final events = await splitThinkStream(
        Stream.fromIterable(['$open 思', '考 $close', '正文', '结尾 <th']),
      ).toList();
      final reasoning = events.map((e) => e.reasoningDelta).join();
      final content = events.map((e) => e.contentDelta).join();
      expect(reasoning, ' 思考 ');
      expect(content, '正文结尾 <th');
    });
  });
}
