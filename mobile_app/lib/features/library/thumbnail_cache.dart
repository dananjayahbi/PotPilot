// Doc 45: in-memory thumbnail cache + the card tile that renders one.
//
// `LIST_MEDIA` items carry an optional `thumbnail_b64` JPEG (≤ 15 KB, 320 px,
// per the frozen wire schema). Decoded bytes are memoized per file path in a
// bounded insertion-ordered map (LRU-ish: a re-read moves the entry to the
// end, the oldest entries evict first). While the PC is still generating a
// frame — or ffmpeg is unavailable — the tile shows a quiet placeholder; a
// malformed base64 payload or a failed image decode falls back to the same
// placeholder (never a broken-image glyph).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/theme/oled_theme.dart';

/// Upper bound of cached thumbnails (~128 × 15 KB ≈ 2 MB of raw JPEG).
const int kLibraryThumbnailCacheCapacity = 128;

/// Decoded ceiling for one thumbnail; anything larger is corrupt by contract.
const int kLibraryThumbnailMaxBytes = 64 * 1024;

class _ThumbEntry {
  const _ThumbEntry(this.source, this.bytes);

  /// The exact base64 payload this frame was decoded from.
  final String source;

  final Uint8List bytes;
}

/// App-scoped LRU-ish byte cache for decoded library thumbnails.
class LibraryThumbnailCache {
  LibraryThumbnailCache({this.capacity = kLibraryThumbnailCacheCapacity});

  /// Maximum retained entries; the oldest are evicted first.
  final int capacity;

  final Map<String, _ThumbEntry> _entries = <String, _ThumbEntry>{};

  /// Number of retained entries (tests).
  int get length => _entries.length;

  /// Resolves [path]'s frame for the incoming [thumbnailB64]:
  ///
  /// * matching cached frame → cached bytes (no decode);
  /// * `null` payload → cached bytes if any (PC omitted it this round), else null;
  /// * new valid payload → decode, store, return;
  /// * malformed payload → cached bytes if any, else null (broken-thumb fallback).
  Uint8List? thumbnailBytes(String path, String? thumbnailB64) {
    final _ThumbEntry? hit = _entries[path];
    if (thumbnailB64 == null || thumbnailB64.isEmpty) {
      return hit?.bytes;
    }
    if (hit != null && hit.source == thumbnailB64) {
      _touch(path, hit); // re-read → newest
      return hit.bytes;
    }
    final Uint8List? decoded = _tryDecode(thumbnailB64);
    if (decoded == null) {
      return hit?.bytes; // keep the last good frame over a broken one
    }
    _entries[path] = _ThumbEntry(thumbnailB64, decoded);
    if (_entries.length > capacity) {
      _entries.remove(_entries.keys.first); // insertion-order LRU eviction
    }
    return decoded;
  }

  void _touch(String path, _ThumbEntry entry) {
    _entries.remove(path);
    _entries[path] = entry;
  }

  static Uint8List? _tryDecode(String base64Payload) {
    try {
      final Uint8List bytes = base64.decode(base64Payload);
      if (bytes.isEmpty || bytes.length > kLibraryThumbnailMaxBytes) {
        return null; // contract breach → treat as broken
      }
      return bytes;
    } on FormatException {
      return null;
    }
  }

  /// Drops everything (tests / low-memory hooks).
  void clear() => _entries.clear();
}

/// App-wide cache instance used by [MovieThumbnail].
final LibraryThumbnailCache libraryThumbnailCache = LibraryThumbnailCache();

/// One card thumbnail: decoded frame, or a placeholder while the PC has not
/// produced one yet, or a fallback when decoding fails.
class MovieThumbnail extends StatelessWidget {
  const MovieThumbnail({
    super.key,
    required this.path,
    required this.thumbnailB64,
    this.iconSize = 26,
  });

  /// Absolute PC path — cache key and widget key namespace.
  final String path;

  /// Optional wire payload from `LIST_MEDIA` (null → placeholder state).
  final String? thumbnailB64;

  /// Placeholder glyph size.
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final Uint8List? bytes = libraryThumbnailCache.thumbnailBytes(
      path,
      thumbnailB64,
    );
    if (bytes == null) {
      return _placeholder();
    }
    return Image.memory(
      bytes,
      key: ValueKey<String>('library_thumb_$path'),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
          _placeholder(),
    );
  }

  Widget _placeholder() {
    return Container(
      key: ValueKey<String>('library_thumb_placeholder_$path'),
      color: AppColors.surfaceHigh,
      alignment: Alignment.center,
      child: Icon(
        Icons.movie_outlined,
        size: iconSize,
        color: AppColors.textSecondary,
      ),
    );
  }
}
