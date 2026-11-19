import 'package:material_ui/material_ui.dart';

const ink = Color(0xff202c3f);
const muted = Color(0xff5d6d83);
const blue = Color(0xff346ab7);
const paper = Color(0xfff5f8fc);
const line = Color(0xffe7edf5);

ThemeData todoTheme() => ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: blue,
    primary: blue,
    surface: Colors.white,
    onSurface: ink,
  ),
  scaffoldBackgroundColor: paper,
  appBarTheme: const AppBarTheme(
    backgroundColor: paper,
    foregroundColor: ink,
    surfaceTintColor: Colors.transparent,
  ),
  cardTheme: CardThemeData(
    color: Colors.white,
    elevation: 0,
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: const BorderSide(color: line),
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(13)),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(13),
      borderSide: const BorderSide(color: line),
    ),
  ),
  navigationBarTheme: const NavigationBarThemeData(
    backgroundColor: Colors.white,
    height: 64,
  ),
);

void message(BuildContext context, Object text) {
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(text.toString())));
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String content,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认'),
          ),
        ],
      ),
    ) ??
    false;

class EmptyContent extends StatelessWidget {
  const EmptyContent(
    this.title, {
    super.key,
    this.icon = Icons.checklist_rounded,
  });
  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 38, color: muted),
          const SizedBox(height: 14),
          Text(
            title,
            style: const TextStyle(color: muted, fontSize: 15),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}

class PageContent extends StatelessWidget {
  const PageContent({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 24),
  });
  final List<Widget> children;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: ListView(padding: padding, children: children),
    ),
  );
}

class LoadingPage extends StatelessWidget {
  const LoadingPage(this.title, this.future, this.content, {super.key});
  final String title;
  final Future<Map<String, dynamic>> future;
  final List<Widget> Function(Map<String, dynamic>) content;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: FutureBuilder<Map<String, dynamic>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.hasError) return EmptyContent('${snapshot.error}');
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return PageContent(children: content(snapshot.data!));
      },
    ),
  );
}
