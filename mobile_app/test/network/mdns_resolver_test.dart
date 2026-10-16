// Doc 32 §9 — resolver contract tests against a fake MdnsBackend.
// Hand-built DNS-SD datagrams exercise the in-file PTR/SRV/TXT/A codec;
// no sockets, no MulticastLock, no zeroconf.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/network/pairing_scanner.dart';

const String _service = '_potpilot._tcp.local.';
const String _instance = 'bedroom-pc._potpilot._tcp.local.';
const String _target = 'bedroom-pc.local.';

// ---------------------------------------------------------------------------
// Test-side DNS-SD packet builder (mirrors what a zeroconf agent answers)
// ---------------------------------------------------------------------------

List<int> _encName(String name) {
  final List<int> out = <int>[];
  for (final String label in name.split('.')) {
    if (label.isEmpty) {
      continue;
    }
    out.add(label.length);
    out.addAll(label.codeUnits);
  }
  out.add(0);
  return out;
}

List<int> _buildResponse({
  String ptrOwner = _service,
  String instance = _instance,
  String target = _target,
  String ip = '192.168.1.42',
  int udpPort = 50505,
  int wsPort = 50506,
  bool includePtr = true,
  bool includeA = true,
}) {
  final List<int> answers = <int>[];
  int ancount = 0;
  void addRecord(String owner, int type, List<int> rdata) {
    answers.addAll(_encName(owner));
    answers
      ..add(type >> 8)
      ..add(type & 0xFF)
      ..addAll(const <int>[0x00, 0x01]) // class IN
      ..addAll(const <int>[0, 0, 0, 120]) // TTL
      ..add(rdata.length >> 8)
      ..add(rdata.length & 0xFF)
      ..addAll(rdata);
    ancount++;
  }

  if (includePtr) {
    addRecord(ptrOwner, 12, _encName(instance));
  }
  final List<int> txt = <int>[];
  for (final String entry
      in <String>['udp=$udpPort', 'ws=$wsPort', 'ver=1']) {
    txt.add(entry.length);
    txt.addAll(entry.codeUnits);
  }
  addRecord(instance, 16, txt);
  final List<int> srv = <int>[
    0, 0, // priority
    0, 0, // weight
    (wsPort >> 8) & 0xFF,
    wsPort & 0xFF,
    ..._encName(target),
  ];
  addRecord(instance, 33, srv);
  if (includeA) {
    final List<int> octets = ip
        .split('.')
        .map((String part) => int.parse(part))
        .toList(growable: false);
    addRecord(target, 1, octets);
  }
  return <int>[
    0, 0, // id
    0x84, 0x00, // flags: response
    0, 0, // qdcount
    (ancount >> 8) & 0xFF,
    ancount & 0xFF,
    0, 0, // nscount
    0, 0, // arcount
    ...answers,
  ];
}

class _FakeBackend implements MdnsBackend {
  int openCalls = 0;
  int closeCalls = 0;
  final List<List<int>> sent = <List<int>>[];
  final StreamController<List<int>> out =
      StreamController<List<int>>.broadcast();

  @override
  Future<void> open() async => openCalls++;

  @override
  Future<void> close() async => closeCalls++;

  @override
  Future<void> send(List<int> query) async => sent.add(query);

  @override
  Stream<List<int>> get responses => out.stream;
}

Future<void> pump0() => Future<void>.delayed(Duration.zero);

