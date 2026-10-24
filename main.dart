import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_to_text.dart' as stt;

void main() => runApp(const PhoenixApp());

const bg = Color(0xFF080F1C);
const panel = Color(0xFF111D2D);
const cyan = Color(0xFF52D8E8);
const amber = Color(0xFFFFA34D);

class PhoenixApp extends StatelessWidget {
  const PhoenixApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Phoenix AI',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.dark(primary: cyan, secondary: amber, surface: panel),
      useMaterial3: true,
      fontFamily: 'Roboto',
    ),
    home: const ChatScreen(),
  );
}

class ChatMessage {
  ChatMessage(this.text, this.isUser, {this.isError = false});
  final String text;
  final bool isUser;
  final bool isError;
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with SingleTickerProviderStateMixin {
  static const secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  final input = TextEditingController();
  final scroll = ScrollController();
  final speech = stt.SpeechToText();
  final tts = FlutterTts();
  final messages = <ChatMessage>[
    ChatMessage("I'm Phoenix. Your voice-first assistant is ready. Add your Gemini API key in Settings, then talk or type.", false),
  ];
  bool listening = false;
  bool busy = false;
  bool voiceMode = true;
  bool speakReplies = true;
  bool speechAvailable = false;
  String model = 'gemini-2.5-flash';
  String status = 'READY';
  late final AnimationController pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    _initSpeech();
    tts.setLanguage('en-US');
    tts.setSpeechRate(0.48);
  }

