// Doc 45: relative-path sectioning for the library grid.
//
// The notifier keeps its flat, sorted, filtered `List<MovieEntry>` (that
// contract is load-bearing for search/sort tests); the screen groups that
// list for display only: one section per distinct parent directory, headed by
// the directory path *relative to the deepest common ancestor* of every
// listed entry — so `D:\Movies\Action\1995\Heat.mkv` renders under
// "Action\1995", and files sharing the ancestor itself render under its name.
// Sections are ordered case-insensitively; entries keep the incoming sort.

import 'movie_browser.dart';

/// One display section: a folder heading and the entries under it.
class LibrarySection {
  const LibrarySection({required this.heading, required this.entries});

  /// Relative directory path (or the common root's name for root-level files).
  final String heading;

  /// Entries in this section, in the incoming (already sorted) order.
  final List<MovieEntry> entries;
}

/// Directory portion of a Windows-style path (`D:\a\f.mkv` → `D:\a`).
String libraryDirOf(String path) {
  final int cut = path.lastIndexOf(RegExp(r'[\\/]'));
  return cut > 0 ? path.substring(0, cut) : path;
}

/// Groups [entries] into heading-ordered sections (see file doc). An empty
/// input yields an empty list; a single directory yields one section headed
/// by that directory's name.
List<LibrarySection> buildLibrarySections(List<MovieEntry> entries) {
  if (entries.isEmpty) {
    return const <LibrarySection>[];
  }

  // dir (canonical key) → entries, preserving incoming order within a dir.
  final Map<String, List<MovieEntry>> byDir = <String, List<MovieEntry>>{};
  final Map<String, String> displayDir = <String, String>{};
  for (final MovieEntry entry in entries) {
    final String dir = libraryDirOf(entry.path);
    final String key = dir.toLowerCase();
    (byDir[key] ??= <MovieEntry>[]).add(entry);
    displayDir[key] = dir;
  }

  final List<String> common = _commonPrefixSegments(
    displayDir.values.map(_segmentsOf),
  );

  final List<_SectionDraft> drafts = <_SectionDraft>[
    for (final MapEntry<String, List<MovieEntry>> group in byDir.entries)
      _SectionDraft(
        heading: _headingFor(displayDir[group.key]!, common),
        entries: group.value,
      ),
  ];
  drafts.sort(
    (_SectionDraft a, _SectionDraft b) =>
        a.heading.toLowerCase().compareTo(b.heading.toLowerCase()),
  );
  return <LibrarySection>[
    for (final _SectionDraft draft in drafts)
      LibrarySection(heading: draft.heading, entries: draft.entries),
  ];
}

class _SectionDraft {
  const _SectionDraft({required this.heading, required this.entries});

  final String heading;
  final List<MovieEntry> entries;
}

List<String> _segmentsOf(String dir) => dir.split(RegExp(r'[\\/]+'))
    .where((String segment) => segment.isNotEmpty)
    .toList();

/// Longest shared leading segment list across every directory.
List<String> _commonPrefixSegments(Iterable<List<String>> groups) {
  List<String>? common;
  for (final List<String> segments in groups) {
    if (common == null) {
      common = <String>[...segments];
      continue;
    }
    int shared = 0;
    while (shared < common.length &&
        shared < segments.length &&
        common[shared].toLowerCase() == segments[shared].toLowerCase()) {
      shared++;
    }
    common = common.sublist(0, shared);
    if (common.isEmpty) {
      break;
    }
  }
  return common ?? const <String>[];
}

String _headingFor(String dir, List<String> common) {
  final List<String> segments = _segmentsOf(dir);
  int offset = 0;
  while (offset < common.length &&
      offset < segments.length &&
      segments[offset].toLowerCase() == common[offset].toLowerCase()) {
    offset++;
  }
  final List<String> relative = segments.sublist(offset);
  if (relative.isNotEmpty) {
    return relative.join('\\');
  }
  // The directory IS the common ancestor: fall back to its own name.
  return segments.isNotEmpty ? segments.last : dir;
}
