import 'dart:ui';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:csv/csv.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'widgets/enhanced_markdown_view.dart';

void main() {
  runApp(const ClassEchoApp());
}

const String defaultAsrModel = 'FunAudioLLM/SenseVoiceSmall';
const String defaultLlmModel = 'deepseek-ai/DeepSeek-V3.2';
const String defaultVisionModel = 'Qwen/Qwen3-VL-32B-Instruct';
const String defaultApiBaseUrl = 'https://api.siliconflow.cn';
const String prefEnableContextCorrection = 'enable_context_correction';
const String prefEnableCardMerge = 'enable_card_merge';
const String prefShowStabilityPanel = 'show_stability_panel';

const Map<String, String> asrModelDescriptions = {
  'FunAudioLLM/SenseVoiceSmall': '中文识别稳定，延迟低，适合课堂实时转写。',
  'iic/SenseVoiceSmall': '兼顾中英混合语音识别，适合术语和代码词较多场景。',
};

const Map<String, String> llmModelDescriptions = {
  'deepseek-ai/DeepSeek-V3.2': '综合质量高，摘要准确，适合课堂知识点提炼。',
  'Qwen/Qwen3-14B': '响应更快、成本更低，适合实时轻量总结。',
  'Pro/zai-org/GLM-4.7': '中文表达自然，结构化总结能力强。',
};

String normalizeBaseUrl(String raw) {
  String normalized = raw.trim();
  if (normalized.isEmpty) return defaultApiBaseUrl;
  while (normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  if (normalized.endsWith('/v1')) {
    normalized = normalized.substring(0, normalized.length - 3);
  }
  return normalized;
}

Uri buildOpenAiStyleUri(String customBaseUrl, String pathUnderV1) {
  final base = normalizeBaseUrl(customBaseUrl);
  final path = pathUnderV1.startsWith('/')
      ? pathUnderV1.substring(1)
      : pathUnderV1;
  return Uri.parse('$base/v1/$path');
}

String _twoDigits(int n) => n.toString().padLeft(2, '0');

String formatTimeForTranscript(int timestampMs) {
  final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs);
  return '${_twoDigits(dt.hour)}:${_twoDigits(dt.minute)}:${_twoDigits(dt.second)}';
}

String buildTranscriptFromSegments(List<TranscriptSegment> segments) {
  if (segments.isEmpty) return '等待老师发言...\n\n';
  final sorted = [...segments]
    ..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
  return sorted
          .map((s) => '[${formatTimeForTranscript(s.timestampMs)}] ${s.text}')
          .join('\n') +
      '\n';
}

enum TimelineNodeType { text, image }

class TimelineNode {
  final String id;
  final TimelineNodeType type;
  final int timestampMs;
  final String? text;
  final String? imagePath;
  final String? imageLabel;

  const TimelineNode({
    required this.id,
    required this.type,
    required this.timestampMs,
    this.text,
    this.imagePath,
    this.imageLabel,
  });

  factory TimelineNode.text({
    required String id,
    required int timestampMs,
    required String text,
  }) {
    return TimelineNode(
      id: id,
      type: TimelineNodeType.text,
      timestampMs: timestampMs,
      text: text,
    );
  }

  factory TimelineNode.image({
    required String id,
    required int timestampMs,
    required String imagePath,
    String? imageLabel,
  }) {
    return TimelineNode(
      id: id,
      type: TimelineNodeType.image,
      timestampMs: timestampMs,
      imagePath: imagePath,
      imageLabel: imageLabel,
    );
  }

  bool get hasImage => type == TimelineNodeType.image;

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'timestampMs': timestampMs,
    'text': text,
    'imagePath': imagePath,
    'imageLabel': imageLabel,
  };

  factory TimelineNode.fromJson(Map<String, dynamic> json) {
    final typeName = json['type']?.toString() ?? TimelineNodeType.text.name;
    final type = TimelineNodeType.values.firstWhere(
      (element) => element.name == typeName,
      orElse: () => TimelineNodeType.text,
    );

    return TimelineNode(
      id:
          json['id']?.toString() ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      type: type,
      timestampMs: json['timestampMs'] as int,
      text: json['text']?.toString(),
      imagePath: json['imagePath']?.toString(),
      imageLabel: json['imageLabel']?.toString(),
    );
  }
}

String buildTranscriptFromTimelineNodes(List<TimelineNode> nodes) {
  if (nodes.isEmpty) return '等待老师发言...\n\n';
  final sorted = [...nodes]
    ..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
  final buffer = StringBuffer();
  for (final node in sorted) {
    final time = formatTimeForTranscript(node.timestampMs);
    if (node.type == TimelineNodeType.text) {
      final text = (node.text ?? '').trim();
      if (text.isEmpty) continue;
      buffer.writeln('[$time] $text');
    } else {
      final label = node.imageLabel?.trim().isNotEmpty == true
          ? node.imageLabel!.trim()
          : '白板快照';
      buffer.writeln('[$time] [图片节点] $label');
    }
  }
  return '${buffer.toString()}\n';
}

List<Widget> buildTimelineWidgets(
  List<TimelineNode> nodes, {
  required void Function(TimelineNode node) onImageTap,
}) {
  final sorted = [...nodes]
    ..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
  return sorted.map((node) {
    final time = formatTimeForTranscript(node.timestampMs);
    if (node.type == TimelineNodeType.image) {
      final imagePath = node.imagePath ?? '';
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '[$time] ${node.imageLabel?.trim().isNotEmpty == true ? node.imageLabel!.trim() : '白板快照'}',
              style: const TextStyle(color: Colors.cyanAccent, fontSize: 12),
            ),
            const SizedBox(height: 6),
            GestureDetector(
              onTap: () => onImageTap(node),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white24),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: imagePath.isEmpty
                      ? Container(
                          height: 140,
                          color: Colors.white10,
                          alignment: Alignment.center,
                          child: const Text(
                            '图片缺失',
                            style: TextStyle(color: Colors.white54),
                          ),
                        )
                      : Image.file(
                          File(imagePath),
                          height: 140,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              Container(
                                height: 140,
                                color: Colors.white10,
                                alignment: Alignment.center,
                                child: const Text(
                                  '图片无法加载',
                                  style: TextStyle(color: Colors.white54),
                                ),
                              ),
                        ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final text = (node.text ?? '').trim();
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        '[$time] $text',
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 15,
          height: 1.55,
        ),
      ),
    );
  }).toList();
}

enum HistoryExportAction { markdown, ankiCsv }

class AnkiCsvCard {
  final String front;
  final String back;
  final String tags;

  const AnkiCsvCard({
    required this.front,
    required this.back,
    required this.tags,
  });
}

class PendingAudioTask {
  final int? id;
  final String sessionId;
  final String audioFilePath;
  final int timestampMs;
  final String status;
  final int createdAtMs;
  final int retryCount;
  final String? lastError;

  const PendingAudioTask({
    this.id,
    required this.sessionId,
    required this.audioFilePath,
    required this.timestampMs,
    required this.status,
    required this.createdAtMs,
    this.retryCount = 0,
    this.lastError,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'session_id': sessionId,
    'audio_file_path': audioFilePath,
    'timestamp_ms': timestampMs,
    'status': status,
    'created_at_ms': createdAtMs,
    'retry_count': retryCount,
    'last_error': lastError,
  };

  factory PendingAudioTask.fromMap(Map<String, dynamic> map) =>
      PendingAudioTask(
        id: map['id'] as int?,
        sessionId: map['session_id'] as String,
        audioFilePath: map['audio_file_path'] as String,
        timestampMs: map['timestamp_ms'] as int,
        status: map['status'] as String,
        createdAtMs: map['created_at_ms'] as int,
        retryCount: (map['retry_count'] as int?) ?? 0,
        lastError: map['last_error'] as String?,
      );
}

class PendingAudioTaskStore {
  PendingAudioTaskStore._();
  static final PendingAudioTaskStore instance = PendingAudioTaskStore._();

  static const String tableName = 'pending_audio_tasks';
  Database? _db;

  static const String createTableSql = '''
CREATE TABLE pending_audio_tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  audio_file_path TEXT NOT NULL,
  timestamp_ms INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at_ms INTEGER NOT NULL,
  retry_count INTEGER NOT NULL DEFAULT 0,
  last_error TEXT
);
''';

  Future<Database> get database async {
    if (_db != null) return _db!;
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(dir.path, 'class_echo_pending.db');
    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute(createTableSql);
      },
    );
    return _db!;
  }

  Future<int> insertPending(PendingAudioTask task) async {
    final db = await database;
    return db.insert(tableName, task.toMap());
  }

  Future<List<PendingAudioTask>> listPending() async {
    final db = await database;
    final rows = await db.query(
      tableName,
      where: 'status = ?',
      whereArgs: ['pending'],
      orderBy: 'timestamp_ms ASC',
    );
    return rows.map(PendingAudioTask.fromMap).toList();
  }

  Future<int> countPending() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM $tableName WHERE status = ?',
      ['pending'],
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<void> markDone(int id) async {
    final db = await database;
    await db.update(
      tableName,
      {'status': 'done'},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> bumpRetry(int id, String error) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE $tableName SET retry_count = retry_count + 1, last_error = ? WHERE id = ?',
      [error, id],
    );
  }
}

class PendingAudioRetryService {
  static Future<int> retryAllPendingTasks() async {
    final tasks = await PendingAudioTaskStore.instance.listPending();
    if (tasks.isEmpty) return 0;

    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('silicon_api_key') ?? '';
    final asrModel = prefs.getString('asr_model') ?? defaultAsrModel;
    final customBaseUrl = prefs.getString('custom_base_url') ?? '';

    int successCount = 0;
    for (final task in tasks) {
      final taskId = task.id;
      if (taskId == null) continue;

      try {
        final f = File(task.audioFilePath);
        if (!await f.exists()) {
          await PendingAudioTaskStore.instance.bumpRetry(taskId, '音频文件不存在');
          continue;
        }

        final wavBytes = await f.readAsBytes();
        final request = http.MultipartRequest(
          'POST',
          buildOpenAiStyleUri(customBaseUrl, 'audio/transcriptions'),
        );
        request.headers.addAll({'Authorization': 'Bearer $apiKey'});
        request.fields['model'] = asrModel;
        request.files.add(
          http.MultipartFile.fromBytes(
            'file',
            wavBytes,
            filename: p.basename(task.audioFilePath),
          ),
        );

        final response = await request.send().timeout(
          const Duration(seconds: 15),
        );
        final body = await response.stream.bytesToString();
        if (response.statusCode != 200) {
          await PendingAudioTaskStore.instance.bumpRetry(
            taskId,
            '重试失败 HTTP ${response.statusCode}',
          );
          continue;
        }

        final text = jsonDecode(body)['text'].toString().trim();
        if (text.isNotEmpty) {
          await _insertRecoveredTranscript(
            sessionId: task.sessionId,
            timestampMs: task.timestampMs,
            text: text,
          );
        }

        await PendingAudioTaskStore.instance.markDone(taskId);
        successCount++;
      } catch (e) {
        await PendingAudioTaskStore.instance.bumpRetry(taskId, '重试异常: $e');
      }
    }

    return successCount;
  }

