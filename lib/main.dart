import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'firebase_options.dart';

const categories = ['Assignment', 'Project', 'Quiz', 'Exam', 'Other'];
const priorities = ['High', 'Medium', 'Low'];
const statuses = ['Pending', 'In Progress', 'Completed'];
const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String fmt(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');
  final ap = d.hour >= 12 ? 'PM' : 'AM';
  return '${months[d.month - 1]} ${d.day}, ${d.year} · $h:$m $ap';
}

Color priorityColor(String p) =>
    p == 'High' ? Colors.red : (p == 'Medium' ? Colors.orange : Colors.green);

// ---------------- Notifications ----------------
class Notifier {
  static final _plugin = FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    try {
      tzdata.initializeTimeZones();
      await _plugin.initialize(const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher')));
      final a = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await a?.requestNotificationsPermission();
    } catch (_) {}
  }

  static Future<void> _schedule(int id, String title, String body, DateTime when) async {
    if (when.isBefore(DateTime.now())) return;
    await _plugin.zonedSchedule(
      id,
      title,
      body,
      tz.TZDateTime.from(when, tz.UTC),
      const NotificationDetails(
          android: AndroidNotificationDetails('deadlines', 'Deadline reminders',
              importance: Importance.high, priority: Priority.high)),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  static Future<void> cancel(Task t) async {
    try {
      await _plugin.cancel(t.notifId);
      await _plugin.cancel(t.notifId + 1);
    } catch (_) {}
  }

  static Future<void> sync(Task t) async {
    try {
      await cancel(t);
      if (t.done) return;
      await _schedule(t.notifId, 'Due in 1 hour', t.title, t.due.subtract(const Duration(hours: 1)));
      await _schedule(t.notifId + 1, 'Deadline now', t.title, t.due);
    } catch (_) {}
  }
}

// ---------------- Model & database ----------------
class Task {
  final String id, title, category, priority, status, notes;
  final DateTime due;
  final int notifId;
  Task({
    this.id = '',
    required this.title,
    required this.category,
    required this.priority,
    required this.status,
    required this.notes,
    required this.due,
    required this.notifId,
  });

  factory Task.fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data();
    return Task(
      id: d.id,
      title: (m['title'] ?? '') as String,
      category: (m['category'] ?? 'Other') as String,
      priority: (m['priority'] ?? 'Medium') as String,
      status: (m['status'] ?? 'Pending') as String,
      notes: (m['notes'] ?? '') as String,
      due: (m['due'] as Timestamp).toDate(),
      notifId: (m['notifId'] ?? 1000) as int,
    );
  }

  Map<String, dynamic> toMap() => {
        'title': title,
        'category': category,
        'priority': priority,
        'status': status,
        'notes': notes,
        'due': Timestamp.fromDate(due),
        'notifId': notifId,
      };

  bool get done => status == 'Completed';
  bool get overdue => !done && due.isBefore(DateTime.now());
}

class Db {
  static String get uid => FirebaseAuth.instance.currentUser!.uid;
  static DocumentReference<Map<String, dynamic>> get profile =>
      FirebaseFirestore.instance.collection('users').doc(uid);
  static CollectionReference<Map<String, dynamic>> get tasks => profile.collection('tasks');

  static Future<void> save(Task t) async {
    final ref = t.id.isEmpty ? tasks.doc() : tasks.doc(t.id);
    await ref.set(t.toMap());
    await Notifier.sync(t);
  }

  static Future<void> delete(Task t) async {
    await tasks.doc(t.id).delete();
    await Notifier.cancel(t);
  }
}

// ---------------- App ----------------
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await Notifier.init();
  runApp(const StudyTrackApp());
}

class StudyTrackApp extends StatelessWidget {
  const StudyTrackApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'StudyTrack',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          return snap.data == null ? const AuthScreen() : const HomeShell();
        },
      ),
    );
  }
}

