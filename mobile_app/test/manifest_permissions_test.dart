import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Manifest suite (Doc 05 section 9): the main AndroidManifest declares
/// exactly the section 5.2 permission strings - no more, no fewer.
///
/// Doc 05 section 5.2 lists six feature rows; the Wi-Fi row declares two
/// permission strings, so the exact expected set is seven strings.
void main() {
  const Set<String> expected = <String>{
    'android.permission.INTERNET',
    'android.permission.ACCESS_NETWORK_STATE',
    'android.permission.ACCESS_WIFI_STATE',
    'android.permission.CHANGE_WIFI_MULTICAST_STATE',
    'android.permission.CAMERA',
    'android.permission.READ_PHONE_STATE',
    'android.permission.VIBRATE',
  };

  File resolveManifest() {
    final File direct =
        File('android/app/src/main/AndroidManifest.xml');
    if (direct.existsSync()) {
      return direct;
    }
    final File nested =
        File('mobile_app/android/app/src/main/AndroidManifest.xml');
    if (nested.existsSync()) {
      return nested;
    }
    return fail(
      'AndroidManifest.xml not found from ${Directory.current.path}',
    );
  }

  test('AndroidManifest declares exactly the section 5.2 permissions',
      () {
    final String xml = resolveManifest().readAsStringSync();
    final RegExp permissionPattern = RegExp(
      r'<uses-permission[^>]*android:name="([^"]+)"',
    );
    final List<String> declared = permissionPattern
        .allMatches(xml)
        .map((Match match) => match.group(1)!)
        .toList();

    expect(
      declared.toSet(),
      expected,
      reason: 'Manifest must declare exactly the Doc 05 section 5.2 '
          'permissions',
    );
    expect(
      declared.length,
      expected.length,
      reason: 'No permission may be declared twice',
    );
  });
}