  static Future<void> _insertRecoveredTranscript({
    required String sessionId,
    required int timestampMs,
    required String text,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList('class_history') ?? [];
    final targetIndex = history.indexWhere((jsonStr) {
      final s = ClassSession.fromJson(jsonDecode(jsonStr));
      return s.sessionId == sessionId;
    });
    if (targetIndex == -1) return;

    final oldSession = ClassSession.fromJson(jsonDecode(history[targetIndex]));
    final segments = [...oldSession.transcriptSegments];
    segments.add(TranscriptSegment(timestampMs: timestampMs, text: text));
    segments.sort((a, b) => a.timestampMs.compareTo(b.timestampMs));

    final newSession = ClassSession(
      sessionId: oldSession.sessionId,
      subject: oldSession.subject,
      dateStr: oldSession.dateStr,
      transcript: buildTranscriptFromSegments(segments),
      transcriptSegments: segments,
      summaries: oldSession.summaries,
      bounties: oldSession.bounties,
    );

    history[targetIndex] = jsonEncode(newSession.toJson());
    await prefs.setStringList('class_history', history);
  }
}

// ================= 数据模型类 =================
class SummaryCard {
  String text; // 改为非 final，以便后续编辑修改
  bool isHighlighted;
  SummaryCard({required this.text, this.isHighlighted = false});

  Map<String, dynamic> toJson() => {
    'text': text,
    'isHighlighted': isHighlighted,
  };

  factory SummaryCard.fromJson(Map<String, dynamic> json) => SummaryCard(
    text: json['text'],
    isHighlighted: json['isHighlighted'] ?? false,
  );
}

class BountyTask {
  final String id;
  final String context;
  final String timeStr;

  BountyTask({required this.id, required this.context, required this.timeStr});

  Map<String, dynamic> toJson() => {
    'id': id,
    'context': context,
    'timeStr': timeStr,
  };

  factory BountyTask.fromJson(Map<String, dynamic> json) => BountyTask(
    id: json['id'],
    context: json['context'],
    timeStr: json['timeStr'],
  );
}

class TranscriptSegment {
  final int timestampMs;
  final String text;

  TranscriptSegment({required this.timestampMs, required this.text});

  Map<String, dynamic> toJson() => {'timestampMs': timestampMs, 'text': text};

  factory TranscriptSegment.fromJson(Map<String, dynamic> json) =>
      TranscriptSegment(
        timestampMs: json['timestampMs'] as int,
        text: json['text'] as String,
      );
}

class ClassSession {
  final String sessionId;
  final String title;
  final String subject;
  final String focusTerms;
  final String dateStr;
  final String transcript;
  final List<TranscriptSegment> transcriptSegments;
  final List<TimelineNode> timelineNodes;
  final List<SummaryCard> summaries;
  final List<BountyTask> bounties;

  ClassSession({
    String? sessionId,
    this.title = '',
    required this.subject,
    this.focusTerms = '',
    required this.dateStr,
    required this.transcript,
    List<TranscriptSegment>? transcriptSegments,
    List<TimelineNode>? timelineNodes,
    required this.summaries,
    required this.bounties,
  }) : sessionId =
           sessionId ?? DateTime.now().millisecondsSinceEpoch.toString(),
       transcriptSegments = transcriptSegments ?? const [],
       timelineNodes = timelineNodes ?? const [];

  ClassSession copyWith({
    String? title,
    String? subject,
    String? focusTerms,
    String? dateStr,
    String? transcript,
    List<TranscriptSegment>? transcriptSegments,
    List<TimelineNode>? timelineNodes,
    List<SummaryCard>? summaries,
    List<BountyTask>? bounties,
  }) {
    return ClassSession(
      sessionId: sessionId,
      title: title ?? this.title,
      subject: subject ?? this.subject,
      focusTerms: focusTerms ?? this.focusTerms,
      dateStr: dateStr ?? this.dateStr,
      transcript: transcript ?? this.transcript,
      transcriptSegments: transcriptSegments ?? this.transcriptSegments,
      timelineNodes: timelineNodes ?? this.timelineNodes,
      summaries: summaries ?? this.summaries,
      bounties: bounties ?? this.bounties,
    );
  }

  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'title': title,
    'subject': subject,
    'focusTerms': focusTerms,
    'dateStr': dateStr,
    'transcript': transcript,
    'transcriptSegments': transcriptSegments.map((e) => e.toJson()).toList(),
    'timelineNodes': timelineNodes.map((e) => e.toJson()).toList(),
    'summaries': summaries.map((e) => e.toJson()).toList(),
    'bounties': bounties.map((e) => e.toJson()).toList(),
  };

  factory ClassSession.fromJson(Map<String, dynamic> json) => ClassSession(
    sessionId: json['sessionId']?.toString() ?? json['dateStr']?.toString(),
    title: json['title']?.toString() ?? '',
    subject: json['subject'],
    focusTerms: json['focusTerms']?.toString() ?? '',
    dateStr: json['dateStr'],
    transcript: json['transcript'] ?? '',
    transcriptSegments: json['transcriptSegments'] != null
        ? (json['transcriptSegments'] as List)
              .map((e) => TranscriptSegment.fromJson(e))
              .toList()
        : [],
    timelineNodes: json['timelineNodes'] != null
        ? (json['timelineNodes'] as List)
              .map((e) => TimelineNode.fromJson(e))
              .toList()
        : (json['transcriptSegments'] != null
              ? (json['transcriptSegments'] as List).map((e) {
                  final segment = TranscriptSegment.fromJson(e);
                  return TimelineNode.text(
                    id: 'legacy_${segment.timestampMs}',
                    timestampMs: segment.timestampMs,
                    text: segment.text,
                  );
                }).toList()
              : []),
    summaries: (json['summaries'] as List)
        .map((e) => SummaryCard.fromJson(e))
        .toList(),
    bounties: json['bounties'] != null
        ? (json['bounties'] as List).map((e) => BountyTask.fromJson(e)).toList()
        : [],
  );
}

// ================= 主程序及导航 =================
class ClassEchoApp extends StatelessWidget {
  const ClassEchoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClassEcho',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(
        useMaterial3: true,
      ).copyWith(scaffoldBackgroundColor: const Color(0xFF0F172A)),
      home: const MainNavigator(),
    );
  }
}

class MainNavigator extends StatefulWidget {
  const MainNavigator({super.key});

  @override
  State<MainNavigator> createState() => _MainNavigatorState();
}

class _MainNavigatorState extends State<MainNavigator> {
  int _currentIndex = 0;
  String userApiKey = "";
  String userAsrModel = defaultAsrModel;
  String userLlmModel = defaultLlmModel;
  String userCustomBaseUrl = "";

  @override
  void initState() {
    super.initState();
    _loadUserSettings();
  }

  Future<void> _loadUserSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      userApiKey = prefs.getString('silicon_api_key') ?? "";
      userAsrModel = prefs.getString('asr_model') ?? defaultAsrModel;
      userLlmModel = prefs.getString('llm_model') ?? defaultLlmModel;
      userCustomBaseUrl = prefs.getString('custom_base_url') ?? "";

      if (!asrModelDescriptions.containsKey(userAsrModel)) {
        userAsrModel = defaultAsrModel;
      }
      if (!llmModelDescriptions.containsKey(userLlmModel)) {
        userLlmModel = defaultLlmModel;
      }
    });
  }

  Future<void> _updateApiKey(String newKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('silicon_api_key', newKey);
    setState(() {
      userApiKey = newKey;
    });
  }

  Future<void> _updateModels(String asrModel, String llmModel) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('asr_model', asrModel);
    await prefs.setString('llm_model', llmModel);
    setState(() {
      userAsrModel = asrModel;
      userLlmModel = llmModel;
    });
  }

  Future<void> _updateCustomBaseUrl(String baseUrl) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('custom_base_url', baseUrl);
    setState(() {
      userCustomBaseUrl = baseUrl;
    });
  }

  void _onTabTapped(int index) {
    setState(() {
      _currentIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> pages = [
      HomeScreen(
        apiKey: userApiKey,
        asrModel: userAsrModel,
        llmModel: userLlmModel,
        customBaseUrl: userCustomBaseUrl,
      ),
      const HistoryScreen(),
      SettingsScreen(
        currentApiKey: userApiKey,
        currentAsrModel: userAsrModel,
        currentLlmModel: userLlmModel,
        currentBaseUrl: userCustomBaseUrl,
        onApiKeySaved: _updateApiKey,
        onModelsSaved: _updateModels,
        onBaseUrlSaved: _updateCustomBaseUrl,
      ),
    ];

    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF0F172A),
                  Color(0xFF1E1B4B),
                  Color(0xFF0F172A),
                ],
              ),
            ),
          ),
          Positioned(
            top: -100,
            left: -100,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.blueAccent.withOpacity(0.2),
              ),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
                child: Container(),
              ),
            ),
          ),
          pages[_currentIndex],
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: const Color(0xFF0F172A).withOpacity(0.8),
        selectedItemColor: Colors.cyanAccent,
        unselectedItemColor: Colors.grey,
        currentIndex: _currentIndex,
        onTap: _onTabTapped,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.mic), label: '监听'),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: '历史'),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: '设置'),
        ],
      ),
    );
  }
}

class GlassmorphismContainer extends StatelessWidget {
  final Widget child;
  final double width;
  final double? height;
  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final Color? borderColor;
  final Color? backgroundColor;