// ---------------- Login / Register ----------------
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool register = false, busy = false;
  final name = TextEditingController(),
      course = TextEditingController(),
      section = TextEditingController(),
      email = TextEditingController(),
      pass = TextEditingController();

  Future<void> submit() async {
    if (email.text.trim().isEmpty || pass.text.isEmpty || (register && name.text.trim().isEmpty)) {
      msg('Please fill in all required fields.');
      return;
    }
    setState(() => busy = true);
    try {
      final auth = FirebaseAuth.instance;
      if (register) {
        final cred = await auth.createUserWithEmailAndPassword(
            email: email.text.trim(), password: pass.text);
        await FirebaseFirestore.instance.collection('users').doc(cred.user!.uid).set({
          'name': name.text.trim(),
          'course': course.text.trim(),
          'section': section.text.trim(),
          'email': email.text.trim(),
        });
      } else {
        await auth.signInWithEmailAndPassword(email: email.text.trim(), password: pass.text);
      }
    } on FirebaseAuthException catch (e) {
      msg(e.message ?? 'Authentication failed.');
    } catch (e) {
      msg('Something went wrong: $e');
    }
    if (mounted) setState(() => busy = false);
  }

  void msg(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Widget field(TextEditingController c, String label,
          {bool hide = false, TextInputType? type}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          obscureText: hide,
          keyboardType: type,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(children: [
              const Icon(Icons.checklist_rounded, size: 72, color: Colors.indigo),
              const Text('StudyTrack',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              const Text('Student Task & Deadline Tracker'),
              const SizedBox(height: 24),
              if (register) ...[
                field(name, 'Full name *'),
                field(course, 'Course'),
                field(section, 'Section'),
              ],
              field(email, 'Email *', type: TextInputType.emailAddress),
              field(pass, 'Password * (min. 6 characters)', hide: true),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                    onPressed: busy ? null : submit,
                    child: Text(busy ? 'Please wait...' : (register ? 'Create account' : 'Log in'))),
              ),
              TextButton(
                  onPressed: () => setState(() => register = !register),
                  child: Text(register
                      ? 'Already have an account? Log in'
                      : 'No account yet? Register')),
            ]),
          ),
        ),
      ),
    );
  }
}

// ---------------- Home shell ----------------
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int tab = 0;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: Db.tasks.orderBy('due').snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Scaffold(
              body: Center(
                  child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Could not load tasks. Check your Firestore rules.\n${snap.error}'))));
        }
        final tasks = snap.hasData ? snap.data!.docs.map((d) => Task.fromDoc(d)).toList() : <Task>[];
        final pages = [
          Dashboard(tasks: tasks),
          TasksPage(tasks: tasks),
          const ProfilePage(),
        ];
        return Scaffold(
          appBar: AppBar(title: const Text('StudyTrack')),
          body: snap.connectionState == ConnectionState.waiting
              ? const Center(child: CircularProgressIndicator())
              : pages[tab],
          floatingActionButton: tab == 2
              ? null
              : FloatingActionButton.extended(
                  onPressed: () => Navigator.push(
                      context, MaterialPageRoute(builder: (_) => const TaskForm())),
                  icon: const Icon(Icons.add),
                  label: const Text('Add task')),
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (i) => setState(() => tab = i),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.dashboard_outlined), label: 'Dashboard'),
              NavigationDestination(icon: Icon(Icons.list_alt), label: 'Tasks'),
              NavigationDestination(icon: Icon(Icons.person_outline), label: 'Profile'),
            ],
          ),
        );
      },
    );
  }
}

// ---------------- Dashboard ----------------
class Dashboard extends StatelessWidget {
  final List<Task> tasks;
  const Dashboard({super.key, required this.tasks});

  Widget stat(String label, int n, Color c, IconData icon) => Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(children: [
              Icon(icon, color: c),
              Text('$n', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: c)),
              Text(label, style: const TextStyle(fontSize: 12)),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final pending = tasks.where((t) => t.status == 'Pending').length;
    final prog = tasks.where((t) => t.status == 'In Progress').length;
    final done = tasks.where((t) => t.done).length;
    final overdue = tasks.where((t) => t.overdue).toList();
    final upcoming = tasks
        .where((t) => !t.done && !t.overdue && t.due.isBefore(now.add(const Duration(days: 7))))
        .toList();
    return ListView(padding: const EdgeInsets.all(12), children: [
      Row(children: [
        stat('Pending', pending, Colors.orange, Icons.hourglass_empty),
        stat('In Progress', prog, Colors.blue, Icons.autorenew),
        stat('Completed', done, Colors.green, Icons.check_circle_outline),
      ]),
      if (overdue.isNotEmpty) ...[
        const Padding(
            padding: EdgeInsets.fromLTRB(4, 12, 4, 4),
            child: Text('Overdue',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.red))),
        ...overdue.map((t) => TaskTile(task: t)),
      ],
      const Padding(
          padding: EdgeInsets.fromLTRB(4, 12, 4, 4),
          child: Text('Upcoming (next 7 days)',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
      if (upcoming.isEmpty)
        const Padding(
            padding: EdgeInsets.all(16), child: Text('No upcoming deadlines. Tap "Add task" to create one.')),
      ...upcoming.map((t) => TaskTile(task: t)),
      const SizedBox(height: 80),
    ]);
  }
}

// ---------------- Task tile ----------------
class TaskTile extends StatelessWidget {
  final Task task;
  const TaskTile({super.key, required this.task});