void main() {
  group('DNS-SD codec', () {
    test('buildDnsSdQuery is one PTR/IN question for the frozen type', () {
      final List<int> query = buildDnsSdQuery(_service);
      expect(query.sublist(0, 12), <int>[0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
      expect(query.sublist(12), <int>[
        ..._encName(_service),
        0, 12, // type PTR
        0, 1, // class IN
      ]);
    });

    test('full PTR/SRV/TXT/A response decodes to one trusted agent', () {
      final List<MdnsAgentInfo> found =
          parseMdnsResponse(_buildResponse(ip: '192.168.1.42'));
      expect(found, hasLength(1));
      final MdnsAgentInfo info = found.single;
      expect(info.serviceName, 'bedroom-pc');
      expect(info.hostname, 'bedroom-pc');
      expect(info.ipv4, '192.168.1.42');
      expect(info.udpPort, 50505);
      expect(info.wsPort, 50506);
      expect(info.trusted, isTrue);
    });

    test('TXT port mismatch marks the advertisement untrusted', () {
      final List<MdnsAgentInfo> found = parseMdnsResponse(
        _buildResponse(udpPort: 1234, wsPort: 8080),
      );
      expect(found.single.udpPort, 1234);
      expect(found.single.wsPort, 8080);
      expect(found.single.trusted, isFalse);
    });

    test('cross-packet A record resolves an earlier PTR/SRV (addressCache)',
        () {
      final Map<String, String> cache = <String, String>{};
      // Packet 1: A only → address cached, but no instance advertisement
      // yet → nothing emitted.
      expect(
        parseMdnsResponse(
          _buildResponse(includePtr: false),
          addressCache: cache,
        ),
        isEmpty,
      );
      // Packet 2: PTR/SRV/TXT without A → resolves via the cached address.
      final List<MdnsAgentInfo> found = parseMdnsResponse(
        _buildResponse(includeA: false),
        addressCache: cache,
      );
      expect(found.single.ipv4, '192.168.1.42');
    });

    test('foreign service type and garbage never crash or leak', () {
      // Another service's advertisement (PTR owner differs) → filtered out.
      expect(
        parseMdnsResponse(
          _buildResponse(ptrOwner: '_googlecast._tcp.local.'),
        ),
        isEmpty,
      );
      expect(parseMdnsResponse(<int>[1, 2, 3]), isEmpty);
      expect(parseMdnsResponse(<int>[]), isEmpty);
      // Truncated mid-record → tolerated, no throw.
      final List<int> full = _buildResponse();
      expect(parseMdnsResponse(full.sublist(0, full.length ~/ 2)), isEmpty);
    });
  });

  group('MdnsAgentResolver (fake backend)', () {
    late _FakeBackend backend;
    late MdnsAgentResolver resolver;

    setUp(() {
      backend = _FakeBackend();
      resolver = MdnsAgentResolver(backend: backend);
    });

    tearDown(() async {
      await resolver.stop();
      await backend.out.close();
    });

    Future<void> startAndSubscribe(List<MdnsAgentInfo> events) async {
      final StreamSubscription<MdnsAgentInfo> sub =
          resolver.watchAgents().listen(events.add);
      await resolver.start();
      addTearDown(sub.cancel);
    }

    test('start is idempotent: one open, one browse query', () async {
      await resolver.start();
      await resolver.start();
      expect(backend.openCalls, 1);
      expect(backend.sent, hasLength(1));
      expect(backend.sent.single, buildDnsSdQuery(_service));
    });

    test('watchAgents: add, dedup, change — filtered to the frozen type',
        () async {
      final List<MdnsAgentInfo> events = <MdnsAgentInfo>[];
      await startAndSubscribe(events);

      backend.out.add(_buildResponse(ip: '192.168.1.42'));
      await pump0();
      expect(events, hasLength(1));
      expect(events.single.ipv4, '192.168.1.42');

      // Identical datagram again → suppressed (equal-state rule).
      backend.out.add(_buildResponse(ip: '192.168.1.42'));
      await pump0();
      expect(events, hasLength(1));

      // DHCP change (new A) → one new emission.
      backend.out.add(_buildResponse(ip: '192.168.1.77'));
      await pump0();
      expect(events, hasLength(2));
      expect(events.last.ipv4, '192.168.1.77');

      // Foreign service type → ignored.
      backend.out
          .add(_buildResponse(ptrOwner: '_googlecast._tcp.local.'));
      await pump0();
      expect(events, hasLength(2));
    });

    test('resolveHost returns the known IPv4 without waiting', () async {
      await resolver.start();
      backend.out.add(_buildResponse(ip: '10.1.2.3'));
      await pump0();
      final String? ip = await resolver.resolveHost(
        timeout: const Duration(milliseconds: 50),
      );
      expect(ip, '10.1.2.3');
    });

    test('resolveHost → null within the deadline when nothing advertises',
        () async {
      final Stopwatch watch = Stopwatch()..start();
      final String? ip = await resolver.resolveHost(
        timeout: const Duration(milliseconds: 60),
      );
      watch.stop();
      expect(ip, isNull);
      expect(
        watch.elapsedMilliseconds,
        lessThan(3000),
        reason: 'must fail fast, not the full 3 s default',
      );
    });

    test('stop releases the backend; a later start reopens it', () async {
      await resolver.start();
      expect(backend.openCalls, 1);
      await resolver.stop();
      expect(backend.closeCalls, 1);
      await resolver.start();
      expect(backend.openCalls, 2);
    });
  });
}
