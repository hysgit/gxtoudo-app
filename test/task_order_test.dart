import 'package:flutter_test/flutter_test.dart';
import 'package:gxtodo/domain.dart';
import 'package:gxtodo/tasks.dart';

Task task(String uid, int planned, {int? completed}) =>
    Task(Item(table: Tables.task, team: 10, uid: uid, data: {'name': uid}), [
      Item(
        table: Tables.schedule,
        team: 10,
        uid: 'schedule-$uid',
        data: {'start_at': planned},
      ),
      if (completed != null)
        Item(
          table: Tables.check,
          team: 10,
          uid: 'check-$uid',
          data: {'user_id': 1, 'status': 1, 'check_at': completed},
        ),
    ], 1);

void main() {
  test('已完成按实际完成时间倒序，与计划时间先后无关', () {
    final recent = task('刚完成的旧计划', 100, completed: 900);
    final earlier = task('先完成的新计划', 500, completed: 600);
    final values = [(earlier, 500), (recent, 100)]
      ..sort((a, b) => compareTaskEntries(a, b, 1));
    expect(values.map((entry) => entry.$1.uid), ['刚完成的旧计划', '先完成的新计划']);
  });

  test('未完成按计划时间正序，未安排的最后，完成区位于未完成之后', () {
    final values = [
      (task('已完成', 50, completed: 999), 50),
      (task('较晚', 300), 300),
      (task('未安排', 0), 0),
      (task('较早', 100), 100),
    ]..sort((a, b) => compareTaskEntries(a, b, 1));
    expect(values.map((entry) => entry.$1.uid), ['较早', '较晚', '未安排', '已完成']);
  });
}
