import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'controller.dart';
import 'repository.dart';

const refreshTask = 'net.icycloud.fdtodolist.sync.refresh';
const processingTask = 'net.icycloud.fdtodolist.sync.processing';
Future<void>? _setup;

@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, input) async {
    WidgetsFlutterBinding.ensureInitialized();
    final controller = TodoController(SqliteRepository(), automatic: false);
    try {
      await controller.initialize();
      if (!controller.ready) return false;
      await controller.sync();
      return true;
    } catch (_) {
      // The durable queue survives process termination and is retried later.
      return false;
    } finally {
      controller.dispose();
    }
  });
}

Future<void> initializeBackgroundSync() => _setup ??= _initialize();

Future<void> _initialize() async {
  if (!Platform.isAndroid && !Platform.isIOS) return;
  await Workmanager().initialize(backgroundDispatcher);
  await Workmanager().registerPeriodicTask(
    refreshTask,
    refreshTask,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
  );
}

Future<void> queueBackgroundSync() async {
  await initializeBackgroundSync();
  if (Platform.isIOS) {
    await Workmanager().registerProcessingTask(
      processingTask,
      processingTask,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  } else if (Platform.isAndroid) {
    await Workmanager().registerOneOffTask(
      processingTask,
      processingTask,
      existingWorkPolicy: ExistingWorkPolicy.keep,
      constraints: Constraints(networkType: NetworkType.connected),
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(seconds: 30),
    );
  }
}
