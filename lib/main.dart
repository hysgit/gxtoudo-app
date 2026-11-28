import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'app_lock.dart';
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
    desktop: Platform.isWindows,
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
      appLock: Platform.isAndroid || Platform.isIOS
          ? AppLock(controller.repository)
          : null,
      onReminder: controller.desktop ? null : reminders.request,
      onResume: reminders.queue,
    ),
  );
}
