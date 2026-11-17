import 'package:material_ui/material_ui.dart';

import 'appearance.dart';
import 'backup_page.dart';
import 'catalog.dart';
import 'cloud_pages.dart';
import 'controller.dart';
import 'domain.dart';
import 'schedule.dart';
import 'task_editor.dart';
import 'tasks.dart';

class TodoApp extends StatelessWidget {
  const TodoApp(this.controller, {super.key, this.onReminder, this.onResume});
  final TodoController controller;
  final Future<void> Function()? onReminder;
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '高效Todo',
    debugShowCheckedModeBanner: false,
    theme: todoTheme(),
    locale: const Locale('zh', 'CN'),
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    home: Workbench(controller, onReminder: onReminder, onResume: onResume),
  );
}

class Workbench extends StatefulWidget {
  const Workbench(this.controller, {super.key, this.onReminder, this.onResume});
  final TodoController controller;
  final Future<void> Function()? onReminder;
  final VoidCallback? onResume;
  @override
  State<Workbench> createState() => _WorkbenchState();
}

class _WorkbenchState extends State<Workbench> with WidgetsBindingObserver {
  TodoController get controller => widget.controller;
  int tab = 0, filter = 0;
  DateTime selected = dayOnly(DateTime.now());
  String project = '', tag = '', query = '';
  bool archive = false, search = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.onResume?.call();
  }

  Future<T?> go<T>(Widget screen) =>
      Navigator.push<T>(context, MaterialPageRoute(builder: (_) => screen));

  Future<void> sync() async {
    if (controller.account == null) {
      await go(AccountPage(controller));
      return;
    }
    try {
      final count = await controller.sync();
      if (mounted) message(context, count == 0 ? '同步完成' : '已同步 $count 条改动');
    } catch (error) {
      if (mounted) message(context, error);
    }
  }

  void editTask(Task? task, {DateTime? day}) => go(
    TaskEditor(
      controller: controller,
      team: task?.team ?? controller.team,
      task: task,
      project: project,
      day: day,
      onReminder: widget.onReminder,
    ),
  );

  void editCatalog(int table, [Item? item]) =>
      go(CatalogEditor(controller, controller.team, table, item: item));

  void selectTab(int value) => setState(() {
    tab = value;
    filter = 0;
    project = '';
    tag = '';
    search = false;
    query = '';
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (!controller.ready) {
        return Scaffold(
          body: Center(
            child: controller.initializationError == null
                ? const CircularProgressIndicator()
                : Text('打开本地数据失败：${controller.initializationError}'),
          ),
        );
      }
      final tasks = taskList(
        controller.data,
        controller.identity,
        controller.team,
      );
      return Scaffold(
        appBar: AppBar(
          title: Text(
            controller.space.name.isEmpty ? '高效Todo' : controller.space.name,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          actions: [
            IconButton(
              tooltip: search ? '关闭搜索' : '搜索',
              icon: Icon(search ? Icons.close : Icons.search),
              onPressed: () => setState(() {
                search = !search;
                query = '';
              }),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                onPressed: controller.syncing ? null : sync,
                icon: controller.syncing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        controller.account == null
                            ? Icons.person_outline
                            : Icons.sync,
                        size: 19,
                      ),
                label: Text(controller.account == null ? '登录' : '同步'),
              ),
            ),
          ],
        ),
        drawer: drawer(),
        body: search
            ? renderSearch(tasks)
            : switch (tab) {
                0 => renderTimeline(tasks),
                1 => renderList(tasks),
                2 => renderProjects(),
                _ => renderNotes(),
              },
        floatingActionButton: FloatingActionButton.extended(
          icon: const Icon(Icons.add),
          label: Text(switch (tab) {
            2 => '新建项目',
            3 => '新建便签',
            _ => '新建任务',
          }),
          onPressed: () {
            if (tab == 2 || tab == 3) {
              editCatalog(tab == 2 ? Tables.project : Tables.note);
            } else {
              editTask(null, day: tab == 0 ? selected : null);
            }
          },
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: selectTab,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.calendar_today_outlined),
              selectedIcon: Icon(Icons.calendar_month),
              label: '时间轴',
            ),
            NavigationDestination(
              icon: Icon(Icons.checklist_outlined),
              label: '任务',
            ),
            NavigationDestination(
              icon: Icon(Icons.folder_outlined),
              selectedIcon: Icon(Icons.folder),
              label: '项目',
            ),
            NavigationDestination(
              icon: Icon(Icons.sticky_note_2_outlined),
              label: '便签',
            ),
          ],
        ),
      );
    },
  );

  Widget drawer() => Drawer(
    child: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 14, 14, 12),
            child: Text(
              '我的空间',
              style: TextStyle(fontSize: 27, fontWeight: FontWeight.w700),
            ),
          ),
          for (final space in controller.spaces)
            ListTile(
              title: Text(space.name),
              leading: Icon(
                space.type == 1 ? Icons.person_outline : Icons.groups_outlined,
              ),
              selected: controller.team == space.id,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              onTap: () {
                Navigator.pop(context);
                selectTab(0);
                controller.selectSpace(space.id);
              },
            ),
          const Divider(height: 22),
          _drawerItem(
            Icons.groups_outlined,
            '团队空间',
            () => go(
              controller.account == null
                  ? AccountPage(controller)
                  : TeamsPage(controller),
            ),
          ),
          _drawerItem(
            Icons.mail_outline,
            '消息',
            () => go(
              controller.account == null
                  ? AccountPage(controller)
                  : InboxPage(controller),
            ),
          ),
          _drawerItem(Icons.sell_outlined, '标签与地点', () async {
            final value = await go<String>(
              TaxonomyPage(controller, controller.team),
            );
            if (mounted && value != null) {
              setState(() {
                tab = 1;
                filter = 0;
                tag = value;
                project = '';
                search = false;
              });
            }
          }),
          _drawerItem(
            Icons.bar_chart,
            '完成统计',
            () => go(StatisticsPage(controller, controller.team)),
          ),
          _drawerItem(
            Icons.file_present_outlined,
            '数据备份',
            () => go(BackupPage(controller)),
          ),
          _drawerItem(
            Icons.account_circle_outlined,
            '账户与服务端',
            () => go(AccountPage(controller)),
          ),
          if (controller.syncStatus.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                controller.syncStatus,
                style: const TextStyle(color: muted),
              ),
            ),
        ],
      ),
    ),
  );

  ListTile _drawerItem(IconData icon, String label, VoidCallback open) =>
      ListTile(
        leading: Icon(icon),
        title: Text(label),
        onTap: () {
          Navigator.pop(context);
          open();
        },
      );

  bool matches(Task task) =>
      (project.isEmpty || task.project == project) &&
      (tag.isEmpty || task.tags.any((item) => item.data['tag_name'] == tag));

  int timelineTime(Task task, DateTime day) {
    final direct = task.on(day);
    if (direct > 0 ||
        task.repeat != null ||
        task.start <= 0 ||
        task.end <= task.start) {
      return direct;
    }
    final today = dayOnly(day);
    return today.isAfter(dayOnly(localTime(task.start))) &&
            !today.isAfter(dayOnly(localTime(task.end)))
        ? task.start
        : 0;
  }

  Widget renderTimeline(List<Task> tasks) {
    final today = dayOnly(DateTime.now());
    final monday = addDays(selected, 1 - selected.weekday);
    final visible =
        tasks
            .where(matches)
            .map((task) => (task, timelineTime(task, selected)))
            .where((entry) => entry.$2 > 0)
            .toList()
          ..sort(
            (a, b) => a.$2 == b.$2
                ? b.$1.rank.compareTo(a.$1.rank)
                : a.$2.compareTo(b.$2),
          );
    return PageContent(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
      children: [
        Row(
          children: [
            Expanded(
              child: TextButton.icon(
                style: TextButton.styleFrom(alignment: Alignment.centerLeft),
                onPressed: () async {
                  final value = await showDatePicker(
                    context: context,
                    initialDate: selected,
                    firstDate: DateTime(1970),
                    lastDate: DateTime(2099, 12, 31),
                  );
                  if (value != null && mounted) {
                    setState(() => selected = dayOnly(value));
                  }
                },
                icon: const Icon(Icons.calendar_month_outlined, size: 19),
                label: Text(
                  '${selected.year}年 ${selected.month}月',
                  style: const TextStyle(fontSize: 17),
                ),
              ),
            ),
            TextButton(
              onPressed: () => setState(() => selected = today),
              child: const Text('今天'),
            ),
            IconButton(
              tooltip: '上一周',
              onPressed: () => setState(() => selected = addDays(selected, -7)),
              icon: const Icon(Icons.chevron_left),
            ),
            IconButton(
              tooltip: '下一周',
              onPressed: () => setState(() => selected = addDays(selected, 7)),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                for (var index = 0; index < 7; index++)
                  Expanded(
                    child: calendarDay(addDays(monday, index), tasks, index),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          '${selected == today ? '今天 · ' : ''}${dayLabel(selected)}',
          style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w700),
        ),
        if (visible.isEmpty) const EmptyContent('这一天没有安排'),
        ...sections(visible),
      ],
    );
  }

  Widget calendarDay(DateTime date, List<Task> tasks, int index) {
    final active = date == selected;
    final scheduled = tasks.any(
      (task) => timelineTime(task, date) > 0 && matches(task),
    );
    return Semantics(
      button: true,
      selected: active,
      label: dayLabel(date),
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => selected = date),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: active ? const Color(0xffe6effb) : null,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              Text(
                '一二三四五六日'[index],
                style: const TextStyle(color: muted, fontSize: 12),
              ),
              Text(
                '${date.day}',
                style: TextStyle(
                  fontSize: 19,
                  color: active ? blue : ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                width: 4,
                height: 4,
                decoration: BoxDecoration(
                  color: scheduled ? blue : Colors.transparent,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget renderList(List<Task> tasks) {
    final today = dayOnly(DateTime.now());
    final visible =
        tasks.where(matches).map((task) => (task, task.listTime(today))).where((
          entry,
        ) {
          final done = entry.$1.done(controller.identity.user, entry.$2);
          return switch (filter) {
            1 => !done,
            2 => done,
            3 => entry.$2 == 0,
            _ => true,
          };
        }).toList()..sort(
          (a, b) => (a.$2 == 0 ? 1 << 62 : a.$2).compareTo(
            b.$2 == 0 ? 1 << 62 : b.$2,
          ),
        );
    return PageContent(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
      children: [
        if (project.isNotEmpty || tag.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: InputChip(
              label: Text(
                project.isNotEmpty
                    ? controller.data
                              .get(controller.team, Tables.project, project)
                              ?.name ??
                          '项目'
                    : '#$tag',
              ),
              onDeleted: () => setState(() {
                project = '';
                tag = '';
              }),
            ),
          ),
        Wrap(
          spacing: 8,
          children: [
            for (final (index, title) in ['全部', '待完成', '已完成', '未安排'].indexed)
              ChoiceChip(
                label: Text(title),
                selected: filter == index,
                onSelected: (_) => setState(() => filter = index),
              ),
          ],
        ),
        if (visible.isEmpty) const EmptyContent('没有符合条件的任务'),
        ...sections(visible),
      ],
    );
  }

  List<Widget> sections(List<(Task, int)> entries) {
    final pending = <(Task, int)>[], checked = <(Task, int)>[];
    for (final entry in entries) {
      (entry.$1.done(controller.identity.user, entry.$2) ? checked : pending)
          .add(entry);
    }
    return [
      for (final (label, rows) in [('待完成', pending), ('已完成', checked)])
        if (rows.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 14, 0, 8),
            child: Text(
              '$label  ${rows.length}',
              style: const TextStyle(color: muted, fontWeight: FontWeight.w600),
            ),
          ),
          for (final (task, occurrence) in rows) taskCard(task, occurrence),
        ],
    ];
  }

  Widget taskCard(Task task, int occurrence) {
    final done = task.done(controller.identity.user, occurrence);
    final when = occurrence == 0
        ? '未安排'
        : '${tab == 0 ? '' : '${dayLabel(localTime(occurrence))} '}${task.allDay ? '全天' : clock(localTime(occurrence))}';
    final meta = [
      when,
      if (task.repeat != null) repeatNames[repeatKind(task.repeat?.data)],
      if (task.tags.isNotEmpty) '#${text(task.tags.first.data['tag_name'])}',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Card(
        child: ListTile(
          contentPadding: const EdgeInsets.only(left: 10, right: 14),
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 4,
                height: 34,
                decoration: BoxDecoration(
                  color: rankColors[task.rank - 1],
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              Tooltip(
                message: done ? '标记未完成' : '完成任务',
                child: Checkbox(
                  value: done,
                  onChanged: (_) async {
                    try {
                      await controller.mutate(
                        (data, who) => toggleTask(
                          data,
                          who,
                          task.team,
                          task.uid,
                          occurrence,
                        ),
                      );
                    } catch (error) {
                      if (mounted) message(context, error);
                    }
                  },
                ),
              ),
            ],
          ),
          title: Text(
            task.name,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              decoration: done ? TextDecoration.lineThrough : null,
            ),
          ),
          subtitle: Text(
            meta.join('  ·  '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: task.alert == null
              ? null
              : const Icon(Icons.notifications_none, color: muted, size: 18),
          onTap: () => editTask(task),
        ),
      ),
    );
  }

  Widget renderProjects() {
    final projects = controller.data
        .list(controller.team, Tables.project)
        .where((item) => (integer(item.data['status']) != 0) == archive)
        .toList();
    return PageContent(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('活动项目')),
            ButtonSegment(value: true, label: Text('已归档')),
          ],
          selected: {archive},
          onSelectionChanged: (value) => setState(() => archive = value.single),
        ),
        const SizedBox(height: 14),
        if (projects.isEmpty)
          EmptyContent(
            archive ? '没有归档项目' : '还没有项目',
            icon: Icons.folder_outlined,
          ),
        for (final item in projects)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card(
              child: ListTile(
                leading: Icon(Icons.folder, color: projectColor(item)),
                title: Text(item.name),
                subtitle: text(item.data['intro']).isEmpty
                    ? null
                    : Text(
                        text(item.data['intro']),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                onTap: () => setState(() {
                  tab = 1;
                  filter = 0;
                  project = item.uid;
                  tag = '';
                }),
                trailing: IconButton(
                  tooltip: '编辑项目',
                  onPressed: () => editCatalog(Tables.project, item),
                  icon: const Icon(Icons.edit_outlined),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget renderNotes() {
    final notes = controller.data.list(controller.team, Tables.note).toList()
      ..sort((a, b) => b.edited.compareTo(a.edited));
    return PageContent(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
        if (notes.isEmpty)
          const EmptyContent('还没有便签', icon: Icons.sticky_note_2_outlined),
        for (final note in notes) noteCard(note),
      ],
    );
  }

  Widget noteCard(Item note) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Card(
      child: ListTile(
        leading: const Icon(Icons.sticky_note_2_outlined, color: blue),
        title: Text(note.name, maxLines: 5, overflow: TextOverflow.ellipsis),
        onTap: () => editCatalog(Tables.note, note),
      ),
    ),
  );

  Widget renderSearch(List<Task> tasks) {
    final needle = query.trim().toLowerCase();
    final results = tasks.where(
      (task) => '${task.name} ${task.detail(1)} ${task.detail(2)}'
          .toLowerCase()
          .contains(needle),
    );
    final notes = controller.data
        .list(controller.team, Tables.note)
        .where((item) => item.name.toLowerCase().contains(needle));
    final projects = controller.data
        .list(controller.team, Tables.project)
        .where((item) => item.name.toLowerCase().contains(needle));
    return PageContent(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
        TextFormField(
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '搜索任务、项目或便签',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (value) => setState(() => query = value),
        ),
        const SizedBox(height: 12),
        if (needle.isNotEmpty) ...[
          for (final task in results)
            taskCard(task, task.listTime(dayOnly(DateTime.now()))),
          for (final note in notes) noteCard(note),
          for (final item in projects)
            Card(
              child: ListTile(
                title: Text(item.name),
                leading: const Icon(Icons.folder_outlined),
                onTap: () => editCatalog(Tables.project, item),
              ),
            ),
          if (results.isEmpty && notes.isEmpty && projects.isEmpty)
            const EmptyContent('没有找到匹配内容', icon: Icons.search),
        ],
      ],
    );
  }
}
