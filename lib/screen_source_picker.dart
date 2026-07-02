import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Dialog that lists available screen/window capture sources and lets the
/// user pick one. Mirrors flutter_webrtc's own example picker (which lives
/// under example/lib and isn't part of the published package API), adapted
/// to this app's needs.
class ScreenSourcePicker extends StatefulWidget {
  const ScreenSourcePicker({super.key});

  @override
  State<ScreenSourcePicker> createState() => _ScreenSourcePickerState();
}

class _ScreenSourcePickerState extends State<ScreenSourcePicker> {
  final Map<String, DesktopCapturerSource> _sources = {};
  final List<StreamSubscription> _subscriptions = [];
  SourceType _sourceType = SourceType.Screen;
  DesktopCapturerSource? _selected;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _subscriptions.add(
      desktopCapturer.onAdded.stream.listen((source) {
        setState(() => _sources[source.id] = source);
      }),
    );
    _subscriptions.add(
      desktopCapturer.onRemoved.stream.listen((source) {
        setState(() => _sources.remove(source.id));
      }),
    );
    _subscriptions.add(
      desktopCapturer.onThumbnailChanged.stream.listen((_) {
        setState(() {});
      }),
    );
    _loadSources();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    for (final s in _subscriptions) {
      s.cancel();
    }
    super.dispose();
  }

  Future<void> _loadSources() async {
    final sources = await desktopCapturer.getSources(types: [_sourceType]);
    setState(() {
      _sources
        ..clear()
        ..addEntries(sources.map((s) => MapEntry(s.id, s)));
    });
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      desktopCapturer.updateSources(types: [_sourceType]);
    });
  }

  void _selectType(SourceType type) {
    if (type == _sourceType) return;
    setState(() {
      _sourceType = type;
      _selected = null;
    });
    _loadSources();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 640,
        height: 480,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Text(
                    'Choose what to share',
                    style: TextStyle(fontSize: 16),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context, null),
                  ),
                ],
              ),
            ),
            SegmentedButton<SourceType>(
              segments: const [
                ButtonSegment(value: SourceType.Screen, label: Text('Screen')),
                ButtonSegment(value: SourceType.Window, label: Text('Window')),
              ],
              selected: {_sourceType},
              onSelectionChanged: (s) => _selectType(s.first),
            ),
            Expanded(
              child: _sources.isEmpty
                  ? const Center(child: Text('No sources found.'))
                  : GridView.count(
                      padding: const EdgeInsets.all(12),
                      crossAxisCount: _sourceType == SourceType.Screen ? 2 : 3,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      children: _sources.values
                          .map(
                            (source) => _SourceThumbnail(
                              source: source,
                              selected: _selected?.id == source.id,
                              onTap: () => setState(() => _selected = source),
                            ),
                          )
                          .toList(),
                    ),
            ),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, null),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: _selected == null
                      ? null
                      : () => Navigator.pop(context, _selected),
                  child: const Text('Share'),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _SourceThumbnail extends StatefulWidget {
  const _SourceThumbnail({
    required this.source,
    required this.selected,
    required this.onTap,
  });

  final DesktopCapturerSource source;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SourceThumbnail> createState() => _SourceThumbnailState();
}

class _SourceThumbnailState extends State<_SourceThumbnail> {
  StreamSubscription<Uint8List>? _subscription;
  Uint8List? _thumbnail;

  @override
  void initState() {
    super.initState();
    _thumbnail = widget.source.thumbnail;
    _subscription = widget.source.onThumbnailChanged.stream.listen((bytes) {
      setState(() => _thumbnail = bytes);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: widget.onTap,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: widget.selected ? Colors.blueAccent : Colors.black26,
            width: widget.selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Expanded(
              child: _thumbnail != null
                  ? Image.memory(_thumbnail!, gaplessPlayback: true)
                  : const Center(child: CircularProgressIndicator()),
            ),
            Padding(
              padding: const EdgeInsets.all(4),
              child: Text(
                widget.source.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
