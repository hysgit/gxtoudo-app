import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'controller.dart';
import 'home.dart';
import 'reminders.dart';
import 'repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = TodoController(SqliteRepository());
  final reminders = TodoReminders(controller);
  unawaited(controller.initialize());
  unawaited(
    reminders.start().catchError((Object error, StackTrace trace) {
      debugPrint('Reminder initialization failed: $error');
    }),
  );
  runApp(
    TodoApp(
      controller,
      onReminder: reminders.request,
      onResume: reminders.queue,
    ),
  );
}
