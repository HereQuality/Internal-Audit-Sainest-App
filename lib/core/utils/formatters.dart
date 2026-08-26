import 'package:intl/intl.dart';
import 'package:timeago/timeago.dart' as timeago;

class Formatters {
  Formatters._();

  static final _date = DateFormat('dd MMM yyyy');
  static final _dateTime = DateFormat('dd MMM yyyy, hh:mm a');

  static String date(dynamic value) {
    final parsed = _parse(value);
    if (parsed == null) return '-';
    return _date.format(parsed);
  }

  static String dateTime(dynamic value) {
    final parsed = _parse(value);
    if (parsed == null) return '-';
    return _dateTime.format(parsed);
  }

  static String relative(dynamic value) {
    final parsed = _parse(value);
    if (parsed == null) return '';
    return timeago.format(parsed);
  }

  static DateTime? _parse(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value.toLocal();
    return DateTime.tryParse(value.toString())?.toLocal();
  }

  static String initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }
}
