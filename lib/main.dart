import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'controller.dart';
import 'home.dart';
import 'reminders.dart';
import 'repository.dart';
import 'background_sync.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = TodoController(
    SqliteRepository(),
    onLocalChange: queueBackgroundSync,
  );
  unawaited(
    initializeBackgroundSync().catchError((Object error) {
      debugPrint('Background sync initialization failed: $error');
    }),
  );
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
