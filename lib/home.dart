import 'package:material_ui/material_ui.dart';

import 'appearance.dart';
import 'backup_page.dart';
import 'catalog.dart';
import 'cloud_pages.dart';
import 'controller.dart';
import 'domain.dart';
import 'note_editor.dart';
import 'notes.dart';
import 'schedule.dart';
import 'task_editor.dart';
import 'tasks.dart';
import 'space_swipe.dart';
import 'bill_editor.dart';
import 'ledger_page.dart';
import 'record_history_page.dart';
import 'ai_page.dart';

class TodoApp extends StatelessWidget {
  const TodoApp(this.controller, {super.key, this.onReminder, this.onResume});
  final TodoController controller;
  final Future<void> Function(String mode)? onReminder;
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '高效Todo',
    debugShowCheckedModeBanner: false,
    theme: todoTheme(),
    locale: const Locale('zh', 'CN'),
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    home: ListenableBuilder(
      listenable: controller,
      builder: (context, _) =>
          controller.desktop && controller.ready && controller.account == null
          ? desktopAccountLogin(controller)
          : Workbench(controller, onReminder: onReminder, onResume: onResume),
    ),
  );
}

class Workbench extends StatefulWidget {
  const Workbench(this.controller, {super.key, this.onReminder, this.onResume});
  final TodoController controller;
  final Future<void> Function(String mode)? onReminder;
  final VoidCallback? onResume;
  @override
  State<Workbench> createState() => _WorkbenchState();
}

