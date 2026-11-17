import 'package:material_ui/material_ui.dart';

import 'appearance.dart';
import 'controller.dart';
import 'domain.dart';
import 'schedule.dart';
import 'tasks.dart';

const projectColors = {
  '346ab7': '蓝',
  '488975': '绿',
  'c37832': '橙',
  '7968a6': '紫',
  '5d6b7f': '灰',
};

Color projectColor(Item item) {
  final value = int.tryParse(
    text(item.data['color']).replaceAll('#', ''),
    radix: 16,
  );
  return value == null ? blue : Color(0xff000000 | value);
}

class CatalogEditor extends StatefulWidget {
  const CatalogEditor(
    this.controller,
    this.team,
    this.table, {
    super.key,
    this.item,
  });
  final TodoController controller;
  final int team, table;
  final Item? item;

  @override
  State<CatalogEditor> createState() => _CatalogEditorState();
}

class _CatalogEditorState extends State<CatalogEditor> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.item?.name);
  late final intro = TextEditingController(
    text: text(widget.item?.data['intro']),
  );
  late final latitude = TextEditingController(
    text: text(widget.item?.data['latitude']),
  );
  late final longitude = TextEditingController(
    text: text(widget.item?.data['longitude']),
  );
  late var color = text(widget.item?.data['color']).replaceAll('#', '');
  late bool archived = integer(widget.item?.data['status']) != 0;
  bool busy = false;

  String get label => switch (widget.table) {
    Tables.project => '项目',
    Tables.note => '便签',
    Tables.tag => '标签',
    _ => '地点',
  };

  @override
  void dispose() {
    for (final controller in [name, intro, latitude, longitude]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> save() async {
    if (busy || form.currentState?.validate() != true) return;
    final value = widget.table == Tables.note ? name.text : name.text.trim();
    final data = <String, dynamic>{'name': value};
    switch (widget.table) {
      case Tables.project:
        data.addAll({
          'intro': intro.text,
          'color': projectColors.containsKey(color)
              ? color
              : projectColors.keys.first,
          'status': archived ? 1 : 0,
          'privacy': 6728,
        });
      case Tables.note:
        data.addAll({
          'sequence': DateTime.now().millisecondsSinceEpoch,
          'status': 0,
        });
      case Tables.place:
        final neither = latitude.text.isEmpty && longitude.text.isEmpty;
        final north = neither ? 0.0 : double.tryParse(latitude.text);
        final east = neither ? 0.0 : double.tryParse(longitude.text);
        if (north == null ||
            east == null ||
            !north.isFinite ||
            !east.isFinite ||
            north.abs() > 90 ||
            east.abs() > 180) {
          message(context, '请输入有效经纬度');
          return;
        }
        data.addAll({
          'latitude': north,
          'longitude': east,
          'map_type': 1,
          'coor_type': 3,
        });
    }
    setState(() => busy = true);
    try {
      await widget.controller.mutate((workspace, who) {
        if (widget.table != Tables.note &&
            workspace
                .list(widget.team, widget.table)
                .any(
                  (record) =>
                      record.name == value && record.uid != widget.item?.uid,
                )) {
          throw const FormatException('此名称已存在');
        }
        final item = widget.item;
        if (item != null &&
            workspace.get(item.team, item.table, item.uid) == null) {
          throw const FormatException('记录已被删除');
        }
        if (widget.table == Tables.tag && item != null && item.name != value) {
          for (final mapping
              in workspace.list(widget.team, Tables.taskTag).toList()) {
            if (mapping.data['tag_name'] == item.name) {
              workspace.save(who, widget.team, Tables.taskTag, mapping.uid, {
                'tag_name': value,
              });
            }
          }
        }
        workspace.save(
          who,
          widget.team,
          widget.table,
          item?.uid ?? newId(widget.table),
          data,
        );
      });
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) message(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> remove() async {
    final item = widget.item!;
    final accepted = await confirm(
      context,
      '删除$label？',
      widget.table == Tables.project ? '项目下的任务会移动到未分类。' : '删除后，关联的任务会更新。',
    );
    if (!accepted || !mounted) return;
    setState(() => busy = true);
    try {
      await widget.controller.mutate((workspace, who) {
        if (item.table == Tables.project || item.table == Tables.place) {
          final field = item.table == Tables.project
              ? 'project_id'
              : 'position_id';
          for (final row in workspace.list(widget.team, Tables.task).toList()) {
            if (row.data[field] == item.uid) {
              workspace.save(who, widget.team, Tables.task, row.uid, {
                field: '',
              });
            }
          }
        }
        if (item.table == Tables.tag) {
          for (final row
              in workspace.list(widget.team, Tables.taskTag).toList()) {
            if (row.data['tag_name'] == item.name) workspace.remove(row);
          }
        }
        workspace.remove(item);
      });
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) message(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNote = widget.table == Tables.note;
    final isProject = widget.table == Tables.project;
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.item == null ? '新建' : '编辑'}$label'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: busy ? null : save,
              child: const Text('保存'),
            ),
          ),
        ],
      ),
      body: Form(
        key: form,
        child: PageContent(
          children: [
            TextFormField(
              controller: name,
              decoration: InputDecoration(
                labelText: isNote ? '便签内容' : '$label名称',
              ),
              minLines: isNote ? 9 : 1,
              maxLines: isNote ? 22 : 1,
              maxLength: isNote ? 60000 : 100,
              validator: (value) => value == null || value.trim().isEmpty
                  ? '请输入$label'
                  : widget.table == Tables.tag && RegExp('[,，]').hasMatch(value)
                  ? '标签名称不能包含逗号'
                  : null,
            ),
            if (isProject) ...[
              TextFormField(
                controller: intro,
                decoration: const InputDecoration(labelText: '简介'),
                maxLines: 4,
                maxLength: 1000,
              ),
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: '颜色'),
                initialValue: projectColors.containsKey(color)
                    ? color
                    : projectColors.keys.first,
                items: [
                  for (final entry in projectColors.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                ],
                onChanged: (value) => setState(() => color = value ?? color),
              ),
              SwitchListTile(
                title: const Text('归档项目'),
                value: archived,
                onChanged: (value) => setState(() => archived = value),
              ),
            ],
            if (widget.table == Tables.place) ...[
              TextFormField(
                controller: latitude,
                decoration: const InputDecoration(labelText: '纬度（可选）'),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: longitude,
                decoration: const InputDecoration(labelText: '经度（可选）'),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
              ),
            ],
            if (widget.item != null)
              TextButton(
                onPressed: busy ? null : remove,
                child: Text(
                  '删除$label',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class TaxonomyPage extends StatelessWidget {
  const TaxonomyPage(this.controller, this.team, {super.key});
  final TodoController controller;
  final int team;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      Widget section(int table, String label) => Card(
        child: Column(
          children: [
            ListTile(
              title: Text(label),
              trailing: IconButton(
                tooltip: '添加$label',
                icon: const Icon(Icons.add),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CatalogEditor(controller, team, table),
                  ),
                ),
              ),
            ),
            for (final item in controller.data.list(team, table))
              ListTile(
                title: Text(item.name),
                onTap: table == Tables.tag
                    ? () => Navigator.pop(context, item.name)
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => CatalogEditor(
                            controller,
                            team,
                            table,
                            item: item,
                          ),
                        ),
                      ),
                trailing: IconButton(
                  tooltip: '编辑$label',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          CatalogEditor(controller, team, table, item: item),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
      return Scaffold(
        appBar: AppBar(title: const Text('标签与地点')),
        body: PageContent(
          children: [
            section(Tables.tag, '标签'),
            const SizedBox(height: 12),
            section(Tables.place, '地点'),
          ],
        ),
      );
    },
  );
}

class StatisticsPage extends StatelessWidget {
  const StatisticsPage(this.controller, this.team, {super.key});
  final TodoController controller;
  final int team;

  @override
  Widget build(BuildContext context) {
    final now = dayOnly(DateTime.now());
    final days = List.generate(7, (index) => addDays(now, index - 6));
    final counts = List.filled(days.length, 0);
    var total = 0;
    for (final task in taskList(controller.data, controller.identity, team)) {
      for (final check in task.checks) {
        if (integer(check.data['user_id']) != controller.identity.user ||
            integer(check.data['status']) != 1) {
          continue;
        }
        total++;
        final time = integer(check.data['check_at']);
        if (time > 0) {
          final index = days.indexOf(dayOnly(localTime(time)));
          if (index >= 0) counts[index]++;
        }
      }
    }
    final maximum = counts.fold<int>(
      1,
      (left, right) => left > right ? left : right,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('完成统计')),
      body: PageContent(
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$total 次完成',
                    style: const TextStyle(
                      fontSize: 30,
                      color: blue,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    '近 7 天',
                    style: TextStyle(color: muted, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 14),
                  for (final (index, day) in days.indexed)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          SizedBox(width: 80, child: Text(dayLabel(day))),
                          Expanded(
                            child: LinearProgressIndicator(
                              value: counts[index] / maximum,
                              minHeight: 8,
                              borderRadius: BorderRadius.circular(8),
                              backgroundColor: line,
                            ),
                          ),
                          SizedBox(
                            width: 36,
                            child: Text(
                              '${counts[index]}',
                              textAlign: TextAlign.right,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
