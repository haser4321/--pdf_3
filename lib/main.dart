import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PdfToVoiceApp());
}

class PdfToVoiceApp extends StatelessWidget {
  const PdfToVoiceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PDF إلى صوت',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF39735B),
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F7F5),
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          backgroundColor: Color(0xFFF5F7F5),
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(
              color: Color(0xFFE3E9E4),
            ),
          ),
        ),
      ),
      home: const ReaderScreen(),
    );
  }
}

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final FlutterTts _tts = FlutterTts();
  final TextEditingController _textController =
      TextEditingController();

  String _fileName = 'لم يتم اختيار ملف PDF';
  String _status = 'اختر ملف PDF للبدء';
  String? _savedPath;

  bool _busy = false;
  bool _ttsReady = false;
  bool _isPlaying = false;
  bool _isPaused = false;
  bool _stopRequested = false;

  double _speechRate = 0.45;

  Completer<void>? _resumeCompleter;

  static const int _chunkSize = 1800;
  static const int _maxSaveCharacters = 3000;

  @override
  void initState() {
    super.initState();
    _initializeTts();
  }

  Future<void> _initializeTts() async {
    try {
      await _tts.setLanguage('ar');
      await _tts.setSpeechRate(_speechRate);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      await _tts.awaitSpeakCompletion(true);

      _tts.setErrorHandler((message) {
        if (!mounted) return;

        setState(() {
          _status = 'خطأ في محرك النطق: $message';
        });
      });

      final available = await _tts.isLanguageAvailable('ar');

      if (!mounted) return;

      setState(() {
        _ttsReady = available == true;
        _status = _ttsReady
            ? 'محرك النطق العربي جاهز'
            : 'لم يُعثر على صوت عربي. تحقق من إعدادات أندرويد.';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _ttsReady = false;
        _status = 'تعذر تجهيز محرك النطق: $e';
      });
    }
  }

  // قراءة الملف متوافقة مع file_picker 8.3.7.
  Future<Uint8List> _readSelectedFile(
    PlatformFile selected,
  ) async {
    // بعض الملفات تكون بياناتها موجودة في الذاكرة.
    final memoryBytes = selected.bytes;

    if (memoryBytes != null && memoryBytes.isNotEmpty) {
      return memoryBytes;
    }

    // عند عدم توفر البيانات في الذاكرة، نستخدم المسار.
    final filePath = selected.path;

    if (filePath != null && filePath.isNotEmpty) {
      final file = File(filePath);

      if (await file.exists()) {
        final bytes = await file.readAsBytes();

        if (bytes.isNotEmpty) {
          return bytes;
        }
      }
    }

    throw Exception('تعذرت قراءة الملف المحدد');
  }

  Future<void> _choosePdf() async {
    if (_busy) return;

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) return;

      setState(() {
        _busy = true;
        _status = 'جارٍ فتح الملف واستخراج النص...';
      });

      final selected = result.files.single;
      final Uint8List bytes = await _readSelectedFile(selected);

      final document = PdfDocument(inputBytes: bytes);

      String extractedText;

      try {
        extractedText =
            PdfTextExtractor(document).extractText();
      } finally {
        document.dispose();
      }

      extractedText = extractedText
          .replaceAll('\u0000', '')
          .replaceAll(RegExp(r'[ \t]+\n'), '\n')
          .trim();

      if (extractedText.isEmpty) {
        throw Exception(
          'لم يُعثر على نص. قد يكون الملف PDF صورًا ممسوحة ضوئيًا.',
        );
      }

      await _stopSpeech();

      if (!mounted) return;

      setState(() {
        _fileName = selected.name;
        _textController.text = extractedText;
        _savedPath = null;
        _status =
            'اكتمل استخراج ${extractedText.length} حرفًا';
      });

      _notify('تم استخراج النص من الملف');
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _status = 'تعذر فتح PDF: $e';
      });

      _notify('تعذر استخراج النص من الملف');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  List<String> _splitText(String text) {
    final parts = <String>[];
    var remaining = text.trim();

    while (remaining.isNotEmpty) {
      if (remaining.length <= _chunkSize) {
        parts.add(remaining);
        break;
      }

      var cut = remaining.lastIndexOf(' ', _chunkSize);

      if (cut < _chunkSize ~/ 2) {
        cut = remaining.lastIndexOf('\n', _chunkSize);
      }

      if (cut < _chunkSize ~/ 2) {
        cut = remaining.lastIndexOf('،', _chunkSize);
      }

      if (cut < _chunkSize ~/ 2) {
        cut = _chunkSize;
      }

      parts.add(remaining.substring(0, cut).trim());
      remaining = remaining.substring(cut).trim();
    }

    return parts.where((part) => part.isNotEmpty).toList();
  }

  Future<void> _startReading() async {
    if (_isPlaying || _busy) return;

    final text = _textController.text.trim();

    if (text.isEmpty) {
      _notify('اختر ملف PDF يحتوي على نص أولًا');
      return;
    }

    if (!_ttsReady) {
      _notify('الصوت العربي غير متاح. تحقق من محرك النطق.');
      return;
    }

    _stopRequested = false;
    _isPaused = false;
    _releasePauseGate();

    setState(() {
      _isPlaying = true;
      _status = 'جارٍ بدء القراءة...';
    });

    try {
      await _tts.setLanguage('ar');
      await _tts.setSpeechRate(_speechRate);
      await _tts.awaitSpeakCompletion(true);

      final chunks = _splitText(text);

      for (var i = 0; i < chunks.length; i++) {
        if (_stopRequested || !mounted) break;

        setState(() {
          _status =
              'جارٍ قراءة الجزء ${i + 1} من ${chunks.length}';
        });

        while (!_stopRequested && mounted) {
          await _tts.speak(chunks[i]);

          if (_stopRequested || !mounted) break;

          final gate = _resumeCompleter;

          if (gate != null) {
            await gate.future;
            continue;
          }

          break;
        }
      }

      if (mounted) {
        setState(() {
          _status = _stopRequested
              ? 'تم إيقاف القراءة'
              : 'اكتملت القراءة';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'تعذرت القراءة: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _isPaused = false;
        });
      }

      _releasePauseGate();
    }
  }

  Future<void> _pauseReading() async {
    if (!_isPlaying || _isPaused) return;

    _resumeCompleter ??= Completer<void>();

    setState(() {
      _isPaused = true;
      _status = 'القراءة متوقفة مؤقتًا';
    });

    try {
      await _tts.stop();
    } catch (_) {}
  }

  Future<void> _resumeReading() async {
    if (!_isPlaying || !_isPaused) return;

    setState(() {
      _isPaused = false;
      _status = 'جارٍ استئناف القراءة من بداية الجزء الحالي...';
    });

    _releasePauseGate();
  }

  void _releasePauseGate() {
    final gate = _resumeCompleter;
    _resumeCompleter = null;

    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
  }

  Future<void> _stopSpeech() async {
    _stopRequested = true;
    _releasePauseGate();

    try {
      await _tts.stop();
    } catch (_) {}

    if (!mounted) return;

    setState(() {
      _isPlaying = false;
      _isPaused = false;
    });
  }

  Future<void> _saveAudio() async {
    final text = _textController.text.trim();

    if (text.isEmpty) {
      _notify('لا يوجد نص لتحويله إلى صوت');
      return;
    }

    if (_isPlaying) {
      _notify('أوقف القراءة قبل إنشاء ملف صوتي');
      return;
    }

    if (!_ttsReady) {
      _notify('تحقق من توفر صوت عربي في محرك أندرويد');
      return;
    }

    if (text.length > _maxSaveCharacters) {
      _notify(
        'حد الحفظ في هذه النسخة $_maxSaveCharacters حرف. '
        'قسّم النص إلى أجزاء أصغر.',
      );
      return;
    }

    setState(() {
      _busy = true;
      _status = 'جارٍ إنشاء ملف الصوت...';
    });

    String? temporaryPath;

    try {
      await _tts.stop();

      final directory = await getTemporaryDirectory();

      temporaryPath =
          '${directory.path}/pdf_audio_'
          '${DateTime.now().millisecondsSinceEpoch}.wav';

      await _tts.setLanguage('ar');
      await _tts.setSpeechRate(_speechRate);
      await _tts.awaitSpeakCompletion(true);

      final result = await _tts.synthesizeToFile(
        text,
        temporaryPath,
        true,
      );

      final generatedFile = File(temporaryPath);

      if (!await generatedFile.exists()) {
        throw Exception('لم يُنشئ محرك النطق ملفًا صوتيًا');
      }

      final audioBytes = await generatedFile.readAsBytes();

      if (audioBytes.isEmpty) {
        throw Exception('ملف الصوت الناتج فارغ');
      }

      final destination = await FilePicker.platform.saveFile(
        dialogTitle: 'حفظ الملف الصوتي',
        fileName:
            'قراءة_${DateTime.now().millisecondsSinceEpoch}.wav',
        bytes: audioBytes,
      );

      if (destination == null) {
        if (mounted) {
          setState(() {
            _status = 'أُلغي حفظ الملف';
          });
        }
        return;
      }

      if (!mounted) return;

      setState(() {
        _savedPath = destination;
        _status = 'تم حفظ الملف الصوتي';
      });

      _notify('اكتملت عملية الحفظ');
      debugPrint('TTS synthesis result: $result');
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'فشل إنشاء الصوت أو حفظه: $e';
        });
      }

      _notify('تعذر إنشاء الصوت. تحقق من دعم محرك النطق.');
    } finally {
      if (temporaryPath != null) {
        try {
          final file = File(temporaryPath);

          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {}
      }

      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  void _notify(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  void dispose() {
    _stopRequested = true;
    _releasePauseGate();
    _tts.stop();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textLength = _textController.text.length;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'PDF إلى صوت',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          actions: [
            IconButton(
              onPressed: _busy ? null : _choosePdf,
              tooltip: 'اختيار ملف',
              icon: const Icon(Icons.folder_open_rounded),
            ),
            const SizedBox(width: 6),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildWelcomeCard(),
                    const SizedBox(height: 14),
                    _buildFileCard(),
                    const SizedBox(height: 14),
                    _buildSpeedCard(),
                    const SizedBox(height: 14),
                    _buildTextCard(textLength),
                    const SizedBox(height: 14),
                    _buildStatusCard(),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
              _buildControls(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWelcomeCard() {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: const Color(0xFFE3EEE7),
        borderRadius: BorderRadius.circular(22),
      ),
      child: const Column(
        children: [
          Icon(
            Icons.record_voice_over_rounded,
            size: 50,
            color: Color(0xFF39735B),
          ),
          SizedBox(height: 12),
          Text(
            'استمع إلى كتبك ومستنداتك',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'افتح ملف PDF، واستخرج النص العربي، '
            'ثم اقرأه أو احفظه كملف صوتي.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildFileCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'ملف PDF',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 17,
              ),
            ),
            const SizedBox(height: 8),
            Text(_fileName),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _choosePdf,
              icon: const Icon(Icons.picture_as_pdf_rounded),
              label: const Text('اختيار ملف PDF'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSpeedCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'سرعة النطق',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 17,
              ),
            ),
            Slider(
              value: _speechRate,
              min: 0.25,
              max: 0.75,
              divisions: 10,
              label: _speechRate.toStringAsFixed(2),
              onChanged: _busy
                  ? null
                  : (value) {
                      setState(() {
                        _speechRate = value;
                      });
                    },
            ),
            const Text(
              'القيمة الأقل تعني قراءة أبطأ.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextCard(int textLength) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'النص المستخرج',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 17,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _textController,
              minLines: 6,
              maxLines: 14,
              textDirection: TextDirection.rtl,
              textAlign: TextAlign.right,
              onChanged: (_) {
                setState(() {
                  _savedPath = null;
                });
              },
              decoration: InputDecoration(
                hintText: 'سيظهر النص هنا بعد اختيار الملف...',
                alignLabelWithHint: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'عدد الأحرف: $textLength',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'الحالة',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(_status),
            if (_busy) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (_savedPath != null) ...[
              const SizedBox(height: 10),
              const Text('مكان حفظ الملف:'),
              SelectableText(
                _savedPath!,
                textDirection: TextDirection.ltr,
              ),
            ],
            const SizedBox(height: 6),
            Text(
              _ttsReady
                  ? 'محرك النطق العربي: متاح'
                  : 'محرك النطق العربي: غير مؤكد التوفر',
              style: TextStyle(
                fontSize: 12,
                color: _ttsReady
                    ? Colors.green.shade800
                    : Colors.orange.shade900,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls() {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 14),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          top: BorderSide(color: Color(0xFFE3E9E4)),
        ),
      ),
      child: Row(
        children: [
          _control(
            icon: Icons.play_arrow_rounded,
            label: 'قراءة',
            onPressed:
                _busy || _isPlaying ? null : _startReading,
          ),
          _control(
            icon: _isPaused
                ? Icons.play_arrow_rounded
                : Icons.pause_rounded,
            label: _isPaused ? 'استئناف' : 'إيقاف مؤقت',
            onPressed: _busy || !_isPlaying
                ? null
                : (_isPaused
                    ? _resumeReading
                    : _pauseReading),
          ),
          _control(
            icon: Icons.stop_rounded,
            label: 'إيقاف',
            onPressed:
                _busy || !_isPlaying ? null : _stopSpeech,
          ),
          _control(
            icon: Icons.audio_file_rounded,
            label: 'حفظ الصوت',
            onPressed: _busy ? null : _saveAudio,
          ),
        ],
      ),
    );
  }

  Widget _control({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton.filledTonal(
              onPressed: onPressed,
              icon: Icon(icon),
            ),
            Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 10.5),
            ),
          ],
        ),
      ),
    );
  }
}