class _WorkbenchState extends State<Workbench> with WidgetsBindingObserver {
  TodoController get controller => widget.controller;
  int tab = 0, filter = 0;
  DateTime selected = dayOnly(DateTime.now());
  String tag = '', query = '';
  bool search = false;
  bool _calendarExpanded = false;
  double _calendarDrag = 0;
  NoteSection notesSection = NoteSection.quick;
  String noteFolder = '';
  bool drawerOpen = false;

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
    if (state == AppLifecycleState.resumed) {
      widget.onResume?.call();
      controller.resume();
      if (mounted) setState(() {});
    }
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
      day: day,
      onReminder: widget.onReminder,
    ),
  );

  void editNote(Item? note) => go(
    NoteEditor(
      controller,
      note?.team ?? controller.team,
      note: note,
      section: notesSection,
      parentFolder: currentNotebookFolder?.uid ?? '',
    ),
  );
  void editBill(Item? bill) =>
      go(BillEditor(controller, bill?.team ?? controller.team, bill: bill));

  void openAiRecord(Fields reference) {
    final team = integer(reference['team_id']);
    final table = integer(reference['table']);
    final uid = text(reference['uid']);
    final row = controller.spaces.any((space) => space.id == team)
        ? controller.data.get(team, table, uid)
        : null;
    if (row == null) {
      message(context, '本机没有这条记录，请同步后重试');
      return;
    }
    switch (table) {
      case Tables.task:
        final task = findTask(controller.data, controller.identity, team, uid);
        if (task != null) editTask(task);
      case Tables.bill:
        editBill(row);
      case Tables.note:
        editNote(row);
    }
  }

  void selectTab(int value) => setState(() {
    tab = value;
    filter = 0;
    tag = '';
    search = false;
    query = '';
  });

  void switchSpace(int direction) {
    final spaces = controller.spaces;
    if (spaces.length < 2) return;
    final current = spaces.indexWhere((space) => space.id == controller.team);
    final next = ((current < 0 ? 0 : current) + direction) % spaces.length;
    setState(() {
      filter = 0;
      tag = '';
      search = false;
      query = '';
    });
    controller.selectSpace(spaces[next].id);
  }

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
      final serviceTab = tab == 2;
      return SpaceSwipe(
        enabled: !serviceTab && !drawerOpen && controller.spaces.length > 1,
        onSwitch: switchSpace,
        child: Scaffold(
          backgroundColor: Colors.white,
          appBar: AppBar(
            backgroundColor: Colors.white,
            toolbarHeight: tab == 3 ? 44 : null,
            title: Text(
              tab == 2
                  ? 'AI 对话'
                  : controller.space.name.isEmpty
                  ? '高效Todo'
                  : controller.space.name,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            actions: [
              if (!serviceTab)
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
          drawerEnableOpenDragGesture: false,
          onDrawerChanged: (value) => setState(() => drawerOpen = value),
          body: KeyedSubtree(
            key: ValueKey(
              serviceTab ? controller.identity.scope : controller.team,
            ),
            child: search
                ? renderSearch(tasks)
                : switch (tab) {
                    0 => renderList(tasks),
                    1 => renderTimeline(tasks),
                    2 => AiPage(
                      controller,
                      onLogin: () => go(AccountPage(controller)),
                      openRecord: openAiRecord,
                    ),
                    3 => LedgerPage(
                      controller,
                      controller.team,
                      onEdit: editBill,
                    ),
                    _ => renderNotes(),
                  },
          ),
          floatingActionButton: serviceTab
              ? null
              : FloatingActionButton(
                  tooltip: switch (tab) {
                    3 => '新建账单',
                    4 => notesSection == NoteSection.quick ? '新建便签' : '新建记事本',
                    _ => '新建任务',
                  },
                  child: const Icon(Icons.add),
                  onPressed: () {
                    if (tab == 3) {
                      editBill(null);
                    } else if (tab == 4) {
                      editNote(null);
                    } else {
                      editTask(null, day: tab == 1 ? selected : null);
                    }
                  },
                ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: selectTab,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.checklist_outlined),
                label: '任务',
              ),
              NavigationDestination(
                icon: Icon(Icons.calendar_today_outlined),
                selectedIcon: Icon(Icons.calendar_month),
                label: '时间轴',
              ),
              NavigationDestination(
                icon: Icon(Icons.auto_awesome_outlined),
                selectedIcon: Icon(Icons.auto_awesome),
                label: 'AI',
              ),
              NavigationDestination(
                icon: Icon(Icons.account_balance_wallet_outlined),
                selectedIcon: Icon(Icons.account_balance_wallet),
                label: '记账',
              ),
              NavigationDestination(
                icon: Icon(Icons.sticky_note_2_outlined),
                label: '便签',
              ),
            ],
          ),
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
            Icons.delete_outline,
            '回收站',
            () => go(RecycleBinPage(controller, controller.team)),
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
    final first = DateTime(selected.year, selected.month);
    final start = _calendarExpanded
        ? addDays(first, 1 - first.weekday)
        : monday;
    final monthDays = DateTime(selected.year, selected.month + 1, 0).day;
    final weeks = _calendarExpanded
        ? (first.weekday - 1 + monthDays + 6) ~/ 7
        : 1;
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
    final calendarBody = Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        key: ValueKey(_calendarExpanded ? 'month-calendar' : 'week-calendar'),
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_calendarExpanded)
            Row(
              children: [
                for (final label in '一二三四五六日'.split(''))
                  Expanded(
                    child: Center(
                      child: Text(
                        label,
                        style: const TextStyle(color: muted, fontSize: 12),
                      ),
                    ),
                  ),
              ],
            ),
          for (var row = 0; row < weeks; row++)
            Row(
              children: [
                for (var column = 0; column < 7; column++)
                  Expanded(
                    child: calendarDay(
                      addDays(start, row * 7 + column),
                      tasks,
                      column,
                      showWeekday: !_calendarExpanded,
                    ),
                  ),
              ],
            ),
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 6, bottom: 2),
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ),
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
              tooltip: _calendarExpanded ? '上一月' : '上一周',
              onPressed: () => changeCalendarPage(-1),
              icon: const Icon(Icons.chevron_left),
            ),
            IconButton(
              tooltip: _calendarExpanded ? '下一月' : '下一周',
              onPressed: () => changeCalendarPage(1),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        Semantics(
          label: _calendarExpanded ? '月历，上滑收起为周历' : '周历，下滑展开为月历',
          onIncrease: () => setCalendarExpanded(true),
          onDecrease: () => setCalendarExpanded(false),
          child: GestureDetector(
            key: const ValueKey('timeline-calendar'),
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (_) => _calendarDrag = 0,
            onVerticalDragUpdate: (details) =>
                _calendarDrag += details.primaryDelta ?? 0,
            onVerticalDragEnd: (details) {
              final velocity = details.primaryVelocity ?? 0;
              if (_calendarDrag.abs() >= 36 || velocity.abs() >= 450) {
                setCalendarExpanded(
                  _calendarDrag.abs() >= 36 ? _calendarDrag > 0 : velocity > 0,
                );
              }
              _calendarDrag = 0;
            },
            onVerticalDragCancel: () => _calendarDrag = 0,
            child: Card(
              child: MediaQuery.disableAnimationsOf(context)
                  ? calendarBody
                  : AnimatedSize(
                      alignment: Alignment.topCenter,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      child: calendarBody,
                    ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (visible.isEmpty) const EmptyContent('这一天没有安排'),
        ...sections(visible),
      ],
    );
  }

  void setCalendarExpanded(bool expanded) {
    if (_calendarExpanded != expanded) {
      setState(() => _calendarExpanded = expanded);
    }
  }

  void changeCalendarPage(int direction) {
    setState(() {
      if (_calendarExpanded) {
        final last = DateTime(selected.year, selected.month + direction + 1, 0);
        selected = DateTime(
          selected.year,
          selected.month + direction,
          selected.day.clamp(1, last.day),
        );
      } else {
        selected = addDays(selected, direction * 7);
      }
    });
  }

  Widget calendarDay(
    DateTime date,
    List<Task> tasks,
    int index, {
    bool showWeekday = true,
  }) {
    final active = date == selected;
    final outsideMonth = _calendarExpanded && date.month != selected.month;
    final scheduled = tasks.any(
      (task) => timelineTime(task, date) > 0 && matches(task),
    );
    return Semantics(
      key: ValueKey('calendar-day-${date.toIso8601String().substring(0, 10)}'),
      button: true,
      selected: active,
      label: '${dayLabel(date)}${scheduled ? '，有任务' : ''}',
      onTap: () => setState(() => selected = date),
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => selected = date),
        child: AnimatedContainer(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 120),
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: active ? const Color(0xffe6effb) : null,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              if (showWeekday)
                Text(
                  '一二三四五六日'[index],
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '${date.day}',
                  style: TextStyle(
                    fontSize: 19,
                    color: active
                        ? blue
                        : outsideMonth
                        ? muted
                        : ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Container(
                key: ValueKey(
                  'calendar-dot-${date.toIso8601String().substring(0, 10)}',
                ),
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
        if (tag.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: InputChip(
              label: Text('#$tag'),
              onDeleted: () => setState(() => tag = ''),
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
    pending.sort((a, b) => compareTaskEntries(a, b, controller.identity.user));
    checked.sort((a, b) => compareTaskEntries(a, b, controller.identity.user));
    return [
      for (final (label, rows) in [('待完成', pending), ('已完成', checked)])
        if (rows.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 12, 0, 4),
            child: Text(
              '$label  ${rows.length}',
              style: const TextStyle(
                color: muted,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          for (final (task, occurrence) in rows) taskCard(task, occurrence),
        ],
    ];
  }

  Widget taskCard(Task task, int occurrence) {
    final done = task.done(controller.identity.user, occurrence);
    final when = occurrence == 0
        ? ''
        : '${tab == 1 ? '' : '${dayLabel(localTime(occurrence))} '}${task.allDay ? '全天' : clock(localTime(occurrence))}';
    final meta = [
      if (when.isNotEmpty) when,
      if (task.repeat != null) repeatNames[repeatKind(task.repeat?.data)],
      if (task.tags.isNotEmpty) '#${text(task.tags.first.data['tag_name'])}',
    ];
    return InkWell(
      onTap: () => editTask(task),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 2,
          vertical: meta.isEmpty ? 0 : 4,
        ),
        child: ConstrainedBox(
          key: ValueKey('task-row-${task.uid}'),
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              SizedBox(
                width: 48,
                height: 48,
                child: Tooltip(
                  message: done ? '标记未完成' : '完成任务',
                  child: Checkbox(
                    value: done,
                    activeColor: muted,
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
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      task.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w400,
                        color: done ? muted : ink,
                        decoration: done ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        meta.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: muted),
                      ),
                    ],
                  ],
                ),
              ),
              if (task.alert != null)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(Icons.notifications_none, color: muted, size: 16),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget renderNotes() {
    final quick = notesSection == NoteSection.quick;
    final folders = notebookFolders(
      controller.data,
      controller.team,
      notesSection,
    );
    final folder = folders.where((item) => item.uid == noteFolder).firstOrNull;
    final known = folders.map((item) => item.uid).toSet();
    final notes = filterNotes(
      controller.data
          .list(controller.team, Tables.note)
          .where(
            (note) =>
                noteSection(note) == notesSection && !isNotebookFolder(note),
          )
          .where((note) {
            if (!notesSection.customFolders) return true;
            final parent = noteFolderParent(note);
            return (known.contains(parent) ? parent : '') ==
                (folder?.uid ?? '');
          }),
    );
    return PageContent(
      key: ValueKey((controller.team, notesSection)),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
        SegmentedButton<NoteSection>(
          expandedInsets: EdgeInsets.zero,
          showSelectedIcon: false,
          style: const ButtonStyle(
            padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 8)),
          ),
          segments: [
            for (final section in NoteSection.values)
              ButtonSegment(
                value: section,
                label: Text(section.label, textAlign: TextAlign.center),
              ),
          ],
          selected: {notesSection},
          onSelectionChanged: (value) => setState(() {
            notesSection = value.single;
            noteFolder = '';
          }),
        ),
        const SizedBox(height: 4),
        if (notesSection.customFolders)
          ...renderCustomNotebook(folders, folder, notes)
        else if (notes.isEmpty)
          EmptyContent(
            quick ? '还没有便签' : '还没有记事本',
            icon: Icons.sticky_note_2_outlined,
          )
        else if (quick)
          for (final note in notes) noteCard(note)
        else
          ...notebookTree(notes),
      ],
    );
  }

  NotebookFolder? get currentNotebookFolder => notebookFolders(
    controller.data,
    controller.team,
    notesSection,
  ).where((item) => item.uid == noteFolder).firstOrNull;

  List<Widget> renderCustomNotebook(
    List<NotebookFolder> folders,
    NotebookFolder? folder,
    List<Item> notes,
  ) {
    final children = folders
        .where((item) => item.parent == (folder?.uid ?? ''))
        .toList();
    return [
      Row(
        children: [
          if (folder != null)
            IconButton(
              tooltip: '上级目录',
              onPressed: () => setState(() => noteFolder = folder.parent),
              icon: const Icon(Icons.chevron_left),
            ),
          Expanded(
            child: Text(
              folder?.path ?? '根目录',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton.icon(
            onPressed: folder?.depth == 3
                ? null
                : () => createNotebookFolder(folder?.uid ?? ''),
            icon: const Icon(Icons.create_new_folder_outlined, size: 17),
            label: const Text('新建目录'),
          ),
        ],
      ),
      for (final child in children)
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 2),
          leading: const Icon(Icons.folder_outlined, color: blue, size: 20),
          title: Text(child.name),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => setState(() => noteFolder = child.uid),
        ),
      for (final note in notes) noteCard(note),
      if (children.isEmpty && notes.isEmpty)
        const EmptyContent('这里还没有目录或记录', icon: Icons.folder_open_outlined),
    ];
  }

  Future<void> createNotebookFolder(String parent) async {
    final section = notesSection,
        team = controller.team,
        scope = controller.identity.scope;
    var draft = '';
    final submitted = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新建目录'),
        content: TextField(
          autofocus: true,
          maxLength: 100,
          decoration: const InputDecoration(labelText: '目录名称', counterText: ''),
          onChanged: (value) => draft = value,
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, draft),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (submitted == null || !mounted || controller.identity.scope != scope) {
      return;
    }
    final uid = newId(Tables.note);
    try {
      await controller.mutate((data, who) {
        if (who.scope != scope) throw const FormatException('账户已切换，请重新打开目录');
        saveNotebookFolder(
          data,
          who,
          team,
          section,
          uid,
          submitted,
          parent: parent,
        );
      });
      if (mounted && controller.team == team && notesSection == section) {
        setState(() => noteFolder = uid);
      }
    } on FormatException catch (error) {
      if (mounted) message(context, error.message);
    }
  }

  Iterable<Widget> notebookTree(List<Item> notes) sync* {
    final years = <int, Map<int, List<Item>>>{};
    final undated = <Item>[];
    for (final note in notes) {
      final created = noteCreated(note);
      if (created == null) {
        undated.add(note);
        continue;
      }
      final months = years.putIfAbsent(created.year, () => {});
      months.putIfAbsent(created.month, () => []).add(note);
    }
    for (final entry in years.entries) {
      yield ExpansionTile(
        key: PageStorageKey((controller.team, notesSection, entry.key)),
        dense: true,
        visualDensity: VisualDensity.compact,
        tilePadding: const EdgeInsets.symmetric(horizontal: 4),
        childrenPadding: const EdgeInsets.only(left: 14),
        initiallyExpanded: entry.key == years.keys.first,
        title: Text('${entry.key} 年'),
        children: [
          for (final month in entry.value.entries)
            ExpansionTile(
              key: PageStorageKey((
                controller.team,
                notesSection,
                entry.key,
                month.key,
              )),
              dense: true,
              visualDensity: VisualDensity.compact,
              tilePadding: const EdgeInsets.symmetric(horizontal: 4),
              childrenPadding: const EdgeInsets.only(left: 14),
              initiallyExpanded: month.key == entry.value.keys.first,
              title: Text('${month.key} 月'),
              children: [for (final note in month.value) noteCard(note)],
            ),
        ],
      );
    }
    for (final note in undated) {
      yield noteCard(note);
    }
  }

  Widget noteCard(Item note) {
    final section = noteSection(note);
    final quick = section == NoteSection.quick;
    return ListTile(
      dense: true,
      minTileHeight: 48,
      visualDensity: VisualDensity.compact,
      minVerticalPadding: 4,
      minLeadingWidth: 24,
      contentPadding: const EdgeInsets.symmetric(horizontal: 2),
      leading: const Icon(Icons.sticky_note_2_outlined, color: blue, size: 20),
      title: Text(
        quick || section.customFolders ? noteTitle(note) : notebookTitle(note),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: ink, fontSize: 16),
      ),
      subtitle: quick
          ? Text(
              noteCreatedLabel(note),
              style: const TextStyle(color: muted, fontSize: 12),
            )
          : null,
      onTap: () => editNote(note),
    );
  }

  Widget renderSearch(List<Task> tasks) {
    final needle = query.trim().toLowerCase();
    final results = tasks.where(
      (task) => '${task.name} ${task.detail(1)} ${task.detail(2)}'
          .toLowerCase()
          .contains(needle),
    );
    final notes = controller.data
        .list(controller.team, Tables.note)
        .where(
          (item) =>
              !isNotebookFolder(item) &&
              noteSearchText(
                controller.data,
                item,
              ).toLowerCase().contains(needle),
        );
    final bills = controller.data
        .list(controller.team, Tables.bill)
        .where(
          (item) =>
              '${item.name} ${text(item.data['channel'])} ${text(item.data['party'])}'
                  .toLowerCase()
                  .contains(needle),
        );
    return PageContent(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
        TextFormField(
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '搜索任务、账单或便签',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (value) => setState(() => query = value),
        ),
        const SizedBox(height: 12),
        if (needle.isNotEmpty) ...[
          for (final task in results)
            taskCard(task, task.listTime(dayOnly(DateTime.now()))),
          for (final note in notes) noteCard(note),
          for (final bill in bills) BillTile(bill, onTap: () => editBill(bill)),
          if (results.isEmpty && notes.isEmpty && bills.isEmpty)
            const EmptyContent('没有找到匹配内容', icon: Icons.search),
        ],
      ],
    );
  }
}
