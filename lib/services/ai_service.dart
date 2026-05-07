import 'dart:convert';
import 'package:dio/dio.dart';
import 'config.dart';

/// AI 服务 — 调用 OpenAI 兼容 API（DeepSeek/Qwen/MiniMax 等）
class AIService {
  final AppConfig config;
  late Dio _dio;

  AIService({required this.config}) {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
    ));
  }

  /// 是否已配置 AI
  bool get isConfigured => config.apiKey.isNotEmpty && config.baseUrl.isNotEmpty;

  /// 通用 API 调用
  Future<String?> _callApi(String prompt, {String system = ''}) async {
    if (!isConfigured) return null;

    final messages = <Map<String, String>>[];
    if (system.isNotEmpty) {
      messages.add({'role': 'system', 'content': system});
    }
    messages.add({'role': 'user', 'content': prompt});

    try {
      final resp = await _dio.post(
        '${config.baseUrl}/chat/completions',
        options: Options(
          headers: {
            'Authorization': 'Bearer ${config.apiKey}',
            'Content-Type': 'application/json',
          },
        ),
        data: {
          'model': config.modelName,
          'messages': messages,
          'temperature': 0.7,
          'max_tokens': 2000,
        },
      );

      final data = resp.data;
      return data['choices'][0]['message']['content'] as String?;
    } catch (e) {
      return null;
    }
  }

  /// 根据划线生成书籍摘要
  Future<String?> summarizeBook(String title, String author, List<String> highlights) async {
    final highlightsText = highlights.take(30).map((h) => '- $h').join('\n');
    final prompt = '''请根据以下书籍的划线内容，生成一份简洁的书籍摘要：

📖 《$title》 - $author

划线内容：
$highlightsText

请包含：
1. 核心主题（一句话概括）
2. 主要观点（3-5个要点）
3. 金句提炼（最精彩的3句话）
4. 一句话读后感''';

    return _callApi(prompt, system: '你是一位专业的读书笔记助手，擅长从划线中提炼书籍精华。');
  }

  /// 分析阅读习惯
  Future<String?> analyzeReading(List<String> bookTitles, int bookmarkCount) async {
    final bookList = bookTitles.take(20).map((t) => '- $t').join('\n');
    final prompt = '''请分析以下阅读数据，给出阅读习惯洞察：

已读书籍：
$bookList

总划线数: $bookmarkCount

请分析：
1. 阅读偏好类型
2. 知识结构特点
3. 推荐下一步阅读方向''';

    return _callApi(prompt, system: '你是一位阅读顾问，擅长分析阅读习惯并给出建议。');
  }

  /// 为金句生成解读
  Future<String?> interpretQuote(String text, String bookTitle) async {
    final prompt = '''请为以下金句写一段简短的解读（100字以内）：

「$text」
——《$bookTitle》''';

    return _callApi(prompt, system: '你是一位文学评论家，擅长解读经典语句的深层含义。');
  }
}