  @override
  Widget build(BuildContext context) {
    final t = task;
    return Card(
      child: ListTile(
        leading: Checkbox(
          value: t.done,
          onChanged: (v) => Db.save(Task(
              id: t.id,
              title: t.title,
              category: t.category,
              priority: t.priority,
              status: v == true ? 'Completed' : 'Pending',
              notes: t.notes,
              due: t.due,
              notifId: t.notifId)),
        ),
        title: Text(t.title,
            style: TextStyle(decoration: t.done ? TextDecoration.lineThrough : null)),
        subtitle: Text('${t.category} · ${t.status}\n${fmt(t.due)}',
            style: TextStyle(color: t.overdue ? Colors.red : null)),
        isThreeLine: true,
        trailing: Chip(
            label: Text(t.priority, style: const TextStyle(fontSize: 11, color: Colors.white)),
            backgroundColor: priorityColor(t.priority),
            padding: EdgeInsets.zero),
        onTap: () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => TaskForm(task: t))),
      ),
    );
  }
}

// ---------------- Tasks list with search & filter ----------------
class TasksPage extends StatefulWidget {
  final List<Task> tasks;
  const TasksPage({super.key, required this.tasks});
  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  String q = '', cat = 'All', pri = 'All', stat = 'All';

  Widget filter(String label, String value, List<String> opts, void Function(String) on) =>
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: DropdownButtonFormField<String>(
            value: value,
            isExpanded: true,
            decoration: InputDecoration(
                labelText: label,
                isDense: true,
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10)),
            items: ['All', ...opts]
                .map((o) => DropdownMenuItem(value: o, child: Text(o, style: const TextStyle(fontSize: 13))))
                .toList(),
            onChanged: (v) => setState(() => on(v!)),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final list = widget.tasks
        .where((t) =>
            t.title.toLowerCase().contains(q.toLowerCase()) &&
            (cat == 'All' || t.category == cat) &&
            (pri == 'All' || t.priority == pri) &&
            (stat == 'All' || t.status == stat))
        .toList();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
        child: TextField(
          decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search tasks',
              border: OutlineInputBorder(),
              isDense: true),
          onChanged: (v) => setState(() => q = v),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        child: Row(children: [
          filter('Category', cat, categories, (v) => cat = v),
          filter('Priority', pri, priorities, (v) => pri = v),
          filter('Status', stat, statuses, (v) => stat = v),
        ]),
      ),
      Expanded(
        child: list.isEmpty
            ? const Center(child: Text('No tasks found.'))
            : ListView.builder(
                padding: const EdgeInsets.only(bottom: 80),
                itemCount: list.length,
                itemBuilder: (c, i) {
                  final t = list[i];
                  return Dismissible(
                    key: ValueKey(t.id),
                    direction: DismissDirection.endToStart,
                    background: Container(
                        color: Colors.red,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: const Icon(Icons.delete, color: Colors.white)),
                    confirmDismiss: (_) async =>
                        await showDialog<bool>(
                            context: context,
                            builder: (_) => AlertDialog(
                                  title: const Text('Delete task?'),
                                  content: Text(t.title),
                                  actions: [
                                    TextButton(
                                        onPressed: () => Navigator.pop(context, false),
                                        child: const Text('Cancel')),
                                    TextButton(
                                        onPressed: () => Navigator.pop(context, true),
                                        child: const Text('Delete')),
                                  ],
                                )) ??
                        false,
                    onDismissed: (_) => Db.delete(t),
                    child: TaskTile(task: t),
                  );
                },
              ),
      ),
    ]);
  }
}

// ---------------- Add / Edit task ----------------
class TaskForm extends StatefulWidget {
  final Task? task;
  const TaskForm({super.key, this.task});
  @override
  State<TaskForm> createState() => _TaskFormState();
}

