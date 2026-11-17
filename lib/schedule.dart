import 'dart:math';

import 'domain.dart';

const repeatNames = ['不重复', '每天', '每周', '每个工作日', '每月', '每年'];
const priorities = ['普通', '重要', '紧急', '重要且紧急'];
const alarms = {
  -1: '无提醒',
  0: '开始时',
  300: '提前 5 分钟',
  600: '提前 10 分钟',
  1800: '提前 30 分钟',
  3600: '提前 1 小时',
  86400: '提前 1 天',
};

const secondsPerDay = 86400;
DateTime dayOnly(DateTime date) => DateTime(date.year, date.month, date.day);
DateTime addDays(DateTime date, int days) =>
    DateTime(date.year, date.month, date.day + days);
int seconds(DateTime date) => date.millisecondsSinceEpoch ~/ 1000;
DateTime localTime(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
String pad(int value) => value.toString().padLeft(2, '0');
String clock(DateTime value) => '${pad(value.hour)}:${pad(value.minute)}';
String dayLabel(DateTime value) => '${value.month}月${value.day}日';
int _calendarIndex(DateTime date) =>
    DateTime.utc(date.year, date.month, date.day).millisecondsSinceEpoch ~/
    86400000;

int repeatKind(Fields? repeat) {
  if (integer(repeat?['repeat_start_day']) > 0) return 1;
  if (integer(repeat?['repeat_start_week']) > 0) {
    return repeat?['weekday'] == '0234560' ? 3 : 2;
  }
  if (integer(repeat?['repeat_start_month']) > 0) return 4;
  return integer(repeat?['repeat_start_year']) > 0 ? 5 : 0;
}

Fields recurrence(int kind, int start, int end) {
  final date = localTime(start);
  final weekday = date.weekday % 7;
  final result = <String, dynamic>{
    'repeat_start': start,
    'repeat_end': end,
    'repeat_count': 0,
    'status': 0,
    'repeat_start_day': 0,
    'repeat_start_week': 0,
    'repeat_start_month': 0,
    'repeat_start_year': 0,
    'day_interval': 1,
    'week_interval': 1,
    'month_interval': 1,
    'year_interval': 1,
    'month': 0,
    'day': 0,
    'weekday': '0000000',
  };
  switch (kind) {
    case 1:
      result.addAll({
        'repeat_start_day': seconds(dayOnly(date)),
        'day_interval': secondsPerDay,
      });
    case 2:
    case 3:
      result.addAll({
        'repeat_start_week': seconds(addDays(date, -weekday)),
        'week_interval': secondsPerDay * 7,
        'weekday': kind == 3
            ? '0234560'
            : List.generate(7, (i) => i == weekday ? i + 1 : 0).join(),
      });
    case 4:
      result.addAll({
        'repeat_start_year': date.year,
        'repeat_start_month': date.month,
        'day': date.day,
      });
    case 5:
      result.addAll({
        'repeat_start_year': date.year,
        'month': date.month,
        'day': date.day,
      });
  }
  return result;
}

int occurs(int start, Fields? repeat, DateTime day) {
  if (start <= 0) return 0;
  final first = localTime(start);
  final elapsed = _calendarIndex(day) - _calendarIndex(first);
  if (elapsed < 0) return 0;
  final instance = seconds(
    DateTime(
      day.year,
      day.month,
      day.day,
      first.hour,
      first.minute,
      first.second,
    ),
  );
  final end = integer(repeat?['repeat_end']);
  if (end > 0 && instance > end) return 0;
  final count = integer(repeat?['repeat_count']);
  final monthDay = min(
    integer(repeat?['day'], first.day),
    DateTime(day.year, day.month + 1, 0).day,
  );
  final years = day.year - first.year;
  final months = years * 12 + day.month - first.month;
  final mask = text(repeat?['weekday']);
  final firstDay = first.weekday % 7;
  final week = (elapsed + firstDay) ~/ 7;
  final weekInterval = max(
    1,
    integer(repeat?['week_interval']) ~/ (7 * secondsPerDay),
  );
  final dayInterval = max(1, integer(repeat?['day_interval']) ~/ secondsPerDay);
  final monthInterval = max(1, integer(repeat?['month_interval']));
  final yearInterval = max(1, integer(repeat?['year_interval']));
  final kind = repeatKind(repeat);
  final matches = switch (kind) {
    1 =>
      elapsed % dayInterval == 0 &&
          (count == 0 || elapsed ~/ dayInterval < count),
    2 || 3 =>
      mask.length == 7 &&
          mask[day.weekday % 7] != '0' &&
          week % weekInterval == 0 &&
          (count == 0 ||
              _weeklyCount(mask, firstDay, elapsed, weekInterval) <= count),
    4 =>
      day.day == monthDay &&
          months % monthInterval == 0 &&
          (count == 0 || months ~/ monthInterval < count),
    5 =>
      day.day == monthDay &&
          day.month == integer(repeat?['month'], first.month) &&
          years % yearInterval == 0 &&
          (count == 0 || years ~/ yearInterval < count),
    _ => elapsed == 0,
  };
  return matches ? instance : 0;
}

int _weeklyCount(String mask, int firstDay, int elapsed, int interval) {
  final last = firstDay + elapsed;
  final lastWeek = last ~/ 7;
  if (lastWeek == 0) {
    return mask.substring(firstDay, last + 1).replaceAll('0', '').length;
  }
  final first = mask.substring(firstDay).replaceAll('0', '').length;
  final middle = (lastWeek - 1) ~/ interval * mask.replaceAll('0', '').length;
  final partial = lastWeek % interval == 0
      ? mask.substring(0, last % 7 + 1).replaceAll('0', '').length
      : 0;
  return first + middle + partial;
}
