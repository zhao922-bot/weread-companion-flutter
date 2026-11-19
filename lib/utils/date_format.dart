import 'package:intl/intl.dart';

/// 统一日期时间格式化，避免各页面手写字符串拼接。
abstract final class ReadAmberDateFormat {
  static final _dateTime = DateFormat('yyyy-MM-dd HH:mm');
  static final _date = DateFormat('yyyy-MM-dd');
  static final _fileStamp = DateFormat('yyyyMMdd_HHmmss');

  static String formatTimestamp(int seconds) =>
      _dateTime.format(DateTime.fromMillisecondsSinceEpoch(seconds * 1000));

  static String formatDate(int seconds) =>
      _date.format(DateTime.fromMillisecondsSinceEpoch(seconds * 1000));

  static String formatMillis(int millis) =>
      _dateTime.format(DateTime.fromMillisecondsSinceEpoch(millis));

  static String formatDateTime(DateTime dt) => _dateTime.format(dt);

  static String formatFileStamp(DateTime dt) => _fileStamp.format(dt);
}