class _TaskFormState extends State<TaskForm> {
  final title = TextEditingController(), notes = TextEditingController();
  String category = 'Assignment', priority = 'Medium', status = 'Pending';
  late DateTime due;

  @override
  void initState() {
    super.initState();
    final t = widget.task;
    if (t != null) {
      title.text = t.title;
      notes.text = t.notes;
      category = t.category;
      priority = t.priority;
      status = t.status;
      due = t.due;
    } else {
      final n = DateTime.now().add(const Duration(days: 1));
      due = DateTime(n.year, n.month, n.day, 17, 0);
    }
  }

  Future<void> pickDate() async {
    final d = await showDatePicker(
        context: context,
        initialDate: due,
        firstDate: DateTime(2020),
        lastDate: DateTime(2100));
    if (d != null) setState(() => due = DateTime(d.year, d.month, d.day, due.hour, due.minute));
  }

  Future<void> pickTime() async {
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(due));
    if (t != null) setState(() => due = DateTime(due.year, due.month, due.day, t.hour, t.minute));
  }

  Future<void> save() async {
    if (title.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Please enter a task title.')));
      return;
    }
    final old = widget.task;
    await Db.save(Task(
      id: old?.id ?? '',
      title: title.text.trim(),
      category: category,
      priority: priority,
      status: status,
      notes: notes.text.trim(),
      due: due,
      notifId: old?.notifId ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000) % 1000000000 * 2,
    ));
    if (mounted) Navigator.pop(context);
  }

  Widget drop(String label, String value, List<String> opts, void Function(String) on) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<String>(
          value: value,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
          items: opts.map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(),
          onChanged: (v) => setState(() => on(v!)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.task == null ? 'Add task' : 'Edit task')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
              controller: title,
              decoration: const InputDecoration(labelText: 'Title *', border: OutlineInputBorder())),
        ),
        drop('Category', category, categories, (v) => category = v),
        drop('Priority', priority, priorities, (v) => priority = v),
        drop('Status', status, statuses, (v) => status = v),
        Row(children: [
          Expanded(
              child: OutlinedButton.icon(
                  onPressed: pickDate,
                  icon: const Icon(Icons.calendar_today),
                  label: Text('${months[due.month - 1]} ${due.day}, ${due.year}'))),
          const SizedBox(width: 8),
          Expanded(
              child: OutlinedButton.icon(
                  onPressed: pickTime,
                  icon: const Icon(Icons.access_time),
                  label: Text(fmt(due).split('· ')[1]))),
        ]),
        const SizedBox(height: 12),
        TextField(
            controller: notes,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Notes', border: OutlineInputBorder())),
        const SizedBox(height: 20),
        FilledButton(onPressed: save, child: const Text('Save task')),
      ]),
    );
  }
}

// ---------------- Profile ----------------
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final name = TextEditingController(),
      course = TextEditingController(),
      section = TextEditingController();
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    Db.profile.get().then((d) {
      final m = d.data() ?? {};
      name.text = (m['name'] ?? '') as String;
      course.text = (m['course'] ?? '') as String;
      section.text = (m['section'] ?? '') as String;
      if (mounted) setState(() => loaded = true);
    });
  }

  Widget field(TextEditingController c, String l) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
            controller: c, decoration: InputDecoration(labelText: l, border: const OutlineInputBorder())),
      );

  @override
  Widget build(BuildContext context) {
    if (!loaded) return const Center(child: CircularProgressIndicator());
    return ListView(padding: const EdgeInsets.all(16), children: [
      const CircleAvatar(radius: 40, child: Icon(Icons.person, size: 40)),
      const SizedBox(height: 8),
      Center(child: Text(FirebaseAuth.instance.currentUser?.email ?? '')),
      const SizedBox(height: 16),
      field(name, 'Full name'),
      field(course, 'Course'),
      field(section, 'Section'),
      FilledButton(
        onPressed: () async {
          await Db.profile.set({
            'name': name.text.trim(),
            'course': course.text.trim(),
            'section': section.text.trim(),
            'email': FirebaseAuth.instance.currentUser?.email,
          }, SetOptions(merge: true));
          if (context.mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Profile updated.')));
          }
        },
        child: const Text('Save profile'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
          onPressed: () => FirebaseAuth.instance.signOut(),
          icon: const Icon(Icons.logout),
          label: const Text('Log out')),
    ]);
  }
}