  Future<void> _initSpeech() async {
    try {
      speechAvailable = await speech.initialize(
        onStatus: (s) { if (mounted) setState(() { listening = s == 'listening'; status = listening ? 'LISTENING' : (busy ? 'THINKING' : 'READY'); }); },
        onError: (e) { if (mounted) setState(() { listening = false; status = 'VOICE ERROR'; }); },
      );
      if (mounted) setState(() {});
    } catch (_) {
      speechAvailable = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _listen() async {
    if (busy) return;
    if (!speechAvailable) await _initSpeech();
    if (!speechAvailable) {
      _add(false, 'Speech recognition is unavailable on this device. You can still type messages.');
      return;
    }
    if (listening) {
      await speech.stop();
      return;
    }
    await tts.stop();
    setState(() { status = 'LISTENING'; listening = true; });
    await speech.listen(
      listenFor: const Duration(seconds: 45),
      pauseFor: const Duration(seconds: 4),
      partialResults: true,
      onResult: (result) {
        if (!mounted) return;
        setState(() => input.text = result.recognizedWords);
        input.selection = TextSelection.fromPosition(TextPosition(offset: input.text.length));
        if (result.finalResult && input.text.trim().isNotEmpty) _send();
      },
    );
  }

  void _add(bool user, String text, {bool error = false}) {
    setState(() => messages.add(ChatMessage(text, user, isError: error)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) scroll.animateTo(scroll.position.maxScrollExtent + 180, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
  }

  Future<void> _send() async {
    final prompt = input.text.trim();
    if (prompt.isEmpty || busy) return;
    input.clear();
    await speech.stop();
    await tts.stop();
    _add(true, prompt);
    setState(() { busy = true; status = 'THINKING'; });
    try {
      final key = await secure.read(key: 'gemini_api_key');
      if (key == null || key.trim().isEmpty) {
        _add(false, 'Gemini API key is not configured. Open Settings → API key and save it on this phone.', error: true);
        return;
      }
      final uri = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=${Uri.encodeQueryComponent(key.trim())}');
      final history = messages.where((m) => !m.isError).toList();
      final contents = history.map((m) => {
        'role': m.isUser ? 'user' : 'model',
        'parts': [{'text': m.text}]
      }).toList();
      final response = await http.post(uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'system_instruction': {'parts': [{'text': 'You are Phoenix, a concise, capable personal assistant. Help the user learn and build practical projects. Do not claim to execute actions you have not performed. This is Phoenix AI version 0.0.1.'}]},
          'contents': contents,
          'generationConfig': {'temperature': 0.7, 'maxOutputTokens': 1200}
        }),
      ).timeout(const Duration(seconds: 45));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final detail = response.body.length > 700 ? response.body.substring(0,700) : response.body;
        _add(false, 'Gemini request failed (${response.statusCode}). Check the API key, model availability, network and quota.\n$detail', error: true);
        return;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final candidates = data['candidates'] as List?;
      final parts = candidates?.isNotEmpty == true ? (candidates!.first['content']?['parts'] as List? ?? []) : [];
      final answer = parts.map((p) => p['text'] ?? '').join('').trim();
      if (answer.isEmpty) {
        _add(false, 'The model returned no text. Try again.', error: true);
      } else {
        _add(false, answer);
        if (speakReplies && voiceMode) await tts.speak(answer);
      }
    } catch (e) {
      _add(false, 'Connection or response error: $e', error: true);
    } finally {
      if (mounted) setState(() { busy = false; status = 'READY'; });
    }
  }

  Future<void> _settings() async {
    final current = await secure.read(key: 'gemini_api_key') ?? '';
    final controller = TextEditingController(text: current);
    final modelController = TextEditingController(text: model);
    bool show = false;
    await showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: panel,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('PHOENIX SETTINGS', style: TextStyle(color: cyan, fontWeight: FontWeight.bold, letterSpacing: 2)),
          const SizedBox(height: 8),
          const Text('Your API key is stored in Android secure storage on this device. It is sent to Google only when you make a request.'),
          const SizedBox(height: 14),
          TextField(controller: controller, obscureText: !show, decoration: InputDecoration(labelText: 'Gemini API key', filled: true, fillColor: bg, suffixIcon: IconButton(icon: Icon(show ? Icons.visibility_off : Icons.visibility), onPressed: () => setSheet(() => show = !show)))),
          const SizedBox(height: 12),
          TextField(controller: modelController, decoration: const InputDecoration(labelText: 'Gemini model', hintText: 'gemini-2.5-flash', filled: true, fillColor: bg)),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: () async { await secure.delete(key: 'gemini_api_key'); if (mounted) Navigator.pop(ctx); }, child: const Text('REMOVE KEY'))),
            const SizedBox(width: 10),
            Expanded(child: FilledButton(onPressed: () async {
              if (controller.text.trim().isNotEmpty) await secure.write(key: 'gemini_api_key', value: controller.text.trim());
              setState(() => model = modelController.text.trim().isEmpty ? 'gemini-2.5-flash' : modelController.text.trim());
              if (mounted) Navigator.pop(ctx);
            }, child: const Text('SAVE ON PHONE'))),
          ]),
        ]),
      )),
    );
    controller.dispose(); modelController.dispose();
  }

  @override
  void dispose() {
    input.dispose(); scroll.dispose(); pulse.dispose(); speech.stop(); tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: bg, elevation: 0,
        leadingWidth: 58,
        leading: Padding(padding: const EdgeInsets.only(left: 12), child: Image.asset('assets/phoenix_logo.png')),
        title: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('PHOENIX', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 2, fontSize: 17)),
          Text('PERSONAL AI  •  v0.0.1', style: TextStyle(fontSize: 9, color: cyan, letterSpacing: 1.4)),
        ]),
        actions: [IconButton(onPressed: _settings, icon: const Icon(Icons.tune_rounded)), const SizedBox(width: 6)],
      ),
      body: SafeArea(child: Column(children: [
        Container(
          margin: const EdgeInsets.fromLTRB(14, 4, 14, 10), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFF24364B))),
          child: Row(children: [
            AnimatedBuilder(animation: pulse, builder: (_,__) => Container(width: 9, height: 9, decoration: BoxDecoration(color: listening ? amber : cyan, shape: BoxShape.circle, boxShadow: [BoxShadow(color: (listening ? amber : cyan).withOpacity(0.5), blurRadius: 7 + pulse.value * 7)]))),
            const SizedBox(width: 10),
            Text(status, style: const TextStyle(fontSize: 10, letterSpacing: 2, color: cyan, fontWeight: FontWeight.bold)),
            const Spacer(),
            Text(speechAvailable ? 'VOICE READY' : 'TEXT READY', style: const TextStyle(fontSize: 9, color: Colors.white54, letterSpacing: 1)),
          ]),
        ),
        if (messages.length <= 1) _hero(width),
        Expanded(child: ListView.builder(
          controller: scroll, padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
          itemCount: messages.length,
          itemBuilder: (context, i) => _bubble(messages[i]),
        )),
        if (busy) const Padding(padding: EdgeInsets.only(bottom: 8), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [SizedBox(width: 14,height: 14,child: CircularProgressIndicator(strokeWidth: 2)), SizedBox(width: 9), Text('Phoenix is thinking…', style: TextStyle(color: Colors.white54, fontSize: 12))])),
        _composer(),
      ])),
    );
  }

  Widget _hero(double width) => Padding(
    padding: const EdgeInsets.fromLTRB(22, 8, 22, 14),
    child: Column(children: [
      SizedBox(height: width < 380 ? 104 : 126, child: Stack(alignment: Alignment.center, children: [
        Container(width: 116, height: 116, decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [cyan.withOpacity(0.18), bg]), boxShadow: [BoxShadow(color: cyan.withOpacity(0.10), blurRadius: 35, spreadRadius: 8)])),
        Image.asset('assets/phoenix_logo.png', width: 94, height: 94),
      ])),
      const SizedBox(height: 5),
      const Text('READY WHEN YOU ARE', style: TextStyle(fontSize: 12, letterSpacing: 2.4, fontWeight: FontWeight.bold)),
      const SizedBox(height: 5),
      const Text('Speak naturally. Phoenix listens, thinks and responds.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54, fontSize: 12)),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
        _suggestion('Plan a project'), _suggestion('Explain a concept'), _suggestion('Help me build'),
      ]),
    ]),
  );

  Widget _suggestion(String s) => ActionChip(
    backgroundColor: panel, side: const BorderSide(color: Color(0xFF2A4057)),
    label: Text(s, style: const TextStyle(fontSize: 10, color: Colors.white70)),
    onPressed: () { input.text = s; _send(); },
  );

  Widget _bubble(ChatMessage m) => Align(
    alignment: m.isUser ? Alignment.centerRight : Alignment.centerLeft,
    child: Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.84),
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: m.isUser ? const Color(0xFF17394A) : panel,
        borderRadius: BorderRadius.only(topLeft: const Radius.circular(17), topRight: const Radius.circular(17), bottomLeft: Radius.circular(m.isUser ? 17 : 5), bottomRight: Radius.circular(m.isUser ? 5 : 17)),
        border: Border.all(color: m.isError ? Colors.redAccent.withOpacity(0.45) : (m.isUser ? cyan.withOpacity(0.2) : const Color(0xFF26384C))),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (!m.isUser) const Text('PHOENIX', style: TextStyle(fontSize: 9, color: cyan, letterSpacing: 1.5, fontWeight: FontWeight.bold)),
        if (!m.isUser) const SizedBox(height: 5),
        SelectableText(m.text, style: TextStyle(fontSize: 14, height: 1.42, color: m.isError ? Colors.orange[200] : Colors.white.withOpacity(0.94))),
        if (!m.isUser && !m.isError) Align(alignment: Alignment.centerRight, child: IconButton(visualDensity: VisualDensity.compact, onPressed: () => tts.speak(m.text), icon: const Icon(Icons.volume_up_rounded, size: 18, color: cyan))),
      ]),
    ),
  );

  Widget _composer() => Container(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
    decoration: const BoxDecoration(color: Color(0xFF0C1726), border: Border(top: BorderSide(color: Color(0xFF1D3045)))),
    child: Column(children: [
      Row(children: [
        Expanded(child: TextField(
          controller: input, minLines: 1, maxLines: 4, textInputAction: TextInputAction.send,
          onSubmitted: (_) => _send(),
          decoration: InputDecoration(
            hintText: listening ? 'Listening… speak now' : 'Message Phoenix…',
            hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
            filled: true, fillColor: panel, contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
          ),
        )),
        const SizedBox(width: 8),
        IconButton.filledTonal(onPressed: busy ? null : _send, icon: const Icon(Icons.arrow_upward_rounded), style: IconButton.styleFrom(backgroundColor: cyan, foregroundColor: bg)),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: Row(children: [
          Icon(Icons.graphic_eq, color: voiceMode ? cyan : Colors.white38, size: 18),
          const SizedBox(width: 6),
          Text('VOICE MODE', style: TextStyle(fontSize: 10, letterSpacing: 1.4, color: voiceMode ? cyan : Colors.white38, fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          Switch.adaptive(value: voiceMode, activeColor: cyan, onChanged: (v) async { setState(() => voiceMode = v); if (!v) await tts.stop(); }),
        ])),
        TextButton.icon(onPressed: () => setState(() => speakReplies = !speakReplies), icon: Icon(speakReplies ? Icons.volume_up : Icons.volume_off, size: 16), label: Text(speakReplies ? 'SPEAK REPLIES' : 'MUTED', style: const TextStyle(fontSize: 9, letterSpacing: 1))),
        const SizedBox(width: 3),
        GestureDetector(
          onTap: _listen,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180), width: 48, height: 48,
            decoration: BoxDecoration(shape: BoxShape.circle, color: listening ? amber : cyan, boxShadow: [BoxShadow(color: (listening ? amber : cyan).withOpacity(0.22), blurRadius: 16, spreadRadius: 2)]),
            child: Icon(listening ? Icons.stop_rounded : Icons.mic_rounded, color: bg, size: 24),
          ),
        ),
      ]),
    ]),
  );
}