  const GlassmorphismContainer({
    super.key,
    required this.child,
    this.width = double.infinity,
    this.height,
    this.borderRadius = 20,
    this.padding = EdgeInsets.zero,
    this.borderColor,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
        child: Container(
          width: width,
          height: height,
          padding: padding,
          decoration: BoxDecoration(
            color: backgroundColor ?? Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: borderColor ?? Colors.white.withOpacity(0.15),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 10,
                spreadRadius: 1,
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

// ================= 设置页 =================
class SettingsScreen extends StatefulWidget {
  final String currentApiKey;
  final String currentAsrModel;
  final String currentLlmModel;
  final String currentBaseUrl;
  final ValueChanged<String> onApiKeySaved;
  final void Function(String asrModel, String llmModel) onModelsSaved;
  final ValueChanged<String> onBaseUrlSaved;

  const SettingsScreen({
    super.key,
    required this.currentApiKey,
    required this.currentAsrModel,
    required this.currentLlmModel,
    required this.currentBaseUrl,
    required this.onApiKeySaved,
    required this.onModelsSaved,
    required this.onBaseUrlSaved,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController keyController;
  late final TextEditingController baseUrlController;
  late String selectedAsrModel;
  late String selectedLlmModel;
  bool enableContextCorrection = true;
  bool enableCardMerge = true;
  bool showStabilityPanel = true;

  @override
  void initState() {
    super.initState();
    keyController = TextEditingController(text: widget.currentApiKey);
    baseUrlController = TextEditingController(text: widget.currentBaseUrl);
    selectedAsrModel = widget.currentAsrModel;
    selectedLlmModel = widget.currentLlmModel;
    _loadAdvancedToggles();
  }

  Future<void> _loadAdvancedToggles() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      enableContextCorrection =
          prefs.getBool(prefEnableContextCorrection) ?? true;
      enableCardMerge = prefs.getBool(prefEnableCardMerge) ?? true;
      showStabilityPanel = prefs.getBool(prefShowStabilityPanel) ?? true;
    });
  }

  @override
  void dispose() {
    keyController.dispose();
    baseUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          20 + MediaQuery.of(context).viewInsets.bottom,
        ),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 40),
            const Text(
              '系统设置',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 30),
            const Text(
              '硅基流动 API Key',
              style: TextStyle(fontSize: 14, color: Colors.white70),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: keyController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: '粘贴从硅基流动搞来的 sk-...',
                hintStyle: const TextStyle(color: Colors.white30),
                filled: true,
                fillColor: Colors.white.withOpacity(0.1),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '自定义 Base URL（可留空）',
              style: TextStyle(fontSize: 14, color: Colors.white70),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: baseUrlController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText:
                    '例如 http://192.168.1.10:11434 或 http://127.0.0.1:8000/v1',
                hintStyle: const TextStyle(color: Colors.white30),
                filled: true,
                fillColor: Colors.white.withOpacity(0.1),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '留空则默认使用 https://api.siliconflow.cn',
              style: TextStyle(fontSize: 12, color: Colors.white60),
            ),
            const SizedBox(height: 20),
            const Text(
              '语音转写模型',
              style: TextStyle(fontSize: 14, color: Colors.white70),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: selectedAsrModel,
              dropdownColor: const Color(0xFF1E1B4B),
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.white.withOpacity(0.1),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
              style: const TextStyle(color: Colors.white),
              items: asrModelDescriptions.keys
                  .map(
                    (model) => DropdownMenuItem(
                      value: model,
                      child: Text(model, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) return;
                setState(() => selectedAsrModel = value);
              },
            ),
            const SizedBox(height: 8),
            Text(
              '模型：$selectedAsrModel\n特点：${asrModelDescriptions[selectedAsrModel] ?? ''}',
              style: const TextStyle(fontSize: 12, color: Colors.white60),
            ),
            const SizedBox(height: 16),
            const Text(
              '课堂总结模型',
              style: TextStyle(fontSize: 14, color: Colors.white70),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: selectedLlmModel,
              dropdownColor: const Color(0xFF1E1B4B),
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.white.withOpacity(0.1),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
              style: const TextStyle(color: Colors.white),
              items: llmModelDescriptions.keys
                  .map(
                    (model) => DropdownMenuItem(
                      value: model,
                      child: Text(model, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) return;
                setState(() => selectedLlmModel = value);
              },
            ),
            const SizedBox(height: 8),
            Text(
              '模型：$selectedLlmModel\n特点：${llmModelDescriptions[selectedLlmModel] ?? ''}',
              style: const TextStyle(fontSize: 12, color: Colors.white60),
            ),
            const SizedBox(height: 20),
            SwitchListTile(
              value: enableContextCorrection,
              onChanged: (value) {
                setState(() => enableContextCorrection = value);
              },
              activeColor: Colors.cyanAccent,
              title: const Text(
                '开启转写上下文纠错',
                style: TextStyle(color: Colors.white),
              ),
              subtitle: const Text(
                'ASR 结果会结合最近语境和核心词汇自动修正错字',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              value: enableCardMerge,
              onChanged: (value) {
                setState(() => enableCardMerge = value);
              },
              activeColor: Colors.cyanAccent,
              title: const Text(
                '开启跨卡片断句修复',
                style: TextStyle(color: Colors.white),
              ),
              subtitle: const Text(
                '自动判断上下卡片是否断裂并拼接',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              value: showStabilityPanel,
              onChanged: (value) {
                setState(() => showStabilityPanel = value);
              },
              activeColor: Colors.cyanAccent,
              title: const Text(
                '显示稳定性看板',
                style: TextStyle(color: Colors.white),
              ),
              subtitle: const Text(
                '展示离线队列、缓冲区和传输状态',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.cyanAccent.withOpacity(0.8),
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: () {
                  widget.onApiKeySaved(keyController.text.trim());
                  widget.onModelsSaved(selectedAsrModel, selectedLlmModel);
                  widget.onBaseUrlSaved(baseUrlController.text.trim());
                  SharedPreferences.getInstance().then((prefs) async {
                    await prefs.setBool(
                      prefEnableContextCorrection,
                      enableContextCorrection,
                    );
                    await prefs.setBool(prefEnableCardMerge, enableCardMerge);
                    await prefs.setBool(
                      prefShowStabilityPanel,
                      showStabilityPanel,
                    );
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('✅ 配置与高级开关已保存！'),
                      backgroundColor: Colors.green,
                    ),
                  );
                },
                child: const Text(
                  '保存配置',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

// ================= 主屏幕 =================
class HomeScreen extends StatelessWidget {
  final String apiKey;
  final String asrModel;
  final String llmModel;
  final String customBaseUrl;

  const HomeScreen({
    super.key,
    required this.apiKey,
    required this.asrModel,
    required this.llmModel,
    required this.customBaseUrl,
  });

  void _showSubjectDialog(BuildContext context) {
    TextEditingController subjectController = TextEditingController();
    TextEditingController termsController = TextEditingController();

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: "SubjectDialog",
      barrierColor: Colors.black.withOpacity(0.6),
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (context, anim1, anim2) {
        return Center(
          child: Material(
            color: Colors.transparent,
            child: GlassmorphismContainer(
              width: MediaQuery.of(context).size.width * 0.85,
              height: 340,
              borderRadius: 24,
              borderColor: Colors.amber.withOpacity(0.4),
              backgroundColor: const Color(0xFF1E1B4B).withOpacity(0.7),
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    '📍 设定当前科目',
                    style: TextStyle(
                      color: Colors.amber,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: subjectController,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    textAlign: TextAlign.center,
                    decoration: InputDecoration(
                      hintText: '如：线性代数、C++高级编程',
                      hintStyle: TextStyle(
                        color: Colors.white.withOpacity(0.3),
                      ),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.05),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: Colors.amber,
                          width: 1.5,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: Colors.white.withOpacity(0.1),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: termsController,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    maxLines: 2,
                    decoration: InputDecoration(
                      hintText: '当前学科重点/核心词汇（如：线性表，红黑树，时间复杂度）',
                      hintStyle: TextStyle(
                        color: Colors.white.withOpacity(0.3),
                      ),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.05),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: Colors.cyanAccent,
                          width: 1.2,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: Colors.white.withOpacity(0.1),
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  SizedBox(
                    width: double.infinity,
                    height: 45,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.amber.withOpacity(0.9),
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () {
                        String subject = subjectController.text.trim();
                        final String focusTerms = termsController.text.trim();
                        if (subject.isEmpty) subject = '通用课程';
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => LiveScreen(
                              apiKey: apiKey,
                              subjectName: subject,
                              focusTerms: focusTerms,
                              asrModel: asrModel,
                              llmModel: llmModel,
                              customBaseUrl: customBaseUrl,
                            ),
                          ),
                        );
                      },
                      child: const Text(
                        '开始上课',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, anim1, anim2, child) {
        return FadeTransition(
          opacity: anim1,
          child: ScaleTransition(
            scale: Tween<double>(
              begin: 0.9,
              end: 1.0,
            ).animate(CurvedAnimation(parent: anim1, curve: Curves.easeOut)),
            child: child,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'ClassEcho',
              style: TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.w900,
                letterSpacing: 2,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 10),
            const SizedBox(height: 80),
            GestureDetector(
              onTap: () {
                if (apiKey.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('请先在设置中填写 API Key。'),
                      backgroundColor: Colors.orange,
                    ),
                  );
                  return;
                }
                _showSubjectDialog(context);
              },
              child: GlassmorphismContainer(
                width: 180,
                height: 180,
                borderRadius: 90,
                child: const Center(
                  child: Icon(
                    Icons.mic_none_rounded,
                    size: 80,
                    color: Colors.cyanAccent,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ================= 历史记录列表页 =================
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<ClassSession> historyList = [];
  bool _isBackfillingTitles = false;

  String _fallbackTitle(ClassSession session) {
    if (session.summaries.isNotEmpty) {
      final t = session.summaries.first.text.trim();
      if (t.isNotEmpty) {
        return t.length > 20 ? '${t.substring(0, 20)}...' : t;
      }
    }
    final line = session.transcript
        .split('\n')
        .map((e) => e.trim())
        .firstWhere((e) => e.isNotEmpty, orElse: () => '课程记录');
    final cleaned = line.replaceAll(RegExp(r'^\[[^\]]+\]\s*'), '');
    if (cleaned.isEmpty) return '课程记录';
    return cleaned.length > 20 ? '${cleaned.substring(0, 20)}...' : cleaned;
  }

  String _displayTitle(ClassSession session) {
    final custom = session.title.trim();
    if (custom.isNotEmpty) return custom;
    return _fallbackTitle(session);
  }

  Future<void> _renameSessionTitle(ClassSession session) async {
    final ctrl = TextEditingController(text: _displayTitle(session));
    final newTitle = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('修改标题'),
          content: TextField(
            controller: ctrl,
            maxLength: 30,
            decoration: const InputDecoration(hintText: '输入新的标题'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, ctrl.text.trim()),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );

    if (newTitle == null) return;

    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList('class_history') ?? [];
    final idx = history.indexWhere((jsonStr) {
      final item = ClassSession.fromJson(jsonDecode(jsonStr));
      return item.sessionId == session.sessionId;
    });
    if (idx == -1) return;

    final old = ClassSession.fromJson(jsonDecode(history[idx]));
    final updated = old.copyWith(title: newTitle);
    history[idx] = jsonEncode(updated.toJson());
    await prefs.setStringList('class_history', history);
    await _loadHistory();
  }

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final savedJsonList = prefs.getStringList('class_history') ?? [];
    setState(() {
      historyList = savedJsonList
          .map((jsonStr) => ClassSession.fromJson(jsonDecode(jsonStr)))
          .toList();
    });
    unawaited(_backfillMissingTitles());
  }

  Future<String> _generateAiTitleForSession(
    ClassSession session,
    String apiKey,
    String llmModel,
    String customBaseUrl,
  ) async {
    final fallback = _fallbackTitle(session);
    final summaryHint = session.summaries
        .take(3)
        .map((e) => e.text.trim())
        .where((e) => e.isNotEmpty)
        .join('；');
    final transcriptHint = session.transcript
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .take(8)
        .join(' ');

    try {
      final response = await http
          .post(
            buildOpenAiStyleUri(customBaseUrl, 'chat/completions'),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'model': llmModel,
              'temperature': 0.2,
              'max_tokens': 40,
              'messages': [
                {
                  'role': 'system',
                  'content': '你是课堂记录命名助手。请仅输出一个简洁标题，不超过18个中文字符，不要引号，不要句号。',
                },
                {
                  'role': 'user',
                  'content':
                      '课程：${session.subject}\n要点：$summaryHint\n片段：$transcriptHint',
                },
              ],
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) return fallback;
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final raw =
          data['choices']?[0]?['message']?['content']?.toString().trim() ?? '';
      final cleaned = raw
          .replaceAll('\n', ' ')
          .replaceAll('"', '')
          .replaceAll('“', '')
          .replaceAll('”', '')
          .trim();
      if (cleaned.isEmpty) return fallback;
      return cleaned.length > 18 ? cleaned.substring(0, 18) : cleaned;
    } catch (_) {
      return fallback;
    }
  }

  Future<void> _backfillMissingTitles() async {
    if (_isBackfillingTitles) return;

    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('silicon_api_key') ?? '';
    if (apiKey.trim().isEmpty) return;

    final llmModel = prefs.getString('llm_model') ?? defaultLlmModel;
    final customBaseUrl = prefs.getString('custom_base_url') ?? '';
    final history = prefs.getStringList('class_history') ?? [];

    final indexes = <int>[];
    for (int i = 0; i < history.length; i++) {
      final item = ClassSession.fromJson(jsonDecode(history[i]));
      if (item.title.trim().isEmpty) {
        indexes.add(i);
      }
    }
    if (indexes.isEmpty) return;

    _isBackfillingTitles = true;
    try {
      for (final idx in indexes) {
        final old = ClassSession.fromJson(jsonDecode(history[idx]));
        final aiTitle = await _generateAiTitleForSession(
          old,
          apiKey,
          llmModel,
          customBaseUrl,
        );
        final updated = old.copyWith(title: aiTitle);
        history[idx] = jsonEncode(updated.toJson());
      }
      await prefs.setStringList('class_history', history);
      if (!mounted) return;
      setState(() {
        historyList = history
            .map((jsonStr) => ClassSession.fromJson(jsonDecode(jsonStr)))
            .toList();
      });
    } finally {
      _isBackfillingTitles = false;
    }
  }

  Future<void> _retryPendingTasks() async {
    final recoveredCount =
        await PendingAudioRetryService.retryAllPendingTasks();
    final leftCount = await PendingAudioTaskStore.instance.countPending();
    await _loadHistory();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('补偿完成：成功 $recoveredCount 段，待处理 $leftCount 段'),
        backgroundColor: Colors.teal,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 40),
            const Row(
              children: [
                Icon(Icons.storage, color: Colors.cyanAccent, size: 28),
                SizedBox(width: 10),
                Text(
                  '历史记录',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _retryPendingTasks,
                icon: const Icon(Icons.sync, color: Colors.tealAccent),
                label: const Text(
                  '批量重试离线片段',
                  style: TextStyle(color: Colors.tealAccent),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '本地共保存 ${historyList.length} 条课堂记录',
              style: TextStyle(
                fontSize: 14,
                color: Colors.white.withOpacity(0.5),
              ),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: historyList.isEmpty
                  ? const Center(
                      child: Text(
                        '暂无历史记录\n去开始一节课程吧',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white30, height: 1.5),
                      ),
                    )
                  : ListView.builder(
                      itemCount: historyList.length,
                      itemBuilder: (context, index) {
                        var session = historyList[index];
                        String preview = session.transcript.replaceAll(
                          '\n',
                          ' ',
                        );
                        if (preview.length > 50)
                          preview = '${preview.substring(0, 50)}...';

                        return GestureDetector(
                          onTap: () async {
                            // 等待详情页返回（因为详情页里可能修改了卡片），返回后重新拉取最新数据刷新列表
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    HistoryDetailScreen(session: session),
                              ),
                            );
                            _loadHistory();
                          },
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 16),
                            child: GlassmorphismContainer(
                              padding: const EdgeInsets.all(16),
                              borderColor: Colors.cyanAccent.withOpacity(0.2),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(
                                        child: Text(
                                          _displayTitle(session),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.amber,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      IconButton(
                                        tooltip: '修改标题',
                                        icon: const Icon(
                                          Icons.edit,
                                          color: Colors.cyanAccent,
                                          size: 18,
                                        ),
                                        onPressed: () =>
                                            _renameSessionTitle(session),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.menu_book_rounded,
                                        size: 14,
                                        color: Colors.white54,
                                      ),
                                      const SizedBox(width: 5),
                                      Expanded(
                                        child: Text(
                                          session.subject,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      const Icon(
                                        Icons.schedule,
                                        size: 14,
                                        color: Colors.white54,
                                      ),
                                      const SizedBox(width: 5),
                                      Text(
                                        session.dateStr,
                                        style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    preview,
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.7),
                                      fontSize: 13,
                                      height: 1.4,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.memory,
                                        size: 14,
                                        color: Colors.purpleAccent,
                                      ),
                                      const SizedBox(width: 5),
                                      Text(
                                        '提炼了 ${session.summaries.length} 个知识模块',
                                        style: const TextStyle(
                                          color: Colors.purpleAccent,
                                          fontSize: 12,
                                        ),
                                      ),
                                      const Spacer(),
                                      const Icon(
                                        Icons.arrow_forward_ios,
                                        size: 12,
                                        color: Colors.white30,
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ================= 【更新】：支持长按编辑的详情与导出页 =================
class HistoryDetailScreen extends StatefulWidget {
  final ClassSession session;

  const HistoryDetailScreen({super.key, required this.session});

  @override
  State<HistoryDetailScreen> createState() => _HistoryDetailScreenState();
}

class _HistoryDetailScreenState extends State<HistoryDetailScreen> {
  final Map<String, bool> _isAnsweringByTaskId = {};
  final Map<String, String> _answerMarkdownByTaskId = {};
  final Map<String, String?> _answerErrorByTaskId = {};
  String? _manualTitle;

  @override
  void initState() {
    super.initState();
    _manualTitle = widget.session.title.trim().isEmpty
        ? null
        : widget.session.title.trim();
  }

  String get _displayTitle {
    final current = (_manualTitle ?? widget.session.title).trim();
    if (current.isNotEmpty) return current;
    if (widget.session.summaries.isNotEmpty) {
      final s = widget.session.summaries.first.text.trim();
      if (s.isNotEmpty) return s.length > 20 ? '${s.substring(0, 20)}...' : s;
    }
    final line = widget.session.transcript
        .split('\n')
        .map((e) => e.trim())
        .firstWhere((e) => e.isNotEmpty, orElse: () => '课程记录');
    final cleaned = line.replaceAll(RegExp(r'^\[[^\]]+\]\s*'), '').trim();
    if (cleaned.isEmpty) return '课程记录';
    return cleaned.length > 20 ? cleaned.substring(0, 20) : cleaned;
  }

  Future<void> _editSessionTitle() async {
    final ctrl = TextEditingController(text: _displayTitle);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('修改标题'),
          content: TextField(
            controller: ctrl,
            maxLength: 30,
            decoration: const InputDecoration(hintText: '输入新的标题'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, ctrl.text.trim()),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );

    if (newTitle == null) return;

    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList('class_history') ?? [];
    final idx = history.indexWhere((jsonStr) {
      final item = ClassSession.fromJson(jsonDecode(jsonStr));
      return item.sessionId == widget.session.sessionId;
    });
    if (idx == -1) return;

    final old = ClassSession.fromJson(jsonDecode(history[idx]));
    final updated = old.copyWith(title: newTitle);
    history[idx] = jsonEncode(updated.toJson());
    await prefs.setStringList('class_history', history);

    if (!mounted) return;
    setState(() {
      _manualTitle = newTitle;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('标题已更新'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showTimelineImagePreview(TimelineNode node) {
    final imagePath = node.imagePath;
    if (imagePath == null || imagePath.isEmpty) return;

    showDialog(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: Colors.transparent,
          child: GestureDetector(
            onTap: () => Navigator.pop(dialogContext),
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.file(File(imagePath), fit: BoxFit.contain),
              ),
            ),
          ),
        );
      },
    );
  }

  List<AnkiCsvCard> _buildAnkiCards() {
    final cards = <AnkiCsvCard>[];

    for (final card in widget.session.summaries) {
      final front = '要点：${card.text}';
      final backParts = <String>[
        '课程：${widget.session.subject}',
        if (widget.session.focusTerms.trim().isNotEmpty)
          '核心词汇：${widget.session.focusTerms}',
        '知识说明：${card.text}',
        if (widget.session.transcript.trim().isNotEmpty)
          '课堂原声：${_shortenForAnki(widget.session.transcript)}',
      ];

      cards.add(
        AnkiCsvCard(
          front: front,
          back: backParts.join('\n\n'),
          tags: 'class_echo summary ${widget.session.subject}',
        ),
      );
    }

    for (final task in widget.session.bounties) {
      final answer = (_answerMarkdownByTaskId[task.id] ?? '').trim();
      final context = _extractContextForTask(task);
      final front = '待解问题：${task.context}';
      final backParts = <String>[
        '课程：${widget.session.subject}',
        if (widget.session.focusTerms.trim().isNotEmpty)
          '核心词汇：${widget.session.focusTerms}',
        '问题上下文：$context',
        if (answer.isNotEmpty)
          '深度解答：$answer'
        else
          '深度解答：可在历史详情页点击“生成深度解答”后再导出。',
      ];

      cards.add(
        AnkiCsvCard(
          front: front,
          back: backParts.join('\n\n'),
          tags: 'class_echo bounty ${widget.session.subject}',
        ),
      );
    }

    return cards;
  }

  String _shortenForAnki(String text, {int maxLength = 600}) {
    final normalized = text.replaceAll('\r', ' ').replaceAll('\n', ' ');
    if (normalized.length <= maxLength) return normalized;
    return '${normalized.substring(0, maxLength)}...';
  }

  String _sanitizeFileName(String input) {
    return input.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  }

  Future<Directory> _resolveExportDirectory() async {
    if (Platform.isAndroid) {
      final candidates = <Directory>[
        Directory('/storage/emulated/0/Download'),
        Directory('/sdcard/Download'),
      ];
      for (final dir in candidates) {
        try {
          if (await dir.exists()) return dir;
          await dir.create(recursive: true);
          return dir;
        } catch (_) {
          continue;
        }
      }
    }

    final downloads = await getDownloadsDirectory();
    if (downloads != null) {
      await downloads.create(recursive: true);
      return downloads;
    }

    final fallbackDir = await getApplicationDocumentsDirectory();
    await fallbackDir.create(recursive: true);
    return fallbackDir;
  }

  Future<File> _writeAnkiCsvFile() async {
    final exportDir = await _resolveExportDirectory();
    final fileName =
        'ClassEcho_${_sanitizeFileName(widget.session.subject)}_${_sanitizeFileName(widget.session.dateStr)}_anki.csv';
    final file = File(p.join(exportDir.path, fileName));

    final rows = <List<String>>[
      ['Front', 'Back', 'Tags'],
      ..._buildAnkiCards().map((card) => [card.front, card.back, card.tags]),
    ];

    const converter = ListToCsvConverter(
      fieldDelimiter: ',',
      eol: '\n',
      textEndDelimiter: '"',
      textDelimiter: '"',
    );

    await file.writeAsString(converter.convert(rows), flush: true);
    return file;
  }

  Future<void> _exportAnkiCsv() async {
    try {
      final file = await _writeAnkiCsvFile();
      if (!mounted) return;

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/csv')],
          text: 'ClassEcho 已导出 Anki 复习卡片：${p.basename(file.path)}',
          subject: 'ClassEcho Anki CSV 导出',
        ),
      );

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Anki CSV 已保存到：${file.path}'),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e'), backgroundColor: Colors.redAccent),
      );
    }
  }

  DateTime? _parseTaskTime(BountyTask task) {
    final base = DateTime.tryParse(widget.session.dateStr);
    if (base == null) return null;
    final parts = task.timeStr.split(':');
    if (parts.length < 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    return DateTime(base.year, base.month, base.day, hour, minute);
  }

  String _extractContextForTask(BountyTask task) {
    if (widget.session.transcriptSegments.isNotEmpty) {
      final segments = [...widget.session.transcriptSegments]
        ..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
      int centerIndex = segments.length ~/ 2;
      final taskTime = _parseTaskTime(task);
      if (taskTime != null) {
        final targetMs = taskTime.millisecondsSinceEpoch;
        int bestDelta = 1 << 62;
        for (int i = 0; i < segments.length; i++) {
          final delta = (segments[i].timestampMs - targetMs).abs();
          if (delta < bestDelta) {
            bestDelta = delta;
            centerIndex = i;
          }
        }
      }

      final start = (centerIndex - 3).clamp(0, segments.length - 1);
      final end = (centerIndex + 3).clamp(0, segments.length - 1);
      final selected = segments.sublist(start, end + 1);
      return selected
          .map((s) => '[${formatTimeForTranscript(s.timestampMs)}] ${s.text}')
          .join('\n');
    }

    final lines = widget.session.transcript
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return task.context;

    int center = lines.length ~/ 2;
    final taskKey = task.context.length > 10
        ? task.context.substring(0, 10)
        : task.context;
    final hit = lines.indexWhere((line) => line.contains(taskKey));
    if (hit != -1) center = hit;

    final start = (center - 4).clamp(0, lines.length - 1);
    final end = (center + 4).clamp(0, lines.length - 1);
    return lines.sublist(start, end + 1).join('\n');
  }

  String _buildDeepTutorPrompt(BountyTask task, String context) {
    return '''
你是课程复盘阶段的学习助手。当前课程：${widget.session.subject}。

学生在课堂中的疑难点：
${task.context}

疑难点附近的课堂原始转写上下文：
$context

请输出一份“深度解答”，严格按下面结构：
## 1. 问题重述
## 2. 核心结论
## 3. 详细推导与解释
如果是理工科：请给出必要公式推导，公式使用 LaTeX（行内用 \$...\$，块级用 \$\$...\$\$）。
如果涉及编程：请给出最小可运行代码示例并解释关键行。
## 4. 易错点与反例
## 5. 课后练习（3题，含简要答案）

要求：
- 用中文讲解，逻辑严谨，先结论后展开。
- 内容要和给定课堂上下文保持一致，避免泛泛而谈。
''';
  }

  Future<void> _requestDeepAnswer(BountyTask task) async {
    final taskId = task.id;
    final contextText = _extractContextForTask(task);
    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('silicon_api_key') ?? '';
    final llmModel = prefs.getString('llm_model') ?? defaultLlmModel;
    final customBaseUrl = prefs.getString('custom_base_url') ?? '';

    if (apiKey.isEmpty) {
      if (!mounted) return;
      setState(() {
        _answerErrorByTaskId[taskId] = '请先在设置页配置 API Key';
      });
      return;
    }

    setState(() {
      _isAnsweringByTaskId[taskId] = true;
      _answerErrorByTaskId.remove(taskId);
      _answerMarkdownByTaskId[taskId] = '';
    });

    final request = http.Request(
      'POST',
      buildOpenAiStyleUri(customBaseUrl, 'chat/completions'),
    );
    request.headers.addAll({
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
    });
    request.body = jsonEncode({
      'model': llmModel,
      'stream': true,
      'temperature': 0.2,
      'max_tokens': 900,
      'messages': [
        {'role': 'system', 'content': '你是严谨的理工科学习助手，擅长将课堂片段转化为可学习的讲解。'},
        {'role': 'user', 'content': _buildDeepTutorPrompt(task, contextText)},
      ],
    });

    try {
      final response = await http.Client()
          .send(request)
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        final errBody = await response.stream.bytesToString();
        if (!mounted) return;
        setState(() {
          _answerErrorByTaskId[taskId] =
              '请求失败：HTTP ${response.statusCode}\n$errBody';
          _isAnsweringByTaskId[taskId] = false;
        });
        return;
      }

      await for (final line
          in response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload.isEmpty) continue;
        if (payload == '[DONE]') break;

        try {
          final Map<String, dynamic> jsonMap = jsonDecode(payload);
          final choices = jsonMap['choices'];
          if (choices is! List || choices.isEmpty) continue;
          final delta = choices.first['delta'];
          final chunk = delta?['content']?.toString() ?? '';
          if (chunk.isEmpty) continue;

          if (!mounted) return;
          setState(() {
            _answerMarkdownByTaskId[taskId] =
                (_answerMarkdownByTaskId[taskId] ?? '') + chunk;
          });
        } catch (_) {
          continue;
        }
      }

      if (!mounted) return;
      setState(() {
        _isAnsweringByTaskId[taskId] = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _answerErrorByTaskId[taskId] = '流式请求异常：$e';
        _isAnsweringByTaskId[taskId] = false;
      });
    }
  }

  void _shareAsMarkdown(BuildContext context) {
    StringBuffer sb = StringBuffer();
    sb.writeln('# 【${widget.session.subject}】课堂笔记 (${widget.session.dateStr})');
    sb.writeln();

    var highlighted = widget.session.summaries
        .where((s) => s.isHighlighted)
        .toList();
    if (highlighted.isNotEmpty) {
      sb.writeln('## 🌟 核心考点');
      for (var card in highlighted) sb.writeln('- ${card.text}');
      sb.writeln();
    }

    var normal = widget.session.summaries
        .where((s) => !s.isHighlighted)
        .toList();
    if (normal.isNotEmpty) {
      sb.writeln('## 要点总结');
      for (var card in normal) sb.writeln('- ${card.text}');
      sb.writeln();
    }

    if (widget.session.bounties.isNotEmpty) {
      sb.writeln('## 待解问题清单');
      for (var task in widget.session.bounties) {
        sb.writeln('- [${task.timeStr}] 问题片段：“${task.context}”');
      }
      sb.writeln();
    }

    sb.writeln('## 📜 课堂原声转写');
    sb.writeln(widget.session.transcript);

    Share.share(sb.toString(), subject: '${widget.session.subject} 课堂笔记');
  }

  Future<void> _saveSessionToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      List<String> history = prefs.getStringList('class_history') ?? [];
      int targetIdx = history.indexWhere((jsonStr) {
        var s = ClassSession.fromJson(jsonDecode(jsonStr));
        return s.dateStr == widget.session.dateStr;
      });

      if (targetIdx != -1) {
        history[targetIdx] = jsonEncode(widget.session.toJson());
        await prefs.setStringList('class_history', history);
      }
    } catch (e) {
      debugPrint('保存失败: $e');
    }
  }

  void _showEditDialog(int index, SummaryCard card) {
    TextEditingController ctrl = TextEditingController(text: card.text);
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1B4B),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            // 【终极修复】：直接写死十六进制常量色值，避开所有方法调用，绝对不会报错且性能最高！
            side: const BorderSide(color: Color(0x8018FFFF)),
          ),
          title: const Row(
            children: [
              Icon(Icons.edit_note, color: Colors.cyanAccent),
              SizedBox(width: 8),
              Text(
                '修正神经节点',
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
            ],
          ),
          content: TextField(
            controller: ctrl,
            maxLines: 4,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.black26,
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Colors.cyanAccent),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Colors.white24),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('放弃', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyanAccent,
                foregroundColor: Colors.black,
              ),
              onPressed: () async {
                setState(() {
                  widget.session.summaries[index].text = ctrl.text.trim();
                });
                await _saveSessionToPrefs();
                if (mounted) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('✅ 节点修正已保存'),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              },
              child: const Text(
                '覆写',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        title: Text(
          _displayTitle,
          style: const TextStyle(fontWeight: FontWeight.w300, fontSize: 16),
        ),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            tooltip: '修改标题',
            onPressed: _editSessionTitle,
            icon: const Icon(Icons.edit, color: Colors.cyanAccent),
          ),
          PopupMenuButton<HistoryExportAction>(
            icon: const Icon(Icons.more_vert, color: Colors.cyanAccent),
            onSelected: (value) {
              switch (value) {
                case HistoryExportAction.markdown:
                  _shareAsMarkdown(context);
                  break;
                case HistoryExportAction.ankiCsv:
                  _exportAnkiCsv();
                  break;
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: HistoryExportAction.markdown,
                child: Text('导出 Markdown'),
              ),
              PopupMenuItem(
                value: HistoryExportAction.ankiCsv,
                child: Text('导出 Anki (CSV)'),
              ),
            ],
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: GlassmorphismContainer(
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      '档案生成时间：',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    Text(
                      widget.session.dateStr,
                      style: const TextStyle(color: Colors.amber, fontSize: 12),
                    ),
                  ],
                ),
                if (widget.session.focusTerms.trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '核心词汇：${widget.session.focusTerms}',
                    style: const TextStyle(
                      color: Colors.cyanAccent,
                      fontSize: 12,
                    ),
                  ),
                ],
                const Divider(color: Colors.white24, height: 30),
                const Row(
                  children: [
                    Text(
                      '要点总结',
                      style: TextStyle(
                        color: Colors.purpleAccent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Spacer(),
                    Text(
                      '(长按可修正)',
                      style: TextStyle(color: Colors.white30, fontSize: 10),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ...widget.session.summaries.asMap().entries.map((entry) {
                  int idx = entry.key;
                  SummaryCard card = entry.value;
                  return GestureDetector(
                    onLongPress: () => _showEditDialog(idx, card),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.only(bottom: 12.0),
                      color: Colors.transparent,
                      child: Text(
                        '• ${card.text}',
                        style: TextStyle(
                          color: card.isHighlighted
                              ? Colors.amber
                              : Colors.white70,
                          height: 1.5,
                        ),
                      ),
                    ),
                  );
                }),
                if (widget.session.bounties.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  const Text(
                    '待解问题清单',
                    style: TextStyle(
                      color: Colors.redAccent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 10),
                  ...widget.session.bounties.map((b) {
                    final answering = _isAnsweringByTaskId[b.id] ?? false;
                    final answerText = _answerMarkdownByTaskId[b.id] ?? '';
                    final answerErr = _answerErrorByTaskId[b.id];
                    return Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 12.0),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.03),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '[${b.timeStr}] ${b.context}',
                            style: const TextStyle(
                              color: Colors.white60,
                              fontStyle: FontStyle.italic,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton.icon(
                              onPressed: answering
                                  ? null
                                  : () => _requestDeepAnswer(b),
                              icon: const Icon(Icons.psychology_alt, size: 18),
                              label: Text(answering ? '正在生成解答...' : '生成深度解答'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.cyanAccent,
                                side: const BorderSide(
                                  color: Colors.cyanAccent,
                                ),
                              ),
                            ),
                          ),
                          if (answering) ...[
                            const SizedBox(height: 10),
                            const LinearProgressIndicator(minHeight: 2),
                          ],
                          if (answerErr != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              answerErr,
                              style: const TextStyle(
                                color: Colors.orangeAccent,
                                fontSize: 12,
                              ),
                            ),
                          ],
                          if (answerText.trim().isNotEmpty) ...[
                            const SizedBox(height: 10),
                            const Divider(color: Colors.white24),
                            const SizedBox(height: 6),
                            EnhancedMarkdownView(data: answerText),
                          ],
                        ],
                      ),
                    );
                  }),
                ],
                const SizedBox(height: 20),
                const Text(
                  '📜 原始听写文本',
                  style: TextStyle(
                    color: Colors.cyanAccent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 10),
                if (widget.session.timelineNodes.isNotEmpty)
                  ...buildTimelineWidgets(
                    widget.session.timelineNodes,
                    onImageTap: _showTimelineImagePreview,
                  )
                else
                  Text(
                    widget.session.transcript,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 14,
                      height: 1.6,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ================= 实况监听页 =================
class LiveScreen extends StatefulWidget {
  final String apiKey;
  final String subjectName;
  final String focusTerms;
  final String asrModel;
  final String llmModel;
  final String customBaseUrl;

  const LiveScreen({
    super.key,
    required this.apiKey,
    required this.subjectName,
    required this.focusTerms,
    required this.asrModel,
    required this.llmModel,
    required this.customBaseUrl,
  });

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> with WidgetsBindingObserver {
  final AudioRecorder audioRecorder = AudioRecorder();
  static const int _audioSampleRate = 16000;
  static const int _audioBytesPerSample = 2;
  // 仅用于展示“本次预估消费”，具体账单以平台结算页为准。
  static const double _asrPriceRmbPerMinute = 0.012;
  bool isRecording = false;
  bool isBreakMode = false;
  bool isPowerSavingMode = false;
  bool _isStopping = false;
  bool _hasConsumedForSession = false;
  bool _enableContextCorrection = true;
  bool _enableCardMerge = true;
  bool _showStabilityPanel = true;
  bool _isRetryingPending = false;
  int _pendingChunkCount = 0;
  int _uploadedAudioMs = 0;
  String? _lastPipelineError;
  final String _sessionId = DateTime.now().millisecondsSinceEpoch.toString();

  String fullTranscript = "等待老师发言...\n\n";
  List<TranscriptSegment> transcriptSegments = [];
  List<TimelineNode> timelineNodes = [];
  List<TimelineNode> semanticWindowNodes = [];
  List<SummaryCard> aiSummaryCards = [];
  String semanticBuffer = "";
  bool isPinnedMode = false;

  List<BountyTask> bountyTasks = [];
  StreamSubscription<List<int>>? recorderStreamSubscription;
  List<int> mainAudioBuffer = [];
  Timer? sliceTimer;
  Timer? _stabilityTimer;

  Duration get _sliceDuration => const Duration(seconds: 15);

  int get _semanticMinLength => 60;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadRuntimePreferences();
    _startStabilityRefreshLoop();
    _initAndStartContinuousPipeline();
  }

  Future<void> _loadRuntimePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _enableContextCorrection =
          prefs.getBool(prefEnableContextCorrection) ?? true;
      _enableCardMerge = prefs.getBool(prefEnableCardMerge) ?? true;
      _showStabilityPanel = prefs.getBool(prefShowStabilityPanel) ?? true;
    });
  }

  void _startStabilityRefreshLoop() {
    _refreshPendingCount();
    _stabilityTimer?.cancel();
    _stabilityTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      unawaited(_refreshPendingCount());
    });
  }

  Future<void> _refreshPendingCount() async {
    final count = await PendingAudioTaskStore.instance.countPending();
    if (!mounted) return;
    setState(() => _pendingChunkCount = count);
  }

  Future<void> _retryPendingInBackground() async {
    if (_isRetryingPending) return;
    setState(() => _isRetryingPending = true);
    try {
      await PendingAudioRetryService.retryAllPendingTasks();
      await _refreshPendingCount();
    } finally {
      if (mounted) {
        setState(() => _isRetryingPending = false);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!isRecording) return;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      sliceTimer?.cancel();
      unawaited(_drainAndSendCurrentBuffer());
      return;
    }

    if (state == AppLifecycleState.resumed && !isBreakMode) {
      _startSliceTimer();
      unawaited(_retryPendingInBackground());
    }
  }

  void _appendTranscriptSegment(TranscriptSegment segment) {
    transcriptSegments.add(segment);
    transcriptSegments.sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
    timelineNodes.add(
      TimelineNode.text(
        id: 'text_${segment.timestampMs}_${transcriptSegments.length}',
        timestampMs: segment.timestampMs,
        text: segment.text,
      ),
    );
    fullTranscript = buildTranscriptFromTimelineNodes(timelineNodes);
  }

  void _appendImageNode(TimelineNode node) {
    timelineNodes.add(node);
    fullTranscript = buildTranscriptFromTimelineNodes(timelineNodes);
  }

  void _appendSemanticWindowNode(TimelineNode node) {
    semanticWindowNodes.add(node);
  }

  void _clearSemanticWindow() {
    semanticBuffer = '';
    semanticWindowNodes.clear();
  }

  Future<void> _cachePendingAudioTask(Uint8List wavBytes, String error) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final appDir = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(appDir.path, 'pending_audio_chunks'));
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }

    final filename = '${_sessionId}_$now.wav';
    final filePath = p.join(folder.path, filename);
    await File(filePath).writeAsBytes(wavBytes, flush: true);

    await PendingAudioTaskStore.instance.insertPending(
      PendingAudioTask(
        sessionId: _sessionId,
        audioFilePath: filePath,
        timestampMs: now,
        status: 'pending',
        createdAtMs: now,
        lastError: error,
      ),
    );
  }

  Future<void> _initAndStartContinuousPipeline() async {
    bool hasPermission = await audioRecorder.hasPermission();
    if (!hasPermission) {
      setState(() {
        fullTranscript = "❌ 没有麦克风权限，请在系统设置里允许麦克风访问后重试。";
        _lastPipelineError = "麦克风权限未授予";
      });
      return;
    }

    setState(() {
      isRecording = true;
      fullTranscript = "[${widget.subjectName}] 录音已开始。\n";
      aiSummaryCards.add(SummaryCard(text: "正在等待更多课堂内容以生成首条要点。"));
    });

    await WakelockPlus.enable();
    await _startRecorderStream();
    _startSliceTimer();
  }

  Future<void> _startRecorderStream() async {
    const config = RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
    );
    final Stream<List<int>> audioStream = await audioRecorder.startStream(
      config,
    );
    recorderStreamSubscription = audioStream.listen(
      (data) => mainAudioBuffer.addAll(data),
    );
  }

  void _startSliceTimer() {
    sliceTimer?.cancel();
    sliceTimer = Timer.periodic(_sliceDuration, (timer) {
      unawaited(_drainAndSendCurrentBuffer());
    });
  }

  Future<void> _drainAndSendCurrentBuffer() async {
    if (mainAudioBuffer.isEmpty || !isRecording) return;
    final chunkToSend = List<int>.from(mainAudioBuffer);
    mainAudioBuffer.clear();
    if (chunkToSend.isNotEmpty) {
      await _sendToCloudZeroLoss(chunkToSend);
    }
  }

  Future<String> _persistPickedImage(XFile file) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final appDir = await getApplicationDocumentsDirectory();
    final folder = Directory(
      p.join(appDir.path, 'whiteboard_snapshots', _sessionId),
    );
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }

    final extension = p.extension(file.path).isNotEmpty
        ? p.extension(file.path)
        : '.jpg';
    final targetPath = p.join(folder.path, 'snapshot_$now$extension');
    await File(targetPath).writeAsBytes(await file.readAsBytes(), flush: true);
    return targetPath;
  }

  Future<void> _showSnapshotSourceSheet() async {
    if (!isRecording) return;

    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1B4B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(
                  Icons.photo_camera,
                  color: Colors.cyanAccent,
                ),
                title: const Text('拍照', style: TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await _captureWhiteboardSnapshot(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.photo_library,
                  color: Colors.cyanAccent,
                ),
                title: const Text(
                  '从相册选择',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await _captureWhiteboardSnapshot(ImageSource.gallery);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _captureWhiteboardSnapshot(ImageSource source) async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: source, imageQuality: 85);
      if (picked == null) return;

      final savedPath = await _persistPickedImage(picked);
      final node = TimelineNode.image(
        id: 'image_${DateTime.now().millisecondsSinceEpoch}',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        imagePath: savedPath,
        imageLabel: source == ImageSource.camera ? '白板拍照' : '相册图片',
      );

      if (!mounted) return;
      setState(() {
        _appendImageNode(node);
        _appendSemanticWindowNode(node);
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('图片节点已插入时间轴'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('图片采集失败：$e'), backgroundColor: Colors.redAccent),
      );
    }
  }

  Future<void> _sendToCloudZeroLoss(List<int> rawPcmData) async {
    Uint8List? wavBytes;
    try {
      final sampleCount = rawPcmData.length ~/ _audioBytesPerSample;
      final chunkMs = ((sampleCount * 1000) / _audioSampleRate).round();
      if (chunkMs > 0) {
        _uploadedAudioMs += chunkMs;
      }
      wavBytes = _generateWavHeader(rawPcmData, 16000, 1);
      var request = http.MultipartRequest(
        'POST',
        buildOpenAiStyleUri(widget.customBaseUrl, 'audio/transcriptions'),
      );
      request.headers.addAll({'Authorization': 'Bearer ${widget.apiKey}'});
      request.fields['model'] = widget.asrModel;
      request.files.add(
        http.MultipartFile.fromBytes('file', wavBytes, filename: 'chunk.wav'),
      );

      var response = await request.send().timeout(const Duration(seconds: 15));
      var responseData = await response.stream.bytesToString();

      if (response.statusCode == 200) {
        String text = jsonDecode(responseData)['text'].toString().trim();
        if (_enableContextCorrection) {
          text = await _repairTranscriptByContext(text);
        }
        if (text.isNotEmpty && mounted) {
          final segment = TranscriptSegment(
            timestampMs: DateTime.now().millisecondsSinceEpoch,
            text: text,
          );
          setState(() {
            _appendTranscriptSegment(segment);
            semanticBuffer += '$text ';
            _appendSemanticWindowNode(
              TimelineNode.text(
                id: 'semantic_${segment.timestampMs}_${transcriptSegments.length}',
                timestampMs: segment.timestampMs,
                text: segment.text,
              ),
            );
            _lastPipelineError = null;
          });
          _checkSemanticTrigger();
        }
      } else {
        final String statusMsg = 'ASR 请求失败: HTTP ${response.statusCode}';
        debugPrint('$statusMsg, body=$responseData');
        await _cachePendingAudioTask(wavBytes, '$statusMsg body=$responseData');
        if (mounted) {
          setState(() {
            _lastPipelineError = '$statusMsg（已离线缓存，稍后可补偿）';
          });
        }
      }
    } catch (e) {
      debugPrint('ASR 异常: $e');
      if (wavBytes != null) {
        await _cachePendingAudioTask(wavBytes, 'ASR 异常: $e');
      }
      if (mounted) {
        setState(() {
          _lastPipelineError = 'ASR 异常: $e（已离线缓存，稍后可补偿）';
        });
      }
    }
  }

  Future<String> _repairTranscriptByContext(String rawText) async {
    final cleaned = rawText.trim();
    if (cleaned.isEmpty) return cleaned;

    final recent = transcriptSegments.reversed
        .take(4)
        .toList()
        .reversed
        .map((e) => e.text)
        .join(' ');

    try {
      final response = await http
          .post(
            buildOpenAiStyleUri(widget.customBaseUrl, 'chat/completions'),
            headers: {
              'Authorization': 'Bearer ${widget.apiKey}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'model': widget.llmModel,
              'temperature': 0,
              'max_tokens': 100,
              'messages': [
                {
                  'role': 'system',
                  'content':
                      '你是课堂语音转写纠错器。仅修正明显错字/同音词，不改变原意，不扩写，不解释。只返回修正后的单句文本。',
                },
                {
                  'role': 'user',
                  'content':
                      '课程：${widget.subjectName}\n核心词汇：${widget.focusTerms}\n上文：$recent\n当前句：$cleaned',
                },
              ],
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) return cleaned;
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final fixed =
          data['choices']?[0]?['message']?['content']?.toString().trim() ??
          cleaned;
      return fixed.isEmpty ? cleaned : fixed;
    } catch (_) {
      return cleaned;
    }
  }

  void _checkSemanticTrigger() {
    bool hasPunctuation =
        semanticBuffer.endsWith('。') ||
        semanticBuffer.endsWith('？') ||
        semanticBuffer.endsWith('！');
    bool hasTransition =
        semanticBuffer.contains('所以') ||
        semanticBuffer.contains('接下来') ||
        semanticBuffer.contains('总之') ||
        semanticBuffer.contains('另外');

    if (semanticBuffer.length > _semanticMinLength &&
        (hasPunctuation || hasTransition)) {
      final textToSummarize = semanticBuffer;
      final nodesToSummarize = List<TimelineNode>.from(semanticWindowNodes);
      _clearSemanticWindow();
      _callLLMBrain(textToSummarize, nodesToSummarize);
    }
  }

  List<String> _extractSummaryUnits(String summary) {
    final lines = summary
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .where((e) => !e.startsWith('【核心考点】'))
        .where((e) => !e.startsWith('【细节】'))
        .toList();

    final units = <String>[];
    for (final line in lines) {
      final normalized = line.replaceFirst(RegExp(r'^[-•\d\.\s]+'), '').trim();
      if (normalized.isEmpty) continue;
      if (normalized.length <= 38) {
        units.add(normalized);
        continue;
      }

      final parts = normalized
          .split(RegExp(r'(?<=[。！？；;])\s*'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty);
      units.addAll(parts);
    }

    return units;
  }

  bool _looksLikeContinuation(String prev, String curr) {
    const weakEndings = ['的', '了', '和', '与', '及', '在', '对', '把', '将'];
    const continueStarts = ['并且', '并', '而且', '同时', '其中', '然后', '因此', '所以'];

    if (prev.isEmpty || curr.isEmpty) return false;
    final prevLast = prev.substring(prev.length - 1);
    final prevNoEndPunc = !'。！？；.!?;'.contains(prevLast);
    final currStartsWithConnector = continueStarts.any(
      (w) => curr.startsWith(w),
    );
    final prevEndsWeak = weakEndings.any((w) => prev.endsWith(w));
    return prevNoEndPunc || currStartsWithConnector || prevEndsWeak;
  }

  void _insertSummaryCardsWithContext(String summary) {
    final units = _extractSummaryUnits(summary);
    if (units.isEmpty) {
      aiSummaryCards.insert(0, SummaryCard(text: summary.trim()));
      return;
    }

    for (final unit in units.reversed) {
      if (aiSummaryCards.isNotEmpty &&
          _looksLikeContinuation(unit, aiSummaryCards.first.text)) {
        aiSummaryCards.first.text = '$unit${aiSummaryCards.first.text}';
      } else {
        aiSummaryCards.insert(0, SummaryCard(text: unit));
      }
    }
  }

  String _buildDynamicSystemPrompt({bool hasImages = false}) {
    final terms = widget.focusTerms.trim();
    final termsGuide = terms.isEmpty
        ? '当前未提供额外核心词汇，请保持术语准确并尽量使用课堂上下文中的专业表述。'
        : '本次课程涉及的核心术语有：$terms。请在总结时优先且准确地使用这些专业词汇，避免替换成模糊表达。';

    final imageGuide = hasImages
        ? '当前语义窗口内包含白板快照/相册图片，请结合图像内容与文字上下文进行多模态总结。'
        : '当前语义窗口没有图片节点，仅依据文本总结。';

    return '你是一个课堂总结助手，当前课程是【${widget.subjectName}】。$termsGuide $imageGuide\n'
        '请将语音转写内容极速提炼为结构化总结。格式：\n'
        '【核心考点】：一句话总结。\n'
        '【细节】：列出1-2个关键点。';
  }

  String _toDataUrl(String imagePath) {
    final bytes = File(imagePath).readAsBytesSync();
    final extension = p.extension(imagePath).toLowerCase();
    final mimeType = extension == '.png' ? 'image/png' : 'image/jpeg';
    return 'data:$mimeType;base64,${base64Encode(bytes)}';
  }

  String _resolveVisionModel() {
    final current = widget.llmModel.toLowerCase();
    if (current.contains('vl') ||
        current.contains('vision') ||
        current.contains('4.5v') ||
        current.contains('4.1v')) {
      return widget.llmModel;
    }
    return defaultVisionModel;
  }

  Future<void> _callLLMBrain(
    String text,
    List<TimelineNode> windowNodes,
  ) async {
    final hasImages = windowNodes.any(
      (node) => node.type == TimelineNodeType.image,
    );
    if (hasImages) {
      return _callVlmBrain(text, windowNodes);
    }

    try {
      var response = await http.post(
        buildOpenAiStyleUri(widget.customBaseUrl, 'chat/completions'),
        headers: {
          'Authorization': 'Bearer ${widget.apiKey}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          "model": widget.llmModel,
          "messages": [
            {"role": "system", "content": _buildDynamicSystemPrompt()},
            {"role": "user", "content": text},
          ],
          "max_tokens": 220,
          "temperature": 0.2,
        }),
      );

      if (response.statusCode == 200) {
        var data = jsonDecode(utf8.decode(response.bodyBytes));
        String summary = data['choices'][0]['message']['content'];
        if (mounted) {
          setState(() {
            if (aiSummaryCards.length == 1 &&
                aiSummaryCards[0].text.contains("正在等待")) {
              aiSummaryCards.clear();
            }
            if (_enableCardMerge) {
              _insertSummaryCardsWithContext(summary);
            } else {
              aiSummaryCards.insert(0, SummaryCard(text: summary.trim()));
            }
            _lastPipelineError = null;
          });
        }
      } else {
        final String statusMsg = 'LLM 请求失败: HTTP ${response.statusCode}';
        debugPrint('$statusMsg, body=${response.body}');
        if (mounted) {
          setState(() => _lastPipelineError = statusMsg);
        }
      }
    } catch (e) {
      debugPrint('LLM 异常: $e');
      if (mounted) {
        setState(() => _lastPipelineError = 'LLM 异常: $e');
      }
    }
  }

  Future<void> _callVlmBrain(
    String text,
    List<TimelineNode> windowNodes,
  ) async {
    final imageNodes = windowNodes
        .where(
          (node) =>
              node.type == TimelineNodeType.image &&
              (node.imagePath?.isNotEmpty ?? false),
        )
        .toList();

    try {
      final userContent = <Map<String, dynamic>>[
        {
          'type': 'text',
          'text': text.isNotEmpty
              ? '$text\n\n请结合以下图片节点进行多模态总结。'
              : '当前语义窗口内主要包含图片节点，请结合图片内容进行总结。',
        },
        ...imageNodes.map(
          (node) => {
            'type': 'image_url',
            'image_url': {'url': _toDataUrl(node.imagePath!)},
          },
        ),
      ];

      final response = await http.post(
        buildOpenAiStyleUri(widget.customBaseUrl, 'chat/completions'),
        headers: {
          'Authorization': 'Bearer ${widget.apiKey}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': _resolveVisionModel(),
          'messages': [
            {
              'role': 'system',
              'content': _buildDynamicSystemPrompt(hasImages: true),
            },
            {'role': 'user', 'content': userContent},
          ],
          'max_tokens': 260,
          'temperature': 0.2,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        final summary = data['choices'][0]['message']['content'];
        if (mounted) {
          setState(() {
            if (aiSummaryCards.length == 1 &&
                aiSummaryCards[0].text.contains('正在等待')) {
              aiSummaryCards.clear();
            }
            if (_enableCardMerge) {
              _insertSummaryCardsWithContext(summary);
            } else {
              aiSummaryCards.insert(0, SummaryCard(text: summary.trim()));
            }
            _lastPipelineError = null;
          });
        }
      } else {
        final statusMsg = 'VLM 请求失败: HTTP ${response.statusCode}';
        debugPrint('$statusMsg, body=${response.body}');
        if (mounted) {
          setState(() => _lastPipelineError = statusMsg);
        }
      }
    } catch (e) {
      debugPrint('VLM 异常: $e');
      if (mounted) {
        setState(() => _lastPipelineError = 'VLM 异常: $e');
      }
    }
  }

  Uint8List _generateWavHeader(
    List<int> data,
    int sampleRate,
    int numChannels,
  ) {
    int dataLength = data.length;
    final header = ByteData(44);
    header.setUint32(0, 0x52494646, Endian.big);
    header.setUint32(4, 36 + dataLength, Endian.little);
    header.setUint32(8, 0x57415645, Endian.big);
    header.setUint32(12, 0x666d7420, Endian.big);
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, numChannels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, sampleRate * numChannels * 2, Endian.little);
    header.setUint16(32, (numChannels * 2), Endian.little);
    header.setUint16(34, 16, Endian.little);
    header.setUint32(36, 0x64617461, Endian.big);
    header.setUint32(40, dataLength, Endian.little);
    final finalBytes = Uint8List(44 + dataLength);
    finalBytes.setRange(0, 44, header.buffer.asUint8List());
    finalBytes.setRange(44, finalBytes.length, data);
    return finalBytes;
  }

  Future<void> _stopContinuousPipeline() async {
    if (_isStopping) return;
    _isStopping = true;

    setState(() {
      isRecording = false;
      isBreakMode = false;
      fullTranscript += "\n\n[🛑 监听已结束]";
    });
    sliceTimer?.cancel();
    await recorderStreamSubscription?.cancel();
    recorderStreamSubscription = null;
    await audioRecorder.stop();

    if (mainAudioBuffer.isNotEmpty) {
      final List<int> lastChunk = List<int>.from(mainAudioBuffer);
      mainAudioBuffer.clear();
      await _sendToCloudZeroLoss(lastChunk);
    }

    if (semanticBuffer.trim().isNotEmpty) {
      final String remainText = semanticBuffer;
      final nodesToSummarize = List<TimelineNode>.from(semanticWindowNodes);
      _clearSemanticWindow();
      await _callLLMBrain(remainText, nodesToSummarize);
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      List<String> history = prefs.getStringList('class_history') ?? [];
      final aiTitle = await _generateSessionTitle();

      ClassSession newSession = ClassSession(
        sessionId: _sessionId,
        title: aiTitle,
        subject: widget.subjectName,
        focusTerms: widget.focusTerms,
        dateStr: DateTime.now().toString().substring(0, 16),
        transcript: fullTranscript,
        transcriptSegments: transcriptSegments,
        timelineNodes: timelineNodes,
        summaries: aiSummaryCards,
        bounties: bountyTasks,
      );

      history.insert(0, jsonEncode(newSession.toJson()));
      await prefs.setStringList('class_history', history);
      await _refreshPendingCount();

      if (!_hasConsumedForSession) {
        final currentCostRmb =
            (_uploadedAudioMs / 60000.0) * _asrPriceRmbPerMinute;
        final oldTotalRmb = prefs.getDouble('lesson_total_rmb') ?? 0;
        await prefs.setDouble('lesson_total_rmb', oldTotalRmb + currentCostRmb);
        _hasConsumedForSession = true;

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '本次预估消费 ¥${currentCostRmb.toStringAsFixed(4)}（以平台账单为准）',
              ),
              backgroundColor: Colors.indigo,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('课堂记录已保存到历史记录。'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('保存课堂记录失败: $e');
    } finally {
      await WakelockPlus.disable();
      _isStopping = false;
    }
  }

  Future<void> _togglePowerSavingMode() async {
    setState(() {
      isPowerSavingMode = !isPowerSavingMode;
    });
    if (isPowerSavingMode) {
      await WakelockPlus.disable();
    } else if (isRecording) {
      await WakelockPlus.enable();
    }
    _showRealtimeStatusSnackBar(
      isPowerSavingMode ? '省电模式已开启：仅降低手机自身功耗，不影响识别与总结功能。' : '省电模式已关闭。',
    );
  }

  Future<String> _generateSessionTitle() async {
    final fallback = _buildFallbackSessionTitle();
    if (widget.apiKey.trim().isEmpty) return fallback;

    final summaryHint = aiSummaryCards
        .take(3)
        .map((e) => e.text.trim())
        .where((e) => e.isNotEmpty)
        .join('；');
    final transcriptHint = fullTranscript
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .take(8)
        .join(' ');

    try {
      final response = await http
          .post(
            buildOpenAiStyleUri(widget.customBaseUrl, 'chat/completions'),
            headers: {
              'Authorization': 'Bearer ${widget.apiKey}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'model': widget.llmModel,
              'temperature': 0.2,
              'max_tokens': 40,
              'messages': [
                {
                  'role': 'system',
                  'content': '你是课堂记录命名助手。请仅输出一个简洁标题，不超过18个中文字符，不要引号，不要句号。',
                },
                {
                  'role': 'user',
                  'content':
                      '课程：${widget.subjectName}\n要点：$summaryHint\n片段：$transcriptHint',
                },
              ],
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) return fallback;
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final raw =
          data['choices']?[0]?['message']?['content']?.toString().trim() ?? '';
      final cleaned = raw
          .replaceAll('\n', ' ')
          .replaceAll('"', '')
          .replaceAll('“', '')
          .replaceAll('”', '')
          .trim();
      if (cleaned.isEmpty) return fallback;
      return cleaned.length > 18 ? cleaned.substring(0, 18) : cleaned;
    } catch (_) {
      return fallback;
    }
  }

  String _buildFallbackSessionTitle() {
    if (aiSummaryCards.isNotEmpty) {
      final first = aiSummaryCards.first.text.trim();
      if (first.isNotEmpty) {
        return first.length > 18 ? first.substring(0, 18) : first;
      }
    }
    final line = fullTranscript
        .split('\n')
        .map((e) => e.trim())
        .firstWhere((e) => e.isNotEmpty, orElse: () => '课堂记录');
    final cleaned = line.replaceAll(RegExp(r'^\[[^\]]+\]\s*'), '').trim();
    if (cleaned.isEmpty) return '课堂记录';
    return cleaned.length > 18 ? cleaned.substring(0, 18) : cleaned;
  }

  void _showRealtimeStatusSnackBar(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    // 立即清空当前与排队中的提示，确保状态提示始终与最新状态一致。
    messenger
      ..clearSnackBars()
      ..removeCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 900),
      ),
    );
  }

  Future<void> _toggleBreakMode() async {
    if (!isRecording) return;

    if (!isBreakMode) {
      setState(() {
        isBreakMode = true;
      });
      sliceTimer?.cancel();
      await recorderStreamSubscription?.cancel();
      recorderStreamSubscription = null;
      await audioRecorder.stop();
      await _drainAndSendCurrentBuffer();
      _showRealtimeStatusSnackBar('已进入课间休息，暂不监听；可自由切到其他应用。');
      return;
    }

    await _startRecorderStream();
    _startSliceTimer();
    setState(() {
      isBreakMode = false;
    });
    _showRealtimeStatusSnackBar('课间休息结束，已恢复课堂监听。');
  }

  Future<void> _exitAndSave() async {
    if (_isStopping) return;
    if (isRecording) {
      await _stopContinuousPipeline();
    }
    if (!mounted) return;
    Navigator.pop(context);
  }

  Future<bool> _handleBackAttempt() async {
    if (!isRecording) return true;

    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('结束本节课？'),
          content: const Text('退出前建议先保存本节内容到历史记录。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'cancel'),
              child: const Text('继续上课'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'pause_only'),
              child: const Text('仅暂停不结束'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, 'save_exit'),
              child: const Text('保存并退出'),
            ),
          ],
        );
      },
    );

    if (action == 'save_exit') {
      await _exitAndSave();
    } else if (action == 'pause_only' && !isBreakMode) {
      await _toggleBreakMode();
    }
    return false;
  }

  @override
  void dispose() {
    sliceTimer?.cancel();
    _stabilityTimer?.cancel();
    recorderStreamSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(WakelockPlus.disable());
    audioRecorder.dispose();
    super.dispose();
  }

  List<SummaryCard> get displayedCards {
    if (!isPinnedMode) return aiSummaryCards;
    var highlighted = aiSummaryCards.where((c) => c.isHighlighted).toList();
    var normal = aiSummaryCards.where((c) => !c.isHighlighted).toList();
    return [...highlighted, ...normal];
  }

  void _createBountyTask() {
    String targetContext = semanticBuffer.isNotEmpty
        ? semanticBuffer
        : fullTranscript;
    if (targetContext.length > 60) {
      targetContext =
          "...${targetContext.substring(targetContext.length - 60)}";
    }
    String timeNow =
        "${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}";
    String uniqueId = DateTime.now().millisecondsSinceEpoch.toString();
    setState(() {
      bountyTasks.insert(
        0,
        BountyTask(id: uniqueId, context: targetContext, timeStr: timeNow),
      );
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.crisis_alert, color: Colors.white),
            SizedBox(width: 8),
            Text('已添加到待解问题清单'),
          ],
        ),
        backgroundColor: Colors.redAccent.withOpacity(0.9),
      ),
    );
  }

  // 【升级】：呼出带有动画逻辑的独立面板组件
  void _showBountyBoard() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return BountyBoardSheet(
          tasks: bountyTasks,
          onBadgeUpdate: () => setState(() {}), // 通知面板关闭或数据变化时刷新背后角标
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _handleBackAttempt,
      child: Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        appBar: AppBar(
          title: Text(
            '${widget.subjectName} | ${isBreakMode ? "☕ 课间休息" : (isRecording ? "🔴 监听中" : "已暂停")}',
            style: const TextStyle(fontWeight: FontWeight.w300, fontSize: 16),
          ),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 20),
            onPressed: _handleBackAttempt,
          ),
          actions: [
            IconButton(
              icon: Icon(
                isPowerSavingMode ? Icons.battery_saver : Icons.battery_6_bar,
                color: isPowerSavingMode
                    ? Colors.lightGreenAccent
                    : Colors.white70,
              ),
              tooltip: '省电模式',
              onPressed: _togglePowerSavingMode,
            ),
            IconButton(
              icon: Icon(
                isBreakMode ? Icons.play_circle_outline : Icons.free_breakfast,
                color: Colors.orangeAccent,
              ),
              tooltip: isBreakMode ? '结束课间休息' : '课间休息',
              onPressed: _toggleBreakMode,
            ),
            if (isRecording)
              IconButton(
                icon: const Icon(
                  Icons.photo_camera_outlined,
                  color: Colors.cyanAccent,
                ),
                tooltip: '拍照/相册',
                onPressed: _showSnapshotSourceSheet,
              ),
            IconButton(
              icon: const Icon(Icons.exit_to_app),
              tooltip: '保存并退出',
              onPressed: _exitAndSave,
            ),
            Padding(
              padding: const EdgeInsets.only(right: 15),
              child: GestureDetector(
                onTap: _showBountyBoard,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    const Icon(
                      Icons.assignment_late_outlined,
                      size: 28,
                      color: Colors.amber,
                    ),
                    if (bountyTasks.isNotEmpty)
                      Positioned(
                        top: 10,
                        right: 0,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: Colors.redAccent,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            '${bountyTasks.length}',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.only(left: 16, right: 16, bottom: 90),
          child: Column(
            children: [
              Expanded(
                flex: 4,
                child: GlassmorphismContainer(
                  padding: const EdgeInsets.all(16),
                  child: SingleChildScrollView(
                    reverse: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: buildTimelineWidgets(
                        timelineNodes,
                        onImageTap: _showImagePreview,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                flex: 5,
                child: GlassmorphismContainer(
                  padding: const EdgeInsets.all(16),
                  child: ListView.builder(
                    itemCount: displayedCards.length,
                    itemBuilder: (context, index) {
                      var card = displayedCards[index];
                      return GestureDetector(
                        onTap: () => setState(
                          () => card.isHighlighted = !card.isHighlighted,
                        ),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: card.isHighlighted
                                ? Colors.amber.withOpacity(0.15)
                                : Colors.purpleAccent.withOpacity(0.05),
                            border: Border.all(
                              color: card.isHighlighted
                                  ? Colors.amber
                                  : Colors.purpleAccent.withOpacity(0.3),
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            card.text,
                            style: TextStyle(
                              color: card.isHighlighted
                                  ? Colors.white
                                  : Colors.white70,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              if (_lastPipelineError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _lastPipelineError!,
                  style: const TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: 12,
                  ),
                ),
              ],
              if (_showStabilityPanel) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '稳定性：离线队列 $_pendingChunkCount | 缓冲 ${mainAudioBuffer.length ~/ 1024} KB | ${_isRetryingPending ? "重试中" : "稳定"}',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _isRetryingPending
                            ? null
                            : _retryPendingInBackground,
                        child: const Text('立即补偿'),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
        floatingActionButton: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Stack(
            alignment: Alignment.bottomCenter,
            children: [
              Visibility(
                visible: isRecording,
                child: GestureDetector(
                  onTap: _exitAndSave,
                  child: GlassmorphismContainer(
                    width: 60,
                    height: 60,
                    borderRadius: 30,
                    borderColor: Colors.redAccent.withOpacity(0.5),
                    backgroundColor: Colors.redAccent.withOpacity(0.1),
                    child: const Center(
                      child: Icon(
                        Icons.stop,
                        size: 30,
                        color: Colors.redAccent,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                bottom: 0,
                child: Visibility(
                  visible: isRecording,
                  child: GestureDetector(
                    onTap: _showSnapshotSourceSheet,
                    child: GlassmorphismContainer(
                      width: 60,
                      height: 60,
                      borderRadius: 30,
                      borderColor: Colors.cyanAccent.withOpacity(0.7),
                      backgroundColor: Colors.cyanAccent.withOpacity(0.12),
                      child: const Center(
                        child: Icon(
                          Icons.photo_camera_outlined,
                          size: 28,
                          color: Colors.cyanAccent,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: Visibility(
                  visible: isRecording,
                  child: GestureDetector(
                    onTap: _createBountyTask,
                    child: GlassmorphismContainer(
                      width: 60,
                      height: 60,
                      borderRadius: 30,
                      borderColor: Colors.redAccent.withOpacity(0.8),
                      backgroundColor: Colors.redAccent.withOpacity(0.2),
                      child: const Center(
                        child: Icon(
                          Icons.crisis_alert,
                          size: 30,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showImagePreview(TimelineNode node) {
    final imagePath = node.imagePath;
    if (imagePath == null || imagePath.isEmpty) return;

    showDialog(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: Colors.transparent,
          child: GestureDetector(
            onTap: () => Navigator.pop(dialogContext),
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.file(File(imagePath), fit: BoxFit.contain),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ================= 【更新】：动效独立悬赏面板与组件 =================
class BountyBoardSheet extends StatefulWidget {
  final List<BountyTask> tasks;
  final VoidCallback onBadgeUpdate;

  const BountyBoardSheet({
    super.key,
    required this.tasks,
    required this.onBadgeUpdate,
  });

  @override
  State<BountyBoardSheet> createState() => _BountyBoardSheetState();
}

class _BountyBoardSheetState extends State<BountyBoardSheet> {
  final GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();

  void _handleSettle(BountyTask task) {
    final int index = widget.tasks.indexOf(task);
    if (index == -1) return;

    final removedTask = widget.tasks[index];

    _listKey.currentState?.removeItem(
      index,
      (context, animation) => _buildAnimatedTaskItem(removedTask, animation),
      duration: const Duration(milliseconds: 400),
    );

    widget.tasks.removeAt(index);
    widget.onBadgeUpdate();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('问题已标记为已解决。'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 1),
      ),
    );
  }

  Widget _buildAnimatedTaskItem(BountyTask task, Animation<double> animation) {
    return SizeTransition(
      sizeFactor: animation,
      axisAlignment: -1.0,
      child: FadeTransition(
        opacity: animation,
        child: Container(
          margin: const EdgeInsets.only(bottom: 15),
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: Colors.redAccent.withOpacity(0.1),
            border: Border.all(
              color: Colors.redAccent.withOpacity(0.4),
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(15),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '⏱️ ${task.timeStr}',
                    style: const TextStyle(
                      color: Colors.amber,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  AnimatedSettleButton(onSettle: () => _handleSettle(task)),
                ],
              ),
              const SizedBox(height: 10),
              const Text(
                '案发现场上下文：',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 5),
              Text(
                '“${task.context}”',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  height: 1.5,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: const BoxDecoration(
        color: Color(0xFF1E1B4B),
        borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.white30,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Row(
            children: [
              Icon(Icons.assignment_late, color: Colors.amber, size: 28),
              SizedBox(width: 10),
              Text(
                '悬赏委托中心',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Expanded(
            child: widget.tasks.isEmpty
                ? const Center(
                    child: Text(
                      '🎉 太棒了！当前没有任何未解决的知识盲区。',
                      style: TextStyle(color: Colors.white54),
                    ),
                  )
                : AnimatedList(
                    key: _listKey,
                    initialItemCount: widget.tasks.length,
                    itemBuilder: (context, index, animation) {
                      return _buildAnimatedTaskItem(
                        widget.tasks[index],
                        animation,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// 附带点击回弹动效的物理反馈按钮
class AnimatedSettleButton extends StatefulWidget {
  final VoidCallback onSettle;
  const AnimatedSettleButton({super.key, required this.onSettle});

  @override
  State<AnimatedSettleButton> createState() => _AnimatedSettleButtonState();
}

class _AnimatedSettleButtonState extends State<AnimatedSettleButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapCancel: () => setState(() => _isPressed = false),
      onTapUp: (_) {
        setState(() => _isPressed = false);
        widget.onSettle();
      },
      child: AnimatedScale(
        scale: _isPressed ? 0.9 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.greenAccent.withOpacity(0.2),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.greenAccent.withOpacity(0.5)),
          ),
          child: const Text(
            '结算清除',
            style: TextStyle(
              color: Colors.greenAccent,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}
